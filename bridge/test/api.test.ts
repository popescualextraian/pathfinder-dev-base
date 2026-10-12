import { describe, expect, it } from "vitest";
import { handle, checkAccess, type ApiTarget, type ApiRequest } from "../src/api.js";
import type { Input, Outcome } from "../src/task.js";

const tokens = { task: "task-token-0123456789", agent: "agent-token-0123456789" };
const access = { hosts: ["bridge.internal"], origins: [] as string[] };
function target(outcome: Outcome = { ok: true, effects: [] }) {
  const seen: Input[] = [];
  const t: ApiTarget = {
    ready: () => true,
    status: () => ({ state: "idle" }),
    command: (i) => { seen.push(i); return outcome; },
    events: (since, limit) => Array.from({ length: 5 }, (_, k) => ({ seq: k + 1 })).filter((e) => e.seq > since).slice(0, limit) as never,
  };
  return { t, seen };
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
    expect(handle(req("POST", "/prompt", "x".repeat(1048577)), t, tokens, access)).toMatchObject({ status: 400, json: { error: { message: "body too large" } } });
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
    expect(handle(req("GET", "/events", undefined, {}, "since=2&limit=2"), t, tokens, access)).toEqual({ status: 200, ndjson: [{ seq: 3 }, { seq: 4 }] });
    expect(handle(req("GET", "/events", undefined, {}, "since=x"), t, tokens, access)).toMatchObject({ status: 400 });
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
});
