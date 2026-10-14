// The task state machine (spec §6). Pure: inputs in, effects out; bridge.ts performs the effects.
import type { EventType, PermissionOption, Question, State, TaskRecord } from "./types.js";

export type Effect =
  | { kind: "spawn"; mode: "new" | "load" }
  | { kind: "prompt"; text: string }
  | { kind: "cancel" }
  | { kind: "permission"; question: string; optionId: string | null }
  | { kind: "kill" }
  | { kind: "exit"; code: number }
  | { kind: "emit"; type: EventType; data: Record<string, unknown> }
  | { kind: "question"; question: Question }
  | { kind: "timer"; on: boolean }
  | { kind: "notify"; question: Question | null };

export type Input =
  | { kind: "boot"; fresh: boolean }
  | { kind: "userPrompt"; text: string }
  | { kind: "answer"; question?: string; text: string; grant: string[] }
  | { kind: "cancel" }
  | { kind: "stop"; reason?: string; byUser?: boolean }
  | { kind: "ask"; text: string; options: string[]; recommend: string | null }
  | { kind: "permissionRequest"; title: string; command: string; options: PermissionOption[] }
  | { kind: "agentReady"; session: string }
  | { kind: "turnEnd"; stopReason: string; summary: string }
  | { kind: "agentExit"; error: string }
  | { kind: "idleTimeout" }
  | { kind: "gate"; rule: string; command: string };

export type Outcome =
  | { ok: true; effects: Effect[]; value?: { id: string } }
  | { ok: false; code: "conflict" | "not_found" | "bad_request"; message: string };

export const GRANT_RE = /^(push|open-pr|deploy:[A-Za-z0-9_.-]+)$/;
const PROMPTABLE: State[] = ["idle", "waiting", "suspended", "interrupted", "failed"];
const NOTIFY: State[] = ["waiting", "idle", "failed", "stopped"];
const UNCLEAN: State[] = ["starting", "running", "waiting", "idle"];
const DORMANT: State[] = ["suspended", "interrupted", "failed"];

const fail = (code: "conflict" | "not_found" | "bad_request", message: string): Outcome => ({ ok: false, code, message });

export class TaskMachine {
  promptOutstanding = false;
  agentLive = false;
  private spawning = false;
  private promptText: string | null = null; // the text of the outstanding prompt, kept for a resume
  private cancelling = false; // a cancel is in flight; cleared at turn end
  private readonly pending = new Set<string>(); // permission questions the live agent waits on

  constructor(public record: TaskRecord, public questions: Question[], private readonly now: () => string) {}

  // dormant: booted lazily with no agent; the idle timeout ends the container and keeps the state
  dormant(): boolean {
    return DORMANT.includes(this.record.state) && !this.agentLive && !this.spawning;
  }

  openQuestions(): Question[] {
    return this.questions.filter((q) => q.status === "open");
  }

