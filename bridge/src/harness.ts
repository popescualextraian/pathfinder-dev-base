// Claude and Copilot facts for the bridge (spec §7.1).
import { fileURLToPath } from "node:url";
import type { AgentName } from "./types.js";

export interface SessionCalls {
  setMode(sessionId: string, modeId: string): Promise<void>;
  setConfigOption(sessionId: string, configId: string, value: string): Promise<void>;
}

export interface HarnessSpec {
  name: AgentName;
  command: string[];
  env: Record<string, string>;
  sessionMeta(paragraph: string): Record<string, unknown> | undefined;
  afterSession(calls: SessionCalls, sessionId: string, model: string | null): Promise<void>;
}

// The adapter ships in the bridge's own node_modules (src/ and dist/ sit next to it).
export const CLAUDE_ACP_ENTRY = fileURLToPath(
  new URL("../node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js", import.meta.url),
);

export function harnessFor(name: AgentName, opts: { model: string | null; acpCmd: string[] | null }): HarnessSpec {
  if (name === "claude") {
    return {
      name,
      command: opts.acpCmd ?? ["node", CLAUDE_ACP_ENTRY],
      // One Claude version per image: the adapter runs the image's claude, not its bundled binary.
      env: { CLAUDE_CODE_EXECUTABLE: process.env.CLAUDE_CODE_EXECUTABLE ?? "/usr/local/bin/claude" },
      sessionMeta: (paragraph) => (paragraph ? { systemPrompt: { append: paragraph } } : undefined),
      afterSession: async (calls, sessionId, model) => {
        await calls.setMode(sessionId, "bypassPermissions");
        if (model) await calls.setConfigOption(sessionId, "model", model);
      },
    };
  }
  return {
    name,
    command: opts.acpCmd ?? ["copilot", "--acp", "--allow-all", ...(opts.model ? ["--model", opts.model] : [])],
    env: { COPILOT_AUTO_UPDATE: "false" },
    // Copilot reads the task paragraph from copilot-instructions.md (45-hooks writes it).
    sessionMeta: () => undefined,
    afterSession: async (calls, sessionId, model) => {
      if (model) await calls.setConfigOption(sessionId, "model", model);
    },
  };
}
