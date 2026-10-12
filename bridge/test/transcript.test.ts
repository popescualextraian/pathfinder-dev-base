import { describe, expect, it } from "vitest";
import { renderEvent } from "../src/transcript.js";
import type { TaskEvent } from "../src/types.js";

const e = (type: TaskEvent["type"], data: Record<string, unknown>): TaskEvent =>
  ({ seq: 1, ts: "t", task: "T-1", session: null, agent: "claude", type, data });

describe("renderEvent", () => {
  it("quotes user text and prints the final agent message only", () => {
    expect(renderEvent(e("message", { role: "user", text: "Fix it\nplease", final: true }))).toBe("\n> Fix it\n> please\n");
    expect(renderEvent(e("message", { role: "agent", text: "Done.", final: true }))).toBe("\nDone.\n");
    expect(renderEvent(e("message", { role: "agent", text: "Do", final: false }))).toBeNull();
  });

  it("prints finished tool calls with the last 10 lines of output", () => {
    const tail = Array.from({ length: 15 }, (_, i) => `line ${i + 1}`).join("\n");
    const out = renderEvent(e("tool", { id: "t", title: "npm test", kind: "execute", status: "failed", output_tail: tail }));
    expect(out).toBe("\n▸ npm test — failed\n```\n" + Array.from({ length: 10 }, (_, i) => `line ${i + 6}`).join("\n") + "\n```\n");
    expect(renderEvent(e("tool", { id: "t", title: "ls", kind: "execute", status: "done", output_tail: "" }))).toBe("\n▸ ls — done\n");
    expect(renderEvent(e("tool", { id: "t", title: "ls", kind: "execute", status: "running", output_tail: null }))).toBeNull();
  });

  it("uses a longer fence when the output contains backticks", () => {
    const out = renderEvent(e("tool", { id: "t", title: "cat", kind: "execute", status: "done", output_tail: "a\n```\nb" }));
    expect(out).toBe("\n▸ cat — done\n````\na\n```\nb\n````\n");
  });

  it("calls out questions, answers, gate refusals, states and errors", () => {
    expect(renderEvent(e("question", { id: "Q1", source: "ask", text: "Which DB?", options: ["pg", "sqlite"], recommendation: "pg" })))
      .toBe("\n**Question Q1** (ask): Which DB? Options: pg, sqlite. Recommended: pg.\n");
    expect(renderEvent(e("answer", { question: "Q1", text: "pg", grant: ["push"] }))).toBe("\n**Answer to Q1**: pg (allowed: push)\n");
    expect(renderEvent(e("gate", { rule: "gate", command: "git push" }))).toBe("\n**Gate** refused `git push` (gate)\n");
    expect(renderEvent(e("state", { state: "waiting", reason: "question Q1" }))).toBe("\n_— waiting: question Q1 —_\n");
    expect(renderEvent(e("error", { message: "boom" }))).toBe("\n**Error**: boom\n");
    expect(renderEvent(e("plan", { entries: [] }))).toBeNull();
  });
});
