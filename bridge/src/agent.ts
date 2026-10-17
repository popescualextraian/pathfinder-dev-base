// One agent process and its ACP connection (spec §7). Replayed history during session/load is dropped.
import { spawn, type ChildProcess } from "node:child_process";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk";
import type { HarnessSpec } from "./harness.js";
import type { Update } from "./map.js";
import type { AgentCaps, PermissionOption } from "./types.js";

export interface PermissionAsk {
  sessionId: string;
  title: string;
  command: string;
  options: PermissionOption[];
}

export interface AgentHooks {
  onUpdate(sessionId: string, u: Update): void;
  onPermission(req: PermissionAsk): Promise<string | null>;
  onExit(error: string): void;
  onStderr?(chunk: string): void;
}

export interface AgentLike {
  start(): Promise<AgentCaps>;
  newSession(model: string | null): Promise<string>;
  loadSession(id: string, model: string | null): Promise<void>;
  forkSession(id: string, model: string | null): Promise<string>; // session/fork, then session/load of the new id
  prompt(sessionId: string, text: string): Promise<string>;
  cancel(sessionId: string): void;
  kill(): Promise<void>;
}

export class AgentProcess implements AgentLike {
  private child: ChildProcess | null = null;
  private conn: acp.ClientConnection | null = null;
  private loading = new Set<string>(); // sessions whose replay is muted
  private inFlight = new Set<string>(); // sessions with a turn running
  private canFork = false;
  private killing = false;
  private exitReported = false;
  private spawnError: Error | null = null;
  private exited: Promise<void> = Promise.resolve();

  constructor(
    private readonly spec: HarnessSpec,
    private readonly opts: { cwd: string; env: NodeJS.ProcessEnv; paragraph: string },
    private readonly hooks: AgentHooks,
  ) {}

  async start(): Promise<AgentCaps> {
    const [cmd, ...args] = this.spec.command;
    if (!cmd) throw new Error("empty agent command");
    const child = spawn(cmd, args, { cwd: this.opts.cwd, env: { ...this.opts.env, ...this.spec.env }, stdio: ["pipe", "pipe", "pipe"] });
    this.child = child;
    this.exited = new Promise((resolve) => {
      // 'exit' and 'error' can both fire: report once.
      const report = (error: string): void => {
        if (this.killing || this.exitReported) return;
        this.exitReported = true;
        this.hooks.onExit(error);
      };
      child.on("exit", (code, signal) => {
        report(`agent exited with code ${code ?? signal}`);
        resolve();
      });
      child.on("error", (err) => {
        this.spawnError = err;
        report(`agent could not start: ${err.message}`);
        resolve();
      });
    });
    child.stderr?.on("data", (d: Buffer) => this.hooks.onStderr?.(d.toString()));
    const stream = acp.ndJsonStream(
      Writable.toWeb(child.stdin!) as WritableStream<Uint8Array>,
      Readable.toWeb(child.stdout!) as ReadableStream<Uint8Array>,
    );
    this.conn = acp
      .client({ name: "agentic-bridge" })
      .onNotification(acp.methods.client.session.update, (ctx) => {
        if (!this.loading.has(ctx.params.sessionId)) this.hooks.onUpdate(ctx.params.sessionId, ctx.params.update as unknown as Update);
      })
      .onRequest(acp.methods.client.session.requestPermission, async (ctx) => {
        const p = ctx.params;
        const raw = p.toolCall.rawInput as { command?: unknown } | undefined;
        const options = p.options.map((o) => ({ optionId: o.optionId, name: o.name, kind: o.kind }));
        let optionId: string | null = null;
        try {
          optionId = await this.hooks.onPermission({
            sessionId: p.sessionId,
            title: p.toolCall.title ?? "",
            command: typeof raw?.command === "string" ? raw.command : "",
            options,
          });
        } catch {
          optionId = null; // a failing hook must not close the connection
        }
        const ok = optionId !== null && options.some((o) => o.optionId === optionId);
        return { outcome: ok ? { outcome: "selected" as const, optionId: optionId as string } : { outcome: "cancelled" as const } };
      })
      .connect(stream);
    try {
      const init = await this.conn.agent.request(acp.methods.agent.initialize, {
        protocolVersion: acp.PROTOCOL_VERSION,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
      });
      this.canFork = !!init.agentCapabilities?.sessionCapabilities?.fork;
      return { fork: this.canFork };
    } catch (err) {
      // A failed spawn surfaces first as a broken pipe; report the real cause.
      await new Promise((r) => setImmediate(r));
      throw this.spawnError ?? err;
    }
  }

  async newSession(model: string | null): Promise<string> {
    const meta = this.spec.sessionMeta(this.opts.paragraph);
    const r = await this.agent().request(acp.methods.agent.session.new, {
      cwd: this.opts.cwd, mcpServers: [], ...(meta ? { _meta: meta } : {}),
    });
    await this.spec.afterSession(this.calls(), r.sessionId, model);
    return r.sessionId;
  }

  async loadSession(id: string, model: string | null): Promise<void> {
    const meta = this.spec.sessionMeta(this.opts.paragraph);
    this.loading.add(id);
    try {
      await this.agent().request(acp.methods.agent.session.load, {
        sessionId: id, cwd: this.opts.cwd, mcpServers: [], ...(meta ? { _meta: meta } : {}),
      });
    } finally {
      this.loading.delete(id);
    }
    await this.spec.afterSession(this.calls(), id, model);
  }

  async forkSession(id: string, model: string | null): Promise<string> {
    if (!this.canFork) throw new Error(`${this.spec.name} does not support forking a session`);
    const r = await this.agent().request(acp.methods.agent.session.fork, { sessionId: id, cwd: this.opts.cwd, mcpServers: [] });
    await this.loadSession(r.sessionId, model); // a forked id must be loaded before it takes prompts
    return r.sessionId;
  }

  async prompt(sessionId: string, text: string): Promise<string> {
    this.inFlight.add(sessionId);
    try {
      const r = await this.agent().request(acp.methods.agent.session.prompt, { sessionId, prompt: [{ type: "text", text }] });
      return r.stopReason;
    } finally {
      this.inFlight.delete(sessionId);
    }
  }

  cancel(sessionId: string): void {
    if (this.conn && this.inFlight.has(sessionId)) this.conn.agent.notify(acp.methods.agent.session.cancel, { sessionId }).catch(() => {}); // the connection may close right after
  }

  async kill(): Promise<void> {
    if (!this.child) return;
    this.killing = true;
    this.conn?.close();
    this.child.kill("SIGTERM");
    const timer = setTimeout(() => this.child?.kill("SIGKILL"), 5000);
    await this.exited;
    clearTimeout(timer);
  }

  private agent(): acp.ClientContext {
    if (!this.conn) throw new Error("agent not started");
    return this.conn.agent;
  }

  private calls() {
    return {
      setMode: async (sessionId: string, modeId: string) => {
        await this.agent().request(acp.methods.agent.session.setMode, { sessionId, modeId });
      },
      setConfigOption: async (sessionId: string, configId: string, value: string) => {
        await this.agent().request(acp.methods.agent.session.setConfigOption, { sessionId, configId, value });
      },
    };
  }
}
