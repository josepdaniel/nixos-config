#!/usr/bin/env bun
// claudix shim: Helix spawns this as a language server over stdio. It finds
// the daemon for the current project (started by `/claudix` in Claude Code)
// and proxies LSP messages to it over a unix socket.
//
// It is a proxy, not a pipe, so that the daemon can come and go without
// Helix noticing: while no daemon is attached the shim answers Helix's
// requests itself (empty results), and when a daemon appears it replays the
// initialize handshake and the current text of every open document.
//
// Daemon lookup: $CLAUDIX_SOCK, else the state file whose project is the
// longest prefix of the shim's cwd (Helix runs it from its workspace root).

import * as net from "node:net";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { framer, encode, TextDocument, TextDocumentSyncKind, type Msg } from "./lsp";

const RUNTIME_DIR = path.join(process.env.XDG_RUNTIME_DIR ?? os.tmpdir(), "claudix");
const RETRY_MS = 1500;

const toEditor = (m: Msg) => { process.stdout.write(encode(m)); };

// ------------------------------------------------------------ daemon lookup

function findSock(): string | undefined {
  if (process.env.CLAUDIX_SOCK) return process.env.CLAUDIX_SOCK;
  const cwd = path.resolve(process.cwd());
  let best: { project: string; sock: string } | undefined;
  let files: string[] = [];
  try { files = fs.readdirSync(RUNTIME_DIR).filter((f) => f.endsWith(".json")); } catch { return undefined; }
  for (const f of files) {
    try {
      const st = JSON.parse(fs.readFileSync(path.join(RUNTIME_DIR, f), "utf8")) as { project: string; sock: string; pid: number };
      try { process.kill(st.pid, 0); } catch { fs.rmSync(path.join(RUNTIME_DIR, f), { force: true }); continue; }
      if ((cwd === st.project || cwd.startsWith(st.project + path.sep)) && (!best || st.project.length > best.project.length)) best = st;
    } catch {}
  }
  return best?.sock;
}

// ------------------------------------------------------------ editor state

let initializeParams: any = null;       // Helix's initialize request params
let initialized = false;                // Helix sent "initialized"
const docs = new Map<string, TextDocument>();
let shuttingDown = false;

const CAPABILITIES = {
  capabilities: {
    textDocumentSync: TextDocumentSyncKind.Incremental,   // so we can track text while detached
    hoverProvider: true,
    codeActionProvider: true,
    executeCommandProvider: { commands: ["claudix.comment", "claudix.resolve", "claudix.status"] },
  },
  serverInfo: { name: "claudix", version: "0.2.0" },
};

// ------------------------------------------------------------ daemon link

let sock: net.Socket | null = null;
let daemonReady = false;                                 // handshake replayed, safe to forward
const inflight = new Set<number | string>();             // editor request ids forwarded to daemon
const inflightShim = new Map<number | string, () => void>();
let shimReqId = 1 << 30;                                 // ids for the shim's own requests
let attachedBefore = false;

function statusToEditor(message: string, type = 3) {
  if (initialized) toEditor({ method: "window/showMessage", params: { type, message } });
}

function connectDaemon() {
  if (shuttingDown || sock) return;
  const target = findSock();
  if (!target) { scheduleRetry(); return; }
  const s = net.connect(target);
  sock = s;
  s.on("connect", () => { if (initializeParams) replayHandshake(); });
  s.on("data", framer(onDaemonMessage));
  const gone = () => {
    if (sock !== s) return;
    sock = null;
    const wasReady = daemonReady;
    daemonReady = false;
    for (const id of inflight) toEditor({ id, result: null });   // never leave Helix waiting
    inflight.clear();
    inflightShim.clear();
    for (const uri of docs.keys()) toEditor({ method: "textDocument/publishDiagnostics", params: { uri, diagnostics: [] } });
    if (wasReady) statusToEditor("claudix: daemon went away, waiting for /claudix", 2);
    scheduleRetry();
  };
  s.on("error", gone);
  s.on("close", gone);
}

let retryTimer: Timer | null = null;
function scheduleRetry() {
  if (shuttingDown || retryTimer) return;
  retryTimer = setTimeout(() => { retryTimer = null; connectDaemon(); }, RETRY_MS);
}

function sendToDaemon(m: Msg) { sock?.write(encode(m)); }

function replayHandshake() {
  const id = shimReqId++;
  inflightShim.set(id, () => {
    sendToDaemon({ method: "initialized", params: {} });
    for (const [uri, doc] of docs) {
      sendToDaemon({ method: "textDocument/didOpen", params: { textDocument: { uri, languageId: doc.languageId, version: doc.version, text: doc.getText() } } });
    }
    daemonReady = true;
    statusToEditor(attachedBefore ? "claudix: daemon attached again" : "claudix: attached");
    attachedBefore = true;
  });
  sendToDaemon({ id, method: "initialize", params: initializeParams });
}

function onDaemonMessage(m: Msg) {
  if (m.id !== undefined && !m.method) {                 // response
    const own = inflightShim.get(m.id);
    if (own) { inflightShim.delete(m.id); own(); return; }
    if (inflight.has(m.id)) { inflight.delete(m.id); toEditor(m); }
    return;
  }
  if (m.method) {                                        // notification or daemon->editor request
    if (m.id !== undefined) m.id = `d:${m.id}`;
    toEditor(m);
  }
}

// ------------------------------------------------------------ editor side

function onEditorMessage(m: Msg) {
  if (m.id !== undefined && !m.method) {                 // Helix answering a daemon request
    if (typeof m.id === "string" && m.id.startsWith("d:")) sendToDaemon({ ...m, id: m.id.slice(2) });
    return;
  }
  switch (m.method) {
    case "initialize":
      initializeParams = m.params;
      toEditor({ id: m.id, result: CAPABILITIES });
      return;
    case "initialized":
      initialized = true;
      if (sock && !daemonReady) replayHandshake(); else if (!sock) connectDaemon();
      return;
    case "shutdown":
      shuttingDown = true;
      toEditor({ id: m.id, result: null });
      return;
    case "exit":
      try { sock?.end(); } catch {}
      process.exit(0);
    case "textDocument/didOpen": {
      const d = m.params.textDocument;
      docs.set(d.uri, TextDocument.create(d.uri, d.languageId, d.version, d.text));
      break;
    }
    case "textDocument/didChange": {
      const doc = docs.get(m.params.textDocument.uri);
      if (doc) doc.update(m.params.contentChanges, m.params.textDocument.version ?? doc.version + 1);
      break;
    }
    case "textDocument/didClose":
      docs.delete(m.params.textDocument.uri);
      break;
  }
  if (daemonReady) {
    if (m.id !== undefined) inflight.add(m.id);
    sendToDaemon(m);
    return;
  }
  if (m.id !== undefined) {                              // detached: answer so Helix never hangs
    if (m.method === "workspace/executeCommand") statusToEditor("claudix: no daemon for this project. Run /claudix in Claude Code.", 2);
    toEditor({ id: m.id, result: null });
  }
}

process.stdin.on("data", framer(onEditorMessage));
process.stdin.on("end", () => process.exit(0));
connectDaemon();
