#!/usr/bin/env node
// agentic-bridge: the task bridge (no arguments), or `agentic-bridge follow` inside the container.
import { spawnSync } from "node:child_process";
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { AgentProcess } from "./agent.js";
import { Bridge } from "./bridge.js";
import { agentEnvironment, loadConfig } from "./config.js";
import { follow } from "./follow.js";
import { harnessFor } from "./harness.js";
import { Notifier } from "./notify.js";
import { parseHoldPid } from "./release.js";
import { makeRedactor } from "./redact.js";
import { NAME_RE } from "./sessions.js";
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
  const agentic = process.env.AGENTIC_DIR ?? "/opt/agentic";
  const stateDir = process.env.AGENTIC_STATE ?? join(process.env.HOME ?? "/home/dev", ".agentic");
  let close: (() => Promise<void>) | null = null;
  const bridge = new Bridge({
    store, config: cfg, paragraph, log, now: () => new Date().toISOString(),
    notifier: new Notifier({ eventsLog, webhook: cfg.webhook, project: cfg.project, log }),
    agentFactory: (hooks, cwd) => new AgentProcess(spec, { cwd, env, paragraph }, hooks),
    worktree: (args) => {
      const r = spawnSync("bash", [join(agentic, "task", "worktree.sh"), ...args], { encoding: "utf8" });
      return { ok: r.status === 0, out: r.stdout ?? "", err: r.stderr ?? "" };
    },
    release: () => {
      try {
        const pid = parseHoldPid(readFileSync(join(stateDir, "hold.pid"), "utf8"));
        if (pid === null) { log("release skipped: hold.pid does not hold a pid"); return; }
        process.kill(pid, "SIGTERM");
      } catch (e) {
        log(`release failed: ${(e as Error).message}`);
      }
    },
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
  // Docker stop or a host shutdown: agentic-task-hold (the container's command) gets the signal and
  // forwards SIGTERM here; end the agent, keep the state (the next boot shows interrupted, spec D10).
  process.on("SIGTERM", () => { void bridge.shutdownAgent().finally(() => server.close().finally(() => process.exit(143))); });
}

async function followCmd(args: string[]): Promise<void> {
  let since = 0;
  let raw = false;
  let forever = false;
  let status = false;
  let session: string | null = null;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--since") since = Number(args[++i]);
    else if (a === "--raw") raw = true;
    else if (a === "--forever") forever = true;
    else if (a === "--status") status = true;
    else if (a === "--session") session = args[++i] ?? "";
    else die(`unknown option ${a}; usage: agentic-bridge follow [--since N] [--raw] [--forever] [--status] [--session NAME]`);
  }
  if (!Number.isInteger(since) || since < 0) die("--since needs a number >= 0");
  if (session !== null && !NAME_RE.test(session)) die(`--session needs a session name (${NAME_RE})`);
  const token = process.env.AGENTIC_TASK_TOKEN ?? die("AGENTIC_TASK_TOKEN is not set (run follow inside the task container)");
  const port = process.env.AGENTIC_BRIDGE_PORT ?? "8765";
  process.exit(await follow({ url: `ws://127.0.0.1:${port}`, token, since, raw, forever, status, session, out: (s) => process.stdout.write(s) }));
}

const [cmd, ...rest] = process.argv.slice(2);
if (cmd === "follow") await followCmd(rest);
else if (cmd === undefined) await serve().catch((e: Error) => die(e.message));
else die(`unknown command ${cmd}; usage: agentic-bridge [follow [--since N] [--raw] [--forever] [--status] [--session NAME]]`);
