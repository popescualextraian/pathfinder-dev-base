// The task state machine (spec §6), one turn state per session (sessions spec D5–D16).
// Pure: inputs in, effects out; bridge.ts performs the effects.
import { MAIN, MAX_SESSIONS, NAME_RE, deriveState, newSession } from "./sessions.js";
import type { AgentCaps, EventType, PermissionOption, Question, SessionRecord, SessionState, State, TaskRecord } from "./types.js";

export type Effect =
  | { kind: "startAgent" }
  | { kind: "open"; name: string; mode: "new" | "load" | "fork"; from: string | null; model: string | null }
  | { kind: "prompt"; name: string; session: string; text: string }
  | { kind: "cancel"; session: string }
  | { kind: "permission"; question: string; optionId: string | null }
  | { kind: "kill" }
  | { kind: "exit"; code: number }
  | { kind: "emit"; type: EventType; data: Record<string, unknown>; name: string | null }
  | { kind: "question"; question: Question }
  | { kind: "timer"; on: boolean }
  | { kind: "notify"; question: Question | null };

export type Input =
  | { kind: "boot"; fresh: boolean }
  | { kind: "userPrompt"; text: string; session?: string }
  | { kind: "answer"; question?: string; text: string; grant: string[]; session?: string }
  | { kind: "cancel"; session?: string }
  | { kind: "stop"; reason?: string; byUser?: boolean }
  | { kind: "ask"; text: string; options: string[]; recommend: string | null; sessionId?: string }
  | { kind: "permissionRequest"; sessionId: string; title: string; command: string; options: PermissionOption[] }
  | { kind: "addSession"; name: string; model: string | null; fork: string | null; text: string | null }
  | { kind: "agentStarted"; capabilities: AgentCaps }
  | { kind: "sessionReady"; name: string; session: string; seed?: string }
  | { kind: "sessionLost"; name: string; error: string }
  | { kind: "turnEnd"; name: string; stopReason: string; summary: string }
  | { kind: "agentExit"; error: string }
  | { kind: "idleTimeout" }
  | { kind: "gate"; rule: string; command: string; sessionId?: string };

export type Outcome =
  | { ok: true; effects: Effect[]; value?: { id: string } }
  | { ok: false; code: "conflict" | "not_found" | "bad_request"; message: string };

// Live: what a session's turn holds in memory; lost with the agent process.
interface Live {
  outstanding: boolean; // a prompt is sent and its turn has not ended
  text: string | null; // the text of the outstanding prompt, kept for a resume
  cancelling: boolean; // a cancel is in flight; cleared at turn end
  pending: Set<string>; // permission questions the live agent waits on
  loaded: boolean; // the agent has this session open
  opening: boolean; // an open is due or in flight
}

export const GRANT_RE = /^(push|open-pr|deploy:[A-Za-z0-9_.-]+)$/;
const NOTIFY: State[] = ["idle", "failed", "stopped"];
const UNCLEAN: State[] = ["starting", "running", "waiting", "idle"];
const DORMANT: State[] = ["suspended", "interrupted", "failed"];
const ENDED: State[] = ["stopped", "failed", "suspended"];

const fail = (code: "conflict" | "not_found" | "bad_request", message: string): Outcome => ({ ok: false, code, message });

export class TaskMachine {
  agentLive = false;
  private starting = false; // the agent process is starting
  private readonly live = new Map<string, Live>();

  constructor(public record: TaskRecord, public questions: Question[], private readonly now: () => string) {}

  // dormant: booted lazily with no agent; the idle timeout ends the container and keeps the state
  dormant(): boolean {
    return DORMANT.includes(this.record.state) && !this.agentLive && !this.starting;
  }

  // busy: a turn outstanding or the session opening
  busy(name = MAIN): boolean {
    const l = this.live.get(name);
    return !!l && (l.outstanding || l.opening);
  }

  openQuestions(): Question[] {
    return this.questions.filter((q) => q.status === "open");
  }

  apply(input: Input): Outcome {
    const fx: Effect[] = [];
    const o = this.step(input, fx);
    if (o.ok) this.sync(fx, input.kind === "turnEnd" && input.stopReason === "cancelled" ? "cancelled" : "");
    return o;
  }

