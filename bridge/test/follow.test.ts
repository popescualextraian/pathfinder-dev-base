import { describe, expect, it } from "vitest";
import { formatEvent } from "../src/follow.js";
import type { TaskEvent } from "../src/types.js";

const e = (type: TaskEvent["type"], data: Record<string, unknown>): TaskEvent => ({ seq: 7, ts: "t", task: "T-1", session: null, agent: "claude", type, data });

describe("formatEvent", () => {
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
