// The orchestrator: feeds inputs to the state machine and performs its effects (spec §6).
import { spawnSync } from "node:child_process";
import type { ApiTarget } from "./api.js";
import type { AgentHooks, AgentLike } from "./agent.js";
import type { Config } from "./config.js";
import { UpdateMapper, type Mapped } from "./map.js";
import type { Notifier } from "./notify.js";
import type { Store } from "./store.js";
import { TaskMachine, type Effect, type Input, type Outcome } from "./task.js";
import { NO_SUMMARY, SCHEDULED_NOTE, SUMMARY_PROMPT, TIMEOUT_NOTE } from "./scheduled.js";
import { renderEvent } from "./transcript.js";
import { makeRedactor, redactDeep } from "./redact.js";
import { MAIN, newSession, sessionView, upgradeRecord, type SessionView } from "./sessions.js";
import type { EventType, Question, State, TaskEvent, TaskRecord } from "./types.js";

export class BridgeError extends Error {}

export interface WorktreeResult { ok: boolean; out: string; err: string }

export interface BridgeDeps {
  store: Store;
  config: Config;
  notifier: Notifier;
  paragraph: string;
  agentFactory(hooks: AgentHooks, cwd: string): AgentLike;
  worktree(args: string[]): WorktreeResult;
  release(): void;
  exit(code: number): void;
  now(): string;
  log(line: string): void;
}

const message = (e: unknown): string => (e instanceof Error ? e.message : String(e));
const TERMINAL: State[] = ["stopped", "suspended", "failed", "interrupted"];
const LIVE: State[] = ["starting", "running", "waiting"];

export class Bridge implements ApiTarget {
  private machine: TaskMachine | null = null;
  private readonly mappers = new Map<string, UpdateMapper>(); // per session name
  private agent: AgentLike | null = null;
  private readonly listeners = new Set<(e: TaskEvent) => void>();
  private readonly waiters = new Map<string, (optionId: string | null) => void>();
  private idle: NodeJS.Timeout | null = null;
  private flush: NodeJS.Timeout | null = null;
  private readonly kills = new Set<Promise<void>>();
  private readonly webhooks = new Set<Promise<void>>();
  private incoming: ((optionId: string | null) => void) | null = null;
  private down = false;
  private readonly redact: (s: string) => string;
  // a scheduled run (spec 2026-10-15 §6.2): work, then one summary turn, then the end
  private phase: "off" | "work" | "summary" | "done" = "off";
  private lastTurn = "";
  private resultText: string | null = null;
  private timedOut = false;
  private runTimer: NodeJS.Timeout | null = null;
  private graceTimer: NodeJS.Timeout | null = null;

  constructor(private readonly d: BridgeDeps) {
    // what leaves the bridge outside the store (status, webhook, events log, log lines) is masked too
    this.redact = makeRedactor([d.config.tokens.task, d.config.tokens.agent]);
  }

  boot(): void {
    const { store, config } = this.d;
    store.checkWritable();
    const fresh = !store.hasRecord();
    let record: TaskRecord;
    if (fresh) {
      const prompt = store.readPrompt() ?? config.prompt;
      if (!prompt) throw new BridgeError(`no prompt: write ${store.path("prompt.md")} or set AGENTIC_PROMPT`);
      let work = config.work;
      let worktree: string | null = null;
      if (config.worktree) {
        if (!config.branch) throw new BridgeError("AGENTIC_WORKTREE=1 needs AGENTIC_BRANCH");
        const r = this.d.worktree(["add", config.work, config.task, config.branch]);
        const path = r.out.trim().split("\n").pop() ?? "";
        if (!r.ok || !path) {
          const why = (r.err || r.out).trim();
          this.d.log(`worktree: ${why}`);
          throw new BridgeError(`could not create the worktree: ${why}`);
        }
        worktree = work = path;
      }
      const now = this.d.now();
      record = {
        version: 1, task: config.task, project: config.project, agent: config.agent, model: config.model, state: "starting",
        reason: "", session: null, branch: config.worktree ? config.branch : null,
        target: config.target, work, worktree, container: config.container, created_container: config.createdContainer, auto_clean: config.autoClean, cleaned: false, created: now, updated: now, seq: 0, allowed_actions: [...config.allowed],
        sessions: [newSession(MAIN, config.model, now, { inbox: [{ kind: "prompt", text: config.scheduled ? `${prompt}${SCHEDULED_NOTE}` : prompt }] })],
        capabilities: null, summary: "", stopped_by_user: false,
        scheduled: config.scheduled, run_timeout: config.scheduled ? config.runTimeoutMs / 1000 : null,
      };
    } else {
      record = upgradeRecord(store.readRecord());
      if (typeof record.work !== "string") record.work = config.work;
      record.cleaned = record.cleaned === true;
      record.created_container = record.created_container === true;
      record.scheduled = record.scheduled === true;
      record.run_timeout = typeof record.run_timeout === "number" ? record.run_timeout : null;
    }
    // all questions, answered ones too: the next question id counts them all
    this.machine = new TaskMachine(record, store.readQuestions(), this.d.now);
    this.flush = setInterval(() => { for (const [name, mp] of this.mappers) this.emitMapped(name, mp.flushPartial()); }, 1000);
    if (fresh && config.scheduled) {
      this.phase = "work";
      this.runTimer = setTimeout(() => this.onRunTimeout(), config.runTimeoutMs);
    }
    this.run({ kind: "boot", fresh });
  }