  private step(input: Input, fx: Effect[]): Outcome {
    const ok: Outcome = { ok: true, effects: fx };
    switch (input.kind) {
      case "boot":
        if (input.fresh) {
          this.open(this.byId(undefined), fx);
          return ok;
        }
        for (const s of this.record.sessions) {
          if (s.state === "running" || s.state === "starting") this.setSession(s, "interrupted", "the bridge ended without stop or suspension", fx);
        }
        if (UNCLEAN.includes(this.record.state)) {
          this.setState("interrupted", "the bridge ended without stop or suspension", fx);
        } else if (this.record.state === "stopped") {
          fx.push({ kind: "exit", code: 0 });
        }
        if (this.dormant()) fx.push({ kind: "timer", on: true });
        return ok;

      case "userPrompt": {
        if (!input.text.trim()) return fail("bad_request", "empty prompt");
        const name = input.session ?? MAIN;
        const s = this.find(name);
        if (!s) return fail("not_found", `no session ${name}`);
        if (this.record.state === "stopped") return fail("conflict", "task is stopped");
        if (this.record.scheduled && name !== MAIN) return fail("conflict", "a scheduled task runs main only");
        if (s.state === "failed") return fail("conflict", failedText(s));
        if (this.busy(name)) return fail("conflict", "a turn is in progress; cancel first");
        // a resume of an interrupted or failed task carries on every session that was working
        const resume = name === MAIN && (this.record.state === "interrupted" || this.record.state === "failed");
        for (const x of this.record.sessions) {
          const join = x === s || (resume && x.state !== "failed" && (x.state === "interrupted" || x.inbox.length > 0));
          if (!join) continue;
          x.inbox.push({ kind: "prompt", text: input.text });
          this.deliver(x.name, fx);
        }
        return ok;
      }

      case "answer":
        return this.answer(input, fx);

      case "cancel": {
        const name = input.session ?? MAIN;
        const s = this.find(name);
        if (!s) return fail("not_found", `no session ${name}`);
        const l = this.ls(name);
        if (!l.outstanding || !s.session) return fail("conflict", "no turn in progress");
        if (l.cancelling) return ok;
        l.cancelling = true;
        for (const id of l.pending) {
          fx.push({ kind: "permission", question: id, optionId: null });
          this.closeQuestion(id, "cancelled", fx);
        }
        l.pending.clear();
        fx.push({ kind: "cancel", session: s.session });
        return ok;
      }

      case "stop":
        if (this.record.state === "stopped") return ok;
        for (const s of this.record.sessions) {
          if (this.ls(s.name).outstanding && s.session) fx.push({ kind: "cancel", session: s.session });
        }
        this.dropAgent(fx);
        this.record.stopped_by_user = input.byUser ?? true;
        this.setState("stopped", input.reason ?? "stopped by user", fx);
        fx.push({ kind: "exit", code: 0 });
        return ok;

      case "ask": {
        if (!input.text.trim()) return fail("bad_request", "empty question");
        if (this.record.state === "stopped") return fail("conflict", "task is stopped");
        const s = this.byId(input.sessionId);
        const q = this.addQuestion(s.name, "ask", input.text, input.options, input.recommend, fx);
        if (!this.ls(s.name).outstanding && s.state === "idle") this.setSession(s, "waiting", `question ${q.id}`, fx);
        return { ok: true, effects: fx, value: { id: q.id } };
      }

      case "permissionRequest": {
        const s = this.byId(input.sessionId);
        const l = this.ls(s.name);
        if (!l.outstanding) return ok;
        if (l.cancelling) {
          // the turn is being cancelled: answer as cancelled at once; nothing is recorded
          fx.push({ kind: "permission", question: `Q${this.questions.length + 1}`, optionId: null });
          return ok;
        }
        const q = this.addQuestion(s.name, "permission", `Allow: ${input.command || input.title}?`,
          input.options.map((o) => o.name), null, fx, { options: input.options });
        l.pending.add(q.id);
        this.setSession(s, "waiting", `question ${q.id}`, fx);
        return ok;
      }

      case "addSession":
        return this.addSession(input, fx);

      case "agentStarted":
        if (ENDED.includes(this.record.state)) return ok;
        this.agentLive = true;
        this.starting = false;
        this.record.capabilities = input.capabilities;
        for (const s of this.record.sessions) if (this.ls(s.name).opening) this.pushOpen(s, fx);
        return ok;

      case "sessionReady": {
        const s = this.find(input.name);
        if (!s || !this.agentLive) return ok;
        const l = this.ls(s.name);
        l.opening = false;
        l.loaded = true;
        s.session = input.session;
        if (s.name === MAIN) this.record.session = input.session;
        if (input.seed) s.inbox.unshift({ kind: "prompt", text: input.seed });
        this.deliver(s.name, fx);
        if (!l.outstanding) this.settle(s, "", fx);
        return ok;
      }

      case "sessionLost": {
        const s = this.find(input.name);
        if (!s || !this.agentLive) return ok;
        this.ls(s.name).opening = false;
        this.setSession(s, "failed", `its conversation could not be restored: ${input.error}`, fx);
        // its questions can no longer be answered; left open they would block the task
        for (const q of this.openQuestions()) if (q.session === s.name) this.closeQuestion(q.id, "session failed", fx);
        return ok;
      }

      case "turnEnd": {
        const s = this.find(input.name);
        const l = s && this.live.get(s.name);
        if (!s || !l?.outstanding) return ok;
        l.outstanding = l.cancelling = false;
        l.text = null;
        this.release(l, fx);
        if (input.summary) s.summary = this.record.summary = input.summary.slice(0, 300);
        this.deliver(s.name, fx);
        if (!l.outstanding) this.settle(s, input.stopReason === "cancelled" ? "cancelled" : "", fx);
        return ok;
      }

      case "agentExit":
        if (ENDED.includes(this.record.state)) return ok;
        for (const s of this.record.sessions) {
          if (this.ls(s.name).outstanding) this.setSession(s, "interrupted", input.error, fx);
        }
        this.dropAgent(fx, false);
        this.setState("failed", input.error, fx);
        fx.push({ kind: "exit", code: 1 });
        return ok;

      case "idleTimeout":
        if (this.dormant()) {
          fx.push({ kind: "exit", code: 0 });
          return ok;
        }
        if (this.record.state !== "waiting" && this.record.state !== "idle") return ok;
        this.dropAgent(fx);
        this.setState("suspended", "idle timeout", fx);
        fx.push({ kind: "exit", code: 0 });
        return ok;

      case "gate":
        fx.push({ kind: "emit", type: "gate", data: { rule: input.rule, command: input.command },
          name: input.sessionId === undefined ? null : this.byId(input.sessionId).name });
        return ok;
    }
  }

