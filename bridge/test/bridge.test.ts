import { chmodSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { AgentProcess, type AgentHooks, type AgentLike } from "../src/agent.js";
import { Bridge } from "../src/bridge.js";
import { agentEnvironment, loadConfig, type Config } from "../src/config.js";
import { harnessFor } from "../src/harness.js";
import { Notifier } from "../src/notify.js";
import { makeRedactor } from "../src/redact.js";
import { startServer } from "../src/server.js";
import { SCHEDULED_NOTE, SUMMARY_PROMPT } from "../src/scheduled.js";
import { Store } from "../src/store.js";
import type { State, TaskEvent } from "../src/types.js";

const FAKE = fileURLToPath(new URL("./fake-agent.mjs", import.meta.url));
const running: Array<{ bridge: Bridge; close(): Promise<void> }> = [];
afterEach(async () => { for (const r of running.splice(0)) { await r.bridge.shutdownAgent(); await r.close(); } });

async function start(dir: string, extra: Record<string, string> = {},
  worktree: (args: string[]) => { ok: boolean; out: string; err: string } = () => ({ ok: true, out: "", err: "" })) {
  const exits: number[] = [];
  const cwds: string[] = [];
  const wt: string[][] = [];
  let released = 0;
  const env = { AGENTIC_TASK_TOKEN: "task-token-0123456789", AGENTIC_AGENT_TOKEN: "agent-token-0123456789",
    AGENTIC_TASK_DIR: dir, AGENTIC_TASK_ID: "T-1", AGENTIC_PROJECT: "demo", AGENTIC_ACP_CMD: JSON.stringify(["node", FAKE]),
    AGENTIC_WORK: dir, AGENTIC_EVENTS_DIR: join(dir, "no-events"), ...extra };
  const cfg: Config = { ...loadConfig(env), port: 0 };
  const store = new Store(dir, makeRedactor([cfg.tokens.task, cfg.tokens.agent]));
  let agentEnv: NodeJS.ProcessEnv = {};
  const bridge = new Bridge({
    store, config: cfg, paragraph: "Use agentic-ask.",
    notifier: new Notifier({ eventsLog: null, webhook: null, project: "demo", log: () => {} }),
    agentFactory: (hooks, cwd) => { cwds.push(cwd); return new AgentProcess(harnessFor("claude", { model: null, acpCmd: cfg.acpCmd }),
      { cwd, env: { ...agentEnv, FAKE_AGENT_STATE: join(dir, "fake") }, paragraph: "Use agentic-ask.", model: null }, hooks); },
    worktree: (args) => { wt.push(args); return worktree(args); },
    release: () => { released++; },
    exit: (code) => exits.push(code), now: () => new Date().toISOString(), log: () => {},
  });
  const server = await startServer({ port: 0, host: "127.0.0.1", tokens: cfg.tokens, access: { hosts: [], origins: [] },
    target: bridge, subscribe: (fn) => bridge.subscribe(fn) });
  agentEnv = agentEnvironment({ ...process.env }, { ...cfg, port: server.port });
  running.push({ bridge, close: server.close });
  try {
    bridge.boot();
  } catch (e) {
    await bridge.shutdownAgent();
    await server.close();
    running.pop();
    throw e;
  }
  return { bridge, exits, store, port: server.port, cwds, wt, released: () => released };
}

// exit is called once the final webhooks are out: a moment after the command
async function exited(exits: number[]): Promise<number[]> {
  for (let i = 0; i < 200 && exits.length === 0; i++) await new Promise((r) => setTimeout(r, 10));
  return exits;
}

function waitState(bridge: Bridge, ...states: State[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const check = () => states.includes(bridge.status().state as State);
    if (check()) return resolve();
    const t = setTimeout(() => reject(new Error(`timeout waiting for ${states.join("|")}, state ${String(bridge.status().state)}`)), 10000);
    const off = bridge.subscribe(() => { if (check()) { clearTimeout(t); off(); resolve(); } });
  });
}
const finals = (store: Store) => store.readEvents(0).filter((e: TaskEvent) => e.type === "message" && e.data.role === "agent" && e.data.final).map((e) => e.data.text);
function taskDir(prompt = "Fix the login bug") {
  const dir = mkdtempSync(join(tmpdir(), "bridge-"));
  writeFileSync(join(dir, "prompt.md"), prompt);
  return dir;
}

