// Notify, version 1 (spec §10): the project events log and a webhook. Failures never block.
import { appendFileSync } from "node:fs";
import type { Question, TaskRecord } from "./types.js";

export interface NotifyOptions {
  eventsLog: string | null;
  webhook: string | null;
  project: string;
  log(line: string): void;
  fetch?: typeof fetch;
  retryDelayMs?: number;
}

export function notifyPayload(rec: TaskRecord, q: Question | null, ts: string): Record<string, unknown> {
  return {
    task: rec.task,
    project: rec.project,
    state: rec.state,
    question: q ? { id: q.id, text: q.text, options: q.options, recommendation: q.recommendation } : null,
    summary: rec.summary,
    reply: q ? `agentic answer ${rec.task} ${q.id} "…"` : `agentic send ${rec.task} "…"`,
    ts,
  };
}

export class Notifier {
  constructor(private readonly o: NotifyOptions) {}

  logState(rec: TaskRecord): void {
    if (!this.o.eventsLog) return;
    const line = JSON.stringify({ ts: new Date().toISOString(), task: rec.task, project: rec.project, state: rec.state, reason: rec.reason.slice(0, 500) });
    try {
      appendFileSync(this.o.eventsLog, line + "\n");
    } catch (e) {
      this.o.log(`events log failed: ${(e as Error).message}`);
    }
  }

  // true when delivered (or nothing is configured), false after the retry failed
  async webhook(rec: TaskRecord, q: Question | null): Promise<boolean> {
    if (!this.o.webhook) return true;
    const f = this.o.fetch ?? fetch;
    const body = JSON.stringify(notifyPayload(rec, q, new Date().toISOString()));
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const r = await f(this.o.webhook, { method: "POST", body, headers: { "content-type": "application/json" }, signal: AbortSignal.timeout(5000) });
        if (r.ok) return true;
        throw new Error(`HTTP ${r.status}`);
      } catch (e) {
        if (attempt === 1) this.o.log(`webhook failed: ${(e as Error).message}`);
        else await new Promise((r) => setTimeout(r, this.o.retryDelayMs ?? 1000));
      }
    }
    return false;
  }
}
