import { afterEach, describe, expect, it } from "vitest";
import { request } from "node:http";
import { connect } from "node:net";
import WebSocket from "ws";
import { startServer } from "../src/server.js";
import type { ApiTarget } from "../src/api.js";
import type { TaskEvent } from "../src/types.js";

const tokens = { task: "task-token-0123456789", agent: "agent-token-0123456789" };
const ev = (seq: number): TaskEvent => ({ seq, ts: "t", task: "T-1", session: null, name: null, agent: "claude", type: "state", data: { state: "idle" } });
let close: (() => Promise<void>) | null = null;
afterEach(async () => { await close?.(); close = null; });

async function serve(stored: TaskEvent[], seen: string[] = []) {
  const listeners = new Set<(e: TaskEvent) => void>();
  const target: ApiTarget = {
    ready: () => true,
    status: () => ({ state: "idle" }),
    command: (i) => { seen.push(JSON.stringify(i)); return { ok: true, effects: [] }; },
    sessions: () => [],
    events: (since, limit, keep = () => true) => stored.filter((e) => e.seq > since && keep(e)).slice(0, limit),
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

  it("refuses a body over 1 MiB with 413 body too large", async () => {
    const { port } = await serve([]);
    const r = await fetch(`http://127.0.0.1:${port}/prompt`, { method: "POST", body: JSON.stringify({ text: "x".repeat(1048600) }),
      headers: { authorization: `Bearer ${tokens.task}`, "content-type": "application/json" } });
    expect(r.status).toBe(413);
    expect(await r.json()).toEqual({ error: { code: "bad_request", message: "body too large" } });
  });

  it("answers 401 before looking at an oversized body", async () => {
    const { port } = await serve([]);
    const r = await fetch(`http://127.0.0.1:${port}/prompt`, { method: "POST", body: "x".repeat(1048600) }).catch(() => null);
    if (r) expect(r.status).toBe(401);
  });

  it("answers 413 when a chunked body streams past the limit", async () => {
    const { port } = await serve([]);
    const status = await new Promise<number>((resolve) => {
      const q = request({ port, method: "POST", path: "/prompt", headers: { authorization: `Bearer ${tokens.task}`, "transfer-encoding": "chunked" } }, (res) => { resolve(res.statusCode ?? 0); res.resume(); });
      q.on("error", () => undefined);
      q.write("x".repeat(600000));
      q.write("x".repeat(600000));
    });
    expect(status).toBe(413);
  });

  it("survives request targets the URL parser rejects", async () => {
    const { port } = await serve([]);
    const raw = (target: string) => new Promise<string>((resolve) => {
      const c = connect(port, "127.0.0.1", () => c.write(`GET ${target} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer ${tokens.task}\r\nConnection: close\r\n\r\n`));
      let out = "";
      c.on("data", (d) => { out += d.toString(); });
      c.on("close", () => resolve(out));
    });
    expect(await raw("//")).toMatch(/^HTTP\/1.1 400/);
    const ok = await fetch(`http://127.0.0.1:${port}/status`, { headers: { authorization: `Bearer ${tokens.task}` } });
    expect(ok.status).toBe(200);
  });

  it("lets the agent token post a gate refusal over HTTP", async () => {
    const seen: string[] = [];
    const { port } = await serve([], seen);
    const r = await fetch(`http://127.0.0.1:${port}/gate`, { method: "POST", body: JSON.stringify({ rule: "gate", command: "git push" }),
      headers: { authorization: `Bearer ${tokens.agent}`, "content-type": "application/json" } });
    expect(r.status).toBe(204);
    expect(seen).toEqual([JSON.stringify({ kind: "gate", rule: "gate", command: "git push" })]);
  });

  it("answers 500 instead of crashing when the target throws", async () => {
    const s = await startServer({ port: 0, host: "127.0.0.1", tokens, access: { hosts: [], origins: [] }, subscribe: () => () => undefined,
      target: { ready: () => true, status: () => { throw new Error("boom"); }, command: () => ({ ok: true, effects: [] }), sessions: () => [], events: () => [] } });
    close = s.close;
    const r = await fetch(`http://127.0.0.1:${s.port}/status`, { headers: { authorization: `Bearer ${tokens.task}` } });
    expect(r.status).toBe(500);
    expect((await fetch(`http://127.0.0.1:${s.port}/nope`, { headers: { authorization: `Bearer ${tokens.task}` } })).status).toBe(404);
  });

  it("rejects when the port is taken", async () => {
    const { port } = await serve([]);
    const target: ApiTarget = { ready: () => true, status: () => ({}), command: () => ({ ok: true, effects: [] }), sessions: () => [], events: () => [] };
    await expect(startServer({ port, host: "127.0.0.1", tokens, access: { hosts: [], origins: [] }, target, subscribe: () => () => undefined })).rejects.toThrow(/EADDRINUSE/);
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

  it("refuses a WebSocket from an unlisted origin", async () => {
    const { port } = await serve([]);
    const ws = new WebSocket(`ws://127.0.0.1:${port}/events`, { headers: { authorization: `Bearer ${tokens.task}`, origin: "http://evil.example.com" } });
    const status = await new Promise<number>((resolve) => ws.on("unexpected-response", (_req, res) => resolve(res.statusCode ?? 0)));
    expect(status).toBe(403);
  });

  it("pages a long backlog", async () => {
    const { port } = await serve(Array.from({ length: 2500 }, (_, k) => ev(k + 1)));
    const ws = new WebSocket(`ws://127.0.0.1:${port}/events`, { headers: { authorization: `Bearer ${tokens.task}` } });
    const got: number[] = [];
    await new Promise<void>((resolve) => ws.on("message", (frame) => { got.push(JSON.parse(frame.toString()).seq); if (got.length === 2500) resolve(); }));
    ws.close();
    expect(got[2499]).toBe(2500);
  });

  it("serves the status view over HTTP and WebSocket: same seq, backlog and live filtered, resumable, unknown view refused", async () => {
    const tool = (seq: number): TaskEvent => ({ ...ev(seq), type: "tool", data: { status: "running" } });
    const { port, push } = await serve([ev(1), tool(2), ev(3), tool(4)]);
    const auth = { authorization: `Bearer ${tokens.task}` };
    const http = await fetch(`http://127.0.0.1:${port}/events?view=status`, { headers: auth });
    expect((await http.text()).trim().split("\n").map((l) => JSON.parse(l).seq)).toEqual([1, 3]);
    expect((await fetch(`http://127.0.0.1:${port}/events?view=chat`, { headers: auth })).status).toBe(400);

    const ws = new WebSocket(`ws://127.0.0.1:${port}/events?since=1&view=status`, { headers: auth });
    const got: number[] = [];
    await new Promise<void>((resolve) => {
      ws.on("message", (frame) => {
        got.push(JSON.parse(frame.toString()).seq);
        if (got.length === 1) { push(tool(5)); push(ev(6)); }
        if (got.length === 2) resolve();
      });
    });
    ws.close();
    expect(got).toEqual([3, 6]);

    const bad = new WebSocket(`ws://127.0.0.1:${port}/events?view=chat`, { headers: auth });
    expect(await new Promise<number>((resolve) => bad.on("unexpected-response", (_req, res) => resolve(res.statusCode ?? 0)))).toBe(400);
  });
});
