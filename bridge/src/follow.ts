// agentic-bridge follow: prints the task's events readably from the WebSocket (spec §15, follow).
import WebSocket from "ws";
import type { TaskEvent } from "./types.js";

const s = (v: unknown): string => (typeof v === "string" ? v : "");
const END = new Set(["waiting", "idle", "stopped", "failed", "suspended"]);

export function formatEvent(e: TaskEvent): string {
  const d = e.data;
  switch (e.type) {
    case "state": return `— ${s(d.state)}${d.reason ? ` (${s(d.reason)})` : ""}\n`;
    case "message":
      if (d.role === "user") return s(d.text).split("\n").map((l) => `> ${l}`).join("\n") + "\n";
      return d.final ? "\n" : s(d.text);
    case "tool": return `▸ ${s(d.title)} — ${s(d.status)}\n`;
    case "plan": return `plan: ${Array.isArray(d.entries) ? d.entries.length : 0} entries\n`;
    case "question": {
      const opts = Array.isArray(d.options) && d.options.length ? ` [${d.options.join(", ")}]` : "";
      const rec = d.recommendation ? ` (recommended: ${s(d.recommendation)})` : "";
      return `? ${s(d.id)} ${s(d.text)}${opts}${rec}\n`;
    }
    case "answer": return `= ${s(d.question)} ${s(d.text)}${Array.isArray(d.grant) && d.grant.length ? ` (allowed: ${d.grant.join(", ")})` : ""}\n`;
    case "gate": return `✗ gate refused: ${s(d.command)}\n`;
    case "error": return `! ${s(d.message)}\n`;
    default: return "";
  }
}

export function follow(o: { url: string; token: string; since: number; raw: boolean; forever: boolean; out: (s: string) => void }): Promise<number> {
  return new Promise((resolve) => {
    const ws = new WebSocket(`${o.url}/events?since=${o.since}`, { headers: { authorization: `Bearer ${o.token}` } });
    // A state event ends the stream only once the backlog is through: the stored events are sent first.
    let settled: NodeJS.Timeout | null = null;
    ws.on("message", (m) => {
      const e = JSON.parse(m.toString()) as TaskEvent;
      o.out(o.raw ? JSON.stringify(e) + "\n" : formatEvent(e));
      if (settled) clearTimeout(settled);
      if (!o.forever && e.type === "state" && END.has(s(e.data.state))) settled = setTimeout(() => { ws.close(); resolve(0); }, 300);
    });
    ws.on("unexpected-response", (_req, res) => { o.out(`agentic-bridge: follow refused (HTTP ${res.statusCode})\n`); resolve(1); });
    ws.on("error", (err) => { o.out(`agentic-bridge: ${err.message}\n`); resolve(1); });
    ws.on("close", () => resolve(0));
  });
}