describe("Bridge", () => {
  it("runs the first prompt to idle and records events, transcript and summary", async () => {
    const dir = taskDir();
    const { bridge, store } = await start(dir);
    await waitState(bridge, "idle");
    expect(store.readEvents(0).filter((e) => e.type === "state").map((e) => e.data.state)).toEqual(["starting", "running", "idle"]);
    expect(finals(store)).toEqual(["echo: Fix the login bug"]);
    expect(bridge.status()).toMatchObject({ state: "idle", summary: "echo: Fix the login bug", inbox: 0, questions: [] });
    expect(readFileSync(join(dir, "transcript.md"), "utf8")).toContain("> Fix the login bug");
  });

  it("asks over HTTP with the agent token, waits, and delivers an answer with a grant", async () => {
    const { bridge, store } = await start(taskDir("ASK:Which DB?"));
    await waitState(bridge, "waiting");
    expect(bridge.status().questions).toMatchObject([{ id: "Q1", text: "Which DB?", source: "ask" }]);
    expect(bridge.command({ kind: "answer", text: "pg", grant: ["push"] })).toMatchObject({ ok: true });
    await waitState(bridge, "idle");
    expect(finals(store).at(-1)).toBe("echo: Answer to Q1: pg\nAllowed for this task: push.");
    expect(JSON.parse(readFileSync(join(store.dir, "state.json"), "utf8")).allowed_actions).toEqual(["push"]);
  });

  it("cancels a running turn", async () => {
    const { bridge, store } = await start(taskDir("SLEEP:20000"));
    await waitState(bridge, "running");
    await new Promise((r) => setTimeout(r, 300));
    expect(bridge.command({ kind: "cancel" })).toMatchObject({ ok: true });
    await waitState(bridge, "idle");
    expect(bridge.status().reason).toBe("cancelled");
    expect(store.readEvents(0).some((e) => e.type === "tool")).toBe(true);
  });

  it("suspends after the idle timeout, exits 0, and resumes the session in a new bridge without replay", async () => {
    const dir = taskDir();
    const a = await start(dir, { AGENTIC_IDLE_TIMEOUT: "0.3" });
    await waitState(a.bridge, "suspended");
    expect(await exited(a.exits)).toEqual([0]);
    const b = await start(dir);
    expect(b.bridge.status().state).toBe("suspended");
    expect(b.bridge.command({ kind: "userPrompt", text: "HISTORY" })).toMatchObject({ ok: true });
    await waitState(b.bridge, "idle");
    expect(finals(b.store)).toEqual(["echo: Fix the login bug", "history: 2"]);
  });

  it("falls back to a new session seeded with the task history when the session is gone", async () => {
    const dir = taskDir();
    const a = await start(dir, { AGENTIC_IDLE_TIMEOUT: "0.3" });
    await waitState(a.bridge, "suspended");
    const rec = JSON.parse(readFileSync(join(dir, "state.json"), "utf8"));
    writeFileSync(join(dir, "state.json"), JSON.stringify({ ...rec, session: "gone" }));
    const b = await start(dir);
    b.bridge.command({ kind: "userPrompt", text: "go on" });
    await waitState(b.bridge, "idle");
    expect(b.store.readEvents(0).some((e) => e.type === "error" && String(e.data.message).includes("could not be loaded"))).toBe(true);
    expect(String(finals(b.store).at(-1))).toMatch(/^echo: Original task:\nFix the login bug/);
  });

  it("stops: cancels, ends the agent, exits 0", async () => {
    const { bridge, exits } = await start(taskDir("SLEEP:20000"));
    await waitState(bridge, "running");
    bridge.command({ kind: "stop" });
    expect(bridge.status()).toMatchObject({ state: "stopped", stopped_by_user: true });
    expect(await exited(exits)).toEqual([0]);
  });

  it("fails and exits 1 when the agent crashes", async () => {
    const { bridge, exits } = await start(taskDir("CRASH"));
    await waitState(bridge, "failed");
    expect(await exited(exits)).toEqual([1]);
  });

  it("a record left running is interrupted at boot and spawns nothing", async () => {
    const dir = taskDir();
    const a = await start(dir);
    await waitState(a.bridge, "idle");
    const rec = JSON.parse(readFileSync(join(dir, "state.json"), "utf8"));
    writeFileSync(join(dir, "state.json"), JSON.stringify({ ...rec, state: "running" }));
    const b = await start(dir);
    expect(b.bridge.status().state).toBe("interrupted");
  });

  it("holds an ACP permission request as a question and resolves it from the answer", async () => {
    const { bridge, store } = await start(taskDir("PERMISSION:git push"));
    await waitState(bridge, "waiting");
    expect(bridge.status().questions).toMatchObject([{ id: "Q1", source: "permission" }]);
    expect(bridge.command({ kind: "answer", text: "allow", grant: [] })).toMatchObject({ ok: true });
    await waitState(bridge, "idle");
    expect(finals(store).at(-1)).toBe("permission: allow-once");
  });

  it("cancels a pending permission request", async () => {
    const { bridge, store } = await start(taskDir("PERMISSION:git push"));
    await waitState(bridge, "waiting");
    expect(bridge.command({ kind: "cancel" })).toMatchObject({ ok: true });
    await waitState(bridge, "idle");
    expect(finals(store).at(-1)).toBe("permission: cancelled");
  });

  // Review Focus 5
  it.skipIf(process.getuid?.() === 0)("refuses to boot in a directory it cannot write, naming it", async () => {
    const dir = taskDir();
    chmodSync(dir, 0o500);
    await expect(start(dir)).rejects.toThrow(dir);
    chmodSync(dir, 0o700);
  });

  it("refuses to boot a fresh task without a prompt", async () => {
    const dir = mkdtempSync(join(tmpdir(), "bridge-"));
    await expect(start(dir)).rejects.toThrow("no prompt");
  });
});

