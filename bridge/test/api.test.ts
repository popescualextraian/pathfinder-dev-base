import { describe, expect, it } from "vitest";
import { handle, serve, checkAccess, eventView, type ApiTarget, type ApiRequest } from "../src/api.js";
import type { AppOutcome, AppView } from "../src/apps.js";
import type { TaskEvent } from "../src/types.js";
import type { Input, Outcome } from "../src/task.js";

const tokens = { task: "task-token-0123456789", agent: "agent-token-0123456789" };
const access = { hosts: ["bridge.internal"], origins: [] as string[] };
const web: AppView = { name: "web", state: "running", ports: [3000], url: "/", since: 1, exit_code: null };
function target(outcome: Outcome = { ok: true, effects: [] }, app: AppOutcome<AppView> = { ok: true, value: web }) {
  const seen: Input[] = [];
  const appCalls: unknown[][] = [];
  const t: ApiTarget = {
    ready: () => true,
    status: () => ({ state: "idle" }),
    command: (i) => { seen.push(i); return outcome; },
    sessions: () => [{ name: "plan" }, { name: "main" }] as never,
    events: (since, limit, keep = () => true) => (Array.from({ length: 5 }, (_, k) => ({ seq: k + 1, type: k % 2 ? "tool" : "state", name: k % 2 ? "plan" : "main", data: {} })) as never as TaskEvent[])
      .filter((e) => e.seq > since && keep(e)).slice(0, limit),
    apps: async () => { appCalls.push(["list"]); return { ok: true, value: [web] }; },
    appAction: async (name, verb) => { appCalls.push([verb, name]); return app; },
    appLogs: async (name, lines) => { appCalls.push(["logs", name, lines]); return app.ok ? { ok: true, value: ["a", "b"] } : app; },
  };
  return { t, seen, appCalls };
}
const req = (method: string, path: string, body?: unknown, h: Record<string, string> = {}, query = ""): ApiRequest => ({
  method, path, query: new URLSearchParams(query), body: body === undefined ? "" : typeof body === "string" ? body : JSON.stringify(body),
  headers: { host: "127.0.0.1:49153", authorization: `Bearer ${tokens.task}`, ...h },
});

describe("checkAccess", () => {
  it("accepts loopback hosts on any port and listed hosts", () => {
    for (const host of ["127.0.0.1:49153", "localhost:8765", "[::1]:1", "bridge.internal:8765"]) {
      expect(checkAccess({ host, authorization: `Bearer ${tokens.task}` }, tokens, access)).toEqual({ scope: "task" });
    }
  });
  it("compares case-insensitively and rejects look-alike or malformed hosts", () => {
    const auth = `Bearer ${tokens.task}`;
    for (const host of ["LOCALHOST:1", "[::1]", "[::1]:8765", "Bridge.Internal"]) {
      expect(checkAccess({ host, authorization: auth }, tokens, access)).toEqual({ scope: "task" });
    }
    for (const host of ["[::1]evil", "localhost.evil.com", "127.0.0.1.evil", "localhost:abc", "", "a b"]) {
      expect(checkAccess({ host, authorization: auth }, tokens, access)).toMatchObject({ status: 403 });
    }
    expect(checkAccess({ authorization: auth }, tokens, access)).toMatchObject({ status: 403 });
    expect(checkAccess({ host: "evil.com", authorization: auth }, tokens, { hosts: [""], origins: [""] })).toMatchObject({ status: 403 });
    expect(checkAccess({ host: "localhost", origin: "HTTP://UI.example.com", authorization: auth }, tokens, { hosts: [], origins: ["http://ui.example.com"] })).toEqual({ scope: "task" });
    expect(checkAccess({ host: "localhost", origin: "", authorization: auth }, tokens, { hosts: [], origins: [""] })).toMatchObject({ status: 403 });
  });
  it("refuses malformed Authorization headers", () => {
    for (const authorization of ["", "Bearer", "Bearer ", "Basic abc", tokens.task, `bearer ${tokens.task}`]) {
      expect(checkAccess({ host: "localhost", authorization }, tokens, access)).toMatchObject({ status: 401 });
    }
  });
  it("refuses other hosts and unlisted origins with 403", () => {
    expect(checkAccess({ host: "evil.example.com", authorization: `Bearer ${tokens.task}` }, tokens, access)).toMatchObject({ status: 403 });
    expect(checkAccess({ host: "127.0.0.1:1", origin: "http://evil.example.com", authorization: `Bearer ${tokens.task}` }, tokens, access)).toMatchObject({ status: 403 });
  });
  it("needs a known bearer token; the agent token has the agent scope", () => {
    expect(checkAccess({ host: "localhost" }, tokens, access)).toMatchObject({ status: 401, json: { error: { code: "unauthorized", message: "unauthorized" } } });
    expect(checkAccess({ host: "localhost", authorization: "Bearer wrong" }, tokens, access)).toMatchObject({ status: 401 });
    expect(checkAccess({ host: "localhost", authorization: `Bearer ${tokens.agent}` }, tokens, access)).toEqual({ scope: "agent" });
  });
});

