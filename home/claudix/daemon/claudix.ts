#!/usr/bin/env bun
// claudix daemon: a review sidecar owned by a Claude Code session.
//
//   - Helix attaches to it as a language server (via shim.ts over a unix
//     socket). Review threads are rendered as diagnostics, read in full
//     through hover, and managed through code actions / workspace commands.
//   - Claude watches it through a WebSocket (the Monitor tool) and answers
//     threads through a small HTTP API.
//
// Threads live as long as this process, i.e. as long as the Claude session.
// No dependencies beyond Bun: see lsp.ts.

import * as net from "node:net";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import { Connection, TextDocument, DiagnosticSeverity, TextDocumentSyncKind, type Range, type Position, type ContentChange } from "./lsp";

// ---------------------------------------------------------------- args/state

const argv = process.argv.slice(2);
const args: Record<string, string> = {};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i]!;
  if (!a.startsWith("--")) continue;
  const next = argv[i + 1];
  if (next === undefined || next.startsWith("--")) args[a.slice(2)] = "true";
  else { args[a.slice(2)] = next; i++; }
}

const PROJECT = path.resolve(args.project ?? process.cwd());
const RUNTIME_DIR = path.join(process.env.XDG_RUNTIME_DIR ?? os.tmpdir(), "claudix");
fs.mkdirSync(RUNTIME_DIR, { recursive: true });
const KEY = Bun.hash(PROJECT).toString(36);
const SOCK = path.join(RUNTIME_DIR, `${KEY}.sock`);
const STATE_FILE = path.join(RUNTIME_DIR, `${KEY}.json`);

type Kind = "question" | "change";
type Status = "open" | "answered" | "applied" | "declined" | "resolved";
interface Message { role: "you" | "claude"; text: string; at: number; from?: string }
interface Thread {
  id: string;
  kind: Kind;
  uri: string;
  range: Range;          // tracked through edits
  anchorText: string;    // the originally selected code
  outdated: boolean;     // the anchored code was edited since
  status: Status;
  messages: Message[];
  createdAt: number;
}
interface Diagnostic { range: Range; severity: number; source: string; code: string; message: string; data?: any }

const threads = new Map<string, Thread>();
let nextId = 1;

// ------------------------------------------------------------------- helpers

function relPath(uri: string) {
  try { return path.relative(PROJECT, fileURLToPath(uri)); } catch { return uri; }
}

function charOffsetToPosition(text: string, charIndex: number): Position {
  // Helix char indices count Unicode scalar values; LSP wants UTF-16 columns.
  let line = 0, character = 0, i = 0;
  for (const ch of text) {
    if (i >= charIndex) break;
    if (ch === "\n") { line++; character = 0; } else { character += ch.length; }
    i++;
  }
  return { line, character };
}

function cmp(a: Position, b: Position) { return a.line - b.line || a.character - b.character; }
function contains(r: Range, p: Position) { return cmp(r.start, p) <= 0 && cmp(p, r.end) <= 0; }
function overlaps(a: Range, b: Range) { return cmp(a.start, b.end) <= 0 && cmp(b.start, a.end) <= 0; }

function remapRange(r: Range, change: { range: Range; text: string }): { range: Range; touched: boolean } {
  const cr = change.range;
  const newlines = change.text.split("\n");
  const lineDelta = newlines.length - 1 - (cr.end.line - cr.start.line);
  const lastLen = (newlines[newlines.length - 1] ?? "").length;
  const endCharAfter = newlines.length === 1 ? cr.start.character + lastLen : lastLen;
  const shift = (p: Position): Position => {
    if (cmp(p, cr.end) < 0) return p;                           // before the edit
    if (p.line === cr.end.line) return { line: p.line + lineDelta, character: p.character - cr.end.character + endCharAfter };
    return { line: p.line + lineDelta, character: p.character };
  };
  if (cmp(cr.end, r.start) <= 0) return { range: { start: shift(r.start), end: shift(r.end) }, touched: false };
  if (cmp(r.end, cr.start) < 0) return { range: r, touched: false };
  // overlap: clamp to the edit start, mark outdated
  const start = cmp(r.start, cr.start) < 0 ? r.start : cr.start;
  const end = cmp(r.end, cr.end) > 0 ? shift(r.end) : { line: cr.start.line + newlines.length - 1, character: endCharAfter };
  return { range: { start, end }, touched: true };
}