// A scripted agent for the cases a real process cannot reproduce on demand.
class StubAgent implements AgentLike {
  prompts: string[] = [];
  cancels = 0;
  killed = false;
  constructor(readonly hooks: AgentHooks, private readonly script: Array<(text: string) => Promise<string>>) {}
  async start() {}
  async newSession() { return "s1"; }
  async loadSession() {}
  prompt(text: string) { this.prompts.push(text); return (this.script.shift() ?? (async () => "end_turn"))(text); }
  cancel() { this.cancels++; }
  async kill() { this.killed = true; }
}

let stubDir = "";
async function stubbed(opts: { idleMs?: number; fetch?: typeof fetch } = {}) {
  const dir = taskDir();
  stubDir = dir;
  const cfg: Config = { ...loadConfig({ AGENTIC_TASK_TOKEN: "task-token-0123456789", AGENTIC_AGENT_TOKEN: "agent-token-0123456789",
    AGENTIC_TASK_DIR: dir, AGENTIC_NOTIFY_WEBHOOK: "https://hooks.example.com/x" }), ...(opts.idleMs ? { idleTimeoutMs: opts.idleMs } : {}) };
  const store = new Store(dir, makeRedactor([cfg.tokens.task, cfg.tokens.agent]));
  const agents: StubAgent[] = [];
  const script: Array<(text: string) => Promise<string>> = [];
  const exits: number[] = [];
  const bodies: string[] = [];
  const fetchStub = opts.fetch ?? ((async (_u: string, init: RequestInit) => { bodies.push(String(init.body)); return new Response(null, { status: 204 }); }) as unknown as typeof fetch);
  const bridge = new Bridge({
    store, config: cfg, paragraph: "",
    notifier: new Notifier({ eventsLog: null, webhook: cfg.webhook, project: "demo", log: () => {}, fetch: fetchStub, retryDelayMs: 1 }),
    agentFactory: (hooks) => { const a = new StubAgent(hooks, script); agents.push(a); return a; },
    worktree: () => ({ ok: true, out: "", err: "" }), release: () => {},
    exit: (c) => exits.push(c), now: () => new Date().toISOString(), log: () => {},
  });
  running.push({ bridge, close: async () => {} });
  return { bridge, store, agents, exits, bodies, script };
}
const tick = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe("Bridge with a scripted agent", () => {
  it("answers a permission request made while cancelling at once, without recording a question", async () => {
    const { bridge, store, agents, script } = await stubbed();
    let finish: (s: string) => void = () => {};
    script.push(() => new Promise<string>((r) => { finish = r; }));
    bridge.boot();
    await waitState(bridge, "running");
    const ask = { title: "t", command: "git push", options: [{ optionId: "a", name: "Yes", kind: "allow_once" }] };
    const pending = agents[0]!.hooks.onPermission(ask);
    expect(bridge.status()).toMatchObject({ state: "waiting", questions: [{ id: "Q1" }] });
    expect(bridge.command({ kind: "cancel" })).toMatchObject({ ok: true });
    expect(await pending).toBeNull();
    expect(await agents[0]!.hooks.onPermission(ask)).toBeNull();
    expect(store.readQuestions().map((q) => q.id)).toEqual(["Q1"]);
    expect(agents[0]!.cancels).toBe(1);
    finish("cancelled");
    await waitState(bridge, "idle");
  });

  it("answers null to a permission request when no turn is outstanding", async () => {
    const { bridge, agents } = await stubbed();
    bridge.boot();
    await waitState(bridge, "idle");
    const r = await agents[0]!.hooks.onPermission({ title: "t", command: "c", options: [] });
    expect(r).toBeNull();
    expect(bridge.status().questions).toEqual([]);
  });

  it("fails the task and exits 1 when the prompt is rejected by a live agent, keeping the text at the inbox head", async () => {
    const { bridge, agents, script, exits } = await stubbed();
    bridge.boot();
    await waitState(bridge, "idle");
    script.push(async () => { throw new Error("pipe broke"); });
    expect(bridge.command({ kind: "userPrompt", text: "please keep me" })).toMatchObject({ ok: true });
    await waitState(bridge, "failed");
    expect(bridge.status()).toMatchObject({ state: "failed", reason: expect.stringContaining("pipe broke"), inbox: 1 });
    expect(JSON.parse(readFileSync(join(stubDir, "state.json"), "utf8")).inbox[0].text).toBe("please keep me");
    expect(await exited(exits)).toEqual([1]);
    expect(agents[0]!.killed).toBe(true);
  });

  it("keeps the in-flight text when the agent exits mid-turn", async () => {
    const { bridge, agents, script, exits } = await stubbed();
    let hang: () => void = () => {};
    script.push(() => new Promise<string>((_r, rej) => { hang = () => rej(new Error("closed")); }));
    bridge.boot();
    await waitState(bridge, "running");
    agents[0]!.hooks.onExit("agent exited with code 3");
    hang(); // the rejection that follows the exit is ignored
    await waitState(bridge, "failed");
    await new Promise((r) => setTimeout(r, 30));
    expect(bridge.status()).toMatchObject({ state: "failed", reason: "agent exited with code 3", inbox: 1 });
    expect(await exited(exits)).toEqual([1]);
  });

  it("sends the webhook of a failed and of a stopped task before it exits", async () => {
    for (const how of ["failed", "stopped"] as const) {
      const order: string[] = [];
      const slow = (async () => { await new Promise((r) => setTimeout(r, 60)); order.push("webhook"); return new Response(null, { status: 204 }); }) as unknown as typeof fetch;
      const { bridge, agents, exits } = await stubbed({ fetch: slow });
      bridge.boot();
      await waitState(bridge, "idle");
      await new Promise((r) => setTimeout(r, 120)); // the idle webhook is out
      order.length = 0;
      if (how === "failed") agents[0]!.hooks.onExit("boom");
      else bridge.command({ kind: "stop" });
      await waitState(bridge, how);
      await exited(exits);
      order.push("exit");
      expect(order, how).toEqual(["webhook", "exit"]);
    }
  });

  it("emits an error event, without payload or secret, when the webhook fails", async () => {
    const down = (async () => { throw new Error("down task-token-0123456789"); }) as unknown as typeof fetch;
    const { bridge, store } = await stubbed({ fetch: down });
    bridge.boot();
    await waitState(bridge, "idle");
    await new Promise((r) => setTimeout(r, 200));
    const errs = store.readEvents(0).filter((e) => e.type === "error").map((e) => JSON.stringify(e));
    expect(errs.length).toBe(1);
    expect(errs[0]).toContain("webhook delivery failed");
    expect(errs[0]).not.toContain("task-token");
  });

  it("does not re-arm the idle timer after shutdown", async () => {
    const { bridge, exits } = await stubbed({ idleMs: 100 });
    bridge.boot();
    await waitState(bridge, "idle");
    await bridge.shutdownAgent();
    bridge.command({ kind: "gate", rule: "r", command: "c" });
    await new Promise((r) => setTimeout(r, 300));
    expect(bridge.status().state).toBe("idle");
    expect(exits).toEqual([]);
  });

  it("restarts the idle timer on every input", async () => {
    const { bridge, exits } = await stubbed({ idleMs: 600 });
    bridge.boot();
    await waitState(bridge, "idle");
    for (let i = 0; i < 4; i++) { await tick(150); bridge.command({ kind: "gate", rule: "r", command: "c" }); }
    expect(bridge.status().state).toBe("idle");
    await waitState(bridge, "suspended");
    expect(await exited(exits)).toEqual([0]);
  });

  it("a lazy boot of a suspended task exits 0 after the idle timeout, also after a failed request", async () => {
    const { bridge, store, agents, exits } = await stubbed({ idleMs: 300 });
    const now = new Date().toISOString();
    store.writeRecord({ version: 1, task: "T-1", project: "demo", agent: "claude", model: null, state: "suspended",
      reason: "idle timeout", session: "s1", branch: null, target: null, work: "/work", worktree: null, container: null, created_container: false, auto_clean: false, cleaned: false, created: now, updated: now, seq: 0, allowed_actions: [],
      inbox: [], summary: "", stopped_by_user: false, scheduled: false, run_timeout: null });
    bridge.boot();
    await tick(150);
    expect(bridge.command({ kind: "answer", question: "Q9", text: "x", grant: [] })).toMatchObject({ ok: false, code: "not_found" });
    expect(await exited(exits)).toEqual([0]);
    expect(bridge.status()).toMatchObject({ state: "suspended", reason: "idle timeout" });
    expect(agents).toHaveLength(0);
  });

  it("never sends a token to the webhook or the status", async () => {
    const { bridge, bodies } = await stubbed();
    bridge.boot();
    await waitState(bridge, "idle");
    bridge.command({ kind: "ask", text: "use task-token-0123456789 ?", options: [], recommend: null });
    await tick(20);
    expect(bodies.length).toBeGreaterThan(0);
    expect(bodies.join()).not.toContain("task-token-0123456789");
    expect(JSON.stringify(bridge.status())).not.toContain("task-token-0123456789");
  });
});

