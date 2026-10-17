import { WebSocketServer } from "ws";
import type { AddressInfo } from "node:net";
import { describe, expect, it } from "vitest";
import { follow, formatEvent } from "../src/follow.js";
import type { TaskEvent } from "../src/types.js";

const e = (type: TaskEvent["type"], data: Record<string, unknown>): TaskEvent => ({ seq: 7, ts: "t", task: "T-1", session: null, name: null, agent: "claude", type, data });

describe("formatEvent", () => {
  it("replaces control characters from the agent, keeping newline and tab", () => {
    const out = formatEvent(e("message", { role: "assistant", text: "a\u001b[2Jb\u009bc\u007fd\te\nf" }));
    expect(out).toBe("a [2Jb c d\te\nf");
  });
  it("prints one readable line per event; partial messages stream without a newline", () => {
    expect(formatEvent(e("state", { state: "waiting", reason: "question Q1" }))).toBe("— waiting (question Q1)\n");
    expect(formatEvent(e("message", { role: "agent", text: "Hel", final: false }))).toBe("Hel");
    expect(formatEvent(e("message", { role: "agent", text: "Hello", final: true }))).toBe("\n");
    expect(formatEvent(e("message", { role: "agent", text: "Hello", final: true }), { whole: true })).toBe("Hello\n");
    expect(formatEvent(e("message", { role: "user", text: "Fix it", final: true }))).toBe("> Fix it\n");
    expect(formatEvent(e("tool", { title: "npm test", status: "failed" }))).toBe("▸ npm test — failed\n");
    expect(formatEvent(e("question", { id: "Q1", text: "Which DB?", options: ["pg"], recommendation: "pg" }))).toBe("? Q1 Which DB? [pg] (recommended: pg)\n");
    expect(formatEvent(e("answer", { question: "Q1", text: "pg", grant: ["push"] }))).toBe("= Q1 pg (allowed: push)\n");
    expect(formatEvent(e("gate", { rule: "gate", command: "git push" }))).toBe("✗ gate refused: git push\n");
    expect(formatEvent(e("error", { message: "boom" }))).toBe("! boom\n");
  });
});

describe("formatEvent sessions", () => {
  const n = (name: string | null, type: TaskEvent["type"], data: Record<string, unknown>): TaskEvent => ({ ...e(type, data), name });
  it("prefixes other sessions' lines with [name], main and task-level unchanged", () => {
    expect(formatEvent(n("plan", "message", { role: "user", text: "a\nb" }))).toBe("[plan] > a\n[plan] > b\n");
    expect(formatEvent(n("plan", "state", { state: "idle", reason: "" }))).toBe("[plan] — idle\n");
    expect(formatEvent(n("main", "state", { state: "idle", reason: "" }))).toBe("— idle\n");
    expect(formatEvent(n("plan", "message", { role: "agent", text: "Hel", final: false }))).toBe("[plan] Hel");
    expect(formatEvent(n("plan", "message", { role: "agent", text: "lo", final: false }), { midLine: true })).toBe("lo");
    expect(formatEvent(n("plan", "message", { role: "agent", text: "lo", final: true }))).toBe("\n");
  });
});

