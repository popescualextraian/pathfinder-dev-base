import { WebSocketServer } from "ws";
import type { AddressInfo } from "node:net";
import { describe, expect, it } from "vitest";
import { follow, formatEvent } from "../src/follow.js";
import type { TaskEvent } from "../src/types.js";

const e = (type: TaskEvent["type"], data: Record<string, unknown>): TaskEvent => ({ seq: 7, ts: "t", task: "T-1", session: null, agent: "claude", type, data });

describe("formatEvent", () => {
  it("replaces control characters from the agent, keeping newline and tab", () => {
    const out = formatEvent(e("message", { role: "assistant", text: "a\u001b[2Jb\u009bc\u007fd\te\nf" }));
    expect(out).toBe("a [2Jb c d\te\nf");
  });
  it("prints one readable line per event; partial messages stream without a newline", () => {
    expect(formatEvent(e("state", { state: "waiting", reason: "question Q1" }))).toBe("— waiting (question Q1)\n");
    expect(formatEvent(e("message", { role: "agent", text: "Hel", final: false }))).toBe("Hel");
    expect(formatEvent(e("message", { role: "agent", text: "Hello", final: true }))).toBe("\n");
    expect(formatEvent(e("message", { role: "user", text: "Fix it", final: true }))).toBe("> Fix it\n");
    expect(formatEvent(e("tool", { title: "npm test", status: "failed" }))).toBe("▸ npm test — failed\n");
    expect(formatEvent(e("question", { id: "Q1", text: "Which DB?", options: ["pg"], recommendation: "pg" }))).toBe("? Q1 Which DB? [pg] (recommended: pg)\n");
    expect(formatEvent(e("answer", { question: "Q1", text: "pg", grant: ["push"] }))).toBe("= Q1 pg (allowed: push)\n");
    expect(formatEvent(e("gate", { rule: "gate", command: "git push" }))).toBe("✗ gate refused: git push\n");
    expect(formatEvent(e("error", { message: "boom" }))).toBe("! boom\n");
  });
});

describe("follow", () => {
  async function serve(onConn: (ws: import("ws").WebSocket) => void) {
    const wss = new WebSocketServer({ port: 0, host: "127.0.0.1" });
    await new Promise((r) => wss.on("listening", r));
    wss.on("connection", onConn);
    return { url: `ws://127.0.0.1:${(wss.address() as AddressInfo).port}`, close: () => { wss.clients.forEach((c) => c.terminate()); wss.close(); } };
  }
  const opts = (url: string, out: string[], over = {}) => ({ url, token: "t", since: 0, raw: false, forever: false, out: (s: string) => out.push(s), ...over });

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
});
