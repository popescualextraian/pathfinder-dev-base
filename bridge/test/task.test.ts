import { describe, expect, it } from "vitest";
import { TaskMachine, type Effect, type Outcome } from "../src/task.js";
import { newSession } from "../src/sessions.js";
import type { InboxItem, TaskRecord, Question, SessionRecord } from "../src/types.js";

// rec: a task record whose main session holds `inbox` and has the top-level `session` as its id
const rec = (over: Partial<TaskRecord> & { inbox?: InboxItem[] } = {}): TaskRecord => {
  const { inbox = [{ kind: "prompt", text: "Fix the login bug" }], ...rest } = over;
  return {
    version: 1, task: "T-1", project: "demo", agent: "claude", model: null, state: "starting", reason: "",
    session: null, branch: null, target: null, work: "/work", worktree: null, container: null, created_container: false, auto_clean: false, cleaned: false, created: "t0", updated: "t0", seq: 0, allowed_actions: [],
    sessions: [newSession("main", null, "t0", { inbox, session: rest.session ?? null })], capabilities: null,
    summary: "", stopped_by_user: false, scheduled: false, run_timeout: null, ...rest,
  };
};
const m = (over: Partial<TaskRecord> & { inbox?: InboxItem[] } = {}, qs: Question[] = []) => new TaskMachine(rec(over), qs, () => "now");
const fx = (o: Outcome): Effect[] => { if (!o.ok) throw new Error(o.message); return o.effects; };
const kinds = (o: Outcome) => fx(o).map((e) => e.kind === "emit" ? `emit:${e.type}` : e.kind);
// states: the task-level state emits; sstates: those of one session
const states = (o: Outcome) => fx(o).flatMap((e) => (e.kind === "emit" && e.type === "state" && e.name === null ? [e.data.state] : []));
const sstates = (o: Outcome, name: string) => fx(o).flatMap((e) => (e.kind === "emit" && e.type === "state" && e.name === name ? [e.data.state] : []));
const sess = (t: TaskMachine, name: string): SessionRecord => {
  const s = t.record.sessions.find((x) => x.name === name);
  if (!s) throw new Error(`no session ${name}`);
  return s;
};
const main = (t: TaskMachine) => sess(t, "main");

// running: a fresh task whose first prompt is outstanding
function running(fork = true) {
  const t = m();
  t.apply({ kind: "boot", fresh: true });
  t.apply({ kind: "agentStarted", capabilities: { fork } });
  t.apply({ kind: "sessionReady", name: "main", session: "s1" });
  return t;
}

// two: main and plan both run a turn
function two() {
  const t = running();
  t.apply({ kind: "addSession", name: "plan", model: null, fork: null, text: "Plan it" });
  t.apply({ kind: "sessionReady", name: "plan", session: "s2" });
  return t;
}

describe("start", () => {
  it("a fresh task starts the agent, opens main, then sends the first prompt", () => {
    const t = m();
    const a = t.apply({ kind: "boot", fresh: true });
    expect(states(a)).toEqual(["starting"]);
    expect(fx(a)).toContainEqual({ kind: "startAgent" });
    const s = t.apply({ kind: "agentStarted", capabilities: { fork: true } });
    expect(fx(s)).toContainEqual({ kind: "open", name: "main", mode: "new", from: null, model: null });
    expect(t.record.capabilities).toEqual({ fork: true });
    const b = t.apply({ kind: "sessionReady", name: "main", session: "s1" });
    expect(fx(b)).toContainEqual({ kind: "prompt", name: "main", session: "s1", text: "Fix the login bug" });
    expect(t.record.state).toBe("running");
    expect(t.record.session).toBe("s1");
    expect(main(t).session).toBe("s1");
    expect(main(t).inbox).toEqual([]);
  });

  it("a record left running, waiting, idle or starting is interrupted; nothing is started", () => {
    for (const s of ["running", "waiting", "idle", "starting"] as const) {
      const t = m({ state: s, inbox: [] });
      const o = t.apply({ kind: "boot", fresh: false });
      expect(states(o)).toEqual(["interrupted"]);
      expect(kinds(o)).not.toContain("startAgent");
    }
  });

  it("a suspended task boots lazily with the idle timer on; a stopped one exits", () => {
    expect(fx(m({ state: "suspended", inbox: [] }).apply({ kind: "boot", fresh: false }))).toEqual([{ kind: "timer", on: true }]);
    expect(fx(m({ state: "stopped", inbox: [] }).apply({ kind: "boot", fresh: false }))).toEqual([{ kind: "exit", code: 0 }]);
  });

  it("a lazy boot in suspended, interrupted or failed arms the timer; its timeout exits 0 without a state change", () => {
    for (const s of ["suspended", "interrupted", "failed", "running"] as const) {
      const t = m({ state: s, reason: "before", inbox: [] });
      const boot = fx(t.apply({ kind: "boot", fresh: false }));
      expect(boot.at(-1)).toEqual({ kind: "timer", on: true });
      const state = t.record.state;
      expect(fx(t.apply({ kind: "idleTimeout" }))).toEqual([{ kind: "exit", code: 0 }]);
      expect(t.record.state).toBe(state);
    }
  });

  it("once a resume starts the agent, the idle timeout of a lazy boot no longer applies", () => {
    const t = m({ state: "suspended", session: "s1", inbox: [] });
    t.apply({ kind: "boot", fresh: false });
    t.apply({ kind: "userPrompt", text: "go on" });
    expect(fx(t.apply({ kind: "idleTimeout" }))).toEqual([]);
    expect(t.record.state).toBe("starting");
  });
});

