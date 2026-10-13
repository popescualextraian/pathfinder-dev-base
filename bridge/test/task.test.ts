import { describe, expect, it } from "vitest";
import { TaskMachine, type Effect, type Outcome } from "../src/task.js";
import type { TaskRecord, Question } from "../src/types.js";

const rec = (over: Partial<TaskRecord> = {}): TaskRecord => ({
  version: 1, task: "T-1", project: "demo", agent: "claude", model: null, state: "starting", reason: "",
  session: null, branch: null, created: "t0", updated: "t0", seq: 0, allowed_actions: [],
  inbox: [{ kind: "prompt", text: "Fix the login bug" }], summary: "", stopped_by_user: false, ...over,
});
const m = (over: Partial<TaskRecord> = {}, qs: Question[] = []) => new TaskMachine(rec(over), qs, () => "now");
const fx = (o: Outcome): Effect[] => { if (!o.ok) throw new Error(o.message); return o.effects; };
const kinds = (o: Outcome) => fx(o).map((e) => e.kind === "emit" ? `emit:${e.type}` : e.kind);
const states = (o: Outcome) => fx(o).flatMap((e) => (e.kind === "emit" && e.type === "state" ? [e.data.state] : []));

// running: a fresh task whose first prompt is outstanding
function running() {
  const t = m();
  t.apply({ kind: "boot", fresh: true });
  t.apply({ kind: "agentReady", session: "s1" });
  return t;
}

describe("start", () => {
  it("a fresh task spawns a new session, then sends the first prompt", () => {
    const t = m();
    const a = t.apply({ kind: "boot", fresh: true });
    expect(states(a)).toEqual(["starting"]);
    expect(fx(a)).toContainEqual({ kind: "spawn", mode: "new" });
    const b = t.apply({ kind: "agentReady", session: "s1" });
    expect(fx(b)).toContainEqual({ kind: "prompt", text: "Fix the login bug" });
    expect(t.record.state).toBe("running");
    expect(t.record.session).toBe("s1");
    expect(t.record.inbox).toEqual([]);
  });

  it("a record left running, waiting, idle or starting is interrupted; nothing is spawned", () => {
    for (const s of ["running", "waiting", "idle", "starting"] as const) {
      const t = m({ state: s, inbox: [] });
      const o = t.apply({ kind: "boot", fresh: false });
      expect(states(o)).toEqual(["interrupted"]);
      expect(kinds(o)).not.toContain("spawn");
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

  it("once a resume spawns the agent, the idle timeout of a lazy boot no longer applies", () => {
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
    const o = t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "Done." });
    expect(states(o)).toEqual(["idle"]);
    expect(t.record.summary).toBe("Done.");
    expect(fx(o)).toContainEqual({ kind: "timer", on: true });
    expect(fx(o)).toContainEqual({ kind: "notify", question: null });
  });

  it("a turn with an open question ends waiting", () => {
    const t = running();
    t.apply({ kind: "ask", text: "Which DB?", options: ["pg"], recommend: "pg" });
    const o = t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "" });
    expect(t.record.state).toBe("waiting");
    expect(t.record.reason).toBe("question Q1");
    expect(fx(o).find((e) => e.kind === "notify")).toMatchObject({ question: { id: "Q1" } });
  });

  it("a summary is cut to 300 characters", () => {
    const t = running();
    t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "x".repeat(400) });
    expect(t.record.summary).toHaveLength(300);
  });
});

describe("prompts", () => {
  it("are refused while a turn is in progress", () => {
    const o = running().apply({ kind: "userPrompt", text: "more" });
    expect(o).toMatchObject({ ok: false, code: "conflict" });
    expect(o.ok || o.message).toContain("cancel first");
  });

  it("are refused when empty or when stopped", () => {
    const t = running();
    t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "" });
    expect(t.apply({ kind: "userPrompt", text: "  " })).toMatchObject({ ok: false, code: "bad_request" });
    t.apply({ kind: "stop" });
    expect(t.apply({ kind: "userPrompt", text: "x" })).toMatchObject({ ok: false, code: "conflict" });
  });

  it("in idle go straight to the live agent", () => {
    const t = running();
    t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "" });
    const o = t.apply({ kind: "userPrompt", text: "Also add a test" });
    expect(fx(o)).toContainEqual({ kind: "prompt", text: "Also add a test" });
    expect(t.record.state).toBe("running");
  });

  it("in suspended load the session first, then deliver", () => {
    const t = m({ state: "suspended", session: "s1", inbox: [] });
    t.apply({ kind: "boot", fresh: false });
    const o = t.apply({ kind: "userPrompt", text: "go on" });
    expect(fx(o)).toContainEqual({ kind: "spawn", mode: "load" });
    expect(t.record.state).toBe("starting");
    const r = t.apply({ kind: "agentReady", session: "s1" });
    expect(fx(r)).toContainEqual({ kind: "prompt", text: "go on" });
  });
});

