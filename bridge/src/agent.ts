// One agent process and its ACP connection (spec §7). Replayed history during session/load is dropped.
import { spawn, type ChildProcess } from "node:child_process";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk";
import type { HarnessSpec } from "./harness.js";
import type { Update } from "./map.js";
import type { PermissionOption } from "./types.js";

export interface PermissionAsk {
  title: string;
  command: string;
  options: PermissionOption[];
}

export interface AgentHooks {
  onUpdate(u: Update): void;
  onPermission(req: PermissionAsk): Promise<string | null>;
  onExit(error: string): void;
  onStderr?(chunk: string): void;
}

export interface AgentLike {
  start(): Promise<void>;
  newSession(): Promise<string>;
  loadSession(id: string): Promise<void>;
  prompt(text: string): Promise<string>;
  cancel(): void;
  kill(): Promise<void>;
}

export class AgentProcess implements AgentLike {
  private child: ChildProcess | null = null;
  private conn: acp.ClientConnection | null = null;
  private sessionId: string | null = null;
  private loading = false;
  private killing = false;
  private inFlight = false;
  private exitReported = false;
  private spawnError: Error | null = null;
  private exited: Promise<void> = Promise.resolve();

  constructor(
    private readonly spec: HarnessSpec,
    private readonly opts: { cwd: string; env: NodeJS.ProcessEnv; paragraph: string; model: string | null },
    private readonly hooks: AgentHooks,
  ) {}

  async start(): Promise<void> {
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
        if (!this.loading) this.hooks.onUpdate(ctx.params.update as unknown as Update);
      })
      .onRequest(acp.methods.client.session.requestPermission, async (ctx) => {
        const p = ctx.params;
        const raw = p.toolCall.rawInput as { command?: unknown } | undefined;
        const options = p.options.map((o) => ({ optionId: o.optionId, name: o.name, kind: o.kind }));
        let optionId: string | null = null;
        try {
          optionId = await this.hooks.onPermission({
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
      await this.conn.agent.request(acp.methods.agent.initialize, {
        protocolVersion: acp.PROTOCOL_VERSION,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
      });
    } catch (err) {
      // A failed spawn surfaces first as a broken pipe; report the real cause.
      await new Promise((r) => setImmediate(r));
      throw this.spawnError ?? err;
    }
  }

  async newSession(): Promise<string> {
    const meta = this.spec.sessionMeta(this.opts.paragraph);
    const r = await this.agent().request(acp.methods.agent.session.new, {
      cwd: this.opts.cwd, mcpServers: [], ...(meta ? { _meta: meta } : {}),
    });
    this.sessionId = r.sessionId;
    await this.spec.afterSession(this.calls(), r.sessionId, this.opts.model);
    return r.sessionId;
  }

  async loadSession(id: string): Promise<void> {
    const meta = this.spec.sessionMeta(this.opts.paragraph);
    this.loading = true;
    try {
      await this.agent().request(acp.methods.agent.session.load, {
        sessionId: id, cwd: this.opts.cwd, mcpServers: [], ...(meta ? { _meta: meta } : {}),
      });
    } finally {
      this.loading = false;
    }
    this.sessionId = id;
    await this.spec.afterSession(this.calls(), id, this.opts.model);
  }

  async prompt(text: string): Promise<string> {
    const sessionId = this.session();
    this.inFlight = true;
    try {
      const r = await this.agent().request(acp.methods.agent.session.prompt, { sessionId, prompt: [{ type: "text", text }] });
      return r.stopReason;
    } finally {
      this.inFlight = false;
    }
  }

  cancel(): void {
    if (this.conn && this.sessionId && this.inFlight) this.conn.agent.notify(acp.methods.agent.session.cancel, { sessionId: this.sessionId }).catch(() => {}); // the connection may close right after
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

  private session(): string {
    if (!this.sessionId) throw new Error("no session");
    return this.sessionId;
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
