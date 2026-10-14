// Shared types of the bridge (spec §5.2, §8.3).
export type AgentName = "claude" | "copilot";
export type State =
  | "starting" | "running" | "waiting" | "idle" | "suspended" | "stopped" | "failed" | "interrupted";
export type EventType = "state" | "message" | "tool" | "plan" | "question" | "answer" | "gate" | "error";

export interface PermissionOption {
  optionId: string;
  name: string;
  kind: string;
}

export interface Question {
  id: string;
  source: "permission" | "ask";
  text: string;
  options: string[];
  recommendation: string | null;
  asked: string;
  status: "open" | "answered";
  answer?: string;
  grant?: string[];
  answered?: string;
  permission?: { options: PermissionOption[] };
}

export interface InboxItem {
  kind: "prompt" | "answer";
  text: string;
  question?: string;
}

export interface TaskRecord {
  version: 1;
  task: string;
  project: string;
  agent: AgentName;
  model: string | null;
  state: State;
  reason: string;
  session: string | null;
  branch: string | null;
  target: string | null;
  work: string;
  worktree: string | null;
  container: string | null;
  created_container: boolean;
  auto_clean: boolean;
  cleaned: boolean;
  created: string;
  updated: string;
  seq: number;
  allowed_actions: string[];
  inbox: InboxItem[];
  summary: string;
  stopped_by_user: boolean;
}

export interface TaskEvent {
  seq: number;
  ts: string;
  task: string;
  session: string | null;
  agent: AgentName;
  type: EventType;
  data: Record<string, unknown>;
}
