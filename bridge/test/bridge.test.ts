import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
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
import { Store } from "../src/store.js";
import type { State, TaskEvent } from "../src/types.js";

const FAKE = fileURLToPath(new URL("./fake-agent.mjs", import.meta.url));
const running: Array<{ bridge: Bridge; close(): Promise<void> }> = [];
afterEach(async () => { for (const r of running.splice(0)) { await r.bridge.shutdownAgent(); await r.close(); } });

async function start(dir: string, extra: Record<string, string> = {}) {
  const exits: number[] = [];
  const env = { AGENTIC_TASK_TOKEN: "task-token-0123456789", AGENTIC_AGENT_TOKEN: "agent-token-0123456789",
    AGENTIC_TASK_DIR: dir, AGENTIC_TASK_ID: "T-1", AGENTIC_PROJECT: "demo", AGENTIC_ACP_CMD: JSON.stringify(["node", FAKE]),
    AGENTIC_BRIDGE_PORT: "0", AGENTIC_WORK: dir, AGENTIC_EVENTS_DIR: join(dir, "no-events"), ...extra };
  const cfg: Config = loadConfig(env);
  const store = new Store(dir, makeRedactor([cfg.tokens.task, cfg.tokens.agent]));
  let agentEnv: NodeJS.ProcessEnv = {};
  const bridge = new Bridge({
    store, config: cfg, paragraph: "Use agentic-ask.",
    notifier: new Notifier({ eventsLog: null, webhook: null, project: "demo", log: () => {} }),
    agentFactory: (hooks) => new AgentProcess(harnessFor("claude", { model: null, acpCmd: cfg.acpCmd }),
      { cwd: dir, env: { ...agentEnv, FAKE_AGENT_STATE: join(dir, "fake") }, paragraph: "Use agentic-ask.", model: null }, hooks),
    exit: (code) => exits.push(code), now: () => new Date().toISOString(), log: () => {},
  });
  const server = await startServer({ port: 0, host: "127.0.0.1", tokens: cfg.tokens, access: { hosts: [], origins: [] },
    target: bridge, subscribe: (fn) => bridge.subscribe(fn) });
  agentEnv = agentEnvironment({ ...process.env }, { ...cfg, port: server.port });
  running.push({ bridge, close: server.close });
  bridge.boot();
  return { bridge, exits, store, port: server.port };
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
    expect(a.exits).toEqual([0]);
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
    expect(exits).toEqual([0]);
  });

  it("fails and exits 1 when the agent crashes", async () => {
    const { bridge, exits } = await start(taskDir("CRASH"));
    await waitState(bridge, "failed");
    expect(exits).toEqual([1]);
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

async function stubbed(opts: { idleMs?: number; fetch?: typeof fetch } = {}) {
  const dir = taskDir();
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
    notifier: new Notifier({ eventsLog: null, webhook: cfg.webhook, project: "demo", log: () => {}, fetch: fetchStub }),
    agentFactory: (hooks) => { const a = new StubAgent(hooks, script); agents.push(a); return a; },
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

  it("keeps the user's text when sending the prompt fails, and does not also fail the task", async () => {
    const { bridge, store, agents, script } = await stubbed();
    bridge.boot();
    await waitState(bridge, "idle");
    script.push(async () => { throw new Error("pipe broke"); });
    expect(bridge.command({ kind: "userPrompt", text: "please keep me" })).toMatchObject({ ok: true });
    await waitState(bridge, "idle");
    await tick(20);
    expect(store.readEvents(0).some((e) => e.type === "error" && String(e.data.message).includes("pipe broke"))).toBe(true);
    expect(bridge.status()).toMatchObject({ state: "idle", inbox: 1 });
    expect(bridge.command({ kind: "userPrompt", text: "again" })).toMatchObject({ ok: true });
    await tick(50);
    expect(agents[0]!.prompts.at(-1)).toBe("please keep me\n\nagain");
  });

  it("restarts the idle timer on every input", async () => {
    const { bridge, exits } = await stubbed({ idleMs: 400 });
    bridge.boot();
    await waitState(bridge, "idle");
    for (let i = 0; i < 4; i++) { await tick(150); bridge.command({ kind: "gate", rule: "r", command: "c" }); }
    expect(bridge.status().state).toBe("idle");
    await waitState(bridge, "suspended");
    expect(exits).toEqual([0]);
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