describe("turns", () => {
  it("a turn without an open question ends idle, with the summary, timer on, notified", () => {
    const t = running();
    const o = t.apply({ kind: "turnEnd", name: "main", stopReason: "end_turn", summary: "Done." });
    expect(states(o)).toEqual(["idle"]);
    expect(sstates(o, "main")).toEqual(["idle"]);
    expect(t.record.summary).toBe("Done.");
    expect(main(t).summary).toBe("Done.");
    expect(fx(o)).toContainEqual({ kind: "timer", on: true });
    expect(fx(o)).toContainEqual({ kind: "notify", question: null });
  });

  it("a turn with an open question ends waiting; the question notified when it was asked", () => {
    const t = running();
    const a = t.apply({ kind: "ask", text: "Which DB?", options: ["pg"], recommend: "pg" });
    expect(fx(a).find((e) => e.kind === "notify")).toMatchObject({ question: { id: "Q1", session: "main" } });
    const o = t.apply({ kind: "turnEnd", name: "main", stopReason: "end_turn", summary: "" });
    expect(t.record.state).toBe("waiting");
    expect(t.record.reason).toBe("question Q1");
    expect(main(t).state).toBe("waiting");
    expect(kinds(o)).not.toContain("notify");
  });

  it("a summary is cut to 300 characters", () => {
    const t = running();
    t.apply({ kind: "turnEnd", name: "main", stopReason: "end_turn", summary: "x".repeat(400) });
    expect(t.record.summary).toHaveLength(300);
  });
});

describe("prompts", () => {
  it("are refused while a turn is in progress", () => {
    const o = running().apply({ kind: "userPrompt", text: "more" });
    expect(o).toMatchObject({ ok: false, code: "conflict" });
    expect(o.ok || o.message).toContain("cancel first");
  });

  it("are refused when empty, when stopped, or for an unknown session", () => {
    const t = running();
    t.apply({ kind: "turnEnd", name: "main", stopReason: "end_turn", summary: "" });
    expect(t.apply({ kind: "userPrompt", text: "  " })).toMatchObject({ ok: false, code: "bad_request" });
    expect(t.apply({ kind: "userPrompt", text: "x", session: "nope" })).toMatchObject({ ok: false, code: "not_found" });
    t.apply({ kind: "stop" });
    expect(t.apply({ kind: "userPrompt", text: "x" })).toMatchObject({ ok: false, code: "conflict" });
  });

  it("in idle go straight to the live agent", () => {
    const t = running();
    t.apply({ kind: "turnEnd", name: "main", stopReason: "end_turn", summary: "" });
    const o = t.apply({ kind: "userPrompt", text: "Also add a test" });
    expect(fx(o)).toContainEqual({ kind: "prompt", name: "main", session: "s1", text: "Also add a test" });
    expect(t.record.state).toBe("running");
  });

  it("in suspended load the session first, then deliver", () => {
    const t = m({ state: "suspended", session: "s1", inbox: [] });
    t.apply({ kind: "boot", fresh: false });
    const o = t.apply({ kind: "userPrompt", text: "go on" });
    expect(fx(o)).toContainEqual({ kind: "startAgent" });
    expect(t.record.state).toBe("starting");
    const s = t.apply({ kind: "agentStarted", capabilities: { fork: true } });
    expect(fx(s)).toContainEqual({ kind: "open", name: "main", mode: "load", from: null, model: null });
    const r = t.apply({ kind: "sessionReady", name: "main", session: "s1" });
    expect(fx(r)).toContainEqual({ kind: "prompt", name: "main", session: "s1", text: "go on" });
  });

  it("a seed from sessionReady goes before the inbox", () => {
    const t = m({ state: "suspended", session: "s1", inbox: [] });
    t.apply({ kind: "boot", fresh: false });
    t.apply({ kind: "userPrompt", text: "go on" });
    t.apply({ kind: "agentStarted", capabilities: { fork: true } });
    const r = t.apply({ kind: "sessionReady", name: "main", session: "s9", seed: "History." });
    expect(fx(r)).toContainEqual({ kind: "prompt", name: "main", session: "s9", text: "History.\n\ngo on" });
    expect(t.record.session).toBe("s9");
  });
});