describe("questions and answers", () => {
  it("ask records an open question and returns its id", () => {
    const t = running();
    const o = t.apply({ kind: "ask", text: "Which DB?", options: ["pg", "sqlite"], recommend: "pg" });
    expect(o).toMatchObject({ ok: true, value: { id: "Q1" } });
    expect(fx(o).find((e) => e.kind === "question")).toMatchObject({ question: { id: "Q1", status: "open", source: "ask" } });
    expect(t.openQuestions().map((q) => q.id)).toEqual(["Q1"]);
  });

  it("an answer while the agent works is queued and delivered after the turn", () => {
    const t = running();
    t.apply({ kind: "ask", text: "Push?", options: [], recommend: null });
    const a = t.apply({ kind: "answer", text: "yes", grant: ["push"] });
    expect(kinds(a)).not.toContain("prompt");
    expect(t.record.allowed_actions).toEqual(["push"]);
    const e = t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "" });
    expect(fx(e)).toContainEqual({ kind: "prompt", text: "Answer to Q1: yes\nAllowed for this task: push." });
    expect(t.record.state).toBe("running");
  });

  it("an answer in waiting is delivered at once; grants are not duplicated", () => {
    const t = running();
    t.record.allowed_actions = ["push"];
    t.apply({ kind: "ask", text: "Which DB?", options: [], recommend: null });
    t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "" });
    const o = t.apply({ kind: "answer", question: "Q1", text: "pg", grant: ["push", "open-pr"] });
    expect(fx(o)).toContainEqual({ kind: "prompt", text: "Answer to Q1: pg\nAllowed for this task: push, open-pr." });
    expect(t.record.allowed_actions).toEqual(["push", "open-pr"]);
    expect(fx(o).find((e) => e.kind === "emit" && e.type === "answer")).toMatchObject({ data: { question: "Q1", text: "pg", grant: ["push", "open-pr"] } });
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
    expect(t.record.inbox).toHaveLength(1);
  });

  // Review Focus 1
  it("an answer during a resume load is queued and delivered once; a prompt then conflicts", () => {
    const t = m({ state: "suspended", session: "s1", inbox: [] }, [
      { id: "Q1", source: "ask", text: "a", options: [], recommendation: null, asked: "t", status: "open" },
    ]);
    t.apply({ kind: "boot", fresh: false });
    const a = t.apply({ kind: "answer", text: "yes", grant: [] });
    expect(fx(a)).toContainEqual({ kind: "spawn", mode: "load" });
    expect(t.record.state).toBe("starting");
    expect(t.apply({ kind: "userPrompt", text: "x" })).toMatchObject({ ok: false, code: "conflict" });
    const r = t.apply({ kind: "agentReady", session: "s1" });
    expect(fx(r).filter((e) => e.kind === "prompt")).toEqual([{ kind: "prompt", text: "Answer to Q1: yes" }]);
    expect(t.record.inbox).toEqual([]);
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
    const p = t.apply({ kind: "permissionRequest", title: "echo x", command: "echo x", options: opts });
    expect(t.record.state).toBe("waiting");
    expect(fx(p).find((e) => e.kind === "question")).toMatchObject({ question: { id: "Q1", source: "permission", options: ["Yes", "Yes, and allow", "No"] } });
    const a = t.apply({ kind: "answer", text: "allow", grant: [] });
    expect(fx(a)).toContainEqual({ kind: "permission", question: "Q1", optionId: "allow-once" });
    expect(t.record.inbox).toEqual([]);
    expect(t.record.state).toBe("running");
  });

  it("accept option names and kinds, case-insensitive; refuse anything else", () => {
    for (const [text, id] of [["No", "reject"], ["reject", "reject"], ["ALLOW ALWAYS", "allow-with-updates"], ["yes", "allow-once"]] as const) {
      const t = running();
      t.apply({ kind: "permissionRequest", title: "x", command: "x", options: opts });
      expect(fx(t.apply({ kind: "answer", text, grant: [] }))).toContainEqual({ kind: "permission", question: "Q1", optionId: id });
    }
    const t = running();
    t.apply({ kind: "permissionRequest", title: "x", command: "x", options: opts });
    expect(t.apply({ kind: "answer", text: "maybe", grant: [] })).toMatchObject({ ok: false, code: "bad_request" });
  });

  it("are cancelled at suspension; a later answer arrives as text after the load", () => {
    const t = running();
    t.apply({ kind: "permissionRequest", title: "x", command: "x", options: opts });
    const s = t.apply({ kind: "idleTimeout" });
    expect(fx(s)).toContainEqual({ kind: "permission", question: "Q1", optionId: null });
    expect(t.record.state).toBe("suspended");
    const a = t.apply({ kind: "answer", text: "allow", grant: [] });
    expect(fx(a)).toContainEqual({ kind: "spawn", mode: "load" });
    expect(t.record.inbox).toEqual([{ kind: "answer", question: "Q1", text: "Answer to Q1: allow" }]);
  });
});

