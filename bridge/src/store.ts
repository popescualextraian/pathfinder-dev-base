// The task's files on /task (spec §5): one writer, atomic state.json, append-only JSONL with seq.
import {
  accessSync, appendFileSync, closeSync, constants, existsSync, fsyncSync, openSync, readFileSync,
  renameSync, writeSync,
} from "node:fs";
import { join } from "node:path";
import type { Question, TaskEvent, TaskRecord } from "./types.js";

export class StoreError extends Error {}

export class Store {
  private seq: number;

  constructor(readonly dir: string, private readonly redact: (s: string) => string = (s) => s) {
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
      writeSync(fd, this.redact(JSON.stringify(r, null, 1)) + "\n");
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
    renameSync(tmp, p);
  }

  appendEvent(e: Omit<TaskEvent, "seq">): TaskEvent {
    const line = this.redact(JSON.stringify({ seq: this.seq + 1, ...e }));
    appendFileSync(this.path("events.jsonl"), line + "\n");
    this.seq += 1;
    return JSON.parse(line) as TaskEvent;
  }

  readEvents(since: number, limit = 1000): TaskEvent[] {
    return this.readJsonl<TaskEvent>("events.jsonl").filter((e) => e.seq > since).slice(0, limit);
  }

  appendQuestion(q: Question): void {
    appendFileSync(this.path("questions.jsonl"), this.redact(JSON.stringify(q)) + "\n");
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

  private readJsonl<T>(name: string): T[] {
    const p = this.path(name);
    if (!existsSync(p)) return [];
    const out: T[] = [];
    for (const line of readFileSync(p, "utf8").split("\n")) {
      if (!line.trim()) continue;
      try {
        out.push(JSON.parse(line) as T);
      } catch {
        // a torn or corrupt line is skipped (spec §5.2)
      }
    }
    return out;
  }
}
