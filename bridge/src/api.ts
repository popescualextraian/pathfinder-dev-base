// Routes of API version 1 as plain functions (spec §8.2): transport-neutral, so an outbound mode
// could serve them over another connection.
import { createHash, timingSafeEqual } from "node:crypto";
import { APP_ACTIONS, APP_NAME_RE, DEFAULT_LOG_LINES, MAX_LOG_LINES, type AppOutcome, type AppVerb, type AppView } from "./apps.js";
import type { Input, Outcome } from "./task.js";
import type { SessionView } from "./sessions.js";
import type { TaskEvent } from "./types.js";

export interface ApiTarget {
  ready(): boolean;
  status(): Record<string, unknown>;
  command(input: Input): Outcome;
  sessions(): SessionView[];
  events(since: number, limit: number, keep?: (e: TaskEvent) => boolean): TaskEvent[];
  apps(): Promise<AppOutcome<AppView[]>>;
  appAction(name: string, verb: AppVerb): Promise<AppOutcome<AppView>>;
  appLogs(name: string, lines: number): Promise<AppOutcome<string[]>>;
}
export interface Tokens { task: string; agent: string }
export interface AccessOptions { hosts: string[]; origins: string[] }
export interface ApiRequest {
  method: string;
  path: string;
  query: URLSearchParams;
  headers: Record<string, string | undefined>;
  body: string;
}
export interface ApiResponse { status: number; json?: unknown; ndjson?: unknown[] }

export const MAX_BODY = 1048576;
const LOOPBACK = new Set(["127.0.0.1", "localhost", "[::1]"]);
const STATUS = { conflict: 409, not_found: 404, bad_request: 400 } as const;

const STATUS_TYPES = new Set(["state", "question", "answer", "error"]);
// eventView: the filter for an events `view` query value (absent means full), or null if unknown.
// Filtered views keep the full stream's seq numbers, with gaps.
export function eventView(view: string | null): ((e: TaskEvent) => boolean) | null {
  if (view === null || view === "full") return () => true;
  if (view === "status") return (e) => STATUS_TYPES.has(e.type) || (e.type === "message" && e.data.final === true);
  return null;
}

const err = (status: number, code: string, message: string): ApiResponse => ({ status, json: { error: { code, message } } });
// hostname: the lower-case name of a Host header or list entry without its port, or null if malformed.
function hostname(h: string): string | null {
  const m = /^(\[[0-9a-f:.]+\]|[a-z0-9._-]+)(?::\d{1,5})?$/i.exec(h.trim());
  return m?.[1] ? m[1].toLowerCase() : null;
}

// same: constant-time comparison; hashing first hides the length too.
function same(a: string, b: string): boolean {
  const x = createHash("sha256").update(a).digest();
  const y = createHash("sha256").update(b).digest();
  return timingSafeEqual(x, y);
}

export function checkAccess(headers: Record<string, string | undefined>, tokens: Tokens, opts: AccessOptions): { scope: "task" | "agent" } | ApiResponse {
  const host = hostname(headers.host ?? "");
  const listed = opts.hosts.filter((h) => h.trim()).map(hostname);
  if (host === null || (!LOOPBACK.has(host) && !listed.includes(host))) return err(403, "forbidden", "host not allowed");
  const origins = opts.origins.filter((o) => o.trim()).map((o) => o.trim().toLowerCase());
  if (headers.origin !== undefined && !origins.includes(headers.origin.trim().toLowerCase())) return err(403, "forbidden", "origin not allowed");
  const bearer = /^Bearer (.+)$/.exec(headers.authorization ?? "");
  if (bearer?.[1] && same(bearer[1], tokens.task)) return { scope: "task" };
  if (bearer?.[1] && same(bearer[1], tokens.agent)) return { scope: "agent" };
  return err(401, "unauthorized", "unauthorized");
}

const isStr = (v: unknown): v is string => typeof v === "string";
const isStrArray = (v: unknown): v is string[] => Array.isArray(v) && v.every(isStr);