describe("questions and answers", () => {
  it("ask records an open question and returns its id", () => {
    const t = running();
    const o = t.apply({ kind: "ask", text: "Which DB?", options: ["pg", "sqlite"], recommend: "pg" });
    expect(o).toMatchObject({ ok: true, value: { id: "Q1" } });
    expect(fx(o).find((e) => e.kind === "question")).toMatchObject({ question: { id: "Q1", status: "open", source: "ask", session: "main" } });
    expect(t.openQuestions().map((q) => q.id)).toEqual(["Q1"]);
  });

  it("an answer while the agent works is queued and delivered after the turn", () => {
    const t = running();
    t.apply({ kind: "ask", text: "Push?", options: [], recommend: null });
    const a = t.apply({ kind: "answer", text: "yes", grant: ["push"] });
    expect(kinds(a)).not.toContain("prompt");
    expect(t.record.allowed_actions).toEqual(["push"]);
    const e = t.apply({ kind: "turnEnd", name: "main", stopReason: "end_turn", summary: "" });
    expect(fx(e)).toContainEqual({ kind: "prompt", name: "main", session: "s1", text: "Answer to Q1: yes\nAllowed for this task: push." });
    expect(t.record.state).toBe("running");
  });

  it("an answer in waiting is delivered at once; grants are not duplicated", () => {
    const t = running();
    t.record.allowed_actions = ["push"];
    t.apply({ kind: "ask", text: "Which DB?", options: [], recommend: null });
    t.apply({ kind: "turnEnd", name: "main", stopReason: "end_turn", summary: "" });
    const o = t.apply({ kind: "answer", question: "Q1", text: "pg", grant: ["push", "open-pr"] });
    expect(fx(o)).toContainEqual({ kind: "prompt", name: "main", session: "s1", text: "Answer to Q1: pg\nAllowed for this task: push, open-pr." });
    expect(t.record.allowed_actions).toEqual(["push", "open-pr"]);
    expect(fx(o).find((e) => e.kind === "emit" && e.type === "answer")).toMatchObject({ data: { question: "Q1", text: "pg", grant: ["push", "open-pr"] }, name: "main" });
  });

  it("without an id the oldest open question is answered", () => {
    const t = running();
    t.apply({ kind: "ask", text: "a", options: [], recommend: null });
    t.apply({ kind: "ask", text: "b", options: [], recommend: null });
    t.apply({ kind: "answer", text: "x", grant: [] });
    expect(t.openQuestions().map((q) => q.id)).toEqual(["Q2"]);
  });

  it("refuses unknown ids, nothing open, bad grants and empty text", () => {
    const t = running();
    expect(t.apply({ kind: "answer", text: "x", grant: [] })).toMatchObject({ ok: false, code: "conflict" });
    t.apply({ kind: "ask", text: "a", options: [], recommend: null });
    expect(t.apply({ kind: "answer", question: "Q9", text: "x", grant: [] })).toMatchObject({ ok: false, code: "not_found" });
    expect(t.apply({ kind: "answer", text: "x", grant: ["merge"] })).toMatchObject({ ok: false, code: "bad_request" });
    expect(t.apply({ kind: "answer", text: "x", grant: ["deploy:"] })).toMatchObject({ ok: false, code: "bad_request" });
    expect(t.apply({ kind: "answer", text: " ", grant: [] })).toMatchObject({ ok: false, code: "bad_request" });
    expect(t.openQuestions()).toHaveLength(1);
  });

  // Review Focus 2
  it("a second answer to the same question is a conflict and adds nothing to the inbox", () => {
    const t = running();
    t.apply({ kind: "ask", text: "a", options: [], recommend: null });
    t.apply({ kind: "answer", question: "Q1", text: "x", grant: [] });
    const o = t.apply({ kind: "answer", question: "Q1", text: "x", grant: [] });
    expect(o).toMatchObject({ ok: false, code: "conflict", message: "Q1 is already answered" });
    expect(main(t).inbox).toHaveLength(1);
  });

  // Review Focus 1
  it("an answer during a resume load is queued and delivered once; a prompt then conflicts", () => {
    const t = m({ state: "suspended", session: "s1", inbox: [] }, [
      { id: "Q1", source: "ask", text: "a", options: [], recommendation: null, asked: "t", status: "open", session: "main" },
    ]);
    t.apply({ kind: "boot", fresh: false });
    const a = t.apply({ kind: "answer", text: "yes", grant: [] });
    expect(fx(a)).toContainEqual({ kind: "startAgent" });
    expect(t.record.state).toBe("starting");
    expect(t.apply({ kind: "userPrompt", text: "x" })).toMatchObject({ ok: false, code: "conflict" });
    t.apply({ kind: "agentStarted", capabilities: { fork: true } });
    const r = t.apply({ kind: "sessionReady", name: "main", session: "s1" });
    expect(fx(r).filter((e) => e.kind === "prompt")).toEqual([{ kind: "prompt", name: "main", session: "s1", text: "Answer to Q1: yes" }]);
    expect(main(t).inbox).toEqual([]);
  });
});