describe("worktree and auto-clean", () => {
  it("records the target, work, container and auto-clean; the agent starts in AGENTIC_WORK", async () => {
    const dir = taskDir("hello");
    const { bridge, store, cwds } = await start(dir, { AGENTIC_TARGET: "api", AGENTIC_CONTAINER: "agentic-demo-task-T-1" });
    await waitState(bridge, "idle");
    const rec = store.readRecord();
    expect([rec.target, rec.work, rec.worktree, rec.container, rec.auto_clean, rec.cleaned, rec.branch])
      .toEqual(["api", dir, null, "agentic-demo-task-T-1", false, false, null]);
    expect(cwds).toEqual([dir]);
  });

  it("with AGENTIC_WORKTREE the worktree is made before the agent starts, and the agent works in it", async () => {
    const dir = taskDir("hello");
    const wtDir = mkdtempSync(join(tmpdir(), "wt-"));
    const { bridge, store, cwds, wt } = await start(dir, { AGENTIC_WORKTREE: "1", AGENTIC_BRANCH: "agentic/T-1-hello" },
      () => ({ ok: true, out: `${wtDir}\n`, err: "" }));
    await waitState(bridge, "idle");
    expect(wt[0]).toEqual(["add", dir, "T-1", "agentic/T-1-hello"]);
    expect(cwds).toEqual([wtDir]);
    const rec = store.readRecord();
    expect([rec.work, rec.worktree, rec.branch]).toEqual([wtDir, wtDir, "agentic/T-1-hello"]);
  });

  it("AGENTIC_WORKTREE=1 without AGENTIC_BRANCH refuses the boot and makes no worktree", async () => {
    const dir = taskDir("hello");
    const calls: string[][] = [];
    await expect(start(dir, { AGENTIC_WORKTREE: "1" }, (args) => { calls.push(args); return { ok: true, out: "/x", err: "" }; }))
      .rejects.toThrow("AGENTIC_WORKTREE=1 needs AGENTIC_BRANCH");
    expect(calls).toEqual([]);
  });

  it("records whether the task created its container", async () => {
    const a = await start(taskDir("hello"), { AGENTIC_CREATED_CONTAINER: "1" });
    expect(a.store.readRecord().created_container).toBe(true);
    const b = await start(taskDir("hello"));
    expect(b.store.readRecord().created_container).toBe(false);
  });

  it("a worktree that cannot be made refuses the boot with the script's reason", async () => {
    const dir = taskDir("hello");
    await expect(start(dir, { AGENTIC_WORKTREE: "1", AGENTIC_BRANCH: "b" },
      () => ({ ok: false, out: "", err: "agentic-worktree: /work has no commit to start a worktree from\n" })))
      .rejects.toThrow("could not create the worktree: agentic-worktree: /work has no commit to start a worktree from");
  });

  it("auto-clean after a normal turn removes the worktree, stops the task and releases the container it created", async () => {
    const dir = taskDir("hello");
    const wtDir = mkdtempSync(join(tmpdir(), "wt-"));
    const { store, wt, exits, released } = await start(dir,
      { AGENTIC_WORKTREE: "1", AGENTIC_BRANCH: "agentic/T-1-hello", AGENTIC_AUTO_CLEAN: "1", AGENTIC_CREATED_CONTAINER: "1" },
      (args) => ({ ok: true, out: args[0] === "add" ? `${wtDir}\n` : "", err: "" }));
    expect(await exited(exits)).toEqual([0]);
    expect(wt.map((a) => a[0])).toEqual(["add", "remove"]);
    expect(wt[1]).toEqual(["remove", dir, "T-1", "agentic/T-1-hello"]);
    const rec = store.readRecord();
    expect([rec.state, rec.cleaned, rec.reason, rec.stopped_by_user]).toEqual(["stopped", true, "auto-cleaned", false]);
    const states = store.readEvents(0).filter((e) => e.type === "state" && e.data.state === "stopped");
    expect(states.map((e) => e.data.reason)).toEqual(["auto-cleaned"]);
    expect(released()).toBe(1);
  });

  it("auto-clean in a reused container stops the task but does not end the container", async () => {
    const dir = taskDir("hello");
    const { store, exits, released } = await start(dir, { AGENTIC_AUTO_CLEAN: "1" });
    expect(await exited(exits)).toEqual([0]);
    expect(store.readRecord().cleaned).toBe(true);
    expect(released()).toBe(0);
  });

  it("a worktree that cannot be removed keeps the task idle and reports why", async () => {
    const dir = taskDir("hello");
    const wtDir = mkdtempSync(join(tmpdir(), "wt-"));
    const { bridge, store, released } = await start(dir,
      { AGENTIC_WORKTREE: "1", AGENTIC_BRANCH: "b", AGENTIC_AUTO_CLEAN: "1", AGENTIC_CREATED_CONTAINER: "1" },
      (args) => args[0] === "add" ? { ok: true, out: wtDir, err: "" } : { ok: false, out: "", err: "agentic-worktree: x has uncommitted changes" });
    await waitState(bridge, "idle");
    await new Promise((r) => setTimeout(r, 50));
    expect(store.readRecord().cleaned).toBe(false);
    expect(store.readEvents(0).some((e) => e.type === "error" && String(e.data.message).includes("auto-clean kept the task"))).toBe(true);
    expect(released()).toBe(0);
  });
});

