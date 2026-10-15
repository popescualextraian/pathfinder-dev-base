#!/usr/bin/env node
// Scripted ACP agent for the bridge's tests and the smoke test; not a product. Prompts drive it:
//   ASK:<text>        asks the human (POST /ask, or the real agentic-ask with FAKE_ASK=cli), replies "asked <id>"
//   SHELL:<command>   runs the task hook as a harness would (FAKE_HOOK, default /opt/agentic/task/hook.sh) and the
//                     command when allowed; a later "Answer to ..." prompt retries a refused command
//   PERMISSION:<cmd>  asks the client for permission, replies "permission: <optionId|cancelled>"
//   SLEEP:<ms>        a tool call that runs until done or cancelled
//   META              replies with the session's _meta and mode as JSON
//   HISTORY           replies "history: <number of earlier messages>"
//   CRASH             exits with code 3
//   anything else     replies "echo: <prompt>"
//   A first prompt carries a scheduled note after "\n\n[scheduled run]\n"; it is ignored.
//   FAKE_SUMMARY_SLEEP=<ms> delays the reply to the summary prompt (scheduled-run tests).
// Sessions live in $FAKE_AGENT_STATE (default /tmp/fake-agent), so session/load works across processes.
import { createInterface } from "node:readline";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";

const STATE = process.env.FAKE_AGENT_STATE || "/tmp/fake-agent";
mkdirSync(STATE, { recursive: true });
const send = (m) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...m }) + "\n");
const waiting = new Map();
let nextId = 1;
const request = (method, params) => new Promise((resolve) => { const id = nextId++; waiting.set(id, resolve); send({ id, method, params }); });
const update = (sessionId, u) => send({ method: "session/update", params: { sessionId, update: u } });
const say = (sid, text) => update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
const file = (sid) => join(STATE, `${sid}.json`);
const load = (sid) => JSON.parse(readFileSync(file(sid), "utf8"));
const save = (sid, s) => writeFileSync(file(sid), JSON.stringify(s));
const cancelled = new Set();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function hook(command) {
  const payload = JSON.stringify({ tool_name: "Bash", tool_input: { command } });
  const r = spawnSync("bash", [process.env.FAKE_HOOK || "/opt/agentic/task/hook.sh", "claude", "pretooluse"], { input: payload, encoding: "utf8" });
  return r.status === 2 ? (r.stderr || "refused").trim() : null;
}

function shell(sid, s, command, n) {
  const id = `sh-${n}`;
  update(sid, { sessionUpdate: "tool_call", toolCallId: id, title: command, kind: "execute", status: "pending" });
  const refused = hook(command);
  if (refused) {
    update(sid, { sessionUpdate: "tool_call_update", toolCallId: id, status: "failed", content: [{ type: "content", content: { type: "text", text: refused } }] });
    s.lastRefused = command;
    return `refused: ${refused}`;
  }
  const r = spawnSync("bash", ["-c", command], { encoding: "utf8", cwd: process.cwd() });
  update(sid, { sessionUpdate: "tool_call_update", toolCallId: id, status: r.status === 0 ? "completed" : "failed",
    content: [{ type: "content", content: { type: "text", text: (r.stdout || "") + (r.stderr || "") } }] });
  s.lastRefused = null;
  return `ran: ${command} (exit ${r.status})`;
}