describe("permission requests", () => {
  const opts = [
    { optionId: "allow-once", name: "Yes", kind: "allow_once" },
    { optionId: "allow-with-updates", name: "Yes, and allow", kind: "allow_always" },
    { optionId: "reject", name: "No", kind: "reject_once" },
  ];

  it("become a waiting question; an answer goes back through ACP, not the inbox", () => {
    const t = running();
    const p = t.apply({ kind: "permissionRequest", sessionId: "s1", title: "echo x", command: "echo x", options: opts });
    expect(t.record.state).toBe("waiting");
    expect(fx(p).find((e) => e.kind === "question")).toMatchObject({ question: { id: "Q1", source: "permission", options: ["Yes", "Yes, and allow", "No"] } });
    const a = t.apply({ kind: "answer", text: "allow", grant: [] });
    expect(fx(a)).toContainEqual({ kind: "permission", question: "Q1", optionId: "allow-once" });
    expect(main(t).inbox).toEqual([]);
    expect(t.record.state).toBe("running");
  });

  it("accept option names and kinds, case-insensitive; refuse anything else", () => {
    for (const [text, id] of [["No", "reject"], ["reject", "reject"], ["ALLOW ALWAYS", "allow-with-updates"], ["yes", "allow-once"]] as const) {
      const t = running();
      t.apply({ kind: "permissionRequest", sessionId: "s1", title: "x", command: "x", options: opts });
      expect(fx(t.apply({ kind: "answer", text, grant: [] }))).toContainEqual({ kind: "permission", question: "Q1", optionId: id });
    }
    const t = running();
    t.apply({ kind: "permissionRequest", sessionId: "s1", title: "x", command: "x", options: opts });
    expect(t.apply({ kind: "answer", text: "maybe", grant: [] })).toMatchObject({ ok: false, code: "bad_request" });
  });

  it("are cancelled at suspension; the unfinished prompt and a later answer arrive as text after the load", () => {
    const t = running();
    t.apply({ kind: "permissionRequest", sessionId: "s1", title: "x", command: "x", options: opts });
    const s = t.apply({ kind: "idleTimeout" });
    expect(fx(s)).toContainEqual({ kind: "permission", question: "Q1", optionId: null });
    expect(t.record.state).toBe("suspended");
    const a = t.apply({ kind: "answer", text: "allow", grant: [] });
    expect(fx(a)).toContainEqual({ kind: "startAgent" });
    expect(main(t).inbox).toEqual([
      { kind: "prompt", text: "Fix the login bug" },
      { kind: "answer", question: "Q1", text: "Answer to Q1: allow" },
    ]);
  });
});

describe("fix round 1", () => {
  const opts = [
    { optionId: "allow-once", name: "Yes", kind: "allow_once" },
    { optionId: "reject", name: "No", kind: "reject_once" },
  ];
  const perm = { kind: "permissionRequest", sessionId: "s1", title: "x", command: "x", options: opts } as const;

  it("cancel while permissions are pending answers them as cancelled, then cancels", () => {
    const t = running();
    t.apply(perm);
    expect(t.record.state).toBe("waiting");
    const effects = fx(t.apply({ kind: "cancel" }));
    expect(effects[0]).toEqual({ kind: "permission", question: "Q1", optionId: null });
    expect(effects.filter((e) => e.kind === "cancel")).toEqual([{ kind: "cancel", session: "s1" }]);
    expect(effects).toContainEqual({ kind: "emit", type: "answer", data: { question: "Q1", text: "cancelled", grant: [] }, name: "main" });
    // the cancelled request can no longer be answered: its question is closed and the task is running again
    expect(t.openQuestions()).toEqual([]);
    expect(t.record.state).toBe("running");
    t.apply({ kind: "turnEnd", name: "main", stopReason: "cancelled", summary: "" });
    expect(t.record.state).toBe("idle");
    expect(t.record.reason).toBe("cancelled");
  });

  it("cancel is idempotent until the turn ends", () => {
    const t = running();
    expect(fx(t.apply({ kind: "cancel" }))).toEqual([{ kind: "cancel", session: "s1" }]);
    expect(fx(t.apply({ kind: "cancel" }))).toEqual([]);
    t.apply({ kind: "turnEnd", name: "main", stopReason: "cancelled", summary: "" });
    t.apply({ kind: "userPrompt", text: "again" });
    expect(fx(t.apply({ kind: "cancel" }))).toEqual([{ kind: "cancel", session: "s1" }]);
  });

  it("a permission request is ignored unless a turn is in progress", () => {
    const t = running();
    t.apply({ kind: "turnEnd", name: "main", stopReason: "end_turn", summary: "" });
    expect(fx(t.apply(perm))).toEqual([]);
    expect(t.record.state).toBe("idle");
    expect(t.questions).toEqual([]);
  });

  it("a permission request during a cancel is answered as cancelled and not recorded", () => {
    const t = running();
    t.apply({ kind: "cancel" });
    expect(fx(t.apply(perm))).toEqual([{ kind: "permission", question: "Q1", optionId: null }]);
    expect(t.questions).toEqual([]);
    expect(t.record.state).toBe("running");
    t.apply({ kind: "turnEnd", name: "main", stopReason: "cancelled", summary: "" });
    expect(t.record.state).toBe("idle");
  });

  it("agentStarted is ignored when stopped, failed or suspended", () => {
    for (const s of ["stopped", "failed", "suspended"] as const) {
      const t = m({ state: s });
      expect(fx(t.apply({ kind: "agentStarted", capabilities: { fork: true } }))).toEqual([]);
      expect(t.record.state).toBe(s);
      expect(main(t).inbox).toHaveLength(1);
    }
  });

  it("a second agentExit changes nothing", () => {
    const t = running();
    t.apply({ kind: "agentExit", error: "first" });
    expect(fx(t.apply({ kind: "agentExit", error: "second" }))).toEqual([]);
    expect(t.record.reason).toBe("first");
  });

  it("failure switches the timer off", () => {
    const o = running().apply({ kind: "agentExit", error: "boom" });
    expect(fx(o)).toContainEqual({ kind: "timer", on: false });
  });

  it("the notification for a permission question carries that question", () => {
    const t = running();
    t.apply({ kind: "ask", text: "older", options: [], recommend: null });
    const o = t.apply(perm);
    expect(fx(o).filter((e) => e.kind === "notify")).toMatchObject([{ question: { id: "Q2", source: "permission", session: "main" } }]);
  });

  it("rejecting a permission records no grant", () => {
    const t = running();
    t.apply(perm);
    t.apply({ kind: "answer", text: "no", grant: ["push"] });
    expect(t.record.allowed_actions).toEqual([]);
    expect(t.questions[0]?.grant).toEqual([]);
  });
});