function severity(t: Thread): number {
  switch (t.status) {
    case "open": return t.kind === "change" ? DiagnosticSeverity.Warning : DiagnosticSeverity.Information;
    case "declined": return DiagnosticSeverity.Warning;
    default: return DiagnosticSeverity.Hint;
  }
}

// Inline marker: short on purpose. The full thread is one hover away.
function marker(t: Thread) {
  const last = t.messages[t.messages.length - 1];
  const by = last?.role === "claude" && last.from ? ` by ${last.from}` : "";
  switch (t.status) {
    case "open": return t.kind === "change" ? `! ${t.id} · change pending` : `? ${t.id} · pending`;
    case "answered": return `✓ ${t.id} · replied${by}`;
    case "applied": return `✓ ${t.id} · applied${by}`;
    case "declined": return `✗ ${t.id} · declined${by}`;
    default: return `· ${t.id}`;
  }
}

function firstLine(s: string): string { return s.split("\n")[0] ?? ""; }
function headText(t: Thread) { return firstLine(t.messages[0]?.text ?? ""); }

// Helix underlines every diagnostic by severity and offers no per-server
// styling, so by default the diagnostic is published as a zero-width range
// at the thread start: gutter mark and inline text stay, the squiggle goes.
// Hover, code actions and the picker use the thread range, not this one.
// Pass --underline to publish the full range instead.
function diagnosticFor(t: Thread): Diagnostic {
  const msg = marker(t) + (t.outdated ? " · code changed" : "");
  const range = args.underline ? t.range : { start: t.range.start, end: t.range.start };
  return { range, severity: severity(t), source: "claudix", code: t.id, message: msg, data: { thread: t.id } };
}

function threadMarkdown(t: Thread) {
  const lines = [`**${t.id}** · ${t.kind} · ${t.status}${t.outdated ? " · code changed since" : ""}`, ""];
  for (const m of t.messages) lines.push(`**${m.role === "you" ? "you" : m.from ? `claude (${m.from})` : "claude"}:** ${m.text}`, "");
  return lines.join("\n");
}

function safeRead(uri: string) { try { return fs.readFileSync(fileURLToPath(uri), "utf8"); } catch { return ""; } }

function snippet(uri: string, range: Range) {
  const doc = openDocs.get(uri);
  const text = doc?.getText() ?? safeRead(uri);
  if (!text) return "";
  return text.split("\n").slice(range.start.line, range.end.line + 1).join("\n");
}

// ------------------------------------------------------------- event fan-out

type EventPayload =
  | { type: "comment"; thread: Thread; text: string; followup: boolean }
  | { type: "resolved"; thread: Thread }
  | { type: "hello"; project: string; threads: number };

const wsClients = new Set<any>();

function describeForClaude(ev: EventPayload): string {
  if (ev.type === "hello") return `[claudix] attached to ${ev.project}, ${ev.threads} thread(s) open`;
  if (ev.type === "resolved") return `[claudix ${ev.thread.id}] resolved by the reviewer`;
  const t = ev.thread;
  const where = `${relPath(t.uri)}:${t.range.start.line + 1}-${t.range.end.line + 1}`;
  const head = `[claudix ${t.id}] ${ev.followup ? "follow-up on" : "new"} ${t.kind} at ${where}`;
  // Cap quoted code so a whole-file selection cannot push the comment past
  // the Monitor notification limit; Claude can read the file itself.
  const MAX_LINES = 40;
  const all = snippet(t.uri, t.range).split("\n");
  const code = all.length > MAX_LINES ? [...all.slice(0, MAX_LINES), `… (${all.length - MAX_LINES} more lines, see ${where})`].join("\n") : all.join("\n");
  const history = ev.followup
    ? t.messages.slice(0, -1).map((m) => `  ${m.role}: ${firstLine(m.text)}${m.text.includes("\n") ? " …" : ""}`).join("\n")
    : "";
  const ask = t.kind === "change"
    ? "Make this change now if it is sound, then reply with status applied (or declined with why)."
    : "Answer in the thread with reply.";
  return [
    head,
    code ? "```\n" + code + "\n```" : "",
    history ? "thread so far:\n" + history : "",
    `> ${ev.text}`,
    `${ask}  →  bash ${import.meta.dir}/reply.sh ${httpPort} ${t.id} answered|applied|declined '...'`,
  ].filter(Boolean).join("\n");
}