  private addSession(input: { name: string; model: string | null; fork: string | null; text: string | null }, fx: Effect[]): Outcome {
    if (!NAME_RE.test(input.name)) return fail("bad_request", `bad session name ${input.name} (${NAME_RE.source})`);
    if (this.record.state === "stopped") return fail("conflict", "task is stopped");
    if (this.record.scheduled) return fail("conflict", "a scheduled task runs main only");
    if (this.find(input.name)) return fail("conflict", `session ${input.name} exists`);
    if (this.record.sessions.length >= MAX_SESSIONS) return fail("conflict", `a task has at most ${MAX_SESSIONS} sessions`);
    if (input.fork !== null) {
      const src = this.find(input.fork);
      if (!src) return fail("not_found", `no session ${input.fork}`);
      const caps = this.record.capabilities;
      if (!caps) return fail("conflict", "the agent is still starting; try again when the task is idle");
      if (!caps.fork) return fail("conflict", `${this.record.agent} does not support forking a session`);
      if (this.busy(src.name)) return fail("conflict", `${src.name} is running; fork it when it is idle`);
      if (!src.session) return fail("conflict", `${src.name} has no conversation to fork`);
    }
    const s = newSession(input.name, input.model ?? this.record.model, this.now(), {
      fork_of: input.fork, inbox: input.text?.trim() ? [{ kind: "prompt", text: input.text }] : [],
    });
    this.record.sessions.push(s);
    this.open(s, fx);
    return { ok: true, effects: fx, value: { id: s.name } };
  }

