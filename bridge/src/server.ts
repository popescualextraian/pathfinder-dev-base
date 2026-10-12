// HTTP and WebSocket transport for the API (spec §8.1). Request headers and bodies are never logged.
import { createServer, type IncomingMessage } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";
import { checkAccess, handle, MAX_BODY, type AccessOptions, type ApiResponse, type ApiTarget, type Tokens } from "./api.js";
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

export function startServer(o: ServerOptions): Promise<{ port: number; close(): Promise<void> }> {
  const server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    let size = 0;
    let tooLarge = false;
    req.on("data", (c: Buffer) => {
      size += c.length;
      if (size > MAX_BODY) tooLarge = true;
      else chunks.push(c);
    });
    req.on("end", () => {
      const url = new URL(req.url ?? "/", "http://bridge");
      const r: ApiResponse = tooLarge
        ? { status: 400, json: { error: { code: "bad_request", message: "body too large" } } }
        : handle({ method: req.method ?? "GET", path: url.pathname, query: url.searchParams, headers: headersOf(req),
            body: Buffer.concat(chunks).toString("utf8") }, o.target, o.tokens, o.access);
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
    });
  });

  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url ?? "/", "http://bridge");
    const access = checkAccess(headersOf(req), o.tokens, o.access);
    const refuse = (status: number) => { socket.write(`HTTP/1.1 ${status} Refused\r\nConnection: close\r\n\r\n`); socket.destroy(); };
    if ("status" in access) return refuse(access.status);
    if (access.scope !== "task") return refuse(403);
    if (url.pathname !== "/events") return refuse(404);
    const since = Number(url.searchParams.get("since") ?? "0");
    wss.handleUpgrade(req, socket, head, (ws) => follow(ws, Number.isInteger(since) && since >= 0 ? since : 0));
  });

  // follow: the backlog after SINCE, then live events; events arriving during the backlog are queued.
  function follow(ws: WebSocket, since: number): void {
    let last = since;
    let live = false;
    const queue: TaskEvent[] = [];
    const sendEvent = (e: TaskEvent) => { if (e.seq > last) { ws.send(JSON.stringify(e)); last = e.seq; } };
    const unsubscribe = o.subscribe((e) => (live ? sendEvent(e) : queue.push(e)));
    for (const e of o.target.events(since, Number.MAX_SAFE_INTEGER)) sendEvent(e);
    live = true;
    queue.splice(0).forEach(sendEvent);
    const ping = setInterval(() => ws.ping(), 30000);
    ws.on("error", () => ws.terminate());
    ws.on("close", () => { clearInterval(ping); unsubscribe(); });
  }

  return new Promise((resolve) => {
    server.listen(o.port, o.host, () => {
      resolve({
        port: (server.address() as AddressInfo).port,
        close: () => new Promise<void>((done) => { wss.clients.forEach((c) => c.terminate()); server.close(() => done()); }),
      });
    });
  });
}
