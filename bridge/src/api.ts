// Routes of API version 1 as plain functions (spec §8.2): transport-neutral, so an outbound mode
// could serve them over another connection.
import { createHash, timingSafeEqual } from "node:crypto";
import type { Input, Outcome } from "./task.js";
import type { SessionView } from "./sessions.js";
import type { TaskEvent } from "./types.js";

export interface ApiTarget {
  ready(): boolean;
  status(): Record<string, unknown>;
  command(input: Input): Outcome;
  sessions(): SessionView[];
  events(since: number, limit: number, keep?: (e: TaskEvent) => boolean): TaskEvent[];
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

export function handle(req: ApiRequest, target: ApiTarget, tokens: Tokens, opts: AccessOptions): ApiResponse {
  const access = checkAccess(req.headers, tokens, opts);
  if ("status" in access) return access;
  const route = `${req.method} ${req.path}`;
  if (access.scope === "agent" && route !== "POST /ask" && route !== "POST /gate") return err(403, "forbidden", "this token may only ask");
  if (!target.ready()) return err(503, "starting", "the bridge is starting");
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
    default:
      return err(404, "not_found", "no such route");
  }
}