  apply(input: Input): Outcome {
    const fx: Effect[] = [];
    switch (input.kind) {
      case "boot":
        if (input.fresh) {
          this.setState("starting", "first prompt", fx);
          this.spawning = true;
          fx.push({ kind: "spawn", mode: "new" });
        } else if (UNCLEAN.includes(this.record.state)) {
          this.setState("interrupted", "the bridge ended without stop or suspension", fx);
        } else if (this.record.state === "stopped") {
          fx.push({ kind: "exit", code: 0 });
        }
        if (!input.fresh && this.dormant()) fx.push({ kind: "timer", on: true });
        return { ok: true, effects: fx };

      case "userPrompt": {
        if (!input.text.trim()) return fail("bad_request", "empty prompt");
        if (this.promptOutstanding || this.spawning) return fail("conflict", "a turn is in progress; cancel first");
        if (!PROMPTABLE.includes(this.record.state)) return fail("conflict", `task is ${this.record.state}`);
        this.record.inbox.push({ kind: "prompt", text: input.text });
        this.deliver(fx);
        return { ok: true, effects: fx };
      }

      case "answer":
        return this.answer(input, fx);

      case "cancel":
        if (!this.promptOutstanding) return fail("conflict", "no turn in progress");
        if (this.cancelling) return { ok: true, effects: fx };
        this.cancelling = true;
        for (const id of this.pending) {
          fx.push({ kind: "permission", question: id, optionId: null });
          this.closeCancelled(id, fx);
        }
        this.pending.clear();
        fx.push({ kind: "cancel" });
        return { ok: true, effects: fx };

      case "stop":
        if (this.record.state === "stopped") return { ok: true, effects: fx };
        if (this.promptOutstanding) fx.push({ kind: "cancel" });
        for (const id of this.pending) fx.push({ kind: "permission", question: id, optionId: null });
        this.pending.clear();
        if (this.agentLive || this.spawning) fx.push({ kind: "kill" });
        this.promptText = null;
        this.agentLive = this.spawning = this.promptOutstanding = this.cancelling = false;
        this.record.stopped_by_user = input.byUser ?? true;
        this.setState("stopped", input.reason ?? "stopped by user", fx);
        fx.push({ kind: "exit", code: 0 });
        return { ok: true, effects: fx };

      case "ask": {
        if (!input.text.trim()) return fail("bad_request", "empty question");
        if (this.record.state === "stopped") return fail("conflict", "task is stopped");
        const q = this.addQuestion("ask", input.text, input.options, input.recommend, fx);
        if (!this.promptOutstanding && this.record.state === "idle") this.setState("waiting", `question ${q.id}`, fx);
        return { ok: true, effects: fx, value: { id: q.id } };
      }

      case "permissionRequest": {
        if (!this.promptOutstanding || !["running", "waiting"].includes(this.record.state)) return { ok: true, effects: fx };
        if (this.cancelling) {
          // the turn is being cancelled: answer as cancelled at once; nothing is recorded
          fx.push({ kind: "permission", question: `Q${this.questions.length + 1}`, optionId: null });
          return { ok: true, effects: fx };
        }
        const q = this.addQuestion("permission", `Allow: ${input.command || input.title}?`,
          input.options.map((o) => o.name), null, fx, { options: input.options });
        this.pending.add(q.id);
        this.setState("waiting", `question ${q.id}`, fx, q);
        return { ok: true, effects: fx };
      }

      case "agentReady":
        if (["stopped", "failed", "suspended"].includes(this.record.state)) return { ok: true, effects: fx };
        this.agentLive = true;
        this.spawning = false;
        this.record.session = input.session;
        this.deliver(fx);
        if (!this.promptOutstanding) this.settle("", fx);
        return { ok: true, effects: fx };

      case "turnEnd":
        if (!this.promptOutstanding) return { ok: true, effects: fx };
        this.promptOutstanding = this.cancelling = false;
        this.promptText = null;
        this.releasePending(fx);
        if (input.summary) this.record.summary = input.summary.slice(0, 300);
        this.deliver(fx);
        if (!this.promptOutstanding) this.settle(input.stopReason === "cancelled" ? "cancelled" : "", fx);
        return { ok: true, effects: fx };

      case "agentExit":
        if (["stopped", "suspended", "failed"].includes(this.record.state)) return { ok: true, effects: fx };
        // the text of a turn that did not finish goes back to the inbox head: a resume sends it again
        if (this.promptOutstanding && this.promptText !== null) this.record.inbox.unshift({ kind: "prompt", text: this.promptText });
        this.promptText = null;
        this.agentLive = this.spawning = this.promptOutstanding = this.cancelling = false;
        this.releasePending(fx);
        this.setState("failed", input.error, fx);
        fx.push({ kind: "exit", code: 1 });
        return { ok: true, effects: fx };

      case "idleTimeout":
        if (this.dormant()) {
          fx.push({ kind: "exit", code: 0 });
          return { ok: true, effects: fx };
        }
        if (this.record.state !== "waiting" && this.record.state !== "idle") return { ok: true, effects: fx };
        for (const id of this.pending) fx.push({ kind: "permission", question: id, optionId: null });
        this.pending.clear();
        if (this.agentLive) fx.push({ kind: "kill" });
        this.promptText = null;
        this.agentLive = this.promptOutstanding = this.cancelling = false;
        this.setState("suspended", "idle timeout", fx);
        fx.push({ kind: "exit", code: 0 });
        return { ok: true, effects: fx };

      case "gate":
        fx.push({ kind: "emit", type: "gate", data: { rule: input.rule, command: input.command } });
        return { ok: true, effects: fx };
    }
  }

