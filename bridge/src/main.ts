#!/usr/bin/env node
// agentic-bridge: the task bridge (no arguments), or `agentic-bridge follow` inside the container.
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { AgentProcess } from "./agent.js";
import { Bridge } from "./bridge.js";
import { agentEnvironment, loadConfig } from "./config.js";
import { follow } from "./follow.js";
import { harnessFor } from "./harness.js";
import { Notifier } from "./notify.js";
import { makeRedactor } from "./redact.js";
import { startServer } from "./server.js";
import { Store } from "./store.js";

function die(text: string): never {
  process.stderr.write(`agentic-bridge: ${text}\n`);
  process.exit(1);
}

async function serve(): Promise<void> {
  const cfg = loadConfig(process.env);
  const redact = makeRedactor([cfg.tokens.task, cfg.tokens.agent]);
  const store = new Store(cfg.taskDir, redact);
  const log = (m: string) => { try { appendFileSync(store.path("bridge.log"), redact(`${new Date().toISOString()} ${m}\n`)); } catch { /* best effort */ } };
  const eventsLog = existsSync(cfg.eventsDir) ? join(cfg.eventsDir, "events.jsonl") : null;
  const paragraph = existsSync(cfg.paragraphFile) ? readFileSync(cfg.paragraphFile, "utf8") : "";
  const spec = harnessFor(cfg.agent, { model: cfg.model, acpCmd: cfg.acpCmd });
  const env = agentEnvironment(process.env, cfg);
  let close: (() => Promise<void>) | null = null;
  const bridge = new Bridge({
    store, config: cfg, paragraph, log, now: () => new Date().toISOString(),
    notifier: new Notifier({ eventsLog, webhook: cfg.webhook, project: cfg.project, log }),
    agentFactory: (hooks) => new AgentProcess(spec, { cwd: cfg.work, env, paragraph, model: cfg.model }, hooks),
    exit: (code) => { log(`exit ${code}`); void bridge.shutdownAgent().then(() => close?.()).finally(() => process.exit(code)); },
  });
  const server = await startServer({ port: cfg.port, host: "0.0.0.0", tokens: cfg.tokens, access: { hosts: cfg.hosts, origins: cfg.origins },
    target: bridge, subscribe: (fn) => bridge.subscribe(fn) });
  close = server.close;
  try {
    bridge.boot();
  } catch (e) {
    await server.close();
    die((e as Error).message);
  }
  log(`listening on ${server.port}`);
  // Docker stop or a host shutdown: end the agent, keep the state (the next boot shows interrupted, spec D10).
  process.on("SIGTERM", () => { void bridge.shutdownAgent().finally(() => server.close().finally(() => process.exit(143))); });
}

async function followCmd(args: string[]): Promise<void> {
  let since = 0;
  let raw = false;
  let forever = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--since") since = Number(args[++i]);
    else if (a === "--raw") raw = true;
    else if (a === "--forever") forever = true;
    else die(`unknown option ${a}; usage: agentic-bridge follow [--since N] [--raw] [--forever]`);
  }
  if (!Number.isInteger(since) || since < 0) die("--since needs a number >= 0");
  const token = process.env.AGENTIC_TASK_TOKEN ?? die("AGENTIC_TASK_TOKEN is not set (run follow inside the task container)");
  const port = process.env.AGENTIC_BRIDGE_PORT ?? "8765";
  process.exit(await follow({ url: `ws://127.0.0.1:${port}`, token, since, raw, forever, out: (s) => process.stdout.write(s) }));
}

const [cmd, ...rest] = process.argv.slice(2);
if (cmd === "follow") await followCmd(rest);
else if (cmd === undefined) await serve().catch((e: Error) => die(e.message));
else die(`unknown command ${cmd}; usage: agentic-bridge [follow [--since N] [--raw] [--forever]]`);
