import { describe, expect, it } from "vitest";
import { agentEnvironment, loadConfig } from "../src/config.js";

const base = { AGENTIC_TASK_TOKEN: "task-token-0123456789", AGENTIC_AGENT_TOKEN: "agent-token-0123456789" };

describe("loadConfig", () => {
  it("has defaults for everything but the tokens", () => {
    const c = loadConfig(base);
    expect(c).toMatchObject({ taskDir: "/task", agent: "claude", port: 8765, idleTimeoutMs: 900000, eventsDir: "/events",
      work: "/work", acpCmd: null, allowed: [], hosts: [], origins: [], webhook: null, paragraphFile: "/opt/agentic/task/task-prompt.md" });
  });

  it("refuses missing or short tokens, an unknown agent and a bad ACP command", () => {
    expect(() => loadConfig({})).toThrow("AGENTIC_TASK_TOKEN");
    expect(() => loadConfig({ ...base, AGENTIC_AGENT_TOKEN: "short" })).toThrow("AGENTIC_AGENT_TOKEN");
    expect(() => loadConfig({ ...base, AGENTIC_AGENT: "gpt" })).toThrow("AGENTIC_AGENT");
    expect(() => loadConfig({ ...base, AGENTIC_ACP_CMD: "node x" })).toThrow("AGENTIC_ACP_CMD");
    expect(() => loadConfig({ ...base, AGENTIC_IDLE_TIMEOUT: "soon" })).toThrow("AGENTIC_IDLE_TIMEOUT");
  });

  it("parses lists and the ACP command", () => {
    const c = loadConfig({ ...base, AGENTIC_ALLOWED_ACTIONS: "push, open-pr", AGENTIC_BRIDGE_HOSTS: "a:1,b", AGENTIC_ACP_CMD: '["node","/f.mjs"]', AGENTIC_IDLE_TIMEOUT: "3" });
    expect(c.allowed).toEqual(["push", "open-pr"]);
    expect(c.hosts).toEqual(["a:1", "b"]);
    expect(c.acpCmd).toEqual(["node", "/f.mjs"]);
    expect(c.idleTimeoutMs).toBe(3000);
  });
});

describe("agentEnvironment", () => {
  it("gives the agent the bridge URL and its own token, never the task token", () => {
    const env = agentEnvironment({ ...base, PATH: "/bin" }, loadConfig(base));
    expect(env.AGENTIC_TASK_TOKEN).toBeUndefined();
    expect(env.AGENTIC_AGENT_TOKEN).toBe("agent-token-0123456789");
    expect(env.AGENTIC_BRIDGE_URL).toBe("http://127.0.0.1:8765");
    expect(env.AGENTIC_TASK_DIR).toBe("/task");
    expect(env.PATH).toBe("/bin");
  });
});
