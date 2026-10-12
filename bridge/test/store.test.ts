import { mkdtempSync, writeFileSync, readFileSync, appendFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import { Store, StoreError } from "../src/store.js";
import { makeRedactor } from "../src/redact.js";
import type { TaskRecord, Question } from "../src/types.js";

export function record(over: Partial<TaskRecord> = {}): TaskRecord {
  return {
    version: 1, task: "T-1", project: "demo", agent: "claude", model: null, state: "starting", reason: "",
    session: null, branch: null, created: "t0", updated: "t0", seq: 0, allowed_actions: [], inbox: [],
    summary: "", stopped_by_user: false, ...over,
  };
}
const ev = (type: "state" | "message" = "state") =>
  ({ ts: "t", task: "T-1", session: null, agent: "claude" as const, type, data: { state: "running" } });

describe("Store", () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "store-")); });

  it("has no record until one is written; written records read back with the last seq", () => {
    const s = new Store(dir);
    expect(s.hasRecord()).toBe(false);
    s.appendEvent(ev()); s.appendEvent(ev());
    const r = record();
    s.writeRecord(r);
    expect(s.hasRecord()).toBe(true);
    expect(s.readRecord().seq).toBe(2);
    expect(readFileSync(join(dir, "state.json"), "utf8").endsWith("\n")).toBe(true);
  });

  it("numbers events from 1 and continues after a restart", () => {
    const a = new Store(dir);
    expect(a.appendEvent(ev()).seq).toBe(1);
    expect(a.appendEvent(ev()).seq).toBe(2);
    const b = new Store(dir);
    expect(b.appendEvent(ev()).seq).toBe(3);
    expect(b.readEvents(1).map((e) => e.seq)).toEqual([2, 3]);
    expect(b.readEvents(0, 1).map((e) => e.seq)).toEqual([1]);
  });

  it("skips a torn or corrupt line in events and questions", () => {
    const s = new Store(dir);
    s.appendEvent(ev());
    appendFileSync(join(dir, "events.jsonl"), '{"seq":2,"ts":\n');
    const t = new Store(dir);
    expect(t.readEvents(0).map((e) => e.seq)).toEqual([1]);
    expect(t.appendEvent(ev()).seq).toBe(2);
  });

  it("refuses a corrupt state.json with the file name and never resets it", () => {
    writeFileSync(join(dir, "state.json"), "{");
    const s = new Store(dir);
    expect(() => s.readRecord()).toThrow(StoreError);
    expect(() => s.readRecord()).toThrow(join(dir, "state.json"));
    expect(readFileSync(join(dir, "state.json"), "utf8")).toBe("{");
  });

  it("starts a fresh line after a torn tail without newline", () => {
    writeFileSync(join(dir, "events.jsonl"), '{"seq":1,"ts":"t","task":"T-1","session":null,"agent":"claude","type":"state","data":{}}\n{"seq":2,"ts"');
    writeFileSync(join(dir, "questions.jsonl"), '{"id":"Q');
    const s = new Store(dir);
    expect(s.appendEvent(ev()).seq).toBe(2);
    expect(s.readEvents(0).map((e) => e.seq)).toEqual([1, 2]);
    s.appendQuestion({ id: "Q9", source: "ask", text: "x", options: [], recommendation: null, asked: "t", status: "open" });
    expect(s.readQuestions().map((q) => q.id)).toEqual(["Q9"]);
  });

  it("skips lines that parse to non-objects", () => {
    writeFileSync(join(dir, "events.jsonl"), 'null\n3\n[1]\n');
    const s = new Store(dir);
    expect(s.readEvents(0)).toEqual([]);
    expect(s.appendEvent(ev()).seq).toBe(1);
  });

  it("redacts secrets containing quotes or backslashes", () => {
    const secret = 'pa"ss\\word-12345';
    const s = new Store(dir, makeRedactor([secret]));
    const e = s.appendEvent({ ...ev("message"), data: { text: `x ${secret} y` } });
    expect(e.data.text).toBe("x [redacted] y");
    expect(readFileSync(join(dir, "events.jsonl"), "utf8")).not.toContain("word-12345");
    s.writeRecord(record({ summary: secret }));
    expect(s.readRecord().summary).toBe("[redacted]");
  });

  it("keeps the last line per question id", () => {
    const s = new Store(dir);
    const q: Question = { id: "Q1", source: "ask", text: "Which DB?", options: [], recommendation: null, asked: "t", status: "open" };
    s.appendQuestion(q);
    s.appendQuestion({ ...q, status: "answered", answer: "postgres" });
    s.appendQuestion({ ...q, id: "Q2" });
    expect(s.readQuestions().map((x) => [x.id, x.status])).toEqual([["Q1", "answered"], ["Q2", "open"]]);
  });

  it("redacts what it writes", () => {
    const s = new Store(dir, makeRedactor(["task-token-0123456789"]));
    const e = s.appendEvent({ ...ev("message"), data: { text: "use task-token-0123456789" } });
    expect(e.data.text).toBe("use [redacted]");
    s.writeRecord(record({ inbox: [{ kind: "prompt", text: "sk-ant-api03-0123456789abcdef" }] }));
    expect(readFileSync(join(dir, "state.json"), "utf8")).not.toContain("sk-ant-api03");
    s.appendQuestion({ id: "Q1", source: "ask", text: "key task-token-0123456789?", options: [], recommendation: null, asked: "t", status: "open" });
    expect(s.readQuestions()[0]?.text).toBe("key [redacted]?");
    s.appendTranscript("token task-token-0123456789\n");
    expect(readFileSync(join(dir, "transcript.md"), "utf8")).toBe("token [redacted]\n");
  });

  it("reads the first prompt when there is one", () => {
    const s = new Store(dir);
    expect(s.readPrompt()).toBeNull();
    writeFileSync(join(dir, "prompt.md"), "Fix the login bug\n");
    expect(s.readPrompt()).toBe("Fix the login bug\n");
  });

  it.skipIf(process.getuid?.() === 0)("names the directory when it cannot write there", () => {
    chmodSync(dir, 0o500);
    const s = new Store(dir);
    expect(() => s.checkWritable()).toThrow(dir);
    chmodSync(dir, 0o700);
  });
});