describe("follow", () => {
  async function serve(onConn: (ws: import("ws").WebSocket, req: import("node:http").IncomingMessage) => void) {
    const wss = new WebSocketServer({ port: 0, host: "127.0.0.1" });
    await new Promise((r) => wss.on("listening", r));
    wss.on("connection", onConn);
    return { url: `ws://127.0.0.1:${(wss.address() as AddressInfo).port}`, close: () => { wss.clients.forEach((c) => c.terminate()); wss.close(); } };
  }
  const opts = (url: string, out: string[], over = {}) => ({ url, token: "t", since: 0, raw: false, forever: false, status: false, session: null as string | null, out: (s: string) => out.push(s), ...over });

  it("skips a bad frame, prints events, and ends 0 on a final state", async () => {
    const s = await serve((ws) => {
      ws.send("not json");
      ws.send(JSON.stringify(e("message", { role: "agent", text: "Hi", final: false })));
      ws.send(JSON.stringify(e("state", { state: "idle", reason: "" })));
    });
    const out: string[] = [];
    expect(await follow(opts(s.url, out))).toBe(0);
    expect(out.join("")).toContain("skipped a frame");
    expect(out.join("")).toContain("Hi— idle\n");
    s.close();
  });

  it("exits 0 when the bridge closes after a final state, and 1 on an abnormal close", async () => {
    const a = await serve((ws) => { ws.send(JSON.stringify(e("state", { state: "stopped", reason: "" }))); ws.terminate(); });
    expect(await follow(opts(a.url, [], { forever: true }))).toBe(0);
    a.close();
    const b = await serve((ws) => { ws.send(JSON.stringify(e("state", { state: "running", reason: "" }))); ws.terminate(); });
    const out: string[] = [];
    expect(await follow(opts(b.url, out))).toBe(1);
    expect(out.join("")).toContain("connection lost");
    b.close();
  });

  it("--status asks for the status view and prints whole messages", async () => {
    let asked = "";
    const s = await serve((ws, req) => {
      asked = req.url ?? "";
      ws.send(JSON.stringify(e("message", { role: "agent", text: "Done.", final: true })));
      ws.send(JSON.stringify(e("state", { state: "idle", reason: "" })));
    });
    const out: string[] = [];
    expect(await follow(opts(s.url, out, { since: 4, status: true }))).toBe(0);
    expect(asked).toBe("/events?since=4&view=status");
    expect(out.join("")).toBe("Done.\n— idle\n");
    s.close();
  });

  const named = (name: string | null, state: string): TaskEvent => ({ ...e("state", { state, reason: "" }), name });
  const run = async (events: TaskEvent[], session: string | null) => {
    const s = await serve((ws) => { events.forEach((x) => ws.send(JSON.stringify(x))); });
    const out: string[] = [];
    const t = await Promise.race([follow(opts(s.url, out, { session })), new Promise((r) => setTimeout(() => r("open"), 1200))]);
    s.close();
    return { t, out: out.join("") };
  };

  it("follow without a session ends on task-level states only", async () => {
    expect((await run([named("plan", "idle")], null)).t).toBe("open");
    expect((await run([named("plan", "idle"), named(null, "idle")], null)).t).toBe(0);
  });

  it("follow --session plan prints plan's and task-level events and ends when plan idles or the task ends", async () => {
    const a = await run([named("main", "running"), named("plan", "running"), named("plan", "idle")], "plan");
    expect(a.t).toBe(0);
    expect(a.out).toBe("[plan] — running\n[plan] — idle\n");
    expect((await run([named("main", "idle")], "plan")).t).toBe("open");
    const c = await run([named("plan", "running"), named(null, "stopped")], "plan");
    expect(c.t).toBe(0);
    expect(c.out).toBe("[plan] — running\n— stopped\n");
  });

  it("follow --session main shows each main state once", async () => {
    const r = await run([named("main", "running"), named(null, "running"), named("main", "idle"), named(null, "idle")], "main");
    expect(r.t).toBe(0);
    expect(r.out).toBe("— running\n— idle\n");
  });

  it("a task with only main shows each state once in follow", async () => {
    const r = await run([named("main", "running"), named(null, "running"), named("main", "idle"), named(null, "idle")], null);
    expect(r.out).toBe("— running\n— idle\n");
  });

  it("follow --raw prints every state event, main's per-session ones included", async () => {
    const evs = [named("main", "running"), named(null, "running"), named("main", "idle"), named(null, "idle")];
    const s = await serve((ws) => { evs.forEach((x) => ws.send(JSON.stringify(x))); });
    const out: string[] = [];
    expect(await follow(opts(s.url, out, { raw: true }))).toBe(0);
    s.close();
    expect(out.join("").trim().split("\n").map((l) => JSON.parse(l).name)).toEqual(["main", null, "main", null]);
  });

  it("another session's state lines are prefixed", async () => {
    const r = await run([named("plan", "running"), named(null, "running"), named("plan", "idle"), named(null, "idle")], null);
    expect(r.out).toBe("[plan] — running\n— running\n[plan] — idle\n— idle\n");
  });
});