describe("scheduled runs", () => {
  it("records scheduled and run_timeout, and appends the scheduled note to the first prompt", async () => {
    const dir = taskDir("hello");
    const { bridge, store } = await start(dir, { AGENTIC_SCHEDULED: "1", AGENTIC_RUN_TIMEOUT: "120" });
    await waitState(bridge, "stopped");
    const rec = store.readRecord();
    expect([rec.scheduled, rec.run_timeout]).toEqual([true, 120]);
    const first = store.readEvents(0).find((e) => e.type === "message" && e.data.role === "user");
    expect(String(first?.data.text)).toBe(`hello${SCHEDULED_NOTE}`);
  });

  it("an unscheduled task records scheduled false and no run timeout", async () => {
    const dir = taskDir("hello");
    const { bridge, store } = await start(dir);
    await waitState(bridge, "idle");
    expect([store.readRecord().scheduled, store.readRecord().run_timeout]).toEqual([false, null]);
  });

  it("after the work turn asks for the summary, writes result.md from it and stops", async () => {
    const dir = taskDir("hello");
    const { store, exits } = await start(dir, { AGENTIC_SCHEDULED: "1" });
    expect(await exited(exits)).toEqual([0]);
    const rec = store.readRecord();
    expect([rec.state, rec.reason, rec.stopped_by_user]).toEqual(["stopped", "scheduled-done", false]);
    expect(readFileSync(join(dir, "result.md"), "utf8")).toBe(`echo: ${SUMMARY_PROMPT}\n`);
    const prompts = store.readEvents(0).filter((e) => e.type === "message" && e.data.role === "user").map((e) => e.data.text);
    expect(prompts).toEqual([`hello${SCHEDULED_NOTE}`, SUMMARY_PROMPT]);
  });

  it("asks for the summary even with an open question, then auto-cleans despite it", async () => {
    const dir = taskDir("ASK:Which DB?");
    const wtDir = mkdtempSync(join(tmpdir(), "wt-"));
    const { store, exits, wt } = await start(dir,
      { AGENTIC_SCHEDULED: "1", AGENTIC_WORKTREE: "1", AGENTIC_BRANCH: "b", AGENTIC_AUTO_CLEAN: "1", AGENTIC_CREATED_CONTAINER: "1" },
      (args) => ({ ok: true, out: args[0] === "add" ? `${wtDir}\n` : "", err: "" }));
    expect(await exited(exits)).toEqual([0]);
    const rec = store.readRecord();
    expect([rec.state, rec.reason, rec.cleaned]).toEqual(["stopped", "scheduled-done", true]);
    expect(wt.map((a) => a[0])).toEqual(["add", "remove"]);
    expect(store.readQuestions().filter((q) => q.status === "open").map((q) => q.text)).toEqual(["Which DB?"]);
  });

  it("a worktree that cannot be removed still stops the run and keeps it", async () => {
    const dir = taskDir("hello");
    const wtDir = mkdtempSync(join(tmpdir(), "wt-"));
    const { store, exits, released } = await start(dir,
      { AGENTIC_SCHEDULED: "1", AGENTIC_WORKTREE: "1", AGENTIC_BRANCH: "b", AGENTIC_AUTO_CLEAN: "1", AGENTIC_CREATED_CONTAINER: "1" },
      (args) => args[0] === "add" ? { ok: true, out: wtDir, err: "" } : { ok: false, out: "", err: "agentic-worktree: has commits on no remote branch" });
    expect(await exited(exits)).toEqual([0]);
    expect([store.readRecord().state, store.readRecord().cleaned]).toEqual(["stopped", false]);
    expect(released()).toBe(0);
  });

  it("does not arm the idle timer while the run works or summarises", async () => {
    const dir = taskDir("hello");
    const { store, exits } = await start(dir, { AGENTIC_SCHEDULED: "1", AGENTIC_IDLE_TIMEOUT: "0.05" });
    expect(await exited(exits)).toEqual([0]);
    expect(store.readEvents(0).some((e) => e.type === "state" && e.data.state === "suspended")).toBe(false);
  });

  it("a crashed agent fails the run without a summary", async () => {
    const dir = taskDir("CRASH");
    const { store, exits } = await start(dir, { AGENTIC_SCHEDULED: "1" });
    expect(await exited(exits)).toEqual([1]);
    expect(store.readRecord().state).toBe("failed");
    expect(existsSync(join(dir, "result.md"))).toBe(false);
  });

  it("an existing scheduled record booted again behaves as a normal task", async () => {
    const dir = taskDir("hello");
    const first = await start(dir, { AGENTIC_SCHEDULED: "1" });
    expect(await exited(first.exits)).toEqual([0]);
    await first.bridge.shutdownAgent();
    const again = await start(dir, { AGENTIC_SCHEDULED: "1" });
    expect(await exited(again.exits)).toEqual([0]); // stopped is final: boot exits at once
    expect(again.store.readRecord().reason).toBe("scheduled-done");
  });
});
