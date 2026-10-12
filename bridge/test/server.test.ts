import { afterEach, describe, expect, it } from "vitest";
import WebSocket from "ws";
import { startServer } from "../src/server.js";
import type { ApiTarget } from "../src/api.js";
import type { TaskEvent } from "../src/types.js";

const tokens = { task: "task-token-0123456789", agent: "agent-token-0123456789" };
const ev = (seq: number): TaskEvent => ({ seq, ts: "t", task: "T-1", session: null, agent: "claude", type: "state", data: { state: "idle" } });
let close: (() => Promise<void>) | null = null;
afterEach(async () => { await close?.(); close = null; });

async function serve(stored: TaskEvent[], seen: string[] = []) {
  const listeners = new Set<(e: TaskEvent) => void>();
  const target: ApiTarget = {
    ready: () => true,
    status: () => ({ state: "idle" }),
    command: (i) => { seen.push(JSON.stringify(i)); return { ok: true, effects: [] }; },
    events: (since, limit) => stored.filter((e) => e.seq > since).slice(0, limit),
  };
  const s = await startServer({ port: 0, host: "127.0.0.1", tokens, access: { hosts: [], origins: [] }, target,
    subscribe: (fn) => { listeners.add(fn); return () => listeners.delete(fn); } });
  close = s.close;
  return { port: s.port, push: (e: TaskEvent) => { stored.push(e); listeners.forEach((f) => f(e)); } };
}

describe("server", () => {
  it("serves JSON with the token and refuses without it", async () => {
    const { port } = await serve([]);
    const ok = await fetch(`http://127.0.0.1:${port}/status`, { headers: { authorization: `Bearer ${tokens.task}` } });
    expect(ok.status).toBe(200);
    expect(await ok.json()).toEqual({ state: "idle" });
    expect((await fetch(`http://127.0.0.1:${port}/status`)).status).toBe(401);
  });

  it("refuses a body over 1 MiB with 400 body too large", async () => {
    const { port } = await serve([]);
    const r = await fetch(`http://127.0.0.1:${port}/prompt`, { method: "POST", body: JSON.stringify({ text: "x".repeat(1048600) }),
      headers: { authorization: `Bearer ${tokens.task}`, "content-type": "application/json" } });
    expect(r.status).toBe(400);
    expect(await r.json()).toEqual({ error: { code: "bad_request", message: "body too large" } });
  });

  it("streams the backlog after the cursor, then live events, over WebSocket", async () => {
    const { port, push } = await serve([ev(1), ev(2), ev(3)]);
    const ws = new WebSocket(`ws://127.0.0.1:${port}/events?since=1`, { headers: { authorization: `Bearer ${tokens.task}` } });
    const got: number[] = [];
    await new Promise<void>((resolve) => {
      ws.on("message", (frame) => {
        got.push(JSON.parse(frame.toString()).seq);
        if (got.length === 2) push(ev(4));
        if (got.length === 3) resolve();
      });
    });
    ws.close();
    expect(got).toEqual([2, 3, 4]);
  });

  it("refuses a WebSocket without the task token", async () => {
    const { port } = await serve([]);
    const ws = new WebSocket(`ws://127.0.0.1:${port}/events`, { headers: { authorization: `Bearer ${tokens.agent}` } });
    const status = await new Promise<number>((resolve) => ws.on("unexpected-response", (_req, res) => resolve(res.statusCode ?? 0)));
    expect(status).toBe(403);
  });
});