describe("cancel, stop, suspension, failure", () => {
  it("cancel only while a turn is in progress", () => {
    const t = running();
    expect(fx(t.apply({ kind: "cancel" }))).toEqual([{ kind: "cancel", session: "s1" }]);
    t.apply({ kind: "turnEnd", name: "main", stopReason: "cancelled", summary: "" });
    expect(t.record.state).toBe("idle");
    expect(t.apply({ kind: "cancel" })).toMatchObject({ ok: false, code: "conflict" });
  });

  it("stop with a reason and no user flag records them", () => {
    const t = running();
    const o = t.apply({ kind: "stop", reason: "auto-cleaned", byUser: false });
    expect(fx(o)).toContainEqual({ kind: "emit", type: "state", data: { state: "stopped", reason: "auto-cleaned" }, name: null });
    expect(t.record.stopped_by_user).toBe(false);
    expect(t.record.reason).toBe("auto-cleaned");
  });

  it("stop cancels a running turn, ends the agent and exits 0; a late turn end is ignored", () => {
    const t = running();
    const o = t.apply({ kind: "stop" });
    expect(fx(o)).toEqual([
      { kind: "cancel", session: "s1" }, { kind: "kill" },
      { kind: "emit", type: "state", data: { state: "stopped", reason: "stopped by user" }, name: null },
      { kind: "timer", on: false }, { kind: "notify", question: null }, { kind: "exit", code: 0 },
    ]);
    expect(t.record.state).toBe("stopped");
    expect(t.record.stopped_by_user).toBe(true);
    expect(main(t).inbox).toEqual([{ kind: "prompt", text: "Fix the login bug" }]);
    expect(fx(t.apply({ kind: "turnEnd", name: "main", stopReason: "cancelled", summary: "" }))).toEqual([]);
    expect(t.record.state).toBe("stopped");
  });

  it("the idle timeout suspends waiting and idle tasks only", () => {
    const t = running();
    expect(fx(t.apply({ kind: "idleTimeout" }))).toEqual([]);
    t.apply({ kind: "turnEnd", name: "main", stopReason: "end_turn", summary: "" });
    const o = t.apply({ kind: "idleTimeout" });
    expect(fx(o)).toEqual([
      { kind: "kill" },
      { kind: "emit", type: "state", data: { state: "suspended", reason: "idle timeout" }, name: null },
      { kind: "timer", on: false }, { kind: "exit", code: 0 },
    ]);
    expect(t.record.state).toBe("suspended");
    expect(t.agentLive).toBe(false);
  });

  it("an unexpected agent exit fails the task and exits 1; expected ones are ignored", () => {
    const t = running();
    const o = t.apply({ kind: "agentExit", error: "agent exited with code 3" });
    expect(t.record.state).toBe("failed");
    expect(t.record.reason).toBe("agent exited with code 3");
    expect(fx(o)).toContainEqual({ kind: "exit", code: 1 });
    const s = running(); s.apply({ kind: "stop" });
    expect(fx(s.apply({ kind: "agentExit", error: "x" }))).toEqual([]);
  });

  it("a failed task accepts a prompt and resumes its session", () => {
    const t = m({ state: "failed", session: "s1", inbox: [] });
    t.apply({ kind: "boot", fresh: false });
    expect(fx(t.apply({ kind: "userPrompt", text: "retry" }))).toContainEqual({ kind: "startAgent" });
    expect(fx(t.apply({ kind: "agentStarted", capabilities: { fork: true } })))
      .toContainEqual({ kind: "open", name: "main", mode: "load", from: null, model: null });
  });

  it("gate reports become gate events", () => {
    expect(fx(running().apply({ kind: "gate", rule: "gate", command: "git push" })))
      .toEqual([{ kind: "emit", type: "gate", data: { rule: "gate", command: "git push" }, name: null }]);
    expect(fx(two().apply({ kind: "gate", rule: "gate", command: "git push", sessionId: "s2" })))
      .toEqual([{ kind: "emit", type: "gate", data: { rule: "gate", command: "git push" }, name: "plan" }]);
  });
});

