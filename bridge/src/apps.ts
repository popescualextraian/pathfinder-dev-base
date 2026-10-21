// The task's apps (app-run spec §5): the bridge runs agentic-app in the container, always with an
// argument array (never a shell), and maps its answers to API results.
import { execFile } from "node:child_process";

export const APP_NAME_RE = /^[a-z][a-z0-9-]{0,30}$/;
export const APP_ACTIONS = ["started", "stopped", "exited", "failed"] as const;
export type AppAction = (typeof APP_ACTIONS)[number];
export type AppVerb = "start" | "stop" | "restart";
export const APP_VERBS: readonly AppVerb[] = ["start", "stop", "restart"];

export interface AppView {
  name: string;
  state: string;
  ports: number[];
  url: string;
  since: number | null;
  exit_code: number | null;
}
export interface RunResult { code: number | null; out: string; err: string; timedOut: boolean; tooLarge?: boolean }
// Runner: runs agentic-app with ARGS in the task's checkout WORK, ended after TIMEOUT ms.
export type Runner = (args: string[], timeoutMs: number, work: string) => Promise<RunResult>;
export type AppOutcome<T> =
  | { ok: true; value: T }
  | { ok: false; status: 404 | 409 | 502 | 504; code: string; message: string };

// a start runs the app's prepare first (agentic-app's own limit: 600 s), a stop its teardown (120 s);
// each gets more than that, a restart both
export const START_TIMEOUT_MS = 660_000;
export const STOP_TIMEOUT_MS = 180_000;
export const SHORT_TIMEOUT_MS = 10_000;
const VERB_TIMEOUT_MS: Record<AppVerb, number> = { start: START_TIMEOUT_MS, stop: STOP_TIMEOUT_MS, restart: START_TIMEOUT_MS + STOP_TIMEOUT_MS };
export const MAX_LOG_LINES = 2000;
export const DEFAULT_LOG_LINES = 200;
const MAX_MESSAGE_LINES = 20;

// cleanText: no C0 control but tab and newline, no DEL, no C1 control.
export function cleanText(s: string): string {
  // eslint-disable-next-line no-control-regex
  return s.replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/g, "");
}

const notFound = (name: string): AppOutcome<never> => ({ ok: false, status: 404, code: "not_found", message: `unknown app ${name}` });

// failure: agentic-app's refusal as an API result; the message is its last stderr lines.
function failure(r: RunResult, what: string): AppOutcome<never> {
  if (r.tooLarge) return { ok: false, status: 502, code: "app_failed", message: "agentic-app output too large" };
  if (r.timedOut) return { ok: false, status: 504, code: "app_timeout", message: `agentic-app ${what} timed out` };
  const lines = cleanText(r.err).split("\n").filter((l) => l.trim());
  const message = lines.slice(-MAX_MESSAGE_LINES).join("\n") || `agentic-app ${what} failed (exit ${r.code ?? "none"})`;
  if (/ is preparing\b/.test(message)) return { ok: false, status: 409, code: "conflict", message };
  if (/ is not running\b/.test(message)) return { ok: false, status: 409, code: "conflict", message };
  if (/\bunknown app\b/.test(message)) return { ok: false, status: 404, code: "not_found", message };
  return { ok: false, status: 502, code: "app_failed", message };
}

const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
function isView(v: unknown): v is AppView {
  if (v === null || typeof v !== "object") return false;
  const a = v as Record<string, unknown>;
  return typeof a.name === "string" && typeof a.state === "string" && Array.isArray(a.ports) && a.ports.every(isNum)
    && typeof a.url === "string" && (a.since === null || isNum(a.since)) && (a.exit_code === null || a.exit_code === undefined || isNum(a.exit_code));
}

export class Apps {
  constructor(private readonly run: Runner) {}

  async list(work: string): Promise<AppOutcome<AppView[]>> {
    const r = await this.run(["list", "--json"], SHORT_TIMEOUT_MS, work);
    if (r.code !== 0) return failure(r, "list");
    try {
      const v: unknown = JSON.parse(r.out);
      if (Array.isArray(v) && v.every(isView)) return { ok: true, value: v.map((a) => ({ ...a, exit_code: a.exit_code ?? null })) };
    } catch { /* below */ }
    return { ok: false, status: 502, code: "app_failed", message: "agentic-app list gave no JSON list of apps" };
  }

  // act: the name is checked against the configured apps before anything runs for it.
  async act(work: string, name: string, verb: AppVerb): Promise<AppOutcome<AppView>> {
    const before = await this.list(work);
    if (!before.ok) return before;
    const app = before.value.find((a) => a.name === name);
    if (!app) return notFound(name);
    const r = await this.run([verb, name], VERB_TIMEOUT_MS[verb], work);
    if (r.code !== 0) return failure(r, verb);
    const after = await this.list(work);
    return { ok: true, value: (after.ok ? after.value.find((a) => a.name === name) : undefined) ?? app };
  }

  async logs(work: string, name: string, lines: number): Promise<AppOutcome<string[]>> {
    const known = await this.list(work);
    if (!known.ok) return known;
    if (!known.value.some((a) => a.name === name)) return notFound(name);
    const r = await this.run(["logs", name, "--lines", String(lines)], SHORT_TIMEOUT_MS, work);
    if (r.code !== 0) return failure(r, "logs");
    const out = cleanText(r.out).split("\n");
    if (out.at(-1) === "") out.pop();
    return { ok: true, value: out };
  }
}

// configured: the apps of a resolved config (JSON) with a valid name; none for anything else.
function configured(json: string): Array<[string, Record<string, unknown>]> {
  try {
    const conf: unknown = JSON.parse(json);
    const apps = conf !== null && typeof conf === "object" ? (conf as { apps?: unknown }).apps : undefined;
    if (apps === null || typeof apps !== "object" || Array.isArray(apps)) return [];
    return Object.entries(apps as Record<string, unknown>)
      .filter((e): e is [string, Record<string, unknown>] => APP_NAME_RE.test(e[0]) && e[1] !== null && typeof e[1] === "object");
  } catch {
    return [];
  }
}

export const appNames = (json: string): string[] => configured(json).map(([n]) => n);
// autostartNames: the configured apps with autostart true.
export const autostartNames = (json: string): string[] => configured(json).filter(([, a]) => a.autostart === true).map(([n]) => n);

// spawnRunner: CMD with an argument array and ENV plus AGENTIC_WORK; never throws.
export function spawnRunner(cmd: string, env: NodeJS.ProcessEnv): Runner {
  return (args, timeoutMs, work) => new Promise((resolve) => {
    execFile(cmd, args, { env: { ...env, AGENTIC_WORK: work }, timeout: timeoutMs, killSignal: "SIGTERM", maxBuffer: 8 * 1024 * 1024, encoding: "utf8" },
      (error, stdout, stderr) => {
        if (!error) return resolve({ code: 0, out: stdout, err: stderr, timedOut: false });
        const e = error as Omit<NodeJS.ErrnoException, "code"> & { code?: string | number; killed?: boolean; signal?: string | null };
        const code = typeof e.code === "number" ? e.code : null;
        // a buffer overflow kills the child too: it is no timeout
        if (e.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER") return resolve({ code, out: "", err: "", timedOut: false, tooLarge: true });
        const timedOut = e.killed === true && e.signal === "SIGTERM";
        resolve({ code, out: stdout, err: stderr || e.message, timedOut });
      });
  });
}
