// The task's files on /task (spec §5): one writer, atomic state.json, append-only JSONL with seq.
import {
  accessSync, appendFileSync, closeSync, constants, existsSync, fsyncSync, openSync, readFileSync,
  renameSync, writeSync,
} from "node:fs";
import { join } from "node:path";
import { redactDeep } from "./redact.js";
import type { Question, TaskEvent, TaskRecord } from "./types.js";

export class StoreError extends Error {}

export class Store {
  private seq: number;

  constructor(readonly dir: string, private readonly redact: (s: string) => string = (s) => s) {
    for (const f of ["events.jsonl", "questions.jsonl", "transcript.md"]) this.terminateLine(f);
    this.seq = this.readJsonl<TaskEvent>("events.jsonl").reduce((m, e) => Math.max(m, e.seq ?? 0), 0);
  }

  path(name: string): string {
    return join(this.dir, name);
  }

  checkWritable(): void {
    try {
      accessSync(this.dir, constants.W_OK);
    } catch {
      throw new StoreError(`${this.dir} is not writable by uid ${process.getuid?.() ?? "?"}; fix the owner of the task volume`);
    }
  }

  hasRecord(): boolean {
    return existsSync(this.path("state.json"));
  }

  readRecord(): TaskRecord {
    const p = this.path("state.json");
    try {
      return JSON.parse(readFileSync(p, "utf8")) as TaskRecord;
    } catch {
      throw new StoreError(`${p} is not valid JSON; fix or remove it by hand (it is never reset)`);
    }
  }

  writeRecord(r: TaskRecord): void {
    r.seq = this.seq;
    const p = this.path("state.json");
    const tmp = `${p}.tmp`;
    const fd = openSync(tmp, "w", 0o644);
    try {
      writeSync(fd, JSON.stringify(redactDeep(r, this.redact), null, 1) + "\n");
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
    renameSync(tmp, p);
  }

  // writeResult: the summary of a scheduled run, whole, redacted, written like state.json.
  writeResult(text: string): void {
    const p = this.path("result.md");
    const tmp = `${p}.tmp`;
    const fd = openSync(tmp, "w", 0o644);
    try {
      writeSync(fd, this.redact(text.endsWith("\n") ? text : `${text}\n`));
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
    renameSync(tmp, p);
  }

  appendEvent(e: Omit<TaskEvent, "seq">): TaskEvent {
    const out = redactDeep({ seq: this.seq + 1, ...e }, this.redact) as TaskEvent;
    appendFileSync(this.path("events.jsonl"), JSON.stringify(out) + "\n");
    this.seq += 1;
    return out;
  }

  readEvents(since: number, limit = 1000, keep: (e: TaskEvent) => boolean = () => true): TaskEvent[] {
    return this.readJsonl<TaskEvent>("events.jsonl").filter((e) => e.seq > since && keep(e)).slice(0, limit);
  }

  appendQuestion(q: Question): void {
    appendFileSync(this.path("questions.jsonl"), JSON.stringify(redactDeep(q, this.redact)) + "\n");
  }

  readQuestions(): Question[] {
    const byId = new Map<string, Question>();
    for (const q of this.readJsonl<Question>("questions.jsonl")) byId.set(q.id, q);
    return [...byId.values()];
  }

  appendTranscript(md: string): void {
    appendFileSync(this.path("transcript.md"), this.redact(md));
  }

  readPrompt(): string | null {
    const p = this.path("prompt.md");
    return existsSync(p) ? readFileSync(p, "utf8") : null;
  }

  // A torn tail without a newline must not swallow the next append.
  private terminateLine(name: string): void {
    const p = this.path(name);
    if (!existsSync(p)) return;
    const b = readFileSync(p);
    if (b.length > 0 && b[b.length - 1] !== 0x0a) appendFileSync(p, "\n");
  }

  private readJsonl<T>(name: string): T[] {
    const p = this.path(name);
    if (!existsSync(p)) return [];
    const out: T[] = [];
    for (const line of readFileSync(p, "utf8").split("\n")) {
      if (!line.trim()) continue;
      try {
        const v: unknown = JSON.parse(line);
        if (v !== null && typeof v === "object" && !Array.isArray(v)) out.push(v as T);
      } catch {
        // a torn or corrupt line is skipped (spec §5.2)
      }
    }
    return out;
  }
}
