import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { UpdateMapper, outputTail, type Mapped, type Update } from "../src/map.js";

const chunk = (text: string): Update => ({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
const fixture = (name: string): Update[] =>
  readFileSync(new URL(`./fixtures/${name}-updates.jsonl`, import.meta.url), "utf8").trim().split("\n").map((l) => JSON.parse(l));

describe("UpdateMapper", () => {
  it("buffers message chunks until a flush, then emits one final message per turn", () => {
    const m = new UpdateMapper();
    expect(m.handle(chunk("Hel"))).toEqual([]);
    expect(m.handle(chunk("lo"))).toEqual([]);
    expect(m.flushPartial()).toEqual([{ type: "message", data: { role: "agent", text: "Hello", final: false } }]);
    expect(m.flushPartial()).toEqual([]);
    m.handle(chunk(" there"));
    const { events, summary } = m.finishTurn();
    expect(events).toEqual([
      { type: "message", data: { role: "agent", text: " there", final: false } },
      { type: "message", data: { role: "agent", text: "Hello there", final: true } },
    ]);
    expect(summary).toBe("Hello there");
  });

  it("flushes text before a tool event; the summary is the text after the last tool call", () => {
    const m = new UpdateMapper();
    m.handle(chunk("Let me look."));
    const out = m.handle({ sessionUpdate: "tool_call", toolCallId: "t1", title: "ls", kind: "execute", status: "pending" });
    expect(out.map((e) => e.type)).toEqual(["message", "tool"]);
    m.handle(chunk("Found it."));
    expect(m.finishTurn().summary).toBe("Found it.");
  });

  it("emits tool events on status changes only, with the latest title and an output tail when finished", () => {
    const m = new UpdateMapper();
    const a = m.handle({ sessionUpdate: "tool_call", toolCallId: "t1", title: "Terminal", kind: "execute", status: "pending" });
    expect(a).toEqual([{ type: "tool", data: { id: "t1", title: "Terminal", kind: "execute", status: "pending", output_tail: null } }]);
    expect(m.handle({ sessionUpdate: "tool_call_update", toolCallId: "t1", title: "npm test" })).toEqual([]);
    expect(m.handle({ sessionUpdate: "tool_call_update", toolCallId: "t1", status: "in_progress" })[0]?.data.status).toBe("running");
    const done = m.handle({ sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed",
      content: [{ type: "content", content: { type: "text", text: "```console\nok\n```" } }] });
    expect(done).toEqual([{ type: "tool", data: { id: "t1", title: "npm test", kind: "execute", status: "done", output_tail: "ok" } }]);
    expect(m.handle({ sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed" })).toEqual([]);
  });

  it("maps plans and ignores everything else", () => {
    const m = new UpdateMapper();
    expect(m.handle({ sessionUpdate: "plan", entries: [{ content: "a", status: "pending" }] }))
      .toEqual([{ type: "plan", data: { entries: [{ content: "a", status: "pending" }] } }]);
    for (const s of ["agent_thought_chunk", "usage_update", "available_commands_update", "user_message_chunk", "session_info_update"]) {
      expect(m.handle({ sessionUpdate: s, content: { type: "text", text: "x" } })).toEqual([]);
    }
  });

  it("claude fixture: the gate refusal of git push is a failed tool with the reason", () => {
    const m = new UpdateMapper();
    const out: Mapped[] = fixture("claude").flatMap((u) => m.handle(u));
    const failed = out.filter((e) => e.type === "tool" && e.data.status === "failed");
    expect(failed).toHaveLength(1);
    expect(failed[0]?.data.title).toBe("git push origin HEAD");
    expect(String(failed[0]?.data.output_tail)).toContain("agentic gate: git push is not in allowed_actions");
    expect(String(m.finishTurn().events.at(-1)?.data.text)).toContain("PELICAN");
  });

  it("copilot fixture: the deny decision is a failed tool with the reason", () => {
    const m = new UpdateMapper();
    const out = fixture("copilot").flatMap((u) => m.handle(u));
    const failed = out.filter((e) => e.type === "tool" && e.data.status === "failed");
    expect(failed).toHaveLength(1);
    expect(String(failed[0]?.data.output_tail)).toContain("agentic gate: git push is not in allowed_actions");
  });
});

describe("outputTail", () => {
  it("keeps the last 20 lines and at most 2 KB, without code fences", () => {
    const text = "```\n" + Array.from({ length: 30 }, (_, i) => `l${i + 1}`).join("\n") + "\n```";
    const t = outputTail({ sessionUpdate: "tool_call_update", content: [{ type: "content", content: { type: "text", text } }] });
    expect(t.split("\n")).toEqual(Array.from({ length: 20 }, (_, i) => `l${i + 11}`));
    const long = outputTail({ sessionUpdate: "tool_call_update", rawOutput: "x".repeat(5000) });
    expect(long).toHaveLength(2048);
  });

  it("falls back to rawOutput as a string, its content, or its message", () => {
    expect(outputTail({ sessionUpdate: "u", rawOutput: "plain" })).toBe("plain");
    expect(outputTail({ sessionUpdate: "u", rawOutput: { content: "c" } })).toBe("c");
    expect(outputTail({ sessionUpdate: "u", rawOutput: { message: "m", code: "denied" } })).toBe("m");
    expect(outputTail({ sessionUpdate: "u" })).toBe("");
  });
});