describe("handle", () => {
  it("POST /prompt passes the text byte-identical and returns 202 with the status", () => {
    const { t, seen } = target();
    const text = 'line one\nline "two" with $HOME, `ticks` and ünïcødé ✓';
    expect(handle(req("POST", "/prompt", { text }), t, tokens, access)).toEqual({ status: 202, json: { state: "idle" } });
    expect(seen).toEqual([{ kind: "userPrompt", text }]);
  });

  it("maps outcomes to status codes with one error body", () => {
    for (const [code, status] of [["conflict", 409], ["not_found", 404], ["bad_request", 400]] as const) {
      const { t } = target({ ok: false, code, message: "m" });
      expect(handle(req("POST", "/prompt", { text: "x" }), t, tokens, access)).toEqual({ status, json: { error: { code, message: "m" } } });
    }
  });

  it("validates bodies", () => {
    const { t } = target();
    expect(handle(req("POST", "/prompt", "{"), t, tokens, access)).toMatchObject({ status: 400, json: { error: { message: "body is not JSON" } } });
    expect(handle(req("POST", "/prompt", { text: 3 }), t, tokens, access)).toMatchObject({ status: 400 });
    expect(handle(req("POST", "/answer", { text: "x", grant: "push" }), t, tokens, access)).toMatchObject({ status: 400 });
    expect(handle(req("POST", "/prompt", "x".repeat(1048577)), t, tokens, access)).toMatchObject({ status: 413, json: { error: { message: "body too large" } } });
  });

  it("routes answer, cancel and stop", () => {
    const { t, seen } = target();
    handle(req("POST", "/answer", { question: "Q2", text: "yes", grant: ["push"] }), t, tokens, access);
    handle(req("POST", "/answer", { text: "no" }), t, tokens, access);
    handle(req("POST", "/cancel"), t, tokens, access);
    handle(req("POST", "/stop"), t, tokens, access);
    expect(seen).toEqual([
      { kind: "answer", question: "Q2", text: "yes", grant: ["push"] },
      { kind: "answer", text: "no", grant: [] },
      { kind: "cancel" },
      { kind: "stop" },
    ]);
  });

  it("GET /events returns NDJSON after the cursor, with a limit", () => {
    const { t } = target();
    expect(handle(req("GET", "/events", undefined, {}, "since=2&limit=2"), t, tokens, access)).toMatchObject({ status: 200, ndjson: [{ seq: 3, name: "main" }, { seq: 4, name: "plan" }] });
    expect(handle(req("GET", "/events", undefined, {}, "since=x"), t, tokens, access)).toMatchObject({ status: 400 });
  });

  it("GET /events?view=status leaves out the noise before the limit; view=full is the default; another view is 400", () => {
    const { t } = target();
    const seqs = (q: string) => (handle(req("GET", "/events", undefined, {}, q), t, tokens, access).ndjson as TaskEvent[]).map((e) => e.seq);
    expect(seqs("view=status&since=1&limit=2")).toEqual([3, 5]);
    expect(seqs("view=full&since=1&limit=2")).toEqual([2, 3]);
    expect(handle(req("GET", "/events", undefined, {}, "view=chat"), t, tokens, access)).toMatchObject({ status: 400 });
  });

  it("the status view keeps state, question, answer, error and final messages", () => {
    const keep = eventView("status");
    if (!keep) throw new Error("no status view");
    const e = (type: string, data: Record<string, unknown> = {}) => ({ seq: 1, ts: "t", task: "T", session: null, agent: "claude", type, data }) as TaskEvent;
    expect(["state", "question", "answer", "error"].every((type) => keep(e(type)))).toBe(true);
    expect(keep(e("message", { role: "user", text: "hi", final: true }))).toBe(true);
    expect([e("message", { final: false }), e("tool"), e("plan"), e("gate")].some(keep)).toBe(false);
    expect(eventView(null)).toBeTypeOf("function");
    expect(eventView("chat")).toBeNull();
  });

  it("the agent token may only ask and report gate refusals", () => {
    const { t, seen } = target({ ok: true, effects: [], value: { id: "Q1" } });
    const agent = { authorization: `Bearer ${tokens.agent}` };
    expect(handle(req("POST", "/ask", { text: "Which DB?", options: ["pg"], recommend: "pg" }, agent), t, tokens, access)).toEqual({ status: 201, json: { id: "Q1" } });
    expect(handle(req("POST", "/gate", { rule: "gate", command: "git push" }, agent), t, tokens, access)).toEqual({ status: 204 });
    expect(handle(req("POST", "/answer", { text: "yes" }, agent), t, tokens, access)).toMatchObject({ status: 403 });
    expect(handle(req("GET", "/status", undefined, agent), t, tokens, access)).toMatchObject({ status: 403 });
    expect(seen).toEqual([
      { kind: "ask", text: "Which DB?", options: ["pg"], recommend: "pg" },
      { kind: "gate", rule: "gate", command: "git push" },
    ]);
  });

  it("answers 503 until ready and 404 for unknown routes", () => {
    const { t } = target();
    expect(handle(req("GET", "/nope"), t, tokens, access)).toMatchObject({ status: 404 });
    expect(handle(req("GET", "/status"), { ...t, ready: () => false }, tokens, access)).toMatchObject({ status: 503, json: { error: { code: "starting" } } });
  });

  describe("sessions", () => {
    it("GET /sessions lists the views", () => {
      expect(handle(req("GET", "/sessions"), target().t, tokens, access)).toEqual({ status: 200, json: [{ name: "plan" }, { name: "main" }] });
    });
    it("POST /sessions adds one (optional fields null) and returns 201 with its view", () => {
      const { t, seen } = target({ ok: true, effects: [], value: { id: "plan" } });
      expect(handle(req("POST", "/sessions", { name: "plan" }), t, tokens, access)).toEqual({ status: 201, json: { name: "plan" } });
      handle(req("POST", "/sessions", { name: "plan", model: "m", fork: "main", text: "go" }), t, tokens, access);
      expect(seen).toEqual([
        { kind: "addSession", name: "plan", model: null, fork: null, text: null },
        { kind: "addSession", name: "plan", model: "m", fork: "main", text: "go" },
      ]);
    });
    it("POST /sessions checks types and passes refusals through", () => {
      const { t } = target({ ok: false, code: "conflict", message: "exists" });
      for (const b of [{}, { name: 1 }, { name: "a", model: 1 }, { name: "a", fork: 1 }, { name: "a", text: 1 }]) {
        expect(handle(req("POST", "/sessions", b), t, tokens, access)).toMatchObject({ status: 400 });
      }
      expect(handle(req("POST", "/sessions", { name: "a" }), t, tokens, access)).toMatchObject({ status: 409 });
    });
    it("the agent token cannot reach /sessions", () => {
      const agent = { authorization: `Bearer ${tokens.agent}` };
      expect(handle(req("POST", "/sessions", { name: "a" }, agent), target().t, tokens, access)).toMatchObject({ status: 403 });
      expect(handle(req("GET", "/sessions", undefined, agent), target().t, tokens, access)).toMatchObject({ status: 403 });
    });
    it("task routes carry session and reject a non-string one", () => {
      const { t, seen } = target();
      handle(req("POST", "/prompt", { text: "x", session: "plan" }), t, tokens, access);
      handle(req("POST", "/answer", { text: "x", session: "plan" }), t, tokens, access);
      handle(req("POST", "/cancel", { session: "plan" }), t, tokens, access);
      handle(req("POST", "/ask", { text: "q", session: "acp-1" }, { authorization: `Bearer ${tokens.agent}` }), t, tokens, access);
      handle(req("POST", "/gate", { rule: "r", command: "c", session: "acp-1" }, { authorization: `Bearer ${tokens.agent}` }), t, tokens, access);
      expect(seen).toEqual([
        { kind: "userPrompt", text: "x", session: "plan" },
        { kind: "answer", text: "x", grant: [], session: "plan" },
        { kind: "cancel", session: "plan" },
        { kind: "ask", text: "q", options: [], recommend: null, sessionId: "acp-1" },
        { kind: "gate", rule: "r", command: "c", sessionId: "acp-1" },
      ]);
      for (const [p, b] of [["/prompt", { text: "x" }], ["/answer", { text: "x" }], ["/cancel", {}]] as const) {
        expect(handle(req("POST", p, { ...b, session: 1 }), t, tokens, access)).toMatchObject({ status: 400 });
      }
      expect(handle(req("POST", "/ask", { text: "q", session: 1 }), t, tokens, access)).toMatchObject({ status: 400 });
    });
    it("an unknown session name comes back 404", () => {
      const { t } = target({ ok: false, code: "not_found", message: "no session x" });
      expect(handle(req("POST", "/prompt", { text: "x", session: "x" }), t, tokens, access)).toMatchObject({ status: 404 });
    });
    it("GET /events?session= filters by name", () => {
      const r = handle(req("GET", "/events", undefined, {}, "session=plan"), target().t, tokens, access);
      expect((r.ndjson as { name: string }[]).map((e) => e.name)).toEqual(["plan", "plan"]);
      const both = handle(req("GET", "/events", undefined, {}, "session=plan&view=status"), target().t, tokens, access);
      expect(both).toEqual({ status: 200, ndjson: [] });
      const main = handle(req("GET", "/events", undefined, {}, "session=main&view=status"), target().t, tokens, access);
      expect((main.ndjson as { seq: number }[]).map((e) => e.seq)).toEqual([1, 3, 5]);
    });
  });

  describe("apps", () => {
    const agent = { authorization: `Bearer ${tokens.agent}` };
    it("GET /apps lists them; a failure of the target passes through", async () => {
      expect(await serve(req("GET", "/apps"), target().t, tokens, access)).toEqual({ status: 200, json: [web] });
      const t = { ...target().t, apps: async () => ({ ok: false as const, status: 502 as const, code: "app_failed", message: "bad JSON" }) };
      expect(await serve(req("GET", "/apps"), t, tokens, access)).toEqual({ status: 502, json: { error: { code: "app_failed", message: "bad JSON" } } });
    });
    it("start, stop and restart answer 202 with the app", async () => {
      const { t, appCalls } = target();
      for (const verb of ["start", "stop", "restart"]) {
        expect(await serve(req("POST", `/apps/web/${verb}`), t, tokens, access)).toEqual({ status: 202, json: web });
      }
      expect(appCalls).toEqual([["start", "web"], ["stop", "web"], ["restart", "web"]]);
    });
    it("a name outside the app name rule is 404 and never reaches the target; refusals pass through", async () => {
      const { t, appCalls } = target();
      for (const name of ["Web", "a%3Bb", "a;b", "-x", "a b", "x".repeat(32), "%23"]) {
        expect(await serve(req("POST", `/apps/${name}/start`), t, tokens, access)).toMatchObject({ status: 404 });
      }
      expect(await serve(req("POST", "/apps/web/kill"), t, tokens, access)).toMatchObject({ status: 404 });
      expect(await serve(req("GET", "/apps/web/start"), t, tokens, access)).toMatchObject({ status: 404 });
      expect(appCalls).toEqual([]);
      const stopped = target(undefined, { ok: false, status: 409, code: "conflict", message: "the task is stopped" }).t;
      expect(await serve(req("POST", "/apps/web/start"), stopped, tokens, access)).toEqual({ status: 409, json: { error: { code: "conflict", message: "the task is stopped" } } });
    });
    it("GET /apps/:name/logs: 200 lines by default, at most 2000, a bad count is 400", async () => {
      const { t, appCalls } = target();
      expect(await serve(req("GET", "/apps/web/logs"), t, tokens, access)).toEqual({ status: 200, json: { lines: ["a", "b"] } });
      await serve(req("GET", "/apps/web/logs", undefined, {}, "lines=5000"), t, tokens, access);
      await serve(req("GET", "/apps/web/logs", undefined, {}, "lines=7"), t, tokens, access);
      for (const q of ["lines=0", "lines=-1", "lines=x", "lines=1.5", "lines="]) {
        expect(await serve(req("GET", "/apps/web/logs", undefined, {}, q), t, tokens, access)).toMatchObject({ status: 400 });
      }
      expect(appCalls).toEqual([["logs", "web", 200], ["logs", "web", 2000], ["logs", "web", 7]]);
    });
    it("POST /app with the agent token records the event; a bad body is 400", async () => {
      const { t, seen } = target();
      expect(await serve(req("POST", "/app", { name: "web", action: "exited", exit_code: 3 }, agent), t, tokens, access)).toEqual({ status: 204 });
      expect(handle(req("POST", "/app", { name: "web", action: "started" }, agent), t, tokens, access)).toEqual({ status: 204 });
      expect(seen).toEqual([{ kind: "app", name: "web", action: "exited", exitCode: 3 }, { kind: "app", name: "web", action: "started", exitCode: null }]);
      for (const b of [{}, { name: "Web", action: "started" }, { name: "a;b", action: "started" }, { name: "web", action: "prepare" },
        { name: "web", action: "started", exit_code: "1" }, { name: "web", action: "started", exit_code: 1.5 }]) {
        expect(handle(req("POST", "/app", b, agent), t, tokens, access)).toMatchObject({ status: 400 });
      }
      expect(seen).toHaveLength(2);
      const refused = target({ ok: false, code: "bad_request", message: "unknown app api" }).t;
      expect(handle(req("POST", "/app", { name: "api", action: "started" }, agent), refused, tokens, access)).toEqual({ status: 400, json: { error: { code: "bad_request", message: "unknown app api" } } });
    });
    it("the agent token cannot reach the control routes", async () => {
      const { t, appCalls } = target();
      for (const [m, p] of [["GET", "/apps"], ["POST", "/apps/web/start"], ["POST", "/apps/web/stop"], ["POST", "/apps/web/restart"], ["GET", "/apps/web/logs"]] as const) {
        expect(await serve(req(m, p, undefined, agent), t, tokens, access)).toMatchObject({ status: 403 });
      }
      expect(appCalls).toEqual([]);
    });
    it("serve answers the other routes as handle does, and 503 until ready", async () => {
      const { t } = target();
      expect(await serve(req("GET", "/status"), t, tokens, access)).toEqual({ status: 200, json: { state: "idle" } });
      expect(await serve(req("GET", "/apps"), { ...t, ready: () => false }, tokens, access)).toMatchObject({ status: 503 });
      expect(await serve(req("GET", "/apps"), t, { task: "x".repeat(20), agent: "y".repeat(20) }, access)).toMatchObject({ status: 401 });
    });
  });
});
