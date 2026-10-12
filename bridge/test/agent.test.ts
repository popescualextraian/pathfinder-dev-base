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

function make(state: string, hooks: Partial<AgentHooks> = {}) {
  const updates: Update[] = [];
  const exits: string[] = [];
  const a = new AgentProcess(harnessFor("claude", { model: null, acpCmd: ["node", FAKE] }),
    { cwd: state, env: { ...process.env, FAKE_AGENT_STATE: state }, paragraph: "Use agentic-ask.", model: null },
    { onUpdate: (u) => updates.push(u), onPermission: async () => null, onExit: (e) => exits.push(e), ...hooks });
  agents.push(a);
  return { a, updates, exits };
}
const texts = (us: Update[]) => us.filter((u) => u.sessionUpdate === "agent_message_chunk").map((u) => (u.content as { text: string }).text);

describe("AgentProcess", () => {
  it("opens a session with bypass and the paragraph, and runs turns", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a, updates } = make(dir);
    await a.start();
    await a.newSession();
    expect(await a.prompt("hello")).toBe("end_turn");
    expect(texts(updates)).toEqual(["echo: hello"]);
    await a.prompt("META");
    const meta = JSON.parse(texts(updates)[1] ?? "{}");
    expect(meta.mode).toBe("bypassPermissions");
    expect(meta.meta.systemPrompt.append).toBe("Use agentic-ask.");
  });

  it("cancels a running turn", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a } = make(dir);
    await a.start(); await a.newSession();
    const p = a.prompt("SLEEP:10000");
    setTimeout(() => a.cancel(), 200);
    expect(await p).toBe("cancelled");
  });

  it("passes permission requests to the hook and returns its choice", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const asked: unknown[] = [];
    const { a, updates } = make(dir, { onPermission: async (r) => { asked.push(r); return "reject"; } });
    await a.start(); await a.newSession();
    await a.prompt("PERMISSION:echo x");
    expect(asked).toEqual([{ title: "echo x", command: "echo x", options: [
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
    const sid = await first.a.newSession();
    await first.a.prompt("one");
    await first.a.kill();
    const second = make(dir);
    await second.a.start();
    await second.a.loadSession(sid);
    expect(second.updates).toEqual([]);
    await second.a.prompt("HISTORY");
    expect(texts(second.updates)).toEqual(["history: 2"]);
  });

  it("rejects a load of an unknown session", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a } = make(dir);
    await a.start();
    await expect(a.loadSession("nope")).rejects.toThrow();
  });

  it("reports an unexpected exit, but not a kill", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const crash = make(dir);
    await crash.a.start(); await crash.a.newSession();
    await expect(crash.a.prompt("CRASH")).rejects.toThrow();
    await new Promise((r) => setTimeout(r, 200));
    expect(crash.exits).toEqual(["agent exited with code 3"]);
    const quiet = make(dir);
    await quiet.a.start();
    await quiet.a.kill();
    expect(quiet.exits).toEqual([]);
  });
});
