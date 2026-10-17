import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { AgentProcess, type AgentHooks } from "../src/agent.js";
import { harnessFor } from "../src/harness.js";
import type { Update } from "../src/map.js";

const FAKE = fileURLToPath(new URL("./fake-agent.mjs", import.meta.url));
const agents: AgentProcess[] = [];
afterEach(async () => { await Promise.all(agents.splice(0).map((a) => a.kill())); });

function make(state: string, hooks: Partial<AgentHooks> = {}, env: NodeJS.ProcessEnv = {}) {
  const updates: Update[] = [];
  const bySession: string[] = [];
  const exits: string[] = [];
  const a = new AgentProcess(harnessFor("claude", { model: null, acpCmd: ["node", FAKE] }),
    { cwd: state, env: { ...process.env, FAKE_AGENT_STATE: state, ...env }, paragraph: "Use agentic-ask." },
    { onUpdate: (sid, u) => { bySession.push(sid); updates.push(u); }, onPermission: async () => null, onExit: (e) => exits.push(e), ...hooks });
  agents.push(a);
  return { a, updates, exits, bySession };
}
const texts = (us: Update[]) => us.filter((u) => u.sessionUpdate === "agent_message_chunk").map((u) => (u.content as { text: string }).text);

describe("AgentProcess", () => {
  it("opens a session with bypass and the paragraph, and runs turns", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a, updates } = make(dir);
    await a.start();
    const sid = await a.newSession(null);
    expect(await a.prompt(sid, "hello")).toBe("end_turn");
    expect(texts(updates)).toEqual(["echo: hello"]);
    await a.prompt(sid, "META");
    const meta = JSON.parse(texts(updates)[1] ?? "{}");
    expect(meta.mode).toBe("bypassPermissions");
    expect(meta.meta.systemPrompt.append).toBe("Use agentic-ask.");
  });

  it("cancels a running turn", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a } = make(dir);
    await a.start(); const sid = await a.newSession(null);
    const p = a.prompt(sid, "SLEEP:10000");
    setTimeout(() => a.cancel(sid), 200);
    expect(await p).toBe("cancelled");
  });

  it("passes permission requests to the hook and returns its choice", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const asked: unknown[] = [];
    const { a, updates } = make(dir, { onPermission: async (r) => { asked.push(r); return "reject"; } });
    await a.start(); const sid = await a.newSession(null);
    await a.prompt(sid, "PERMISSION:echo x");
    expect(asked).toEqual([{ sessionId: sid, title: "echo x", command: "echo x", options: [
      { optionId: "allow-once", name: "Yes", kind: "allow_once" },
      { optionId: "allow-always", name: "Always", kind: "allow_always" },
      { optionId: "reject", name: "No", kind: "reject_once" },
    ] }]);
    expect(texts(updates)).toEqual(["permission: reject"]);
  });

  it("loads a session in a new process and drops the replayed history", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const first = make(dir);
    await first.a.start();
    const sid = await first.a.newSession(null);
    await first.a.prompt(sid, "one");
    await first.a.kill();
    const second = make(dir);
    await second.a.start();
    await second.a.loadSession(sid, null);
    expect(second.updates).toEqual([]);
    await second.a.prompt(sid, "HISTORY");
    expect(texts(second.updates)).toEqual(["history: 2"]);
  });

  it("rejects a load of an unknown session", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a } = make(dir);
    await a.start();
    await expect(a.loadSession("nope", null)).rejects.toThrow();
  });

  it("reports an unexpected exit, but not a kill", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const crash = make(dir);
    await crash.a.start(); const sid = await crash.a.newSession(null);
    await expect(crash.a.prompt(sid, "CRASH")).rejects.toThrow();
    await new Promise((r) => setTimeout(r, 200));
    expect(crash.exits).toEqual(["agent exited with code 3"]);
    const quiet = make(dir);
    await quiet.a.start();
    await quiet.a.kill();
    expect(quiet.exits).toEqual([]);
  });

  it("cancels a permission request when the hook throws, and the turn goes on", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a, updates } = make(dir, { onPermission: async () => { throw new Error("boom"); } });
    await a.start(); const sid = await a.newSession(null);
    expect(await a.prompt(sid, "PERMISSION:echo x")).toBe("end_turn");
    expect(texts(updates)).toEqual(["permission: cancelled"]);
    expect(await a.prompt(sid, "again")).toBe("end_turn");
  });

  it("cancels a permission request for an option that was not offered", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a, updates } = make(dir, { onPermission: async () => "bogus" });
    await a.start(); const sid = await a.newSession(null);
    await a.prompt(sid, "PERMISSION:echo x");
    expect(texts(updates)).toEqual(["permission: cancelled"]);
  });

  it("sends session/cancel only while a prompt is in flight", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a } = make(dir);
    await a.start(); const sid = await a.newSession(null);
    a.cancel(sid); // idle: must not leak into the next turn
    expect(await a.prompt(sid, "SLEEP:300")).toBe("end_turn");
    a.cancel(sid); // after the prompt settled
    expect(await a.prompt(sid, "SLEEP:300")).toBe("end_turn");
  });

  it("rejects start with the spawn error and reports the exit once", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const exits: string[] = [];
    const a = new AgentProcess(harnessFor("claude", { model: null, acpCmd: ["/nonexistent/agent-bin"] }),
      { cwd: dir, env: process.env, paragraph: "" },
      { onUpdate: () => {}, onPermission: async () => null, onExit: (e) => exits.push(e) });
    agents.push(a);
    await expect(a.start()).rejects.toThrow(/ENOENT/);
    await new Promise((r) => setTimeout(r, 200));
    expect(exits).toHaveLength(1);
    expect(exits[0]).toMatch(/ENOENT/);
  });

  it("reports the fork capability", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    expect(await make(dir).a.start()).toEqual({ fork: true });
    expect(await make(dir, {}, { FAKE_NO_FORK: "1" }).a.start()).toEqual({ fork: false });
  });

  it("runs two sessions at once", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a, bySession } = make(dir);
    await a.start();
    const s1 = await a.newSession(null);
    const s2 = await a.newSession(null);
    expect(await Promise.all([a.prompt(s1, "SLEEP:300"), a.prompt(s2, "SLEEP:300")])).toEqual(["end_turn", "end_turn"]);
    expect(bySession).toContain(s1);
    expect(bySession).toContain(s2);
  });

  it("gives each session its own model", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a, updates } = make(dir);
    await a.start();
    const s1 = await a.newSession("m1");
    const s2 = await a.newSession(null);
    await a.prompt(s1, "MODEL");
    await a.prompt(s2, "MODEL");
    expect(texts(updates)).toEqual(["model: m1", "model: none"]);
  });

  it("forks into a loaded new session with the history", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a, updates } = make(dir);
    await a.start();
    const s1 = await a.newSession(null);
    await a.prompt(s1, "a");
    updates.length = 0;
    const s2 = await a.forkSession(s1, null);
    expect(s2).not.toBe(s1);
    expect(updates).toEqual([]);
    await a.prompt(s2, "HISTORY");
    expect(texts(updates)).toEqual(["history: 2"]);
  });

  it("refuses to fork without the capability", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a } = make(dir, {}, { FAKE_NO_FORK: "1" });
    await a.start();
    const s1 = await a.newSession(null);
    await expect(a.forkSession(s1, null)).rejects.toThrow("claude does not support forking a session");
  });

  it("mutes the replay of a load for that session only", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a, updates, bySession } = make(dir);
    await a.start();
    const s1 = await a.newSession(null);
    const s2 = await a.newSession(null);
    await a.prompt(s2, "replayed");
    updates.length = 0; bySession.length = 0;
    const running = a.prompt(s1, "SLEEP:300");
    await a.loadSession(s2, null);
    await running;
    expect(bySession).toContain(s1);
    expect(bySession).not.toContain(s2);
  });

  it("cancels only the named session", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a } = make(dir);
    await a.start();
    const s1 = await a.newSession(null);
    const s2 = await a.newSession(null);
    const p1 = a.prompt(s1, "SLEEP:600");
    const p2 = a.prompt(s2, "SLEEP:600");
    setTimeout(() => a.cancel(s1), 200);
    expect(await Promise.all([p1, p2])).toEqual(["cancelled", "end_turn"]);
  });
});

describe("copilot harness", () => {
  it("afterSession sets the model when one is given, and nothing otherwise", async () => {
    const calls: string[][] = [];
    const stub = {
      setMode: async (s: string, m: string) => { calls.push(["mode", s, m]); },
      setConfigOption: async (s: string, c: string, v: string) => { calls.push(["config", s, c, v]); },
    };
    const h = harnessFor("copilot", { model: null, acpCmd: null });
    await h.afterSession(stub, "s1", "m2");
    await h.afterSession(stub, "s2", null);
    expect(calls).toEqual([["config", "s1", "model", "m2"]]);
  });
});
