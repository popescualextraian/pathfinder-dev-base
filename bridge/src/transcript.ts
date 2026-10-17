// Readable rendering of events for transcript.md (spec §5.3).
import type { TaskEvent } from "./types.js";

const str = (v: unknown): string => (typeof v === "string" ? v : "");

// Each state change is emitted per session and for the task; show it once. session: the one followed, null for all.
export function showEvent(e: TaskEvent, session: string | null): boolean {
  if (e.type !== "state") return true;
  if (session === null) return e.name !== "main";
  return e.name === session || (e.name === null && ["stopped", "failed", "suspended", "interrupted"].includes(str(e.data.state)));
}

// Other sessions' entries start with [name] on their first line (later lines stay plain, so quotes and fences hold).
export function renderEvent(e: TaskEvent): string | null {
  if (!showEvent(e, null)) return null;
  const out = render(e);
  return out === null || !e.name || e.name === "main" ? out : out.replace(/^(\n*)/, `$1[${e.name}] `);
}

function render(e: TaskEvent): string | null {
  const d = e.data;
  switch (e.type) {
    case "message":
      if (d.role === "user") return "\n" + str(d.text).split("\n").map((l) => `> ${l}`).join("\n") + "\n";
      return d.final === true ? `\n${str(d.text)}\n` : null;
    case "tool": {
      if (d.status !== "done" && d.status !== "failed") return null;
      const head = `\n▸ ${str(d.title)} — ${d.status}\n`;
      const tail = str(d.output_tail).split("\n").filter((l, i, a) => l !== "" || i < a.length - 1).slice(-10).join("\n");
      if (!tail) return head;
      const run = Math.max(0, ...(tail.match(/`+/g) ?? []).map((m) => m.length));
      const fence = "`".repeat(Math.max(3, run + 1));
      return `${head}${fence}\n${tail}\n${fence}\n`;
    }
    case "question": {
      const opts = Array.isArray(d.options) && d.options.length ? ` Options: ${d.options.join(", ")}.` : "";
      const rec = d.recommendation ? ` Recommended: ${str(d.recommendation)}.` : "";
      return `\n**Question ${str(d.id)}** (${str(d.source)}): ${str(d.text)}${opts}${rec}\n`;
    }
    case "answer": {
      const g = Array.isArray(d.grant) && d.grant.length ? ` (allowed: ${d.grant.join(", ")})` : "";
      return `\n**Answer to ${str(d.question)}**: ${str(d.text)}${g}\n`;
    }
    case "gate":
      return `\n**Gate** refused \`${str(d.command)}\` (${str(d.rule)})\n`;
    case "state":
      return `\n_— ${str(d.state)}${d.reason ? `: ${str(d.reason)}` : ""} —_\n`;
    case "error":
      return `\n**Error**: ${str(d.message)}\n`;
    default:
      return null;
  }
}
