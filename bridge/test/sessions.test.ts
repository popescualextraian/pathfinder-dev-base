import { describe, expect, it } from "vitest";
import { MAIN, NAME_RE, deriveState, newSession, sessionView, upgradeQuestion, upgradeRecord } from "../src/sessions.js";
import type { Question, SessionRecord } from "../src/types.js";

const old = (over: Record<string, unknown> = {}) => ({
  version: 1, task: "t", model: "m1", state: "idle", reason: "", session: "s1",
  created: "c", updated: "u", summary: "did y", inbox: [{ kind: "prompt", text: "x" }], ...over,
});

describe("upgradeRecord", () => {
  it("turns an old record into one main session", () => {
    const r = upgradeRecord(old());
    expect(r.sessions).toEqual([{
      name: "main", session: "s1", model: "m1", state: "idle", reason: "",
      inbox: [{ kind: "prompt", text: "x" }], summary: "did y", fork_of: null, created: "c", updated: "u",
    }]);
    expect("inbox" in r).toBe(false);
    expect(r.capabilities).toBeNull();
  });

  it("maps task states onto main", () => {
    const st = (s: string) => upgradeRecord(old({ state: s })).sessions[0]!.state;
    for (const s of ["running", "waiting", "idle", "starting", "interrupted"]) expect(st(s)).toBe(s);
    for (const s of ["suspended", "stopped", "failed"]) expect(st(s)).toBe("idle");
  });

  it("keeps a record that has sessions", () => {
    const raw = { ...old({ inbox: undefined }), sessions: [newSession("main", "m1", "n")], capabilities: { fork: true } };
    expect(upgradeRecord(raw)).toEqual(raw);
  });
});

it("upgradeQuestion defaults the session to main", () => {
  const q = { id: "q" } as unknown as Question;
  expect(upgradeQuestion(q).session).toBe(MAIN);
  expect(upgradeQuestion({ ...q, session: "plan" }).session).toBe("plan");
});

describe("deriveState", () => {
  const s = (state: SessionRecord["state"]) => newSession("a", null, "n", { state });
  it("follows the rules", () => {
    expect(deriveState([s("idle")], 0, true)).toBe("starting");
    expect(deriveState([s("idle"), s("running")], 3, false)).toBe("running");
    expect(deriveState([s("starting")], 0, false)).toBe("running");
    expect(deriveState([s("waiting")], 1, false)).toBe("waiting");
    expect(deriveState([s("interrupted"), s("failed")], 0, false)).toBe("idle");
  });
});

it("NAME_RE accepts main, plan-2, a_b and refuses the rest", () => {
  for (const n of ["main", "plan-2", "a_b"]) expect(NAME_RE.test(n)).toBe(true);
  for (const n of ["", "-x", "A", "a".repeat(33), "../x"]) expect(NAME_RE.test(n)).toBe(false);
});

it("sessionView reports the inbox as a count", () => {
  const v = sessionView(newSession("a", null, "n", { inbox: [{ kind: "prompt", text: "x" }] }));
  expect(v.inbox).toBe(1);
});