  private answer(input: { question?: string; text: string; grant: string[]; session?: string }, fx: Effect[]): Outcome {
    if (!input.text.trim()) return fail("bad_request", "empty answer");
    const bad = input.grant.find((g) => !GRANT_RE.test(g));
    if (bad !== undefined) return fail("bad_request", `unknown grant ${bad} (push, open-pr, deploy:<target>)`);
    if (this.record.state === "stopped") return fail("conflict", "task is stopped");
    if (input.session !== undefined && !this.find(input.session)) return fail("not_found", `no session ${input.session}`);
    let q: Question | undefined;
    if (input.question) {
      q = this.questions.find((x) => x.id === input.question);
      if (!q) return fail("not_found", `no question ${input.question}`);
      if (q.status !== "open") return fail("conflict", `${q.id} is already answered`);
    } else {
      q = this.openQuestions().find((x) => input.session === undefined || x.session === input.session);
      if (!q) return fail("conflict", "no open question");
    }
    const s = this.find(q.session) ?? this.byId(undefined);
    if (s.state === "failed") return fail("conflict", failedText(s));
    const l = this.ls(s.name);
    const live = q.source === "permission" && l.pending.has(q.id);
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
    fx.push({ kind: "emit", type: "answer", data: { question: q.id, text: input.text, grant: input.grant }, name: s.name });
    if (live) {
      l.pending.delete(q.id);
      fx.push({ kind: "permission", question: q.id, optionId });
      if (s.state === "waiting" && l.pending.size === 0) this.setSession(s, "running", "", fx);
    } else {
      const allowed = input.grant.length ? `\nAllowed for this task: ${input.grant.join(", ")}.` : "";
      s.inbox.push({ kind: "answer", question: q.id, text: `Answer to ${q.id}: ${input.text}${allowed}` });
      this.deliver(s.name, fx);
    }
    return { ok: true, effects: fx };
  }

  private find(name: string): SessionRecord | undefined {
    return this.record.sessions.find((s) => s.name === name);
  }

  // byId: the session of an ACP session id; an unknown or missing id means main (D8)
  private byId(id: string | undefined): SessionRecord {
    const s = this.record.sessions.find((x) => x.session !== null && x.session === id) ?? this.find(MAIN);
    if (!s) throw new Error("the task has no main session");
    return s;
  }

  private ls(name: string): Live {
    let l = this.live.get(name);
    if (!l) {
      l = { outstanding: false, text: null, cancelling: false, pending: new Set(), loaded: false, opening: false };
      this.live.set(name, l);
    }
    return l;
  }

  // dropAgent: the agent process ends; unfinished turns go back to their inbox heads (D16), pending
  // permission requests are released and every session must be opened again.
  private dropAgent(fx: Effect[], kill = true): void {
    for (const s of this.record.sessions) {
      const l = this.live.get(s.name);
      if (l?.outstanding && l.text !== null) s.inbox.unshift({ kind: "prompt", text: l.text });
      if (l) this.release(l, fx);
    }
    if (kill && (this.agentLive || this.starting)) fx.push({ kind: "kill" });
    this.live.clear();
    this.agentLive = this.starting = false;
  }

  // release: the agent no longer waits on these permission requests; tell the orchestrator.
  private release(l: Live, fx: Effect[]): void {
    for (const id of l.pending) fx.push({ kind: "permission", question: id, optionId: null });
    l.pending.clear();
  }

  // closeQuestion: a question that can no longer be answered (its request cancelled, its session failed);
  // close it, or the session would wait on it after the turn ends.
  private closeQuestion(id: string, text: string, fx: Effect[]): void {
    const q = this.questions.find((x) => x.id === id);
    if (!q || q.status !== "open") return;
    q.status = "answered";
    q.answer = text;
    q.grant = [];
    q.answered = this.now();
    fx.push({ kind: "question", question: { ...q } });
    fx.push({ kind: "emit", type: "answer", data: { question: id, text, grant: [] }, name: q.session });
    const s = this.find(q.session);
    if (s?.state === "waiting") this.setSession(s, "running", "", fx);
  }

  // deliver: the session's inbox as one prompt when nothing is outstanding; opens the session first.
  private deliver(name: string, fx: Effect[]): void {
    const s = this.find(name);
    const l = this.ls(name);
    if (!s || l.outstanding || s.inbox.length === 0) return;
    if (!this.agentLive || !l.loaded || !s.session) {
      this.open(s, fx);
      return;
    }
    const text = s.inbox.map((i) => i.text).join("\n\n");
    s.inbox = [];
    l.text = text;
    l.outstanding = true;
    this.setSession(s, "running", "", fx);
    fx.push({ kind: "prompt", name, session: s.session, text });
  }

