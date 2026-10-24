import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AgentProcess, type AgentHooks, type AgentLike } from "../src/agent.js";
import { Apps, type RunResult } from "../src/apps.js";
import { Bridge } from "../src/bridge.js";
import { agentEnvironment, loadConfig, type Config } from "../src/config.js";
import { harnessFor } from "../src/harness.js";
import { Notifier } from "../src/notify.js";
import { makeRedactor } from "../src/redact.js";
import { startServer } from "../src/server.js";
import { NO_SUMMARY, SCHEDULED_NOTE, SUMMARY_PROMPT, TIMEOUT_NOTE } from "../src/scheduled.js";
import { newSession } from "../src/sessions.js";
import { Store } from "../src/store.js";
import type { State, TaskEvent } from "../src/types.js";

const FAKE = fileURLToPath(new URL("./fake-agent.mjs", import.meta.url));
const running: Array<{ bridge: Bridge; close(): Promise<void> }> = [];
afterEach(async () => { for (const r of running.splice(0)) { await r.bridge.shutdownAgent(); await r.close(); } });

async function start(dir: string, extra: Record<string, string> = {},
  worktree: (args: string[]) => { ok: boolean; out: string; err: string } = () => ({ ok: true, out: "", err: "" }),
  over: Partial<Config> = {}, bodies?: unknown[]) {
  const exits: number[] = [];
  const cwds: string[] = [];
  const wt: string[][] = [];
  let released = 0;
  const env = { AGENTIC_TASK_TOKEN: "task-token-0123456789", AGENTIC_AGENT_TOKEN: "agent-token-0123456789",
    AGENTIC_TASK_DIR: dir, AGENTIC_TASK_ID: "T-1", AGENTIC_PROJECT: "demo", AGENTIC_ACP_CMD: JSON.stringify(["node", FAKE]),
    AGENTIC_WORK: dir, AGENTIC_EVENTS_DIR: join(dir, "no-events"), ...extra };
  const cfg: Config = { ...loadConfig(env), port: 0, ...over };
  const store = new Store(dir, makeRedactor([cfg.tokens.task, cfg.tokens.agent]));
  let agentEnv: NodeJS.ProcessEnv = {};
  const bridge = new Bridge({
    store, config: cfg, paragraph: "Use agentic-ask.",
    notifier: new Notifier(bodies
      ? { eventsLog: null, webhook: "http://hook.example.com/x", project: "demo", log: () => {},
        fetch: (async (_u: unknown, init?: RequestInit) => { bodies.push(JSON.parse(String(init?.body))); return new Response(null, { status: 204 }); }) as typeof fetch }
      : { eventsLog: null, webhook: null, project: "demo", log: () => {} }),
    agentFactory: (hooks, cwd) => { cwds.push(cwd); return new AgentProcess(harnessFor("claude", { model: null, acpCmd: cfg.acpCmd }),
      { cwd, env: { ...agentEnv, FAKE_AGENT_STATE: join(dir, "fake") }, paragraph: "Use agentic-ask." }, hooks); },
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
    expect(store.readEvents(0).filter((e) => e.type === "state" && e.name === null).map((e) => e.data.state)).toEqual(["starting", "running", "idle"]);
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
    rec.sessions[0].session = "gone";
    writeFileSync(join(dir, "state.json"), JSON.stringify(rec));
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
  async start() { return { fork: true }; }
  async newSession() { return "s1"; }
  async loadSession() {}
  async forkSession() { return "s2"; }
  prompt(_session: string, text: string) { this.prompts.push(text); return (this.script.shift() ?? (async () => "end_turn"))(text); }
  cancel() { this.cancels++; }
  async kill() { this.killed = true; }
}

let stubDir = "";
async function stubbed(opts: { idleMs?: number; fetch?: typeof fetch; dir?: string; apps?: Apps; autostart?: () => string[]; appNames?: () => string[] } = {}) {
  const dir = opts.dir ?? taskDir();
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
    ...(opts.apps ? { apps: opts.apps } : {}), ...(opts.autostart ? { autostart: opts.autostart } : {}),
    ...(opts.appNames ? { appNames: opts.appNames } : {}),
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
    const ask = { sessionId: "s1", title: "t", command: "git push", options: [{ optionId: "a", name: "Yes", kind: "allow_once" }] };
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
    const r = await agents[0]!.hooks.onPermission({ sessionId: "s1", title: "t", command: "c", options: [] });
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
    expect(JSON.parse(readFileSync(join(stubDir, "state.json"), "utf8")).sessions[0].inbox[0].text).toBe("please keep me");
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
      sessions: [newSession("main", null, now, { session: "s1" })], capabilities: null, summary: "", stopped_by_user: false, scheduled: false, run_timeout: null });
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
  it("at the timeout cancels the turn and asks for the summary with the note", async () => {
    const dir = taskDir("SLEEP:10000");
    const { store, exits } = await start(dir, { AGENTIC_SCHEDULED: "1" }, undefined, { runTimeoutMs: 150 });
    expect(await exited(exits)).toEqual([0]);
    expect([store.readRecord().state, store.readRecord().reason]).toEqual(["stopped", "timeout"]);
    expect(readFileSync(join(dir, "result.md"), "utf8")).toBe(`echo: ${TIMEOUT_NOTE}\n\n${SUMMARY_PROMPT}\n`);
  });

  it("a summary that overruns the grace ends the run without one", async () => {
    vi.stubEnv("FAKE_SUMMARY_SLEEP", "5000");
    try {
      const dir = taskDir("SLEEP:10000");
      const { store, exits } = await start(dir, { AGENTIC_SCHEDULED: "1" }, undefined, { runTimeoutMs: 100, summaryGraceMs: 200 });
      expect(await exited(exits)).toEqual([0]);
      expect([store.readRecord().state, store.readRecord().reason]).toEqual(["stopped", "timeout"]);
      expect(readFileSync(join(dir, "result.md"), "utf8").startsWith(NO_SUMMARY)).toBe(true);
    } finally {
      vi.unstubAllEnvs();
    }
  });

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

  it("a scheduled run waiting on a permission never suspends", async () => {
    const dir = taskDir("PERMISSION:git push");
    const { bridge, store } = await start(dir, { AGENTIC_SCHEDULED: "1", AGENTIC_IDLE_TIMEOUT: "0.05" });
    await waitState(bridge, "waiting");
    await new Promise((r) => setTimeout(r, 200));
    expect(store.readRecord().state).toBe("waiting");
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

  it("a result.md that cannot be written still stops the run, with an error event", async () => {
    const spy = vi.spyOn(Store.prototype, "writeResult").mockImplementation(() => { throw new Error("ENOSPC: no space left on device"); });
    try {
      const dir = taskDir("hello");
      const { store, exits } = await start(dir, { AGENTIC_SCHEDULED: "1" });
      expect(await exited(exits)).toEqual([0]);
      expect([store.readRecord().state, store.readRecord().reason]).toEqual(["stopped", "scheduled-done"]);
      expect(store.readEvents(0).some((e) => e.type === "error" && String(e.data.message).includes("ENOSPC"))).toBe(true);
    } finally {
      spy.mockRestore();
    }
  });

  it("the stopped webhook of a scheduled run carries the result", async () => {
    const bodies: Array<Record<string, unknown>> = [];
    const dir = taskDir("hello");
    const { exits } = await start(dir, { AGENTIC_SCHEDULED: "1" }, undefined, {}, bodies);
    expect(await exited(exits)).toEqual([0]);
    const stopped = bodies.find((b) => b.state === "stopped");
    expect(stopped?.result).toBe(`echo: ${SUMMARY_PROMPT}`);
    expect(bodies.filter((b) => b.state === "idle").every((b) => !("result" in b))).toBe(true);
  });
});

const named = (store: Store, name: string) => store.readEvents(0)
  .filter((e) => e.type === "message" && e.data.role === "agent" && e.data.final && e.name === name).map((e) => e.data.text);
async function until(cond: () => boolean, what = "condition"): Promise<void> {
  for (let i = 0; i < 500; i++) { if (cond()) return; await tick(20); }
  throw new Error(`timeout waiting for ${what}`);
}
const view = (bridge: Bridge, name: string) => bridge.sessions().find((s) => s.name === name);
const add = (bridge: Bridge, name: string, text: string | null, over: { model?: string; fork?: string } = {}) =>
  bridge.command({ kind: "addSession", name, model: over.model ?? null, fork: over.fork ?? null, text });
const agentFinal = (e: TaskEvent, name: string) => e.type === "message" && e.data.role === "agent" && !!e.data.final && e.name === name;

describe("sessions", () => {
  it("two sessions run in parallel and both reach idle", async () => {
    const { bridge, store } = await start(taskDir("SLEEP:300"));
    expect(add(bridge, "b", "SLEEP:300")).toMatchObject({ ok: true });
    await until(() => named(store, "main").length === 1 && named(store, "b").length === 1, "both turns");
    await waitState(bridge, "idle");
    const evs = store.readEvents(0);
    expect(named(store, "main")).toEqual(["slept"]);
    expect(named(store, "b")).toEqual(["slept"]);
    // b's tool started before main's turn ended: the turns overlapped
    const bTool = evs.find((e) => e.type === "tool" && e.name === "b");
    const mainEnd = evs.find((e) => agentFinal(e, "main"));
    expect(bTool && mainEnd && bTool.seq < mainEnd.seq).toBe(true);
    expect(bTool?.session).toBe(view(bridge, "b")?.session);
    expect(evs.filter((e) => e.type === "state" && e.name === null).map((e) => e.data.state)).toEqual(["starting", "running", "idle"]);
    expect(bridge.status()).toMatchObject({ state: "idle", inbox: 0, sessions: [{ name: "main", state: "idle" }, { name: "b", state: "idle" }] });
    const onlyB = bridge.events(0, 1000, (e) => e.name === "b");
    expect(onlyB.length).toBeGreaterThan(0);
    expect(onlyB.every((e) => e.name === "b")).toBe(true);
  });

  it("a second session uses its own model", async () => {
    const { bridge, store } = await start(taskDir("MODEL"));
    await waitState(bridge, "idle");
    add(bridge, "b", "MODEL", { model: "m2" });
    await until(() => named(store, "b").length === 1, "b's turn");
    expect(named(store, "b")).toEqual(["model: m2"]);
    expect(named(store, "main")).toEqual(["model: none"]);
    expect(view(bridge, "b")?.model).toBe("m2");
  });

  it("fork copies main's conversation", async () => {
    const { bridge, store } = await start(taskDir("hello"));
    await waitState(bridge, "idle");
    expect(add(bridge, "b", "HISTORY", { fork: "main" })).toMatchObject({ ok: true });
    await until(() => named(store, "b").length === 1, "the fork's turn");
    expect(named(store, "b")).toEqual(["history: 2"]);
    expect(view(bridge, "b")?.fork_of).toBe("main");
    expect(view(bridge, "b")?.session).not.toBe(view(bridge, "main")?.session);
  });

  it("fork on an agent without fork is refused with the exact text", async () => {
    vi.stubEnv("FAKE_NO_FORK", "1");
    try {
      const { bridge } = await start(taskDir("hello"));
      await waitState(bridge, "idle");
      expect(add(bridge, "b", null, { fork: "main" })).toEqual({ ok: false, code: "conflict", message: "claude does not support forking a session" });
      expect(bridge.sessions().map((s) => s.name)).toEqual(["main"]);
    } finally {
      vi.unstubAllEnvs();
    }
  });

  it("an ask through agentic-ask's session id reaches the asking session", async () => {
    const { bridge, store } = await start(taskDir("hello"));
    await waitState(bridge, "idle");
    add(bridge, "b", null);
    await until(() => !!view(bridge, "b")?.session && view(bridge, "b")?.state === "idle", "b open");
    const sessionId = view(bridge, "b")?.session ?? "";
    expect(bridge.command({ kind: "ask", text: "Which DB?", options: [], recommend: null, sessionId })).toMatchObject({ ok: true, value: { id: "Q1" } });
    expect(bridge.status().questions).toMatchObject([{ id: "Q1", session: "b" }]);
    expect(view(bridge, "b")?.state).toBe("waiting");
    bridge.command({ kind: "answer", text: "pg", grant: [] });
    await until(() => named(store, "b").length === 1, "b's answer turn");
    expect(named(store, "b")).toEqual(["echo: Answer to Q1: pg"]);
    expect(named(store, "main")).toEqual(["echo: hello"]);
  });

  it("the webhook fires on a question while another session runs", async () => {
    const bodies: Array<Record<string, unknown>> = [];
    const { bridge } = await start(taskDir("SLEEP:20000"), {}, undefined, {}, bodies);
    add(bridge, "b", "PERMISSION:git push");
    await until(() => bodies.some((b) => b.question), "the question's webhook");
    expect(bodies.filter((b) => b.question)).toMatchObject([{ state: "running", question: { id: "Q1" } }]);
    expect(bridge.status()).toMatchObject({ state: "running", questions: [{ id: "Q1", session: "b", source: "permission" }] });
    bridge.command({ kind: "cancel", session: "b" });
    bridge.command({ kind: "cancel" });
    await waitState(bridge, "idle");
    await tick(50);
    expect(bodies.filter((b) => b.question)).toHaveLength(1);
  });

  it("suspend and resume reload only the prompted session", async () => {
    const dir = taskDir("hello");
    const a = await start(dir, { AGENTIC_IDLE_TIMEOUT: "0.3" });
    add(a.bridge, "b", "hello b");
    await waitState(a.bridge, "suspended");
    const ids = Object.fromEntries(a.store.readRecord().sessions.map((s) => [s.name, s.session]));
    expect(ids.main && ids.b).toBeTruthy();
    const loads = vi.spyOn(AgentProcess.prototype, "loadSession");
    try {
      const b = await start(dir);
      b.bridge.command({ kind: "userPrompt", text: "HISTORY" });
      await until(() => named(b.store, "main").length === 2, "main's turn");
      await waitState(b.bridge, "idle");
      expect(loads.mock.calls.map((c) => c[0])).toEqual([ids.main]);
      expect(named(b.store, "main").at(-1)).toBe("history: 2");
      expect(view(b.bridge, "b")).toMatchObject({ state: "idle", session: ids.b });
    } finally {
      loads.mockRestore();
    }
  });

  it("a lost non-main session fails alone; main's loss still falls back with the seed", async () => {
    const dir = taskDir("hello");
    const a = await start(dir, { AGENTIC_IDLE_TIMEOUT: "0.3" });
    add(a.bridge, "b", "hello b");
    await waitState(a.bridge, "suspended");
    const rec = JSON.parse(readFileSync(join(dir, "state.json"), "utf8"));
    rec.sessions[0].session = "gone";
    rec.sessions[1].session = "gone-b";
    writeFileSync(join(dir, "state.json"), JSON.stringify(rec));
    const b = await start(dir);
    b.bridge.command({ kind: "userPrompt", text: "x", session: "b" });
    await until(() => view(b.bridge, "b")?.state === "failed", "b failed");
    expect(view(b.bridge, "b")?.reason).toMatch(/^its conversation could not be restored: /);
    expect(b.bridge.command({ kind: "userPrompt", text: "y", session: "b" })).toMatchObject({ ok: false, code: "conflict" });
    expect(view(b.bridge, "main")?.state).toBe("idle");
    b.bridge.command({ kind: "userPrompt", text: "go on" });
    await until(() => named(b.store, "main").length === 2, "main's turn");
    expect(String(named(b.store, "main").at(-1))).toMatch(/^echo: Original task:\nhello/);
    expect(b.store.readEvents(0).some((e) => e.type === "error" && e.name === "main" && String(e.data.message).includes("could not be loaded"))).toBe(true);
    expect(named(b.store, "b")).toEqual(["echo: hello b"]);
  });

  it("main's fallback failing fails the task", async () => {
    const dir = taskDir("hello");
    const a = await start(dir, { AGENTIC_IDLE_TIMEOUT: "0.3" });
    await waitState(a.bridge, "suspended");
    const rec = JSON.parse(readFileSync(join(dir, "state.json"), "utf8"));
    rec.sessions[0].session = "gone";
    writeFileSync(join(dir, "state.json"), JSON.stringify(rec));
    vi.stubEnv("FAKE_NO_NEW", "1");
    try {
      const b = await start(dir);
      b.bridge.command({ kind: "userPrompt", text: "go on" });
      await waitState(b.bridge, "failed");
      expect(b.bridge.status().reason).toMatch(/^agent failed to start: .*session\/new refused/);
      expect(await exited(b.exits)).toEqual([1]);
      expect(b.store.readEvents(0).some((e) => e.type === "error" && String(e.data.message).includes("started a new session"))).toBe(false);
    } finally {
      vi.unstubAllEnvs();
    }
  });

  it("a fresh task whose main session cannot open fails and exits 1", async () => {
    vi.stubEnv("FAKE_NO_NEW", "1");
    try {
      const { bridge, exits } = await start(taskDir("hello"));
      await waitState(bridge, "failed");
      expect(bridge.status().reason).toMatch(/^agent failed to start: .*session\/new refused/);
      expect(await exited(exits)).toEqual([1]);
    } finally {
      vi.unstubAllEnvs();
    }
  });

  it("logs each task state once to the events log", async () => {
    const logs = vi.spyOn(Notifier.prototype, "logState");
    try {
      const { bridge } = await start(taskDir("hello"));
      await waitState(bridge, "idle");
      expect(logs.mock.calls.map((c) => c[0].state)).toEqual(["starting", "running", "idle"]);
    } finally {
      logs.mockRestore();
    }
  });

  it("a fork that cannot open says so, not that a conversation could not be restored", async () => {
    const dir = taskDir("hello");
    const { bridge } = await start(dir);
    await waitState(bridge, "idle");
    rmSync(join(dir, "fake", `${view(bridge, "main")?.session}.json`));
    add(bridge, "b", null, { fork: "main" });
    await until(() => view(bridge, "b")?.state === "failed", "b failed");
    expect(view(bridge, "b")?.reason).toMatch(/^could not open the session: .*not found/);
  });

  it("an old record without sessions boots and resumes", async () => {
    const dir = taskDir("hello");
    cpSync(fileURLToPath(new URL("./fixtures/old-task", import.meta.url)), dir, { recursive: true });
    const old = JSON.parse(readFileSync(join(dir, "state.json"), "utf8"));
    writeFileSync(join(dir, "state.json"), JSON.stringify({ ...old, work: dir })); // the agent starts in work
    mkdirSync(join(dir, "fake"));
    writeFileSync(join(dir, "fake", "old-1.json"), JSON.stringify({ history: [{ role: "user", text: "hi" }, { role: "agent", text: "echo: hi" }], meta: null, mode: "default", lastRefused: null }));
    const { bridge, store } = await start(dir);
    expect(bridge.status()).toMatchObject({ state: "suspended", inbox: 0, summary: "did it",
      sessions: [{ name: "main", session: "old-1", state: "idle", inbox: 0, summary: "did it" }] });
    bridge.command({ kind: "userPrompt", text: "HISTORY" });
    await until(() => named(store, "main").length === 1, "main's turn");
    expect(named(store, "main")).toEqual(["history: 2"]);
    expect(store.readQuestions()[0]?.session).toBe("main");
    expect(store.readRecord().sessions[0]?.session).toBe("old-1");
  });

  it("auto-clean waits until every session is idle", async () => {
    const { bridge, store, exits } = await start(taskDir("SLEEP:100"), { AGENTIC_AUTO_CLEAN: "1" });
    add(bridge, "b", "SLEEP:600");
    expect(await exited(exits)).toEqual([0]);
    const evs = store.readEvents(0);
    const bEnd = evs.find((e) => agentFinal(e, "b"));
    const stopped = evs.find((e) => e.type === "state" && e.name === null && e.data.state === "stopped");
    expect(bEnd && stopped && bEnd.seq < stopped.seq).toBe(true);
    expect(store.readRecord().cleaned).toBe(true);
  });

  it("a stopped task shows no live session state", async () => {
    const { bridge } = await start(taskDir("SLEEP:20000"));
    await waitState(bridge, "running");
    bridge.command({ kind: "stop" });
    expect(bridge.sessions()[0]?.state).toBe("stopped");
    expect(bridge.status().sessions).toMatchObject([{ name: "main", state: "stopped" }]);
  });
});

describe("apps in the bridge", () => {
  const web = { name: "web", state: "stopped", ports: [3000], url: "/", since: null, exit_code: null };
  function fakeApps(reply: (args: string[]) => RunResult = () => ({ code: 0, out: "", err: "", timedOut: false })) {
    const calls: Array<{ args: string[]; work: string }> = [];
    const apps = new Apps(async (args, _t, work) => {
      calls.push({ args, work });
      return args[0] === "list" ? { code: 0, out: JSON.stringify([web, { ...web, name: "api" }]), err: "", timedOut: false } : reply(args);
    });
    return { apps, calls };
  }
  const starts = (calls: Array<{ args: string[] }>) => calls.filter((c) => c.args[0] === "start").map((c) => c.args[1]);

  it("autostart starts each named app once per task, in the checkout, and not again on a resume", async () => {
    const { apps, calls } = fakeApps();
    const first = await stubbed({ apps, autostart: () => ["web", "api"] });
    first.bridge.boot();
    await waitState(first.bridge, "idle");
    for (let i = 0; i < 50 && starts(calls).length < 2; i++) await tick(10);
    expect(starts(calls)).toEqual(["web", "api"]);
    expect(calls.every((c) => c.work === first.bridge.status().work)).toBe(true);
    await first.bridge.shutdownAgent();
    const again = await stubbed({ dir: stubDir, apps, autostart: () => ["web", "api"] });
    again.bridge.boot();
    await tick(50);
    expect(starts(calls)).toEqual(["web", "api"]);
  });

  it("a failed autostart is an error event, redacted", async () => {
    const { apps } = fakeApps(() => ({ code: 1, out: "", err: "agentic-app: prepare of web failed: task-token-0123456789\n", timedOut: false }));
    const { bridge, store } = await stubbed({ apps, autostart: () => ["web"] });
    bridge.boot();
    let errs: string[] = [];
    for (let i = 0; i < 50 && errs.length === 0; i++) { await tick(10); errs = store.readEvents(0).filter((e) => e.type === "error").map((e) => JSON.stringify(e.data)); }
    expect(errs[0]).toContain("autostart of app web");
    expect(errs[0]).not.toContain("task-token-0123456789");
  });

  it("lists, acts and reads logs through agentic-app; a stopped task refuses actions with 409 before spawning", async () => {
    const { apps, calls } = fakeApps((args) => ({ code: 0, out: args[0] === "logs" ? "x task-token-0123456789\n" : "", err: "", timedOut: false }));
    const { bridge } = await stubbed({ apps });
    bridge.boot();
    await waitState(bridge, "idle");
    expect(await bridge.apps()).toMatchObject({ ok: true, value: [{ name: "web" }, { name: "api" }] });
    expect(await bridge.appAction("web", "start")).toMatchObject({ ok: true, value: { name: "web" } });
    const logs = await bridge.appLogs("web", 10);
    expect(JSON.stringify(logs)).not.toContain("task-token-0123456789");
    bridge.command({ kind: "stop" });
    await waitState(bridge, "stopped");
    const before = calls.length;
    expect(await bridge.appAction("web", "start")).toMatchObject({ ok: false, status: 409 });
    expect(calls.length).toBe(before);
  });

  it("with no apps configured: an empty list and 404 for a name", async () => {
    const { bridge } = await stubbed();
    bridge.boot();
    await waitState(bridge, "idle");
    expect(await bridge.apps()).toEqual({ ok: true, value: [] });
    expect(await bridge.appAction("web", "start")).toMatchObject({ ok: false, status: 404 });
  });

  it("an app report of a configured app becomes an app event of the task; another name is refused", async () => {
    const { bridge, store } = await stubbed({ appNames: () => ["web"] });
    bridge.boot();
    await waitState(bridge, "idle");
    expect(bridge.command({ kind: "app", name: "web", action: "started", exitCode: null })).toMatchObject({ ok: true });
    expect(bridge.command({ kind: "app", name: "api", action: "started", exitCode: null })).toMatchObject({ ok: false, code: "bad_request" });
    expect(store.readEvents(0).filter((e) => e.type === "app")).toMatchObject([{ name: null, data: { name: "web", action: "started", exit_code: null } }]);
    const none = await stubbed();
    none.bridge.boot();
    await waitState(none.bridge, "idle");
    expect(none.bridge.command({ kind: "app", name: "web", action: "started", exitCode: null })).toMatchObject({ ok: false, code: "bad_request" });
  });

  // listed: Apps whose list answers with web in STATE (or fails when STATE is null)
  function listed(state: { web: string | null }) {
    const calls: string[][] = [];
    const apps = new Apps(async (args) => {
      calls.push(args);
      if (args[0] !== "list") return { code: 0, out: "", err: "", timedOut: false };
      if (state.web === null) return { code: 1, out: "", err: "agentic-app: broken\n", timedOut: false };
      return { code: 0, out: JSON.stringify([{ ...web, state: state.web }]), err: "", timedOut: false };
    });
    return { apps, calls };
  }

  for (const st of ["running", "preparing"]) {
    it(`the idle timeout does not suspend the task while an app is ${st}; it suspends once none is`, async () => {
      const state = { web: st as string | null };
      const { apps } = listed(state);
      const { bridge, exits } = await stubbed({ idleMs: 150, apps });
      bridge.boot();
      await waitState(bridge, "idle");
      await tick(450);
      expect(bridge.status().state).toBe("idle");
      expect(exits).toEqual([]);
      state.web = "stopped";
      await waitState(bridge, "suspended");
      expect(await exited(exits)).toEqual([0]);
    });
  }

  it("the idle timeout suspends as before when no app runs or the list fails", async () => {
    for (const st of ["stopped", "exited", "failed", null]) {
      const { apps } = listed({ web: st });
      const { bridge, exits } = await stubbed({ idleMs: 150, apps });
      bridge.boot();
      await waitState(bridge, "idle");
      await waitState(bridge, "suspended");
      expect(await exited(exits), String(st)).toEqual([0]);
    }
  });

  it("an app action restarts the idle timer", async () => {
    const { apps } = listed({ web: "stopped" });
    const { bridge, exits } = await stubbed({ idleMs: 400, apps });
    bridge.boot();
    await waitState(bridge, "idle");
    await tick(250);
    expect(await bridge.appAction("web", "stop")).toMatchObject({ ok: true });
    await tick(250);
    expect(bridge.status().state).toBe("idle");
    await waitState(bridge, "suspended");
    expect(await exited(exits)).toEqual([0]);
  });

  it("an app report does not restart the idle timer", async () => {
    const { bridge, exits } = await stubbed({ idleMs: 300, appNames: () => ["web"] });
    bridge.boot();
    await waitState(bridge, "idle");
    await tick(180);
    bridge.command({ kind: "app", name: "web", action: "exited", exitCode: 1 });
    await tick(200);
    expect(bridge.status().state).toBe("suspended");
    expect(exits).toEqual([0]);
  });
});