function emit(ev: EventPayload) {
  const text = describeForClaude(ev);
  for (const ws of wsClients) { try { ws.send(text); } catch {} }
  process.stdout.write(JSON.stringify({ at: Date.now(), ...ev }) + "\n");
}

// ---------------------------------------------------------- LSP connections

const openDocs = new Map<string, TextDocument>();   // latest text across clients
// Each editor connection and the documents it has open. Helix may run
// several instances of this server (one per workspace root), all attached to
// the same daemon; diagnostics for a file go only to the instances that
// opened it, or Helix shows every thread once per instance.
const lspClients = new Map<Connection, Set<string>>();

function publishAll(uri?: string) {
  const uris = uri ? [uri] : new Set([...threads.values()].map((t) => t.uri));
  for (const u of uris) {
    const diagnostics = [...threads.values()].filter((t) => t.uri === u && t.status !== "resolved").map(diagnosticFor);
    for (const [c, open] of lspClients) if (open.has(u)) c.sendNotification("textDocument/publishDiagnostics", { uri: u, diagnostics });
  }
}

function threadAt(uri: string, pos: Position): Thread | undefined {
  return [...threads.values()]
    .filter((t) => t.uri === uri && t.status !== "resolved" && contains(t.range, pos))
    .sort((a, b) => b.createdAt - a.createdAt)[0];
}

function addComment(uri: string, range: Range, text: string, kind: Kind, forceNew: boolean) {
  const empty = cmp(range.start, range.end) >= 0 ||
    (range.start.line === range.end.line && range.end.character - range.start.character <= 1);
  const existing = !forceNew && empty ? threadAt(uri, range.start) : undefined;
  if (existing) {
    existing.messages.push({ role: "you", text, at: Date.now() });
    if (kind === "change") existing.kind = "change";
    existing.status = "open";
    publishAll(uri);
    emit({ type: "comment", thread: existing, text, followup: true });
    return existing;
  }
  // a bare cursor with no thread: comment on the whole line
  if (empty) {
    const doc = openDocs.get(uri);
    const lineText = doc?.getText({ start: { line: range.start.line, character: 0 }, end: { line: range.start.line + 1, character: 0 } }) ?? "";
    range = { start: { line: range.start.line, character: 0 }, end: { line: range.start.line, character: Math.max(0, lineText.replace(/\n$/, "").length) } };
  }
  const t: Thread = {
    id: `t${nextId++}`, kind, uri, range, anchorText: snippet(uri, range), outdated: false,
    status: "open", messages: [{ role: "you", text, at: Date.now() }], createdAt: Date.now(),
  };
  threads.set(t.id, t);
  publishAll(uri);
  emit({ type: "comment", thread: t, text, followup: false });
  return t;
}

// After a reload or an outside edit, try to find a thread's original code
// again and re-anchor it there (like review comments surviving a rebase).
function reanchor(uri: string) {
  const doc = openDocs.get(uri);
  if (!doc) return false;
  const text = doc.getText();
  let changed = false;
  for (const t of threads.values()) {
    if (t.uri !== uri || t.status === "resolved" || !t.anchorText.trim()) continue;
    if (snippet(uri, t.range) === t.anchorText) { if (t.outdated) { t.outdated = false; changed = true; } continue; }
    const first = text.indexOf(t.anchorText);
    if (first < 0 || text.indexOf(t.anchorText, first + 1) >= 0) continue;   // missing or ambiguous
    t.range = { start: doc.positionAt(first), end: doc.positionAt(first + t.anchorText.length) };
    t.outdated = false;
    changed = true;
  }
  return changed;
}

