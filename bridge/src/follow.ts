// agentic-bridge follow: prints the task's events readably from the WebSocket (spec §15, follow).
import WebSocket from "ws";
import type { TaskEvent } from "./types.js";

const s = (v: unknown): string => (typeof v === "string" ? v : "");
const END = new Set(["waiting", "idle", "stopped", "failed", "suspended"]);

// Agent-written text must not drive the terminal: control characters other than newline and tab go.
// eslint-disable-next-line no-control-regex
const plain = (t: string): string => t.replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/g, " ");

// whole: the status view sends no chunks, so a final message prints its text.
export function formatEvent(e: TaskEvent, whole = false): string {
  return plain(formatRaw(e, whole));
}

function formatRaw(e: TaskEvent, whole: boolean): string {
  const d = e.data;
  switch (e.type) {
    case "state": return `— ${s(d.state)}${d.reason ? ` (${s(d.reason)})` : ""}\n`;
    case "message":
      if (d.role === "user") return s(d.text).split("\n").map((l) => `> ${l}`).join("\n") + "\n";
      return d.final ? (whole ? `${s(d.text)}\n` : "\n") : s(d.text);
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

export function follow(o: { url: string; token: string; since: number; raw: boolean; forever: boolean; status: boolean; out: (s: string) => void }): Promise<number> {
  return new Promise((resolve) => {
    const ws = new WebSocket(`${o.url}/events?since=${o.since}${o.status ? "&view=status" : ""}`, { headers: { authorization: `Bearer ${o.token}` } });
    // A state event ends the stream only once the backlog is through: the stored events are sent first.
    let settled: NodeJS.Timeout | null = null;
    let ended = false; // a final state was seen: the bridge closing the socket afterwards is normal
    ws.on("message", (m) => {
      let e: TaskEvent;
      try {
        e = JSON.parse(m.toString()) as TaskEvent;
      } catch {
        o.out("agentic-bridge: skipped a frame that is not JSON\n");
        return;
      }
      o.out(o.raw ? JSON.stringify(e) + "\n" : formatEvent(e, o.status));
      if (settled) clearTimeout(settled);
      if (e.type === "state" && END.has(s(e.data.state))) ended = true;
      else if (e.type === "state") ended = false;
      if (!o.forever && ended) settled = setTimeout(() => { ws.close(); resolve(0); }, 300);
    });
    ws.on("unexpected-response", (_req, res) => { o.out(`agentic-bridge: follow refused (HTTP ${res.statusCode})\n`); resolve(1); });
    ws.on("error", (err) => { o.out(`agentic-bridge: ${err.message}\n`); resolve(1); });
    ws.on("close", (code) => {
      if (settled) clearTimeout(settled);
      if (code === 1000 || code === 1005 || ended) return resolve(0);
      o.out(`agentic-bridge: connection lost (close code ${code})\n`);
      resolve(1);
    });
  });
}