function outcome(o: Outcome, ok: () => ApiResponse): ApiResponse {
  return o.ok ? ok() : err(STATUS[o.code], o.code, o.message);
}

// what the agent token may do: ask, report gate refusals and app events; never control apps
const AGENT_ROUTES = new Set(["POST /ask", "POST /gate", "POST /app"]);

// admit: the checks every route passes first (access, the agent token's routes, readiness); null admits.
function admit(req: ApiRequest, target: ApiTarget, tokens: Tokens, opts: AccessOptions): ApiResponse | null {
  const access = checkAccess(req.headers, tokens, opts);
  if ("status" in access) return access;
  if (access.scope === "agent" && !AGENT_ROUTES.has(`${req.method} ${req.path}`)) return err(403, "forbidden", "this token may only ask and report");
  if (!target.ready()) return err(503, "starting", "the bridge is starting");
  return null;
}

const APP_ROUTE = /^\/apps\/([^/]+)\/(start|stop|restart|logs)$/;
const fromApp = <T>(o: AppOutcome<T>, ok: (v: T) => ApiResponse): ApiResponse => (o.ok ? ok(o.value) : err(o.status, o.code, o.message));

// serve: every route; the app routes run agentic-app and answer later, the others go to handle.
export async function serve(req: ApiRequest, target: ApiTarget, tokens: Tokens, opts: AccessOptions): Promise<ApiResponse> {
  const m = APP_ROUTE.exec(req.path);
  if (req.path !== "/apps" && !m) return handle(req, target, tokens, opts);
  const refused = admit(req, target, tokens, opts);
  if (refused) return refused;
  if (!m) return req.method === "GET" ? fromApp(await target.apps(), (v) => ({ status: 200, json: v })) : err(404, "not_found", "no such route");
  const [, name = "", verb = ""] = m;
  if (req.method !== (verb === "logs" ? "GET" : "POST")) return err(404, "not_found", "no such route");
  // checked before anything runs: an encoded or special character never reaches agentic-app
  if (!APP_NAME_RE.test(name)) return err(404, "not_found", "unknown app");
  if (verb !== "logs") return fromApp(await target.appAction(name, verb as AppVerb), (v) => ({ status: 202, json: v }));
  const raw = req.query.get("lines");
  if (raw !== null && !/^[0-9]{1,9}$/.test(raw)) return err(400, "bad_request", `lines must be a number from 1 to ${MAX_LOG_LINES}`);
  const lines = raw === null ? DEFAULT_LOG_LINES : Math.min(Number(raw), MAX_LOG_LINES);
  if (lines < 1) return err(400, "bad_request", `lines must be a number from 1 to ${MAX_LOG_LINES}`);
  return fromApp(await target.appLogs(name, lines), (v) => ({ status: 200, json: { lines: v } }));
}

