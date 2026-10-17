// Named agent sessions of one task: records, names, the upgrade of old records (spec D5, D13).
import type { Question, SessionRecord, SessionState, State, TaskRecord } from "./types.js";

export const MAIN = "main";
export const NAME_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/;
export const MAX_SESSIONS = 16;

export interface SessionView {
  name: string; session: string | null; model: string | null; state: State; reason: string;
  summary: string; inbox: number; fork_of: string | null; created: string; updated: string;
}

export function newSession(
  name: string, model: string | null, now: string, over: Partial<SessionRecord> = {},
): SessionRecord {
  return {
    name, session: null, model, state: "idle", reason: "", inbox: [], summary: "",
    fork_of: null, created: now, updated: now, ...over,
  };
}

const KEPT: readonly string[] = ["starting", "running", "waiting", "idle", "interrupted"];

// An old record (no sessions array) becomes one main session. state.json is agent-writable:
// sessions with a bad name are dropped, and a record left without main gets one rebuilt.
export function upgradeRecord(raw: unknown): TaskRecord {
  const r = raw as Record<string, unknown> & Partial<TaskRecord> & { inbox?: SessionRecord["inbox"] };
  const { inbox, ...rest } = r;
  const main = () => newSession(MAIN, r.model ?? null, r.created ?? "", {
    session: r.session ?? null, state: (KEPT.includes(String(r.state)) ? r.state : "idle") as SessionState,
    reason: r.reason ?? "", inbox: Array.isArray(r.sessions) ? [] : inbox ?? [], summary: r.summary ?? "",
    updated: r.updated ?? r.created ?? "",
  });
  if (!Array.isArray(r.sessions)) return { ...rest, sessions: [main()], capabilities: null } as TaskRecord;
  const sessions = (r.sessions as unknown[]).filter((s): s is SessionRecord =>
    typeof (s as SessionRecord | null)?.name === "string" && NAME_RE.test((s as SessionRecord).name));
  if (!sessions.some((s) => s.name === MAIN)) sessions.unshift(main());
  return { ...r, sessions, capabilities: r.capabilities ?? null } as TaskRecord;
}

export function upgradeQuestion(raw: Question): Question {
  return { ...raw, session: raw.session ?? MAIN };
}

export function deriveState(
  sessions: SessionRecord[], openQuestions: number, agentStarting: boolean,
): "starting" | "running" | "waiting" | "idle" {
  if (agentStarting) return "starting";
  if (sessions.some((s) => s.state === "running" || s.state === "starting")) return "running";
  return openQuestions > 0 ? "waiting" : "idle";
}

export function sessionView(s: SessionRecord): SessionView {
  const { inbox, ...rest } = s;
  return { ...rest, inbox: inbox.length };
}
