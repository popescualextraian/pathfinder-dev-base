import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { Notifier, notifyPayload } from "../src/notify.js";
import type { Question, TaskRecord } from "../src/types.js";

const rec = { version: 1, task: "T-1", project: "demo", agent: "claude", model: null, state: "waiting", reason: "question Q1",
  session: "s", branch: "b", target: null, work: "/work", worktree: null, container: null, created_container: false, auto_clean: false, cleaned: false, created: "t", updated: "t", seq: 3, allowed_actions: [], inbox: [], summary: "Need a DB", stopped_by_user: false } as TaskRecord;
const q: Question = { id: "Q1", source: "ask", text: "Which DB?", options: ["pg"], recommendation: "pg", asked: "t", status: "open" };

describe("notify", () => {
  it("builds the payload with a reply hint", () => {
    expect(notifyPayload(rec, q, "now")).toEqual({ task: "T-1", project: "demo", state: "waiting",
      question: { id: "Q1", text: "Which DB?", options: ["pg"], recommendation: "pg" }, summary: "Need a DB",
      reply: 'agentic answer T-1 Q1 "…"', ts: "now" });
    expect(notifyPayload({ ...rec, state: "idle" }, null, "now")).toMatchObject({ question: null, reply: 'agentic send T-1 "…"' });
  });

  it("appends every state change to the project events log as one line", () => {
    const f = join(mkdtempSync(join(tmpdir(), "n-")), "events.jsonl");
    const n = new Notifier({ eventsLog: f, webhook: null, project: "demo", log: () => {} });
    n.logState(rec); n.logState({ ...rec, state: "idle", reason: "x".repeat(5000) });
    const lines = readFileSync(f, "utf8").trim().split("\n").map((l) => JSON.parse(l));
    expect(lines.map((l) => l.state)).toEqual(["waiting", "idle"]);
    expect(lines[1].reason.length).toBeLessThanOrEqual(500);
  });

  it("posts the webhook, retries once, and logs a failure without throwing", async () => {
    const calls: string[] = [];
    const logs: string[] = [];
    let fail = 2;
    const fetchStub = (async (url: string, init: RequestInit) => {
      calls.push(`${url} ${init.body}`);
      if (fail-- > 0) throw new Error("down");
      return new Response(null, { status: 204 });
    }) as unknown as typeof fetch;
    const n = new Notifier({ eventsLog: null, webhook: "https://hooks.example.com/x", project: "demo", log: (m) => logs.push(m), fetch: fetchStub, retryDelayMs: 1 });
    await n.webhook(rec, q);
    expect(calls).toHaveLength(2);
    expect(logs.join()).toContain("webhook failed");
    fail = 0;
    await n.webhook(rec, q);
    expect(calls).toHaveLength(3);
  });
});