export function handle(req: ApiRequest, target: ApiTarget, tokens: Tokens, opts: AccessOptions): ApiResponse {
  const refused = admit(req, target, tokens, opts);
  if (refused) return refused;
  const route = `${req.method} ${req.path}`;
  if (Buffer.byteLength(req.body) > MAX_BODY) return err(413, "bad_request", "body too large");
  let body: Record<string, unknown> = {};
  if (req.method === "POST" && req.body.trim()) {
    try {
      const parsed: unknown = JSON.parse(req.body);
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return err(400, "bad_request", "body must be a JSON object");
      body = parsed as Record<string, unknown>;
    } catch {
      return err(400, "bad_request", "body is not JSON");
    }
  }
  // optStr: a string field that may be absent; anything else is a 400
  const optStr = (k: string): string | undefined | ApiResponse =>
    body[k] === undefined || isStr(body[k]) ? (body[k] as string | undefined) : err(400, "bad_request", `${k} must be a string`);
  const session = optStr("session");
  if (typeof session === "object") return session;
  const sess = session === undefined ? {} : { session };
  const status = (): ApiResponse => ({ status: 202, json: target.status() });
  switch (route) {
    case "GET /status":
      return { status: 200, json: target.status() };
    case "GET /events": {
      const since = Number(req.query.get("since") ?? "0");
      const limit = Number(req.query.get("limit") ?? "1000");
      if (!Number.isInteger(since) || since < 0 || !Number.isInteger(limit) || limit < 1 || limit > 1000) {
        return err(400, "bad_request", "since must be an integer >= 0 and limit 1..1000");
      }
      const view = eventView(req.query.get("view"));
      if (!view) return err(400, "bad_request", "view must be full or status");
      const session = req.query.get("session");
      const keep = session === null ? view : (e: TaskEvent) => e.name === session && view(e);
      return { status: 200, ndjson: target.events(since, limit, keep) };
    }
    case "GET /sessions":
      return { status: 200, json: target.sessions() };
    case "POST /sessions": {
      const [model, fork, text] = [optStr("model"), optStr("fork"), optStr("text")];
      if (!isStr(body.name)) return err(400, "bad_request", "name must be a string");
      for (const v of [model, fork, text]) if (typeof v === "object") return v;
      const name = body.name;
      const o = target.command({ kind: "addSession", name, model: (model as string | undefined) ?? null, fork: (fork as string | undefined) ?? null, text: (text as string | undefined) ?? null });
      return outcome(o, () => ({ status: 201, json: target.sessions().find((x) => x.name === name) }));
    }
    case "POST /prompt":
      if (!isStr(body.text)) return err(400, "bad_request", "text must be a string");
      return outcome(target.command({ kind: "userPrompt", text: body.text, ...sess }), status);
    case "POST /answer": {
      if (!isStr(body.text)) return err(400, "bad_request", "text must be a string");
      if (body.question !== undefined && !isStr(body.question)) return err(400, "bad_request", "question must be a string");
      if (body.grant !== undefined && !isStrArray(body.grant)) return err(400, "bad_request", "grant must be a list of strings");
      const input: Input = { kind: "answer", text: body.text, grant: body.grant ?? [], ...sess, ...(body.question ? { question: body.question } : {}) };
      return outcome(target.command(input), status);
    }
    case "POST /cancel":
      return outcome(target.command({ kind: "cancel", ...sess }), status);
    case "POST /stop":
      return outcome(target.command({ kind: "stop" }), status);
    case "POST /ask": {
      if (!isStr(body.text)) return err(400, "bad_request", "text must be a string");
      if (body.options !== undefined && !isStrArray(body.options)) return err(400, "bad_request", "options must be a list of strings");
      if (body.recommend !== undefined && body.recommend !== null && !isStr(body.recommend)) return err(400, "bad_request", "recommend must be a string");
      const o = target.command({ kind: "ask", text: body.text, options: body.options ?? [], recommend: body.recommend ?? null, ...(session === undefined ? {} : { sessionId: session }) });
      return outcome(o, () => ({ status: 201, json: o.ok ? o.value : undefined }));
    }
    case "POST /gate":
      target.command({ kind: "gate", rule: isStr(body.rule) ? body.rule : "", command: isStr(body.command) ? body.command : "", ...(session === undefined ? {} : { sessionId: session }) });
      return { status: 204 };
    case "POST /app": {
      // agentic-app reports a start, stop, exit or failed prepare (agent token)
      if (!isStr(body.name) || !APP_NAME_RE.test(body.name)) return err(400, "bad_request", "name must be an app name");
      const action = APP_ACTIONS.find((a) => a === body.action);
      if (!action) return err(400, "bad_request", `action must be one of ${APP_ACTIONS.join(", ")}`);
      const code = body.exit_code;
      if (code !== undefined && code !== null && !Number.isInteger(code)) return err(400, "bad_request", "exit_code must be an integer");
      target.command({ kind: "app", name: body.name, action, exitCode: typeof code === "number" ? code : null });
      return { status: 204 };
    }
    default:
      return err(404, "not_found", "no such route");
  }
}
