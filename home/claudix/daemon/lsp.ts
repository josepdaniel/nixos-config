// Dependency-free pieces of LSP used by the claudix daemon and shim:
// Content-Length framing, a small JSON-RPC connection over a duplex stream,
// and a TextDocument that applies incremental edits and maps positions.

import type { Duplex } from "node:stream";

export type Position = { line: number; character: number };
export type Range = { start: Position; end: Position };
export type Msg = { jsonrpc?: string; id?: number | string; method?: string; params?: any; result?: any; error?: any };
export type ContentChange = { range?: Range; text: string };

export const DiagnosticSeverity = { Error: 1, Warning: 2, Information: 3, Hint: 4 } as const;
export const TextDocumentSyncKind = { None: 0, Full: 1, Incremental: 2 } as const;

// ------------------------------------------------------------------ framing

export function framer(onMessage: (m: Msg) => void) {
  let buf = Buffer.alloc(0);
  return (chunk: Buffer) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      const headerEnd = buf.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      const header = buf.subarray(0, headerEnd).toString("latin1");
      const m = /Content-Length:\s*(\d+)/i.exec(header);
      if (!m) { buf = buf.subarray(headerEnd + 4); continue; }
      const len = Number(m[1]);
      if (buf.length < headerEnd + 4 + len) return;
      const body = buf.subarray(headerEnd + 4, headerEnd + 4 + len).toString("utf8");
      buf = buf.subarray(headerEnd + 4 + len);
      try { onMessage(JSON.parse(body)); } catch {}
    }
  };
}

export function encode(m: Msg) {
  const s = JSON.stringify({ jsonrpc: "2.0", ...m });
  return `Content-Length: ${Buffer.byteLength(s)}\r\n\r\n${s}`;
}

// ------------------------------------------------------------------ JSON-RPC

type Handler = (params: any) => unknown | Promise<unknown>;

export class Connection {
  private requests = new Map<string, Handler>();
  private notifications = new Map<string, Handler>();
  private fallbackRequest: Handler | null = null;
  private nextId = 1;
  private pending = new Map<number | string, (m: Msg) => void>();
  private closed = false;
  private onCloseFns: (() => void)[] = [];

  constructor(private stream: Duplex) {
    stream.on("data", framer((m) => this.dispatch(m)));
    const close = () => { if (!this.closed) { this.closed = true; for (const f of this.onCloseFns) f(); } };
    stream.on("close", close);
    stream.on("end", close);
    stream.on("error", close);
  }

  onRequest(method: string, h: Handler) { this.requests.set(method, h); }
  onNotification(method: string, h: Handler) { this.notifications.set(method, h); }
  onUnhandledRequest(h: Handler) { this.fallbackRequest = h; }
  onClose(f: () => void) { this.onCloseFns.push(f); }

  send(m: Msg) { if (!this.closed) { try { this.stream.write(encode(m)); } catch {} } }
  sendNotification(method: string, params?: any) { this.send({ method, params }); }
  sendRequest(method: string, params?: any): Promise<Msg> {
    const id = this.nextId++;
    return new Promise((res) => { this.pending.set(id, res); this.send({ id, method, params }); });
  }
  dispose() { this.closed = true; try { this.stream.destroy(); } catch {} }

  private async dispatch(m: Msg) {
    if (m.id !== undefined && m.method === undefined) {           // response
      const r = this.pending.get(m.id); if (r) { this.pending.delete(m.id); r(m); }
      return;
    }
    if (!m.method) return;
    if (m.id === undefined) {                                      // notification
      try { await this.notifications.get(m.method)?.(m.params); } catch {}
      return;
    }
    const h = this.requests.get(m.method) ?? this.fallbackRequest;  // request
    try {
      const result = h ? await h(m.params) : null;
      this.send({ id: m.id, result: result === undefined ? null : result });
    } catch (e: any) {
      this.send({ id: m.id, error: { code: -32603, message: String(e?.message ?? e) } });
    }
  }
}

// ------------------------------------------------------------- text document

export class TextDocument {
  private lineStarts: number[] | null = null;
  constructor(public uri: string, public languageId: string, public version: number, private text: string) {}

  static create(uri: string, languageId: string, version: number, text: string) {
    return new TextDocument(uri, languageId, version, text);
  }

  getText(range?: Range) {
    if (!range) return this.text;
    return this.text.slice(this.offsetAt(range.start), this.offsetAt(range.end));
  }

  private starts() {
    if (!this.lineStarts) {
      const s = [0];
      for (let i = 0; i < this.text.length; i++) if (this.text.charCodeAt(i) === 10) s.push(i + 1);
      this.lineStarts = s;
    }
    return this.lineStarts;
  }

  // Offsets and columns are UTF-16 code units, as LSP specifies.
  positionAt(offset: number): Position {
    offset = Math.max(0, Math.min(offset, this.text.length));
    const s = this.starts();
    let lo = 0, hi = s.length;
    while (lo + 1 < hi) { const mid = (lo + hi) >> 1; if (s[mid]! > offset) hi = mid; else lo = mid; }
    return { line: lo, character: offset - s[lo]! };
  }

  offsetAt(p: Position) {
    const s = this.starts();
    if (p.line >= s.length) return this.text.length;
    if (p.line < 0) return 0;
    const start = s[p.line]!;
    const end = p.line + 1 < s.length ? s[p.line + 1]! : this.text.length;
    return Math.max(start, Math.min(start + p.character, end));
  }

  update(changes: ContentChange[], version: number) {
    for (const c of changes) {
      if (!c.range) { this.text = c.text; }
      else {
        const a = this.offsetAt(c.range.start), b = this.offsetAt(c.range.end);
        this.text = this.text.slice(0, a) + c.text + this.text.slice(b);
      }
      this.lineStarts = null;
    }
    this.version = version;
  }
}