describe("fix round 1", () => {
  const opts = [
    { optionId: "allow-once", name: "Yes", kind: "allow_once" },
    { optionId: "reject", name: "No", kind: "reject_once" },
  ];
  const perm = { kind: "permissionRequest", title: "x", command: "x", options: opts } as const;

  it("cancel while permissions are pending answers them as cancelled, then cancels", () => {
    const t = running();
    t.apply(perm);
    expect(t.record.state).toBe("waiting");
    const effects = fx(t.apply({ kind: "cancel" }));
    expect(effects[0]).toEqual({ kind: "permission", question: "Q1", optionId: null });
    expect(effects.at(-1)).toEqual({ kind: "cancel" });
    expect(effects).toContainEqual({ kind: "emit", type: "answer", data: { question: "Q1", text: "cancelled", grant: [] } });
    // the cancelled request can no longer be answered: its question is closed and the task is running again
    expect(t.openQuestions()).toEqual([]);
    expect(t.record.state).toBe("running");
    t.apply({ kind: "turnEnd", stopReason: "cancelled", summary: "" });
    expect(t.record.state).toBe("idle");
  });

  it("cancel is idempotent until the turn ends", () => {
    const t = running();
    expect(fx(t.apply({ kind: "cancel" }))).toEqual([{ kind: "cancel" }]);
    expect(fx(t.apply({ kind: "cancel" }))).toEqual([]);
    t.apply({ kind: "turnEnd", stopReason: "cancelled", summary: "" });
    t.apply({ kind: "userPrompt", text: "again" });
    expect(fx(t.apply({ kind: "cancel" }))).toEqual([{ kind: "cancel" }]);
  });

  it("a permission request is ignored unless a turn is in progress", () => {
    const t = running();
    t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "" });
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
    t.apply({ kind: "turnEnd", stopReason: "cancelled", summary: "" });
    expect(t.record.state).toBe("idle");
  });

  it("agentReady is ignored when stopped, failed or suspended", () => {
    for (const s of ["stopped", "failed", "suspended"] as const) {
      const t = m({ state: s });
      expect(fx(t.apply({ kind: "agentReady", session: "s9" }))).toEqual([]);
      expect(t.record.state).toBe(s);
      expect(t.record.inbox).toHaveLength(1);
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
    expect(fx(o).find((e) => e.kind === "notify")).toMatchObject({ question: { id: "Q2", source: "permission" } });
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
    expect(fx(t.apply({ kind: "cancel" }))).toEqual([{ kind: "cancel" }]);
    t.apply({ kind: "turnEnd", stopReason: "cancelled", summary: "" });
    expect(t.record.state).toBe("idle");
    expect(t.apply({ kind: "cancel" })).toMatchObject({ ok: false, code: "conflict" });
  });

  it("stop cancels a running turn, ends the agent and exits 0; a late turn end is ignored", () => {
    const t = running();
    const o = t.apply({ kind: "stop" });
    expect(fx(o)).toEqual([
      { kind: "cancel" }, { kind: "kill" },
      { kind: "emit", type: "state", data: { state: "stopped", reason: "stopped by user" } },
      { kind: "timer", on: false }, { kind: "notify", question: null }, { kind: "exit", code: 0 },
    ]);
    expect(t.record.state).toBe("stopped");
    expect(t.record.stopped_by_user).toBe(true);
    expect(fx(t.apply({ kind: "turnEnd", stopReason: "cancelled", summary: "" }))).toEqual([]);
    expect(t.record.state).toBe("stopped");
  });

  it("the idle timeout suspends waiting and idle tasks only", () => {
    const t = running();
    expect(fx(t.apply({ kind: "idleTimeout" }))).toEqual([]);
    t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "" });
    const o = t.apply({ kind: "idleTimeout" });
    expect(fx(o)).toEqual([
      { kind: "kill" },
      { kind: "emit", type: "state", data: { state: "suspended", reason: "idle timeout" } },
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
    expect(fx(t.apply({ kind: "userPrompt", text: "retry" }))).toContainEqual({ kind: "spawn", mode: "load" });
  });

  it("gate reports become gate events", () => {
    expect(fx(running().apply({ kind: "gate", rule: "gate", command: "git push" })))
      .toEqual([{ kind: "emit", type: "gate", data: { rule: "gate", command: "git push" } }]);
  });
});

describe("an outstanding prompt that does not finish", () => {
  it("goes back to the inbox head when the agent exits, and pending permissions are released", () => {
    const t = running();
    t.record.inbox = [];
    t.apply({ kind: "permissionRequest", title: "x", command: "x", options: [{ optionId: "a", name: "Yes", kind: "allow_once" }] });
    const effects = fx(t.apply({ kind: "agentExit", error: "boom" }));
    expect(effects).toContainEqual({ kind: "permission", question: "Q1", optionId: null });
    expect(t.record.inbox.map((i) => i.text)).toHaveLength(1);
  });
});