describe("an outstanding prompt that does not finish", () => {
  it("goes back to the inbox head when the agent exits, and pending permissions are released", () => {
    const t = running();
    t.apply({ kind: "permissionRequest", sessionId: "s1", title: "x", command: "x", options: [{ optionId: "a", name: "Yes", kind: "allow_once" }] });
    const effects = fx(t.apply({ kind: "agentExit", error: "boom" }));
    expect(effects).toContainEqual({ kind: "permission", question: "Q1", optionId: null });
    expect(main(t).inbox.map((i) => i.text)).toEqual(["Fix the login bug"]);
  });
});

describe("sessions", () => {
  const opts = [{ optionId: "allow-once", name: "Yes", kind: "allow_once" }];

  it("a second session opens on the live agent and prompts while main runs", () => {
    const t = running();
    const a = t.apply({ kind: "addSession", name: "plan", model: null, fork: null, text: "Plan it" });
    expect(a).toMatchObject({ ok: true, value: { id: "plan" } });
    expect(fx(a)).toContainEqual({ kind: "open", name: "plan", mode: "new", from: null, model: null });
    expect(sess(t, "plan").state).toBe("starting");
    expect(t.busy("plan")).toBe(true);
    const b = t.apply({ kind: "sessionReady", name: "plan", session: "s2" });
    expect(fx(b)).toContainEqual({ kind: "prompt", name: "plan", session: "s2", text: "Plan it" });
    expect(sstates(b, "plan")).toEqual(["running"]);
    expect(states(b)).toEqual([]);
    expect(t.record.state).toBe("running");
    expect(main(t).state).toBe("running");
    expect(t.record.session).toBe("s1");
  });

  it("a session added without text opens and goes idle; it takes the task's model", () => {
    const t = running();
    t.record.model = "m1";
    t.apply({ kind: "turnEnd", name: "main", stopReason: "end_turn", summary: "" });
    const a = t.apply({ kind: "addSession", name: "review", model: null, fork: null, text: null });
    expect(fx(a)).toContainEqual({ kind: "open", name: "review", mode: "new", from: null, model: "m1" });
    expect(t.record.state).toBe("running");
    t.apply({ kind: "sessionReady", name: "review", session: "s3" });
    expect(sess(t, "review").state).toBe("idle");
    expect(t.record.state).toBe("idle");
  });

  it("the task is idle only when no session runs", () => {
    const t = two();
    const a = t.apply({ kind: "turnEnd", name: "main", stopReason: "end_turn", summary: "main done" });
    expect(states(a)).toEqual([]);
    expect(main(t).state).toBe("idle");
    expect(t.record.state).toBe("running");
    expect(t.record.summary).toBe("main done");
    const b = t.apply({ kind: "turnEnd", name: "plan", stopReason: "end_turn", summary: "plan done" });
    expect(states(b)).toEqual(["idle"]);
    expect(t.record.summary).toBe("plan done");
    expect(main(t).summary).toBe("main done");
  });

  it("a permission request from plan while main runs notifies at once and is answered by answer without an id", () => {
    const t = two();
    const p = t.apply({ kind: "permissionRequest", sessionId: "s2", title: "x", command: "x", options: opts });
    expect(fx(p).filter((e) => e.kind === "notify")).toMatchObject([{ question: { id: "Q1", session: "plan" } }]);
    expect(sess(t, "plan").state).toBe("waiting");
    expect(t.record.state).toBe("running");
    const a = t.apply({ kind: "answer", text: "yes", grant: [] });
    expect(fx(a)).toContainEqual({ kind: "permission", question: "Q1", optionId: "allow-once" });
    expect(sess(t, "plan").state).toBe("running");
  });

  it("ask with an unknown session id lands on main; an answer goes to the asking session's inbox", () => {
    const t = two();
    const a = t.apply({ kind: "ask", text: "a", options: [], recommend: null, sessionId: "zzz" });
    expect(fx(a).find((e) => e.kind === "question")).toMatchObject({ question: { id: "Q1", session: "main" } });
    t.apply({ kind: "ask", text: "b", options: [], recommend: null, sessionId: "s2" });
    expect(t.questions[1]?.session).toBe("plan");
    t.apply({ kind: "answer", question: "Q2", text: "B", grant: [] });
    expect(sess(t, "plan").inbox).toEqual([{ kind: "answer", question: "Q2", text: "Answer to Q2: B" }]);
    expect(main(t).inbox).toEqual([]);
    // answer with a session answers that session's oldest open question
    t.apply({ kind: "ask", text: "c", options: [], recommend: null, sessionId: "s2" });
    t.apply({ kind: "answer", text: "C", grant: [], session: "plan" });
    expect(t.openQuestions().map((q) => q.id)).toEqual(["Q1"]);
  });

  it("cancel without a session cancels main only", () => {
    const t = two();
    expect(fx(t.apply({ kind: "cancel" }))).toEqual([{ kind: "cancel", session: "s1" }]);
    expect(t.busy("plan")).toBe(true);
    expect(fx(t.apply({ kind: "cancel", session: "plan" }))).toEqual([{ kind: "cancel", session: "s2" }]);
    expect(t.apply({ kind: "cancel", session: "nope" })).toMatchObject({ ok: false, code: "not_found" });
  });

  it("fork refuses a running source, unknown capabilities, and an agent without fork", () => {
    const add = (t: TaskMachine, fork = "main") => t.apply({ kind: "addSession", name: "f", model: null, fork, text: null });
    const starting = m();
    starting.apply({ kind: "boot", fresh: true });
    expect(add(starting)).toEqual({ ok: false, code: "conflict", message: "the agent is still starting; try again when the task is idle" });
    const nofork = running(false);
    nofork.apply({ kind: "turnEnd", name: "main", stopReason: "end_turn", summary: "" });
    expect(add(nofork)).toEqual({ ok: false, code: "conflict", message: "claude does not support forking a session" });
    const busy = running();
    expect(add(busy)).toEqual({ ok: false, code: "conflict", message: "main is running; fork it when it is idle" });
    expect(add(busy, "nope")).toMatchObject({ ok: false, code: "not_found" });
    busy.apply({ kind: "turnEnd", name: "main", stopReason: "end_turn", summary: "" });
    expect(fx(add(busy))).toContainEqual({ kind: "open", name: "f", mode: "fork", from: "s1", model: null });
    expect(sess(busy, "f").fork_of).toBe("main");
  });

  it("names: bad name 400, duplicate 409, the 17th session 409", () => {
    const t = running();
    const add = (name: string) => t.apply({ kind: "addSession", name, model: null, fork: null, text: null });
    expect(add("Bad!")).toMatchObject({ ok: false, code: "bad_request" });
    expect(add("main")).toMatchObject({ ok: false, code: "conflict" });
    for (let i = 2; i <= 16; i++) expect(add(`s${i}`)).toMatchObject({ ok: true });
    expect(add("s17")).toMatchObject({ ok: false, code: "conflict" });
    expect(t.record.sessions).toHaveLength(16);
  });

  it("a stopped task refuses new sessions", () => {
    const t = running();
    t.apply({ kind: "stop" });
    expect(t.apply({ kind: "addSession", name: "plan", model: null, fork: null, text: null })).toMatchObject({ ok: false, code: "conflict" });
  });

  it("a new or forked session that cannot open says why", () => {
    const t = running();
    t.apply({ kind: "addSession", name: "plan", model: "typo", fork: null, text: null });
    t.apply({ kind: "sessionLost", name: "plan", mode: "new", error: "unknown model" });
    expect(sess(t, "plan").reason).toBe("could not open the session: unknown model");
  });

  it("a lost session fails alone; prompting it says to add a new session", () => {
    const t = running();
    t.apply({ kind: "addSession", name: "plan", model: null, fork: null, text: "Plan it" });
    const l = t.apply({ kind: "sessionLost", name: "plan", mode: "load", error: "no such session" });
    expect(sstates(l, "plan")).toEqual(["failed"]);
    expect(sess(t, "plan").reason).toBe("its conversation could not be restored: no such session");
    expect(main(t).state).toBe("running");
    expect(t.record.state).toBe("running");
    t.apply({ kind: "turnEnd", name: "main", stopReason: "end_turn", summary: "" });
    expect(t.record.state).toBe("idle");
    expect(t.apply({ kind: "userPrompt", text: "x", session: "plan" })).toEqual({
      ok: false, code: "conflict", message: "plan failed: its conversation could not be restored: no such session; add a new session",
    });
  });

  it("a failed session's open questions are closed: answer without an id reaches the next session's question and the task can go idle", () => {
    const q = (id: string, session: string): Question => ({ id, source: "ask", text: id, options: [], recommendation: null, asked: "t", status: "open", session });
    const t = m({
      state: "suspended", session: "s1",
      sessions: [newSession("main", null, "t0", { session: "s1" }), newSession("plan", null, "t0", { session: "s2" })],
    }, [q("Q1", "plan"), q("Q2", "main")]);
    t.apply({ kind: "boot", fresh: false });
    t.apply({ kind: "userPrompt", text: "go", session: "plan" });
    t.apply({ kind: "agentStarted", capabilities: { fork: true } });
    const l = t.apply({ kind: "sessionLost", name: "plan", mode: "load", error: "gone" });
    expect(fx(l)).toContainEqual({ kind: "emit", type: "answer", data: { question: "Q1", text: "session failed", grant: [] }, name: "plan" });
    expect(t.openQuestions().map((x) => x.id)).toEqual(["Q2"]);
    expect(t.apply({ kind: "answer", text: "yes", grant: [] })).toMatchObject({ ok: true });
    expect(main(t).inbox).toEqual([{ kind: "answer", question: "Q2", text: "Answer to Q2: yes" }]);
    t.apply({ kind: "sessionReady", name: "main", session: "s1" });
    t.apply({ kind: "turnEnd", name: "main", stopReason: "end_turn", summary: "" });
    expect(t.record.state).toBe("idle");
  });

  it("agent exit with two turns outstanding requeues both texts and interrupts both", () => {
    const t = two();
    t.apply({ kind: "agentExit", error: "boom" });
    expect(main(t).inbox).toEqual([{ kind: "prompt", text: "Fix the login bug" }]);
    expect(sess(t, "plan").inbox).toEqual([{ kind: "prompt", text: "Plan it" }]);
    expect(main(t).state).toBe("interrupted");
    expect(sess(t, "plan").state).toBe("interrupted");
    expect(t.record.state).toBe("failed");
    expect(t.busy("main")).toBe(false);
  });

  it("a resume prompt to main also reaches every interrupted session", () => {
    const t = two();
    t.apply({ kind: "addSession", name: "review", model: null, fork: null, text: null });
    t.apply({ kind: "sessionReady", name: "review", session: "s3" });
    t.apply({ kind: "agentExit", error: "boom" });
    const r = t.apply({ kind: "userPrompt", text: "carry on" });
    expect(fx(r).filter((e) => e.kind === "startAgent")).toHaveLength(1);
    expect(main(t).inbox.map((i) => i.text)).toEqual(["Fix the login bug", "carry on"]);
    expect(sess(t, "plan").inbox.map((i) => i.text)).toEqual(["Plan it", "carry on"]);
    expect(sess(t, "review").inbox).toEqual([]);
    const s = fx(t.apply({ kind: "agentStarted", capabilities: { fork: true } }));
    expect(s.filter((e) => e.kind === "open").map((e) => e.kind === "open" && [e.name, e.mode])).toEqual([["main", "load"], ["plan", "load"]]);
  });

  it("a non-fresh boot interrupts sessions recorded running", () => {
    const t = m({
      state: "running", session: "s1",
      sessions: [
        newSession("main", null, "t0", { session: "s1", state: "running" }),
        newSession("plan", null, "t0", { session: "s2", state: "starting" }),
        newSession("review", null, "t0", { session: "s3", state: "idle" }),
      ],
    });
    const o = t.apply({ kind: "boot", fresh: false });
    expect(states(o)).toEqual(["interrupted"]);
    expect(t.record.sessions.map((s) => s.state)).toEqual(["interrupted", "interrupted", "idle"]);
  });

  it("sessions reload lazily: after boot only the prompted session is opened, with mode load", () => {
    const t = m({
      state: "suspended", session: "s1",
      sessions: [newSession("main", null, "t0", { session: "s1" }), newSession("plan", "m2", "t0", { session: "s2" })],
    });
    t.apply({ kind: "boot", fresh: false });
    expect(fx(t.apply({ kind: "userPrompt", text: "go", session: "plan" }))).toContainEqual({ kind: "startAgent" });
    const s = fx(t.apply({ kind: "agentStarted", capabilities: { fork: true } }));
    expect(s.filter((e) => e.kind === "open")).toEqual([{ kind: "open", name: "plan", mode: "load", from: null, model: "m2" }]);
    const r = t.apply({ kind: "sessionReady", name: "plan", session: "s2" });
    expect(fx(r)).toContainEqual({ kind: "prompt", name: "plan", session: "s2", text: "go" });
    expect(t.busy("main")).toBe(false);
    expect(t.record.state).toBe("running");
  });

  it("a scheduled task refuses other sessions", () => {
    const t = m({
      scheduled: true,
      sessions: [newSession("main", null, "t0", { inbox: [{ kind: "prompt", text: "x" }] }), newSession("plan", null, "t0")],
    });
    t.apply({ kind: "boot", fresh: true });
    expect(t.apply({ kind: "addSession", name: "other", model: null, fork: null, text: null })).toMatchObject({ ok: false, code: "conflict" });
    expect(t.apply({ kind: "userPrompt", text: "y", session: "plan" })).toMatchObject({ ok: false, code: "conflict" });
  });
});
