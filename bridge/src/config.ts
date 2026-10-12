// The bridge's environment (spec §8.1, §12).
import type { Tokens } from "./api.js";
import type { AgentName } from "./types.js";

export class ConfigError extends Error {}

export interface Config {
  taskDir: string;
  task: string;
  project: string;
  agent: AgentName;
  model: string | null;
  branch: string | null;
  prompt: string | null;
  idleTimeoutMs: number;
  port: number;
  tokens: Tokens;
  hosts: string[];
  origins: string[];
  webhook: string | null;
  eventsDir: string;
  acpCmd: string[] | null;
  work: string;
  allowed: string[];
  paragraphFile: string;
}

const list = (v: string | undefined): string[] => (v ?? "").split(",").map((s) => s.trim()).filter(Boolean);
const opt = (v: string | undefined): string | null => (v && v.trim() ? v : null);

function token(env: NodeJS.ProcessEnv, name: string): string {
  const v = env[name] ?? "";
  if (v.length < 16) throw new ConfigError(`${name} must be set to a random token of 16 or more characters`);
  return v;
}

export function loadConfig(env: NodeJS.ProcessEnv): Config {
  const tokens = { task: token(env, "AGENTIC_TASK_TOKEN"), agent: token(env, "AGENTIC_AGENT_TOKEN") };
  if (tokens.task === tokens.agent) throw new ConfigError("AGENTIC_TASK_TOKEN and AGENTIC_AGENT_TOKEN must differ");
  const agent = env.AGENTIC_AGENT ?? "claude";
  if (agent !== "claude" && agent !== "copilot") throw new ConfigError(`AGENTIC_AGENT must be claude or copilot, not ${agent}`);
  const idle = Number(env.AGENTIC_IDLE_TIMEOUT ?? "900");
  if (!Number.isFinite(idle) || idle <= 0) throw new ConfigError("AGENTIC_IDLE_TIMEOUT must be a number of seconds");
  let acpCmd: string[] | null = null;
  if (opt(env.AGENTIC_ACP_CMD)) {
    try {
      const v: unknown = JSON.parse(env.AGENTIC_ACP_CMD ?? "");
      if (!Array.isArray(v) || v.length === 0 || !v.every((x) => typeof x === "string")) throw new Error();
      acpCmd = v as string[];
    } catch {
      throw new ConfigError('AGENTIC_ACP_CMD must be a JSON array of strings, for example ["node","/fake.mjs"]');
    }
  }
  return {
    taskDir: env.AGENTIC_TASK_DIR ?? "/task",
    task: env.AGENTIC_TASK_ID ?? "task",
    project: env.AGENTIC_PROJECT ?? "project",
    agent,
    model: opt(env.AGENTIC_MODEL),
    branch: opt(env.AGENTIC_BRANCH),
    prompt: opt(env.AGENTIC_PROMPT),
    idleTimeoutMs: idle * 1000,
    port: Number(env.AGENTIC_BRIDGE_PORT ?? "8765"),
    tokens,
    hosts: list(env.AGENTIC_BRIDGE_HOSTS),
    origins: list(env.AGENTIC_BRIDGE_ORIGINS),
    webhook: opt(env.AGENTIC_NOTIFY_WEBHOOK),
    eventsDir: env.AGENTIC_EVENTS_DIR ?? "/events",
    acpCmd,
    work: env.AGENTIC_WORK ?? "/work",
    allowed: list(env.AGENTIC_ALLOWED_ACTIONS),
    paragraphFile: `${env.AGENTIC_DIR ?? "/opt/agentic"}/task/task-prompt.md`,
  };
}

// agentEnvironment: what the agent process sees: the ask channel, never the task token.
export function agentEnvironment(env: NodeJS.ProcessEnv, cfg: Config): NodeJS.ProcessEnv {
  const out: NodeJS.ProcessEnv = { ...env };
  delete out.AGENTIC_TASK_TOKEN;
  out.AGENTIC_AGENT_TOKEN = cfg.tokens.agent;
  out.AGENTIC_BRIDGE_URL = `http://127.0.0.1:${cfg.port}`;
  out.AGENTIC_TASK_DIR = cfg.taskDir;
  return out;
}