  ready(): boolean {
    return this.machine !== null;
  }

  status(): Record<string, unknown> {
    const m = this.m();
    const { sessions, ...rest } = m.record;
    return redactDeep({
      ...rest,
      sessions: this.sessions(),
      inbox: sessions.reduce((n, s) => n + s.inbox.length, 0),
      questions: m.openQuestions().map((q) => ({ id: q.id, source: q.source, text: q.text, options: q.options, recommendation: q.recommendation, asked: q.asked, session: q.session })),
    }, this.redact);
  }

  // sessions: the views; a task in a terminal state shows that state instead of a stale live one
  sessions(): SessionView[] {
    const rec = this.m().record;
    const end = TERMINAL.includes(rec.state);
    return redactDeep(rec.sessions.map((s) => {
      const v = sessionView(s);
      return end && LIVE.includes(v.state) ? { ...v, state: rec.state } : v;
    }), this.redact);
  }

  command(input: Input): Outcome {
    return this.run(input);
  }

  events(since: number, limit: number, keep?: (e: TaskEvent) => boolean): TaskEvent[] {
    return this.d.store.readEvents(since, limit, keep);
  }

  subscribe(fn: (e: TaskEvent) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  // shutdownAgent: ends the agent without a state change (SIGTERM from Docker: the next boot shows interrupted).
  async shutdownAgent(): Promise<void> {
    this.down = true;
    this.clearTimers();
    const a = this.agent;
    this.agent = null;
    if (a) this.track(a.kill());
    await this.drain();
  }

  // drain: waits for the kills and the webhooks in progress (a failed or stopped task still notifies).
  private async drain(): Promise<void> {
    while (this.kills.size || this.webhooks.size) await Promise.all([...this.kills, ...this.webhooks]);
  }

  // track: a kill in progress; shutdownAgent waits for all of them, so no agent process outlives the bridge.
  private track(p: Promise<void>): void {
    const t = p.catch(() => {}).finally(() => this.kills.delete(t));
    this.kills.add(t);
  }

  private log(line: string): void {
    this.d.log(this.redact(line));
  }

  private m(): TaskMachine {
    if (!this.machine) throw new BridgeError("the bridge has not booted");
    return this.machine;
  }

  private run(input: Input): Outcome {
    const m = this.m();
    const out = m.apply(input);
    // any input counts as activity: the machine only emits timer effects on state changes
    if (input.kind !== "idleTimeout") this.touch();
    if (!out.ok) return out;
    // the record first: the gate reads allowed_actions from it before the agent retries
    this.d.store.writeRecord(m.record);
    for (const e of out.effects) this.perform(e);
    this.d.store.writeRecord(m.record);
    if (input.kind !== "idleTimeout") this.touch();
    if (this.phase === "off" && this.cleanable(input)) this.autoClean();
    if (input.kind === "turnEnd" && input.name === MAIN && (this.phase === "work" || this.phase === "summary")) this.scheduledStep();
    return out;
  }

  // cleanable: auto-clean is on and a turn just ended normally with nothing left to do in any session
  // (a derived idle means no session runs, starts or waits).
  private cleanable(input: Input): boolean {
    const m = this.m();
    return this.d.config.autoClean && input.kind === "turnEnd" && input.stopReason !== "cancelled"
      && m.record.state === "idle" && m.record.sessions.every((s) => s.inbox.length === 0) && m.openQuestions().length === 0 && !m.record.cleaned;
  }

  // autoClean: removes the worktree (refusing unpushed work), then stops the task; the exit releases
  // the container when this task created it. false when the worktree was kept.
  private autoClean(reason = "auto-cleaned"): boolean {
    const rec = this.m().record;
    if (rec.worktree && rec.branch) {
      const r = this.d.worktree(["remove", this.d.config.work, rec.task, rec.branch]);
      if (!r.ok) {
        this.emit("error", { message: `auto-clean kept the task: ${(r.err || r.out).trim()}` }, null);
        return false;
      }
    }
    rec.cleaned = true;
    this.run({ kind: "stop", reason, byUser: false });
    return true;
  }

  // scheduledStep: after the work turn, the summary prompt; after the summary turn, the end.
  private scheduledStep(): void {
    const m = this.m();
    if (m.busy(MAIN) || m.record.state === "stopped" || m.record.state === "failed") return;
    if (this.phase === "work") {
      this.phase = "summary";
      this.run({ kind: "userPrompt", text: this.timedOut ? `${TIMEOUT_NOTE}\n\n${SUMMARY_PROMPT}` : SUMMARY_PROMPT });
    } else {
      this.finishScheduled(this.lastTurn.trim() || "(the agent wrote no summary)", this.timedOut ? "timeout" : "scheduled-done");
    }
  }

  // onRunTimeout: cancel the work turn (its end sends the summary prompt with the note); the grace
  // timer ends the run if no summary comes.
  private onRunTimeout(): void {
    this.runTimer = null;
    if (this.down || this.phase === "off" || this.phase === "done") return;
    this.timedOut = true;
    this.emit("error", { message: "the run timed out; asking for the summary" }, null);
    this.graceTimer = setTimeout(() => this.onGraceEnd(), this.d.config.summaryGraceMs);
    const m = this.m();
    if (this.phase !== "work") return;
    if (m.busy(MAIN)) this.run({ kind: "cancel" });
    else {
      this.phase = "summary";
      this.run({ kind: "userPrompt", text: `${TIMEOUT_NOTE}\n\n${SUMMARY_PROMPT}` });
    }
  }

  private onGraceEnd(): void {
    this.graceTimer = null;
    if (this.down || this.phase === "done") return;
    const last = this.m().record.summary;
    this.finishScheduled(last ? `${NO_SUMMARY}\n\nLast message:\n${last}` : NO_SUMMARY, "timeout");
  }

  private clearRunTimers(): void {
    if (this.runTimer) clearTimeout(this.runTimer);
    if (this.graceTimer) clearTimeout(this.graceTimer);
    this.runTimer = this.graceTimer = null;
  }

  // finishScheduled: result.md, then auto-clean or a plain stop; either way the bridge exits 0.
  private finishScheduled(result: string, reason: string): void {
    this.clearRunTimers();
    this.phase = "done";
    this.resultText = result;
    // a result that cannot be written (disk full) must not keep the run alive
    try { this.d.store.writeResult(result); } catch (err) { this.emit("error", { message: `could not write result.md: ${message(err)}` }, null); }
    if (this.d.config.autoClean && this.autoClean(reason)) return;
    this.run({ kind: "stop", reason, byUser: false });
  }

  // touch: restarts the idle timer while the task sits in waiting or idle, or is dormant (a lazy boot
  // that no prompt has woken: the container exits again after the idle timeout).
  private touch(): void {
    const m = this.m();
    const s = m.record.state;
    if (s === "waiting" || s === "idle" || m.dormant()) this.armIdle();
  }

  private perform(e: Effect): void {
    switch (e.kind) {
      case "emit": this.emit(e.type, e.data, e.name); break;
      case "question": this.d.store.appendQuestion(e.question); break;
      case "timer": if (e.on) this.armIdle(); else this.disarmIdle(); break;
      case "notify": {
        const q = e.question ? redactDeep<Question>(e.question, this.redact) : null;
        const rec = this.m().record;
        const result = rec.scheduled && this.resultText !== null && (rec.state === "stopped" || rec.state === "failed")
          ? this.redact(this.resultText.trim()) : null;
        const p = this.d.notifier.webhook(redactDeep(rec, this.redact), q, result)
          .then((ok) => { if (!ok) this.emit("error", { message: "webhook delivery failed after a retry" }, null); })
          .catch((err) => this.log(`webhook failed: ${message(err)}`))
          .finally(() => this.webhooks.delete(p));
        this.webhooks.add(p);
        break;
      }
      case "startAgent": void this.startAgent().catch((err) => this.log(`agent start failed: ${message(err)}`)); break;
      case "open": void this.open(e.name, e.mode, e.from, e.model).catch((err) => this.log(`open failed: ${message(err)}`)); break;
      case "prompt":
        this.emit("message", { role: "user", text: e.text, final: true }, e.name);
        void this.prompt(e.name, e.session, e.text).catch((err) => this.log(`prompt failed: ${message(err)}`));
        break;
      case "cancel": this.agent?.cancel(e.session); break;
      case "permission": {
        // a recorded request, or the one being raised right now (cancelling: answered, never recorded)
        const w = this.waiters.get(e.question);
        if (w) {
          this.waiters.delete(e.question);
          w(e.optionId);
        } else if (this.incoming) {
          const i = this.incoming;
          this.incoming = null;
          i(e.optionId);
        }
        break;
      }
      case "kill": { const a = this.agent; this.agent = null; if (a) this.track(a.kill()); break; }
      case "exit":
        // after the webhooks of the final state (failed, stopped) have gone out
        this.down = true;
        this.clearTimers();
        void this.drain().then(() => {
          if (this.m().record.cleaned && this.d.config.createdContainer) this.d.release();
          this.d.exit(e.code);
        });
        break;
    }
  }

  private hooks(self: () => AgentLike | null): AgentHooks {
    return {
      onUpdate: (sessionId, u) => {
        if (this.agent !== self()) return;
        // an id no session holds (yet) is dropped, never mis-tagged
        const name = this.m().record.sessions.find((s) => s.session === sessionId)?.name;
        if (name) this.emitMapped(name, this.mapper(name).handle(u));
      },
      onPermission: (req) => new Promise((resolve) => {
        // While cancelling, the machine answers at once with a permission effect for a question it
        // does not record; `incoming` lets perform() resolve this very request from that effect.
        const m = this.m();
        const before = m.questions.length;
        let done = false;
        this.incoming = (o) => { done = true; resolve(o); };
        try {
          this.run({ kind: "permissionRequest", ...req });
        } finally {
          this.incoming = null;
        }
        const q = m.questions[before];
        if (q) this.waiters.set(q.id, resolve); // recorded: the answer resolves it
        else if (!done) resolve(null); // ignored (no turn outstanding)
      }),
      onExit: (error) => {
        if (this.agent !== self()) return;
        this.agent = null;
        this.run({ kind: "agentExit", error });
      },
      onStderr: (s) => this.log(`agent: ${s.trimEnd()}`),
    };
  }

  // startAgent: one agent process for every session; agentStarted makes the machine open them.
  private async startAgent(): Promise<void> {
    let agent: AgentLike | null = null;
    agent = this.d.agentFactory(this.hooks(() => agent), this.m().record.work);
    this.agent = agent;
    try {
      const capabilities = await agent.start();
      if (this.agent !== agent) return;
      this.run({ kind: "agentStarted", capabilities });
    } catch (err) {
      if (this.agent !== agent) return;
      this.agent = null;
      this.track(agent.kill());
      this.run({ kind: "agentExit", error: `agent failed to start: ${message(err)}` });
    }
  }

  // open: a session's conversation in the live agent. A failed load of main falls back to a new
  // session seeded with the task history (spec D12); any other failure loses that session alone.
  private async open(name: string, mode: "new" | "load" | "fork", from: string | null, model: string | null): Promise<void> {
    const agent = this.agent;
    if (!agent) return;
    const id = this.m().record.sessions.find((s) => s.name === name)?.session ?? null;
    let input: Input;
    try {
      if (mode === "fork" && from) input = { kind: "sessionReady", name, session: await agent.forkSession(from, model) };
      else if (mode === "load" && id) {
        try {
          await agent.loadSession(id, model);
          input = { kind: "sessionReady", name, session: id };
        } catch (err) {
          if (name !== MAIN) throw err;
          let session: string;
          try {
            session = await agent.newSession(model);
          } catch (again) {
            // no main to fall back to: the task fails, as a failed start does
            if (this.agent !== agent) return;
            this.agent = null;
            this.track(agent.kill());
            this.run({ kind: "agentExit", error: `agent failed to start: ${message(again)}` });
            return;
          }
          if (this.agent !== agent) return;
          this.emit("error", { message: `session ${id} could not be loaded (${message(err)}); started a new session with the task history` }, MAIN);
          input = { kind: "sessionReady", name, session, seed: this.seed() };
        }
      } else input = { kind: "sessionReady", name, session: await agent.newSession(model) };
    } catch (err) {
      input = { kind: "sessionLost", name, error: message(err) };
    }
    if (this.agent === agent) this.run(input);
  }

  private async prompt(name: string, session: string, text: string): Promise<void> {
    const agent = this.agent;
    if (!agent) return;
    let stopReason: string;
    try {
      stopReason = await agent.prompt(session, text);
    } catch (err) {
      // A rejection from a live agent fails the task (spec §6). If the child's exit got here first the
      // agent is already gone and this is ignored; the machine ignores a second agentExit anyway.
      if (this.agent !== agent) return;
      this.agent = null;
      this.track(agent.kill());
      this.run({ kind: "agentExit", error: `prompt failed: ${message(err)}` });
      return;
    }
    if (this.agent !== agent) return;
    const { events, summary } = this.mapper(name).finishTurn();
    this.emitMapped(name, events);
    if (name === MAIN) this.lastTurn = summary;
    this.run({ kind: "turnEnd", name, stopReason, summary });
  }

  private mapper(name: string): UpdateMapper {
    let mp = this.mappers.get(name);
    if (!mp) this.mappers.set(name, mp = new UpdateMapper());
    return mp;
  }

  // seed: the first prompt of a replacement session (spec §6, Resume).
  private seed(): string {
    const m = this.m();
    const qa = m.questions.map((q) => `${q.id}: ${q.text} → ${q.status === "answered" ? q.answer : "(open)"}`).join("\n") || "(none)";
    const log = spawnSync("git", ["-C", m.record.work, "log", "--oneline", "-20"], { encoding: "utf8" }).stdout?.trim() || "(none)";
    return `Original task:\n${this.d.store.readPrompt() ?? this.d.config.prompt ?? ""}\n\nQuestions and answers so far:\n${qa}\n\nRecent commits:\n${log}\n\nThe earlier session could not be restored. Check git status and continue the task.`;
  }

  private emitMapped(name: string, list: Mapped[]): void {
    for (const e of list) this.emit(e.type, e.data, name);
  }

  // emit: an event of one session (name) or of the task (null); `session` is that session's ACP id.
  private emit(type: EventType, data: Record<string, unknown>, name: string | null): void {
    const m = this.m();
    const session = name === null ? null : m.record.sessions.find((s) => s.name === name)?.session ?? null;
    const ev = this.d.store.appendEvent({ ts: this.d.now(), task: m.record.task, session, name, agent: m.record.agent, type, data });
    const md = renderEvent(ev);
    if (md) this.d.store.appendTranscript(md);
    if (type === "state") this.d.notifier.logState(redactDeep(m.record, this.redact));
    for (const fn of this.listeners) {
      try {
        fn(ev);
      } catch (err) {
        this.log(`listener failed: ${message(err)}`);
      }
    }
  }

  private armIdle(): void {
    this.disarmIdle();
    if (this.down) return;
    if (this.phase === "work" || this.phase === "summary") return;
    this.idle = setTimeout(() => this.run({ kind: "idleTimeout" }), this.d.config.idleTimeoutMs);
  }

  private disarmIdle(): void {
    if (this.idle) clearTimeout(this.idle);
    this.idle = null;
  }

  private clearTimers(): void {
    this.clearRunTimers();
    this.disarmIdle();
    if (this.flush) clearInterval(this.flush);
    this.flush = null;
  }
}