async function ask(text) {
  if (process.env.FAKE_ASK === "cli") {
    const r = spawnSync("agentic-ask", [text], { encoding: "utf8" });
    return (r.stdout.match(/Recorded (Q\d+)/) || [])[1] || `failed: ${r.stderr.trim()}`;
  }
  const res = await fetch(`${process.env.AGENTIC_BRIDGE_URL}/ask`, {
    method: "POST",
    headers: { authorization: `Bearer ${process.env.AGENTIC_AGENT_TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify({ text }),
  });
  return (await res.json()).id;
}

async function prompt(sid, text) {
  if (process.env.FAKE_SUMMARY_SLEEP && text.includes("The run ends now")) await sleep(Number(process.env.FAKE_SUMMARY_SLEEP));
  const s = load(sid);
  const before = s.history.length;
  s.history.push({ role: "user", text });
  cancelled.delete(sid);
  let reply = `echo: ${text}`;
  let stopReason = "end_turn";
  if (text.startsWith("ASK:")) reply = `asked ${await ask(text.slice(4))}`;
  else if (text.startsWith("SHELL:")) reply = shell(sid, s, text.slice(6), before);
  else if (text.startsWith("Answer to") && s.lastRefused) reply = shell(sid, s, s.lastRefused, before);
  else if (text.startsWith("PERMISSION:")) {
    const cmd = text.slice(11);
    const r = await request("session/request_permission", {
      sessionId: sid,
      toolCall: { toolCallId: `perm-${before}`, title: cmd, kind: "execute", status: "pending", rawInput: { command: cmd } },
      options: [
        { optionId: "allow-once", name: "Yes", kind: "allow_once" },
        { optionId: "allow-always", name: "Always", kind: "allow_always" },
        { optionId: "reject", name: "No", kind: "reject_once" },
      ],
    });
    reply = `permission: ${r.outcome.outcome === "selected" ? r.outcome.optionId : "cancelled"}`;
  } else if (text.startsWith("SLEEP:")) {
    update(sid, { sessionUpdate: "tool_call", toolCallId: `sleep-${before}`, title: "sleep", kind: "execute", status: "in_progress" });
    const end = Date.now() + Number(text.slice(6));
    while (Date.now() < end && !cancelled.has(sid)) await sleep(50);
    if (cancelled.has(sid)) { stopReason = "cancelled"; reply = ""; }
    else reply = "slept";
  } else if (text === "META") reply = JSON.stringify({ meta: s.meta, mode: s.mode });
  else if (text === "HISTORY") reply = `history: ${before}`;
  else if (text === "CRASH") process.exit(3);
  if (reply) { say(sid, reply); s.history.push({ role: "agent", text: reply }); }
  save(sid, s);
  return { stopReason };
}

async function handle(rpc) {
  if (rpc.id !== undefined && !rpc.method) { waiting.get(rpc.id)?.(rpc.result); waiting.delete(rpc.id); return; }
  const p = rpc.params || {};
  const reply = (result) => send({ id: rpc.id, result });
  switch (rpc.method) {
    case "initialize": return reply({ protocolVersion: 1, agentCapabilities: { loadSession: true }, authMethods: [] });
    case "session/new": {
      const sid = randomUUID();
      save(sid, { history: [], meta: p._meta ?? null, mode: "default", lastRefused: null });
      return reply({ sessionId: sid });
    }
    case "session/load": {
      if (!existsSync(file(p.sessionId))) return send({ id: rpc.id, error: { code: -32002, message: `session ${p.sessionId} not found` } });
      const s = load(p.sessionId);
      if (p._meta) { s.meta = p._meta; save(p.sessionId, s); }
      for (const h of s.history) update(p.sessionId, { sessionUpdate: h.role === "user" ? "user_message_chunk" : "agent_message_chunk", content: { type: "text", text: h.text } });
      return reply({});
    }
    case "session/set_mode": { const s = load(p.sessionId); s.mode = p.modeId; save(p.sessionId, s); return reply({}); }
    case "session/set_config_option": return reply({ configOptions: [] });
    case "session/prompt": return reply(await prompt(p.sessionId, p.prompt.map((b) => b.text ?? "").join("").split("\n\n[scheduled run]\n")[0]));
    case "session/cancel": cancelled.add(p.sessionId); return;
    default: if (rpc.id !== undefined) send({ id: rpc.id, error: { code: -32601, message: `${rpc.method} not supported` } });
  }
}

createInterface({ input: process.stdin }).on("line", (line) => { if (line.trim()) void handle(JSON.parse(line)); });