  private answer(input: { question?: string; text: string; grant: string[] }, fx: Effect[]): Outcome {
    if (!input.text.trim()) return fail("bad_request", "empty answer");
    const bad = input.grant.find((g) => !GRANT_RE.test(g));
    if (bad !== undefined) return fail("bad_request", `unknown grant ${bad} (push, open-pr, deploy:<target>)`);
    if (this.record.state === "stopped") return fail("conflict", "task is stopped");
    let q: Question | undefined;
    if (input.question) {
      q = this.questions.find((x) => x.id === input.question);
      if (!q) return fail("not_found", `no question ${input.question}`);
      if (q.status !== "open") return fail("conflict", `${q.id} is already answered`);
    } else {
      q = this.openQuestions()[0];
      if (!q) return fail("conflict", "no open question");
    }
    const live = q.source === "permission" && this.pending.has(q.id);
    let optionId: string | null = null;
    if (live) {
      optionId = matchOption(q.permission?.options ?? [], input.text);
      if (!optionId) return fail("bad_request", `answer one of: ${q.options.join(", ")}`);
      // a rejection grants nothing
      const kind = q.permission?.options.find((o) => o.optionId === optionId)?.kind ?? "";
      if (kind.startsWith("reject")) input = { ...input, grant: [] };
    }
    q.status = "answered";
    q.answer = input.text;
    q.grant = input.grant;
    q.answered = this.now();
    for (const g of input.grant) if (!this.record.allowed_actions.includes(g)) this.record.allowed_actions.push(g);
    fx.push({ kind: "question", question: { ...q } });
    fx.push({ kind: "emit", type: "answer", data: { question: q.id, text: input.text, grant: input.grant } });
    if (live) {
      this.pending.delete(q.id);
      fx.push({ kind: "permission", question: q.id, optionId });
      if (this.record.state === "waiting" && this.pending.size === 0) this.setState("running", "", fx);
    } else {
      const allowed = input.grant.length ? `\nAllowed for this task: ${input.grant.join(", ")}.` : "";
      this.record.inbox.push({ kind: "answer", question: q.id, text: `Answer to ${q.id}: ${input.text}${allowed}` });
      this.deliver(fx);
    }
    return { ok: true, effects: fx };
  }

  // releasePending: the agent no longer waits on these permission requests; tell the orchestrator.
  private releasePending(fx: Effect[]): void {
    for (const id of this.pending) fx.push({ kind: "permission", question: id, optionId: null });
    this.pending.clear();
  }

  // closeCancelled: a permission question whose request was cancelled can no longer be answered; close it,
  // or the task would wait on it after the turn ends.
  private closeCancelled(id: string, fx: Effect[]): void {
    const q = this.questions.find((x) => x.id === id);
    if (!q || q.status !== "open") return;
    q.status = "answered";
    q.answer = "cancelled";
    q.grant = [];
    q.answered = this.now();
    fx.push({ kind: "question", question: { ...q } });
    fx.push({ kind: "emit", type: "answer", data: { question: id, text: "cancelled", grant: [] } });
    if (this.record.state === "waiting") this.setState("running", "", fx);
  }

  // deliver: the inbox as one prompt when nothing is outstanding; spawns the agent if needed.
  private deliver(fx: Effect[]): void {
    if (this.promptOutstanding || this.record.inbox.length === 0) return;
    if (!this.agentLive) {
      if (this.spawning) return;
      this.spawning = true;
      this.setState("starting", "resuming session", fx);
      fx.push({ kind: "spawn", mode: this.record.session ? "load" : "new" });
      return;
    }
    const text = this.record.inbox.map((i) => i.text).join("\n\n");
    this.record.inbox = [];
    this.promptText = text;
    this.promptOutstanding = true;
    this.setState("running", "", fx);
    fx.push({ kind: "prompt", text });
  }

  // settle: waiting with an open question, else idle.
  private settle(reason: string, fx: Effect[]): void {
    const open = this.openQuestions()[0];
    if (open) this.setState("waiting", `question ${open.id}`, fx);
    else this.setState("idle", reason, fx);
  }

  private addQuestion(source: Question["source"], text: string, options: string[], recommend: string | null,
    fx: Effect[], permission?: Question["permission"]): Question {
    const q: Question = {
      id: `Q${this.questions.length + 1}`, source, text, options, recommendation: recommend, asked: this.now(),
      status: "open", ...(permission ? { permission } : {}),
    };
    this.questions.push(q);
    fx.push({ kind: "question", question: { ...q } });
    fx.push({ kind: "emit", type: "question", data: { id: q.id, source, text, options, recommendation: recommend } });
    return q;
  }

  private setState(state: State, reason: string, fx: Effect[], notifyQ?: Question): void {
    const changed = this.record.state !== state || this.record.reason !== reason;
    this.record.state = state;
    this.record.reason = reason;
    this.record.updated = this.now();
    if (!changed) return;
    fx.push({ kind: "emit", type: "state", data: { state, reason } });
    fx.push({ kind: "timer", on: state === "waiting" || state === "idle" });
    if (NOTIFY.includes(state)) fx.push({ kind: "notify", question: notifyQ ? { ...notifyQ } : this.openQuestions()[0] ?? null });
  }
}

// matchOption: a permission answer by option name or kind ("allow once"), with allow/yes and reject/deny/no.
export function matchOption(options: { optionId: string; name: string; kind: string }[], text: string): string | null {
  const t = text.trim().toLowerCase();
  const alias: Record<string, string> = { allow: "allow_once", yes: "allow_once", reject: "reject_once", deny: "reject_once", no: "reject_once" };
  const byName = options.find((o) => o.name.toLowerCase() === t);
  if (byName) return byName.optionId;
  const kind = alias[t] ?? t.replace(/\s+/g, "_");
  return options.find((o) => o.kind === kind)?.optionId ?? null;
}
