#!/usr/bin/env bun
// Scripted LSP client: drives daemon/shim.ts the way Helix would.
// usage: bun test/lsp-client.ts <project-dir> <file> [command...]
//   commands: comment:<from>:<to>:<kind>:<text>   resolve:<at>   hover:<line>:<char>
//             edit:<line>:<char>:<text>   wait:<ms>   status
import { spawn } from "node:child_process";
import * as path from "node:path";
import { pathToFileURL } from "node:url";
import * as fs from "node:fs";

const [proj, file, ...cmds] = process.argv.slice(2);
if (!proj || !file) { console.error("usage"); process.exit(2); }
const shim = spawn("bun", [path.join(import.meta.dir, "../daemon/shim.ts")], { cwd: proj, stdio: ["pipe", "pipe", "inherit"] });
let buf = Buffer.alloc(0);
let nextId = 1;
const pending = new Map<number, (r: any) => void>();
shim.stdout.on("data", (d: Buffer) => {
  buf = Buffer.concat([buf, d]);
  for (;;) {
    const s = buf.toString("utf8");
    const m = /^Content-Length: (\d+)\r\n\r\n/.exec(s);
    if (!m) return;
    const len = Number(m[1]);
    const headerBytes = Buffer.byteLength(m[0]);
    if (buf.length < headerBytes + len) return;
    const body = buf.subarray(headerBytes, headerBytes + len).toString("utf8");
    buf = buf.subarray(headerBytes + len);
    const msg = JSON.parse(body);
    if (msg.id !== undefined && pending.has(msg.id)) { pending.get(msg.id)!(msg); pending.delete(msg.id); }
    else if (msg.method === "textDocument/publishDiagnostics") {
      console.log("<< diagnostics:", msg.params.diagnostics.map((d: any) => `[${d.code} sev${d.severity} L${d.range.start.line + 1}:${d.range.start.character}-L${d.range.end.line + 1}:${d.range.end.character}] ${d.message}`).join(" | ") || "(none)");
    } else console.log("<< notification:", msg.method, JSON.stringify(msg.params).slice(0, 160));
  }
});
function send(msg: any) { const s = JSON.stringify({ jsonrpc: "2.0", ...msg }); shim.stdin.write(`Content-Length: ${Buffer.byteLength(s)}\r\n\r\n${s}`); }
function request(method: string, params: any) { return new Promise<any>((res) => { const id = nextId++; pending.set(id, res); send({ id, method, params }); }); }
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const uri = pathToFileURL(path.resolve(proj, file)).href;
let text = fs.readFileSync(path.resolve(proj, file), "utf8");
let version = 1;

const init = await request("initialize", { processId: process.pid, rootUri: pathToFileURL(proj).href, capabilities: {} });
console.log("<< initialize:", JSON.stringify(init.result?.serverInfo), Object.keys(init.result?.capabilities ?? {}).join(","));
send({ method: "initialized", params: {} });
send({ method: "textDocument/didOpen", params: { textDocument: { uri, languageId: "rust", version, text } } });
await sleep(200);

for (const c of cmds) {
  const [op, ...rest] = c.split(":");
  if (op === "comment") {
    const [from, to, kind, ...t] = rest;
    const r = await request("workspace/executeCommand", { command: "claudix.comment", arguments: [{ uri, from: +from!, to: +to!, kind, text: t.join(":") }] });
    console.log("<< comment result:", JSON.stringify(r.result ?? r.error));
  } else if (op === "resolve") {
    const r = await request("workspace/executeCommand", { command: "claudix.resolve", arguments: [{ uri, at: +rest[0]! }] });
    console.log("<< resolve result:", JSON.stringify(r.result ?? r.error));
  } else if (op === "hover") {
    const r = await request("textDocument/hover", { textDocument: { uri }, position: { line: +rest[0]!, character: +rest[1]! } });
    console.log("<< hover:", JSON.stringify(r.result?.contents?.value ?? r.result));
  } else if (op === "edit") {
    const [line, ch, ...t] = rest; const ins = t.join(":");
    version++;
    send({ method: "textDocument/didChange", params: { textDocument: { uri, version }, contentChanges: [{ range: { start: { line: +line!, character: +ch! }, end: { line: +line!, character: +ch! } }, text: ins }] } });
    console.log(">> inserted", JSON.stringify(ins), "at", line, ch);
  } else if (op === "status") {
    const r = await request("workspace/executeCommand", { command: "claudix.status", arguments: [] });
    console.log("<< status:", JSON.stringify(r.result));
  } else if (op === "wait") await sleep(+rest[0]!);
  await sleep(150);
}
await request("shutdown", null); send({ method: "exit" });
await sleep(100); process.exit(0);
