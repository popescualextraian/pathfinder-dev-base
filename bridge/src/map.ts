// ACP session updates → bridge events (spec §8.3). Thoughts, usage, commands, config, titles and
// user chunks are dropped; message chunks are buffered and flushed by the caller.
export interface Update {
  sessionUpdate: string;
  [k: string]: unknown;
}
export interface Mapped {
  type: "message" | "tool" | "plan";
  data: Record<string, unknown>;
}
type ToolStatus = "pending" | "running" | "done" | "failed";

const STATUS: Record<string, ToolStatus> = { pending: "pending", in_progress: "running", completed: "done", failed: "failed" };
const str = (v: unknown): string => (typeof v === "string" ? v : "");

export class UpdateMapper {
  private partial = "";
  private turn = "";
  private segment = "";
  private readonly tools = new Map<string, { title: string; kind: string; status: ToolStatus }>();

  handle(u: Update): Mapped[] {
    switch (u.sessionUpdate) {
      case "agent_message_chunk": {
        const c = u.content as { type?: string; text?: unknown } | undefined;
        const t = c?.type === "text" ? str(c.text) : "";
        this.partial += t;
        this.turn += t;
        this.segment += t;
        return [];
      }
      case "tool_call": {
        const out = this.flushPartial();
        this.segment = "";
        const id = str(u.toolCallId);
        const e = { title: str(u.title), kind: str(u.kind) || "other", status: STATUS[str(u.status)] ?? "pending" };
        this.tools.set(id, e);
        out.push(this.toolEvent(id, e, u));
        return out;
      }
      case "tool_call_update": {
        const id = str(u.toolCallId);
        const e = this.tools.get(id) ?? { title: "", kind: "other", status: "pending" as ToolStatus };
        this.tools.set(id, e);
        if (str(u.title)) e.title = str(u.title);
        if (str(u.kind)) e.kind = str(u.kind);
        const s = STATUS[str(u.status)];
        if (!s || s === e.status) return [];
        const out = this.flushPartial();
        e.status = s;
        out.push(this.toolEvent(id, e, u));
        return out;
      }
      case "plan":
        return [{ type: "plan", data: { entries: Array.isArray(u.entries) ? u.entries : [] } }];
      default:
        return [];
    }
  }

  flushPartial(): Mapped[] {
    if (!this.partial) return [];
    const text = this.partial;
    this.partial = "";
    return [{ type: "message", data: { role: "agent", text, final: false } }];
  }

  finishTurn(): { events: Mapped[]; summary: string } {
    const events = this.flushPartial();
    if (this.turn) events.push({ type: "message", data: { role: "agent", text: this.turn, final: true } });
    const summary = this.segment.trim();
    this.turn = "";
    this.segment = "";
    this.tools.clear();
    return { events, summary };
  }

  private toolEvent(id: string, e: { title: string; kind: string; status: ToolStatus }, u: Update): Mapped {
    const finished = e.status === "done" || e.status === "failed";
    return { type: "tool", data: { id, title: e.title, kind: e.kind, status: e.status, output_tail: finished ? outputTail(u) : null } };
  }
}

// outputTail: the tool's text output, fences removed, last 20 lines, 2 KB at most.
export function outputTail(u: Update): string {
  const content = Array.isArray(u.content) ? (u.content as Array<{ type?: string; content?: { type?: string; text?: unknown } }>) : [];
  let text = content.filter((c) => c.type === "content" && c.content?.type === "text").map((c) => str(c.content?.text)).join("\n");
  if (!text) {
    const raw = u.rawOutput as unknown;
    if (typeof raw === "string") text = raw;
    else if (raw && typeof raw === "object") text = str((raw as Record<string, unknown>).content) || str((raw as Record<string, unknown>).message);
  }
  const lines = text.split("\n").filter((l) => !/^```/.test(l));
  while (lines.length && lines[lines.length - 1] === "") lines.pop();
  return lines.slice(-20).join("\n").slice(-2048);
}
