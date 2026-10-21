// HTTP and WebSocket transport for the API (spec §8.1). Request headers and bodies are never logged.
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";
import { checkAccess, eventView, MAX_BODY, serve, type AccessOptions, type ApiResponse, type ApiTarget, type Tokens } from "./api.js";
import type { TaskEvent } from "./types.js";

export interface ServerOptions {
  port: number;
  host: string;
  tokens: Tokens;
  access: AccessOptions;
  target: ApiTarget;
  subscribe(fn: (e: TaskEvent) => void): () => void;
}

const headersOf = (req: IncomingMessage): Record<string, string | undefined> =>
  Object.fromEntries(Object.entries(req.headers).map(([k, v]) => [k, Array.isArray(v) ? v.join(",") : v]));

const BACKLOG_PAGE = 1000;
const MAX_BUFFERED = 8 * 1024 * 1024;

const reply = (res: ServerResponse, r: ApiResponse): void => {
  if (r.ndjson) {
    res.writeHead(r.status, { "content-type": "application/x-ndjson" });
    res.end(r.ndjson.map((e) => JSON.stringify(e) + "\n").join(""));
  } else if (r.json !== undefined) {
    res.writeHead(r.status, { "content-type": "application/json" });
    res.end(JSON.stringify(r.json));
  } else {
    res.writeHead(r.status);
    res.end();
  }
};
const fail = (status: number, code: string, message: string): ApiResponse => ({ status, json: { error: { code, message } } });

// parseUrl: null for a request target the URL parser rejects (for example "//").
function parseUrl(raw: string | undefined): URL | null {
  try {
    return new URL(raw ?? "/", "http://bridge");
  } catch {
    return null;
  }
}

export function startServer(o: ServerOptions): Promise<{ port: number; close(): Promise<void> }> {
  const server = createServer((req, res) => {
    const url = parseUrl(req.url);
    if (!url) { reply(res, fail(400, "bad_request", "bad request target")); req.resume(); return; }
    // Access first: unauthenticated callers learn nothing about bodies.
    const access = checkAccess(headersOf(req), o.tokens, o.access);
    if ("status" in access) { reply(res, access); req.resume(); return; }
    const declared = Number(req.headers["content-length"] ?? "0");
    if (declared > MAX_BODY) { reply(res, fail(413, "bad_request", "body too large")); req.destroy(); return; }
    const chunks: Buffer[] = [];
    let size = 0;
    let aborted = false;
    req.on("data", (c: Buffer) => {
      if (aborted) return;
      size += c.length;
      if (size > MAX_BODY) {
        aborted = true;
        res.writeHead(413, { "content-type": "application/json", connection: "close" });
        res.end(JSON.stringify({ error: { code: "bad_request", message: "body too large" } }), () => req.destroy());
      } else chunks.push(c);
    });
    req.on("end", () => {
      if (aborted) return;
      // an app route answers when agentic-app is done (a start may run the app's prepare)
      void (async () => serve({ method: req.method ?? "GET", path: url.pathname, query: url.searchParams, headers: headersOf(req),
        body: Buffer.concat(chunks).toString("utf8") }, o.target, o.tokens, o.access))()
        .catch((): ApiResponse => fail(500, "internal", "internal error"))
        .then((r) => { if (!res.headersSent && !res.destroyed) reply(res, r); });
    });
  });

  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    const refuse = (status: number) => { socket.write(`HTTP/1.1 ${status} Refused\r\nConnection: close\r\n\r\n`); socket.destroy(); };
    const url = parseUrl(req.url);
    if (!url) return refuse(400);
    const access = checkAccess(headersOf(req), o.tokens, o.access);
    if ("status" in access) return refuse(access.status);
    if (access.scope !== "task") return refuse(403);
    if (url.pathname !== "/events") return refuse(404);
    const since = Number(url.searchParams.get("since") ?? "0");
    const keep = eventView(url.searchParams.get("view"));
    if (!keep) return refuse(400);
    wss.handleUpgrade(req, socket, head, (ws) => follow(ws, Number.isInteger(since) && since >= 0 ? since : 0, keep));
  });

  // follow: the backlog after SINCE in pages, then live events; events arriving during the backlog are
  // queued. A client that falls MAX_BUFFERED behind is dropped.
  function follow(ws: WebSocket, since: number, keep: (e: TaskEvent) => boolean): void {
    let last = since;
    let live = false;
    const queue: TaskEvent[] = [];
    const sendEvent = (e: TaskEvent) => {
      if (e.seq <= last || !keep(e) || ws.readyState !== ws.OPEN) return;
      ws.send(JSON.stringify(e));
      last = e.seq;
      if (ws.bufferedAmount > MAX_BUFFERED) ws.terminate();
    };
    const unsubscribe = o.subscribe((e) => (live ? sendEvent(e) : queue.push(e)));
    const ping = setInterval(() => ws.ping(), 30000);
    ws.on("error", () => ws.terminate());
    ws.on("close", () => { clearInterval(ping); unsubscribe(); });
    try {
      for (;;) {
        const page = o.target.events(last, BACKLOG_PAGE, keep);
        page.forEach(sendEvent);
        if (page.length < BACKLOG_PAGE || ws.readyState !== ws.OPEN) break;
      }
    } catch {
      ws.terminate();
      return;
    }
    live = true;
    queue.splice(0).forEach(sendEvent);
  }

  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(o.port, o.host, () => {
      server.off("error", reject);
      resolve({
        port: (server.address() as AddressInfo).port,
        close: () => new Promise<void>((done) => { wss.clients.forEach((c) => c.terminate()); server.close(() => done()); }),
      });
    });
  });
}