function resolveThread(t: Thread) {
  t.status = "resolved";
  publishAll(t.uri);
  emit({ type: "resolved", thread: t });
}

function serveLsp(socket: net.Socket) {
  const c = new Connection(socket);
  const open = new Set<string>();
  lspClients.set(c, open);
  const drop = () => { lspClients.delete(c); c.dispose(); };

  c.onRequest("initialize", () => ({
    capabilities: {
      textDocumentSync: TextDocumentSyncKind.Incremental,
      hoverProvider: true,
      codeActionProvider: { codeActionKinds: ["quickfix"] },
      executeCommandProvider: { commands: ["claudix.comment", "claudix.resolve", "claudix.status"] },
    },
    serverInfo: { name: "claudix", version: "0.2.0" },
  }));
  c.onNotification("initialized", () => {});
  c.onRequest("shutdown", () => null);
  c.onNotification("exit", drop);

  c.onNotification("textDocument/didOpen", ({ textDocument: d }) => {
    open.add(d.uri);
    openDocs.set(d.uri, TextDocument.create(d.uri, d.languageId, d.version, d.text));
    watchFile(d.uri);
    reanchor(d.uri);
    publishAll(d.uri);
  });
  c.onNotification("textDocument/didClose", ({ textDocument: d }) => {
    open.delete(d.uri);
    if (![...lspClients.values()].some((o) => o.has(d.uri))) openDocs.delete(d.uri);
  });

  // Apply edits to our copy of the text and track thread anchors through them.
  c.onNotification("textDocument/didChange", (params) => {
    const uri: string = params.textDocument.uri;
    let anyTouched = false;
    for (const change of params.contentChanges as ContentChange[]) {
      if (!change.range) continue;
      for (const t of threads.values()) {
        if (t.uri !== uri || t.status === "resolved") continue;
        const { range, touched } = remapRange(t.range, change as { range: Range; text: string });
        t.range = range;
        if (touched) { t.outdated = true; anyTouched = true; }
      }
    }
    const doc = openDocs.get(uri);
    if (doc) doc.update(params.contentChanges, params.textDocument.version ?? doc.version + 1);
    if (anyTouched && reanchor(uri)) anyTouched = true;   // a reload may restore the original code
    if (anyTouched) publishAll(uri);
  });

  c.onRequest("textDocument/hover", ({ textDocument, position }) => {
    const t = threadAt(textDocument.uri, position);
    if (!t) return null;
    return { contents: { kind: "markdown", value: threadMarkdown(t) }, range: t.range };
  });

  c.onRequest("textDocument/codeAction", ({ textDocument, range }) => {
    const here = [...threads.values()].filter((t) => t.uri === textDocument.uri && t.status !== "resolved" && overlaps(t.range, range));
    return here.flatMap((t) => [
      { title: `claudix: resolve ${t.id} (${headText(t).slice(0, 40)})`, kind: "quickfix",
        command: { title: "resolve", command: "claudix.resolve", arguments: [t.id] } },
      ...(t.kind === "question" && t.status !== "open" ? [{
        title: `claudix: ask Claude to apply ${t.id} as a change`, kind: "quickfix",
        command: { title: "apply", command: "claudix.comment", arguments: [{ uri: t.uri, range: t.range, text: "Please apply this.", kind: "change", forceNew: false }] } }] : []),
    ]);
  });

  c.onRequest("workspace/executeCommand", ({ command, arguments: a = [] }): unknown => {
    switch (command) {
      case "claudix.comment": {
        const p = a[0] as { uri: string; from?: number; to?: number; range?: Range; text: string; kind?: Kind; forceNew?: boolean };
        const doc = openDocs.get(p.uri);
        let range = p.range;
        if (!range) {
          const text = doc?.getText() ?? safeRead(p.uri);
          const s = charOffsetToPosition(text, p.from ?? 0), e = charOffsetToPosition(text, p.to ?? p.from ?? 0);
          range = cmp(s, e) <= 0 ? { start: s, end: e } : { start: e, end: s };
        }
        // A line-wise Helix selection ends at column 0 of the next line; pull
        // the end back so the thread covers the selected lines only.
        if (range.end.character === 0 && range.end.line > range.start.line) {
          const prev = (doc?.getText() ?? safeRead(p.uri)).split("\n")[range.end.line - 1] ?? "";
          range = { start: range.start, end: { line: range.end.line - 1, character: prev.length } };
        }
        const t = addComment(p.uri, range, p.text, p.kind ?? "question", !!p.forceNew);
        return { id: t.id, followup: t.messages.length > 1 };
      }
      case "claudix.resolve": {
        const key = a[0];
        const t = typeof key === "string" ? threads.get(key)
          : threadAt(key.uri, charOffsetToPosition(openDocs.get(key.uri)?.getText() ?? "", key.at));
        if (t) resolveThread(t);
        return { resolved: t?.id ?? null };
      }
      case "claudix.status": return status();
    }
    return null;
  });

  c.onUnhandledRequest(() => null);   // anything else Helix asks gets an empty answer
  c.onClose(drop);
}