  // open: start the agent if needed, else ask it to open the session; agentStarted opens the rest.
  private open(s: SessionRecord, fx: Effect[]): void {
    const l = this.ls(s.name);
    if (l.opening) return;
    l.opening = true;
    this.setSession(s, "starting", "", fx);
    if (this.agentLive) {
      this.pushOpen(s, fx);
    } else if (!this.starting) {
      this.starting = true;
      this.setState("starting", this.record.session ? "resuming session" : "first prompt", fx);
      fx.push({ kind: "startAgent" });
    }
  }

  private pushOpen(s: SessionRecord, fx: Effect[]): void {
    const from = s.session === null && s.fork_of !== null ? this.find(s.fork_of)?.session ?? null : null;
    fx.push({ kind: "open", name: s.name, mode: s.session ? "load" : from ? "fork" : "new", from, model: s.model });
  }

  // settle: a session without a turn waits on its open question, else is idle.
  private settle(s: SessionRecord, reason: string, fx: Effect[]): void {
    const open = this.openQuestions().find((q) => q.session === s.name);
    if (open) this.setSession(s, "waiting", `question ${open.id}`, fx);
    else this.setSession(s, "idle", reason, fx);
  }

  // sync: the task state derived from its sessions while the agent is live (D6); terminal states stay.
  private sync(fx: Effect[], reason: string): void {
    if (!this.agentLive) return;
    const open = this.openQuestions()[0];
    const state = deriveState(this.record.sessions, open ? 1 : 0, this.starting);
    const why = state === "waiting" ? `question ${open?.id ?? ""}`
      : state === "idle" && !reason && this.record.state === "idle" ? this.record.reason : reason;
    this.setState(state, state === "running" ? "" : why, fx);
  }

  private addQuestion(session: string, source: Question["source"], text: string, options: string[], recommend: string | null,
    fx: Effect[], permission?: Question["permission"]): Question {
    const q: Question = {
      id: `Q${this.questions.length + 1}`, source, text, options, recommendation: recommend, asked: this.now(),
      status: "open", session, ...(permission ? { permission } : {}),
    };
    this.questions.push(q);
    fx.push({ kind: "question", question: { ...q } });
    fx.push({ kind: "emit", type: "question", data: { id: q.id, source, text, options, recommendation: recommend }, name: session });
    // every question notifies at once, whatever the task state (D15)
    fx.push({ kind: "notify", question: { ...q } });
    return q;
  }

  private setSession(s: SessionRecord, state: SessionState, reason: string, fx: Effect[]): void {
    if (s.state === state && s.reason === reason) return;
    s.state = state;
    s.reason = reason;
    s.updated = this.now();
    fx.push({ kind: "emit", type: "state", data: { state, reason }, name: s.name });
  }

  private setState(state: State, reason: string, fx: Effect[]): void {
    const changed = this.record.state !== state || this.record.reason !== reason;
    this.record.state = state;
    this.record.reason = reason;
    this.record.updated = this.now();
    if (!changed) return;
    fx.push({ kind: "emit", type: "state", data: { state, reason }, name: null });
    fx.push({ kind: "timer", on: state === "waiting" || state === "idle" });
    if (NOTIFY.includes(state)) fx.push({ kind: "notify", question: this.openQuestions()[0] ?? null });
  }
}

const failedText = (s: SessionRecord): string => `${s.name} failed: ${s.reason}; add a new session`;

// matchOption: a permission answer by option name or kind ("allow once"), with allow/yes and reject/deny/no.
export function matchOption(options: { optionId: string; name: string; kind: string }[], text: string): string | null {
  const t = text.trim().toLowerCase();
  const alias: Record<string, string> = { allow: "allow_once", yes: "allow_once", reject: "reject_once", deny: "reject_once", no: "reject_once" };
  const byName = options.find((o) => o.name.toLowerCase() === t);
  if (byName) return byName.optionId;
  const kind = alias[t] ?? t.replace(/\s+/g, "_");
  return options.find((o) => o.kind === kind)?.optionId ?? null;
}