// -------------------------------------------------------- file-change reload

// Tell attached editors when a watched file changes on disk (Claude applying
// a change). inotify misses rename-style writes, so we also poll mtimes.
const watchedFiles = new Set<string>();
const fileStamps = new Map<string, string>();
const changeTimers = new Map<string, Timer>();
const watchedDirs = new Map<string, fs.FSWatcher>();

function stamp(file: string) { try { const st = fs.statSync(file); return `${st.mtimeMs}:${st.size}`; } catch { return "missing"; } }

function fileChanged(changed: string) {
  clearTimeout(changeTimers.get(changed));
  changeTimers.set(changed, setTimeout(() => {
    const u = pathToFileURL(changed).href;
    if (args.debug) process.stderr.write(`claudix: file changed ${changed} -> notifying ${lspClients.size} editor(s)\n`);
    for (const [c, open] of lspClients) if (open.has(u)) c.sendNotification("claudix/fileChanged", { uri: u });
  }, 200));
}

setInterval(() => {
  for (const file of watchedFiles) {
    const now = stamp(file);
    const before = fileStamps.get(file);
    fileStamps.set(file, now);
    if (before !== undefined && before !== now) fileChanged(file);
  }
}, 1000);

function watchFile(uri: string) {
  let file: string; try { file = fileURLToPath(uri); } catch { return; }
  watchedFiles.add(file);
  fileStamps.set(file, stamp(file));
  const dir = path.dirname(file);
  if (watchedDirs.has(dir)) return;
  try {
    const w = fs.watch(dir, (_event, name) => {
      if (!name) return;
      const changed = path.join(dir, String(name));
      if (!watchedFiles.has(changed)) return;
      const now = stamp(changed);
      if (fileStamps.get(changed) === now) return;
      fileStamps.set(changed, now);
      fileChanged(changed);
    });
    watchedDirs.set(dir, w);
  } catch (e: any) { process.stderr.write(`claudix: cannot watch ${dir}: ${e?.message}\n`); }
}

// ----------------------------------------------------------------- HTTP/WS

function status() {
  const all = [...threads.values()];
  const n = (s: Status) => all.filter((t) => t.status === s).length;
  return {
    summary: `${n("open")} open · ${n("answered")} answered · ${n("applied")} applied · ${n("declined")} declined`,
    project: PROJECT, open: n("open"), answered: n("answered"), applied: n("applied"), declined: n("declined"), resolved: n("resolved"),
    threads: all.filter((t) => t.status !== "resolved").sort((a, b) => a.createdAt - b.createdAt).map((t) => {
      const last = t.messages[t.messages.length - 1];
      let path = t.uri; try { path = fileURLToPath(t.uri); } catch {}
      return {
        id: t.id, kind: t.kind, status: t.status, outdated: t.outdated,
        file: relPath(t.uri), path, line: t.range.start.line + 1, col: t.range.start.character,
        head: headText(t), marker: marker(t),
        lineStr: String(t.range.start.line + 1), loc: `${relPath(t.uri)}:${t.range.start.line + 1}`,
        last: last ? `${last.role === "you" ? "you" : last.from ?? "claude"}: ${firstLine(last.text)}` : "",
        markdown: threadMarkdown(t),
        // plain-text version for the Steel picker preview
        preview: [`${t.id} · ${t.kind} · ${t.status}${t.outdated ? " · code changed since" : ""}`, "",
          ...t.messages.flatMap((m) => [`${m.role === "you" ? "you" : m.from ? `claude (${m.from})` : "claude"}: ${m.text}`, ""])],
      };
    }),
  };
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: Number(args.port ?? 0),
  idleTimeout: 0,
  async fetch(req, srv) {
    const url = new URL(req.url);
    if (url.pathname === "/events") {
      if (srv.upgrade(req)) return undefined as any;
      return new Response("websocket only", { status: 400 });
    }
    if (url.pathname === "/threads") return Response.json(status());
    if (url.pathname === "/thread" && url.searchParams.get("id")) {
      const t = threads.get(url.searchParams.get("id")!);
      return t ? Response.json({ ...t, file: relPath(t.uri), code: snippet(t.uri, t.range) }) : new Response("no such thread", { status: 404 });
    }
    if (req.method === "POST" && url.pathname === "/reply") {
      const b = (await req.json()) as { thread: string; text: string; status?: Status; from?: string };
      const t = threads.get(b.thread);
      if (!t) return new Response(`no such thread ${b.thread}`, { status: 404 });
      const from = typeof b.from === "string" && b.from.trim() ? b.from.trim().slice(0, 40) : undefined;
      t.messages.push({ role: "claude", text: b.text, at: Date.now(), from });
      t.status = b.status && ["answered", "applied", "declined"].includes(b.status) ? b.status : "answered";
      publishAll(t.uri);
      process.stdout.write(JSON.stringify({ at: Date.now(), type: "reply", thread: t }) + "\n");
      return Response.json({ ok: true, id: t.id, status: t.status });
    }
    if (req.method === "POST" && url.pathname === "/resolve") {
      const b = (await req.json()) as { thread: string };
      const t = threads.get(b.thread);
      if (!t) return new Response("no such thread", { status: 404 });
      resolveThread(t);
      return Response.json({ ok: true });
    }
    return new Response("claudix", { status: 200 });
  },
  websocket: {
    open(ws) { wsClients.add(ws); ws.send(describeForClaude({ type: "hello", project: PROJECT, threads: status().open })); },
    close(ws) { wsClients.delete(ws); },
    message() {},
  },
});
const httpPort = server.port!;

// ------------------------------------------------------------- unix socket

try { fs.unlinkSync(SOCK); } catch {}
const unix = net.createServer(serveLsp);
unix.on("error", (e) => process.stderr.write(`claudix: unix socket error ${e.message}\n`));
unix.listen(SOCK);

const state = { project: PROJECT, sock: SOCK, port: httpPort, ws: `ws://127.0.0.1:${httpPort}/events`, pid: process.pid, startedAt: Date.now() };
fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
process.stderr.write(`claudix: project=${PROJECT} ws=${state.ws} sock=${SOCK}\n`);
process.stdout.write(JSON.stringify({ at: Date.now(), type: "started", ...state }) + "\n");

// Exit after a while with nobody attached (no editor, no watcher), so
// daemons started detached by up.sh do not pile up across sessions.
const IDLE_MS = Number(args["idle-minutes"] ?? 30) * 60_000;
let idleSince = Date.now();
setInterval(() => {
  if (lspClients.size > 0 || wsClients.size > 0) { idleSince = Date.now(); return; }
  if (Date.now() - idleSince > IDLE_MS) { process.stderr.write("claudix: idle, exiting\n"); shutdown(); }
}, 30_000);

function shutdown() {
  try { fs.unlinkSync(SOCK); } catch {}
  try { fs.unlinkSync(STATE_FILE); } catch {}
  process.exit(0);
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
process.on("SIGHUP", shutdown);
process.on("uncaughtException", (e) => process.stderr.write(`claudix: uncaught ${e?.stack ?? e}\n`));
process.on("unhandledRejection", (e: any) => process.stderr.write(`claudix: unhandled ${e?.stack ?? e}\n`));
