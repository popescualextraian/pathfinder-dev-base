# Several agent sessions in one task: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A task holds several named native agent sessions (`main` first), each prompted, answered,
cancelled and followed on its own, optionally with its own model, forked on Claude, running in
parallel.

**Architecture:** One agent process per task hosts all sessions over one ACP connection. The pure
state machine (`task.ts`) keeps per-session turn state and derives the task state; the orchestrator
(`bridge.ts`) routes ACP updates and requests by session id. The API gains `/sessions` and an
optional `session` on the existing routes; the host CLI relays.

**Tech Stack:** TypeScript (strict, vitest, eslint), `@agentclientprotocol/sdk` 1.8.0, bash + bats,
jq.

**Spec:** `docs/specs/2026-10-17-task-sessions-design.md` (decisions D1–D16 are cited by number).

## Global Constraints

- CLAUDE.md: thin host CLI; no company resources; bash `set -euo pipefail`, shellcheck-clean; a test
  for every behaviour, **written first**; no new dependencies; no `Co-Authored-By` lines.
- Session names: `/^[a-z0-9][a-z0-9_-]{0,31}$/`; the first session is `main`; at most 16 per task.
- Refusal texts (exact): `"<agent> does not support forking a session"`,
  `"<FROM> is running; fork it when it is idle"`,
  `"its conversation could not be restored: <error>"` (session reason, D12).
- Every verb without `--session` behaves as today (on `main`; `answer` takes the oldest open
  question of any session).
- Tasks 1–3 change shared types; `tsc` (`npm run lint`) is expected to fail on `bridge.ts` until
  Task 4 ends. Each task's own vitest file must pass. From Task 4 on, `cd bridge && npm test &&
  npm run lint` is green after every task.

## Review Focus

1. A per-session `idle` event must not end `follow` without `--session`, nor arm auto-clean while
   another session runs → tests in Tasks 4 and 6.
2. A record written before this change (no `sessions`, top-level `inbox`) must boot, resume and
   show in `status`, from the bridge and from the host → tests in Tasks 1, 4 and 8.
3. A permission request from session B while `main` is mid-turn notifies at once and is answerable
   by `answer ID` (oldest question) → tests in Tasks 3 and 4.
4. `stop`, the idle timeout and an agent crash with two sessions mid-turn: both turns' texts go
   back to their own inbox, both sessions become `interrupted`, a resume reaches both → tests in
   Tasks 3 and 4.
5. `--session` with an unknown name is a clean 404 message on every verb, never a silent fallback
   to `main` → tests in Tasks 5 and 8.

---

### Task 1: Session types and record upgrade

**Files:**
- Modify: `bridge/src/types.ts`
- Create: `bridge/src/sessions.ts`
- Test: `bridge/test/sessions.test.ts`

**Interfaces:**
- Produces (types.ts):
  ```ts
  export type SessionState = "starting" | "running" | "waiting" | "idle" | "interrupted" | "failed";
  export interface SessionRecord {
    name: string; session: string | null; model: string | null; state: SessionState; reason: string;
    inbox: InboxItem[]; summary: string; fork_of: string | null; created: string; updated: string;
  }
  export interface AgentCaps { fork: boolean }
  // TaskRecord: `inbox` removed; adds `sessions: SessionRecord[]`, `capabilities: AgentCaps | null`.
  // `session` stays (main's id, D13); `summary` stays (the last ended turn's summary, any session).
  // Question: adds `session: string` (a name). TaskEvent: adds `name: string | null`.
  ```
- Produces (sessions.ts):
  ```ts
  export const MAIN = "main"; export const NAME_RE: RegExp; export const MAX_SESSIONS = 16;
  export interface SessionView { name; session; model; state; reason; summary; inbox: number; fork_of; created; updated }
  export function newSession(name: string, model: string | null, now: string, over?: Partial<SessionRecord>): SessionRecord;
  export function upgradeRecord(raw: unknown): TaskRecord;   // D13
  export function upgradeQuestion(raw: Question): Question;  // session ?? "main"
  export function deriveState(sessions: SessionRecord[], openQuestions: number, agentStarting: boolean): "starting" | "running" | "waiting" | "idle";
  export function sessionView(s: SessionRecord): SessionView;
  ```

- [ ] **Step 1: Write the failing tests** in `bridge/test/sessions.test.ts`:
  - `upgradeRecord turns an old record into one main session`: input with `session: "s1"`,
    `inbox: [{kind:"prompt",text:"x"}]`, `summary: "did y"`, `state: "idle"`, no `sessions` →
    `sessions` equals `[{name:"main", session:"s1", inbox:[{kind:"prompt",text:"x"}], summary:"did y", state:"idle", model: <record model>, fork_of:null, ...}]`,
    no `inbox` key, `capabilities: null`.
  - `upgradeRecord maps task states onto main`: `running|waiting|idle|starting` kept;
    `interrupted` → `interrupted`; `suspended|stopped|failed` → `idle`.
  - `upgradeRecord keeps a record that has sessions` (deep-equal to input).
  - `upgradeQuestion defaults the session to main`.
  - `deriveState`: agentStarting → `starting`; any `running` or `starting` session → `running`;
    else open questions > 0 → `waiting`; else `idle` (an `interrupted`/`failed` session counts as idle).
  - `NAME_RE accepts main, plan-2, a_b and refuses "", "-x", "A", 33 chars, "../x"`.
  - `sessionView reports the inbox as a count`.
- [ ] **Step 2:** `cd bridge && npx vitest run test/sessions.test.ts` → FAIL (module missing).
- [ ] **Step 3:** Implement `types.ts` changes and `sessions.ts`. `upgradeRecord` copies the old
  top-level `inbox`/`session`/`summary` into `main` only when `sessions` is not an array.
- [ ] **Step 4:** Same command → PASS.
- [ ] **Step 5:** Commit `feat(bridge): session records, names and the upgrade of old task records`.

### Task 2: A multi-session agent process

**Files:**
- Modify: `bridge/src/agent.ts`, `bridge/src/harness.ts`, `bridge/test/fake-agent.mjs`
- Test: `bridge/test/agent.test.ts`

**Interfaces:**
- Consumes: `AgentCaps` (Task 1).
- Produces:
  ```ts
  export interface PermissionAsk { sessionId: string; title: string; command: string; options: PermissionOption[] }
  export interface AgentHooks { onUpdate(sessionId: string, u: Update): void; onPermission(req: PermissionAsk): Promise<string | null>; onExit(error: string): void; onStderr?(chunk: string): void }
  export interface AgentLike {
    start(): Promise<AgentCaps>;
    newSession(model: string | null): Promise<string>;
    loadSession(id: string, model: string | null): Promise<void>;
    forkSession(id: string, model: string | null): Promise<string>; // session/fork, then session/load of the new id
    prompt(sessionId: string, text: string): Promise<string>;
    cancel(sessionId: string): void;
    kill(): Promise<void>;
  }
  // AgentProcess constructor opts: { cwd, env, paragraph } (model moves to the calls).
  ```
- Fake agent additions: `initialize` advertises `sessionCapabilities: { fork: {} }` unless
  `FAKE_NO_FORK=1`; `session/fork` copies the source's state file to a new id and replies
  `{sessionId}`; `session/set_config_option` with `configId: "model"` stores it; prompt `MODEL`
  replies `model: <value|none>`; the fetch in `ask()` sends `session: sid` and the `FAKE_ASK=cli`
  path runs `agentic-ask` with `CLAUDE_CODE_SESSION_ID=<sid>` in its env.

- [ ] **Step 1: Write the failing tests** in `agent.test.ts` (existing cases updated to the new
  signatures):
  - `start reports fork capability` → `{fork: true}`; with `FAKE_NO_FORK=1` → `{fork: false}`.
  - `two sessions prompt at once`: `newSession` ×2, `Promise.all` of `SLEEP:300` on both → both
    `end_turn`; `onUpdate` was called with each session id.
  - `each session gets its own model`: `newSession("m1")`, `newSession(null)`; `MODEL` replies
    `model: m1` and `model: none`.
  - `forkSession returns a loaded new id with the history`: prompt `a` on s1, fork → s2 ≠ s1,
    `HISTORY` on s2 replies `history: 2`.
  - `forkSession refuses without the capability` → rejects with `"claude does not support forking a session"` (spec name from `HarnessSpec.name`).
  - `replay of a load is muted for that session only`: s1 runs `SLEEP:300` emitting updates while
    `loadSession(s2)` replays; no replayed s2 text reaches `onUpdate`, s1's tool updates do.
  - `a permission request carries its session id`.
  - `cancel(sessionId) cancels only that session's turn`.
- [ ] **Step 2:** `npx vitest run test/agent.test.ts` → FAIL.
- [ ] **Step 3:** Implement. Keep `agentCapabilities.sessionCapabilities?.fork` presence as
  `fork`; replace the single `loading` flag with a `Set<string>` of loading session ids; drop
  `sessionId`/`inFlight` fields for a `Set<string>` of sessions with a turn in flight (cancel only
  notifies those). `harness.ts`: Copilot's `afterSession` sets `model` with `setConfigOption` when
  given (D9); its `--model` flag stays.
- [ ] **Step 4:** Same command → PASS.
- [ ] **Step 5:** Commit `feat(bridge): one agent process hosts several sessions; fork by capability`.

### Task 3: The state machine per session

**Files:**
- Modify: `bridge/src/task.ts`
- Test: `bridge/test/task.test.ts`

**Interfaces:**
- Consumes: Task 1 types and helpers.
- Produces:
  ```ts
  export type Input =
    | { kind: "boot"; fresh: boolean }
    | { kind: "userPrompt"; text: string; session?: string }
    | { kind: "answer"; question?: string; text: string; grant: string[]; session?: string }
    | { kind: "cancel"; session?: string }
    | { kind: "stop"; reason?: string; byUser?: boolean }
    | { kind: "ask"; text: string; options: string[]; recommend: string | null; sessionId?: string }
    | { kind: "permissionRequest"; sessionId: string; title: string; command: string; options: PermissionOption[] }
    | { kind: "addSession"; name: string; model: string | null; fork: string | null; text: string | null }
    | { kind: "agentStarted"; capabilities: AgentCaps }
    | { kind: "sessionReady"; name: string; session: string; seed?: string }
    | { kind: "sessionLost"; name: string; error: string }
    | { kind: "turnEnd"; name: string; stopReason: string; summary: string }
    | { kind: "agentExit"; error: string }
    | { kind: "idleTimeout" }
    | { kind: "gate"; rule: string; command: string; sessionId?: string };
  export type Effect =
    | { kind: "startAgent" }
    | { kind: "open"; name: string; mode: "new" | "load" | "fork"; from: string | null; model: string | null }
    | { kind: "prompt"; name: string; session: string; text: string }
    | { kind: "cancel"; session: string }
    | { kind: "permission"; question: string; optionId: string | null }
    | { kind: "kill" } | { kind: "exit"; code: number }
    | { kind: "emit"; type: EventType; data: Record<string, unknown>; name: string | null }
    | { kind: "question"; question: Question } | { kind: "timer"; on: boolean }
    | { kind: "notify"; question: Question | null };
  // Outcome unchanged; addSession's value is { id: <name> }.
  // TaskMachine public: record, questions, openQuestions(), dormant(), busy(name = MAIN): boolean
  // (a turn outstanding or the session opening; replaces the `promptOutstanding` field the bridge reads).
  ```

Rules the tests pin (spec refs):
- Live per-session flags stay in memory (`Map<name, {outstanding, text, cancelling, pending:Set, loaded, opening}>`); the agent's `live`/`starting` are task-wide.
- `deliver(name)`: inbox empty or turn outstanding → nothing; agent not live → `startAgent` once,
  session `starting`; agent live but session not loaded → `open` (`load` when it has an id, else
  `new`); else `prompt` with the joined inbox. `agentStarted` sets `record.capabilities` and opens
  every session with a non-empty inbox or a pending fork.
- Task state: `starting` while the agent starts; terminal states as today; else
  `deriveState(...)` after every input. A task-level `state` emit (`name: null`) only when it
  changes; per-session `state` emits carry the name.
- D15: every new question emits `notify` with it; `waiting` is removed from the task-state notify
  list (`idle`, `failed`, `stopped` remain).
- D8: `ask`/`permissionRequest` map `sessionId` to a name (unknown/missing → `main`); the
  question's `session` is that name; a non-permission answer goes into that session's inbox.
- D10: `addSession` with `fork` refuses `409` when the source is busy, when
  `record.capabilities` is null (`"the agent is still starting; try again when the task is idle"`),
  or `!capabilities.fork` (`"<agent> does not support forking a session"`); `404` for an unknown
  source; `400` bad name; `409` name in use, 16 reached, task `stopped`, `record.scheduled`.
- D12: `sessionLost` → that session `failed` with reason `its conversation could not be restored: <error>`;
  `userPrompt`/`answer` to a failed session → `409 "<name> failed: <reason>; add a new session"`.
  `sessionReady` with `seed` unshifts it into that session's inbox (the bridge passes it for `main`).
- D16: `agentExit` and `stop` and `idleTimeout`: each session with a turn outstanding gets its
  text back at its inbox head; on `agentExit` those sessions become `interrupted`. At a non-fresh
  boot, sessions recorded `running`/`starting` become `interrupted`. A `userPrompt` to `main` while
  the task is `interrupted` or `failed` also appends the same text to every other session that is
  `interrupted` or has a non-empty inbox, and delivers each.
- D14: `userPrompt`/`addSession` naming a session other than `main` on a scheduled task → 409.

- [ ] **Step 1: Write the failing tests.** Update the existing `task.test.ts` cases to the new
  inputs (`agentStarted` + `sessionReady {name:"main"}` replace `agentReady`; `turnEnd` gets
  `name: "main"`; `rec()` builds `sessions: [newSession("main", null, "t0", {inbox:[...]})]`), then
  add, each asserting effects and `record.sessions` states:
  - `a second session opens on the live agent and prompts while main runs` → effects
    `open{name:"plan",mode:"new"}`, then after `sessionReady` a `prompt{name:"plan"}`; task stays `running`.
  - `the task is idle only when no session runs`.
  - `a permission request from plan while main runs notifies at once and is answered by answer without an id`.
  - `ask with an unknown session id lands on main`.
  - `cancel without a session cancels main only`.
  - `fork refuses a running source, unknown capabilities, and an agent without fork` (exact texts).
  - `names: bad name 400, duplicate 409, the 17th session 409`.
  - `a lost session fails alone; prompting it says to add a new session`.
  - `agent exit with two turns outstanding requeues both texts and interrupts both`.
  - `a resume prompt to main also reaches every interrupted session`.
  - `a non-fresh boot interrupts sessions recorded running`.
  - `sessions reload lazily: after boot only the prompted session is opened, with mode load`.
  - `a scheduled task refuses other sessions`.
- [ ] **Step 2:** `npx vitest run test/task.test.ts` → FAIL.
- [ ] **Step 3:** Implement in `task.ts`.
- [ ] **Step 4:** Same command → PASS.
- [ ] **Step 5:** Commit `feat(bridge): the task machine keeps turn state per session`.

### Task 4: Orchestrate sessions in the bridge

**Files:**
- Modify: `bridge/src/bridge.ts`, `bridge/src/main.ts`, `bridge/src/store.ts` (questions upgrade on read)
- Test: `bridge/test/bridge.test.ts`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `Bridge.sessions(): SessionView[]`; `Bridge.events(since, limit, session?: string)`
  (filters by `name`); `status()` adds `sessions` (views), `inbox` = sum, each question's `session`.
  `emit(type, data, name: string | null)` sets the event's `session` to that session's id (null
  for task-level) and `name`.

Behaviour: boot reads `upgradeRecord(store.readRecord())`; a fresh record gets
`sessions: [newSession("main", config.model, now, {inbox: [first prompt]})]`. Perform `startAgent`
(start, then `agentStarted`), `open` (`newSession` / `loadSession` / `forkSession`, then
`sessionReady`; a failed `load` of `main` falls back to `newSession` with `seed: this.seed()`; any
other failure → `sessionLost`), `prompt` (per-session `UpdateMapper` in a `Map<name, UpdateMapper>`;
`turnEnd` with that name), `cancel{session}`. Hooks route `onUpdate(sessionId)` and permissions by
the session id. The scheduled-run steps and `cleanable` look at `main` / all inboxes. `main.ts`
builds `AgentProcess` without `model`.

- [ ] **Step 1: Write the failing tests** (existing ones updated where `record.inbox` or
  `session` were read):
  - `two sessions run in parallel and both reach idle` (fake `SLEEP:300` on each, events tagged
    with both names, one task-level `idle` at the end).
  - `a second session uses its own model` (`MODEL` → `model: m2`).
  - `fork copies main's conversation` (`HISTORY` in the fork equals main's count).
  - `fork on an agent without fork is refused with the exact text` (`FAKE_NO_FORK=1`).
  - `an ask through agentic-ask's session id reaches the asking session` (fake posts `session`).
  - `the webhook fires on a question while another session runs` (one call per question).
  - `suspend and resume reload only the prompted session` (second bridge; `open` mode `load`).
  - `a lost non-main session fails alone; main's loss still falls back with the seed`.
  - `an old record without sessions boots and resumes` (fixture under `bridge/test/fixtures/`).
  - `auto-clean waits until every session is idle`.
- [ ] **Step 2:** `npx vitest run test/bridge.test.ts` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `cd bridge && npm test && npm run lint` → all PASS, tsc and eslint clean.
- [ ] **Step 5:** Commit `feat(bridge): run several sessions of one task through one agent`.

### Task 5: API routes and session parameters

**Files:**
- Modify: `bridge/src/api.ts`
- Test: `bridge/test/api.test.ts`, `bridge/test/server.test.ts`

**Interfaces:**
- Consumes: `ApiTarget` gains `sessions(): SessionView[]` and
  `events(since: number, limit: number, session?: string): TaskEvent[]`.
- Routes (spec §4): `GET /sessions` → 200 list; `POST /sessions {name, model?, fork?, text?}` →
  201 the new view (`target.sessions().find(name)`); `POST /prompt|/cancel {session?}`;
  `POST /answer {session?}`; `POST /ask {session?}` (an ACP id → `sessionId`);
  `POST /gate {session?}` (→ `sessionId`); `GET /events?session=NAME`. Type checks: `session`,
  `model`, `fork`, `text` strings when present, else 400. The agent token still reaches only
  `/ask` and `/gate`.

- [ ] **Step 1: Write the failing tests**: one per route above, including `400` for
  `{session: 1}`, `404` passthrough for an unknown session name, `403` for `POST /sessions` with
  the agent token, and `GET /events?session=plan` returning only `name: "plan"` events.
- [ ] **Step 2:** `npx vitest run test/api.test.ts test/server.test.ts` → FAIL.
- [ ] **Step 3:** Implement in `api.ts`.
- [ ] **Step 4:** `npm test && npm run lint` → PASS.
- [ ] **Step 5:** Commit `feat(bridge): API routes for sessions and a session on the task routes`.

### Task 6: Follow, transcript and notify know sessions

**Files:**
- Modify: `bridge/src/follow.ts`, `bridge/src/main.ts`, `bridge/src/transcript.ts`, `bridge/src/notify.ts`
- Test: `bridge/test/follow.test.ts`, `bridge/test/transcript.test.ts`, `bridge/test/notify.test.ts`

**Interfaces:**
- `follow(o: {...; session: string | null})`; `agentic-bridge follow [--session NAME]`.
- `formatEvent` (follow) and `renderEvent` (transcript.md, so `logs --transcript`) prefix `[name] `
  for events of a session other than `main`.
- `notifyPayload` adds `session: q?.session ?? null`.

- [ ] **Step 1: Write the failing tests**:
  - `follow without a session ends on task-level states only` (a `name:"plan"` `idle` event does
    not end it; a `name:null` `idle` does).
  - `follow --session plan prints plan's and task-level events and ends when plan idles or the task ends`.
  - `the transcript prefixes other sessions' lines with [name]`, main's lines unchanged.
  - `the webhook payload names the question's session`.
- [ ] **Step 2:** `npx vitest run test/follow.test.ts test/transcript.test.ts test/notify.test.ts` → FAIL.
- [ ] **Step 3:** Implement; `main.ts` parses `--session` with `NAME_RE` (die on a bad name).
- [ ] **Step 4:** `npm test && npm run lint` → PASS.
- [ ] **Step 5:** Commit `feat(bridge): follow, transcript and webhook name the session`.

### Task 7: The agent's side sends its session

**Files:**
- Modify: `image/bin/agentic-ask`, `image/task/hook.sh`
- Test: `tests/bats/agentic-ask.bats`, `tests/bats/task-hook.bats`

Behaviour: `agentic-ask` adds `session: ${CLAUDE_CODE_SESSION_ID:-${COPILOT_AGENT_SESSION_ID:-}}`
to its body when non-empty (one comment: each harness exports its ACP session id to tool shells,
spec §2). `hook.sh` `report()` adds `session: $(payload_session "$payload")` when non-empty.

- [ ] **Step 1: Write the failing tests**:
  - agentic-ask: `sends the Claude session id`, `sends the Copilot session id`, `sends no session
    outside either` (curl stub captures the body; assert with jq).
  - task-hook: `a block report carries the payload's session id`.
- [ ] **Step 2:** `bats tests/bats/agentic-ask.bats tests/bats/task-hook.bats` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Same → PASS; `shellcheck -x image/bin/agentic-ask image/task/hook.sh` clean.
- [ ] **Step 5:** Commit `feat(image): agentic-ask and the gate report name the asking session`.

### Task 8: Host CLI

**Files:**
- Modify: `bin/agentic` (usage, `cmd_session`, `cmd_send`, `cmd_answer`, `cmd_cancel`,
  `cmd_follow`, `cmd_takeover`, `cmd_status`, `main` dispatch), `lib/host/task.sh`
  (`task_status_record` inbox from `sessions`)
- Test: `tests/bats/cli-task-verbs.bats`, `tests/bats/cli-core.bats` (usage), `tests/bats/docs.bats` if it checks usage against docs

Behaviour:
- `session add ID NAME [--model M] [--fork FROM] [--json] ["prompt"]` → `need_task`,
  `ensure_running`, `bridge_post ID /sessions` with the body built by `jq --arg`; prints the name,
  or the bridge's JSON with `--json`.
- `session list ID [--json]` → running bridge: `GET /sessions`; else `.sessions` of `state.json`
  mapped to the view (`inbox` as a count). Text: `NAME STATE MODEL UPDATED SUMMARY`, control
  characters stripped as in `status`.
- `--session NAME` on `send`, `answer`, `cancel` (adds `session` to the body), `follow` (passed to
  `agentic-bridge follow`), `takeover` (session id from `.sessions[] | select(.name == $n) | .session`
  of the record; `die "task ID has no session NAME"` when absent).
- `status ID`: when `.sessions | length > 1`, one line per session:
  `session NAME  STATE  MODEL  SUMMARY`.
- `task_status_record` from a file: `.inbox` = sum of `.sessions[].inbox` lengths, else the old
  `.inbox` length.

- [ ] **Step 1: Write the failing tests** (the `record` helper gains an optional `sessions` array):
  - `session add posts name, model, fork and text and prints the name`.
  - `session add --json prints the bridge's object`.
  - `session list reads the bridge, or state.json when the task is not running`.
  - `send, answer and cancel pass --session; without it the body has no session`.
  - `follow --session passes the name to the follow client`.
  - `takeover --session resumes that session's id; an unknown name is refused`.
  - `status ID lists sessions when there are several`.
  - `status of an old record without sessions still counts its inbox`.
  - `the bridge's 404 for an unknown session is shown`.
- [ ] **Step 2:** `bats tests/bats/cli-task-verbs.bats` → FAIL.
- [ ] **Step 3:** Implement; update `usage()` with the `session` lines and `--session` options.
- [ ] **Step 4:** `bats tests/bats/cli-task-verbs.bats tests/bats/cli-core.bats` → PASS;
  `shellcheck -x bin/agentic lib/host/task.sh` clean.
- [ ] **Step 5:** Commit `feat(cli): session add and list, --session on the task verbs`.

### Task 9: Docs, smoke and the full checks

**Files:**
- Modify: `docs/tasks.md` (a "Sessions" section after "States"; the routes table and the status
  object in "API, version 1"; "Events" gains `name`; "Notify" gains `session` and the per-question
  rule), `docs/architecture.md` only if it states "one session per task", `tests/image/smoke.sh`

- [ ] **Step 1:** Extend `tests/image/smoke.sh` after the task-1 checks: `ag session add "$id"
  second two`, then `ag follow "$id" --session second` shows `echo: two` (the fake agent's reply),
  and `ag session list "$id" --json | jq length` is 2.
- [ ] **Step 2:** Write the docs.
- [ ] **Step 3:** `make test && make lint` → PASS (includes leak check and generated docs).
- [ ] **Step 4:** `make smoke` → PASS.
- [ ] **Step 5:** Commit `docs: several sessions in one task; smoke opens a second session`.
- [ ] **Step 6 (manual, report the result):** in a real project: one task, `main` and a second
  session with another model in parallel; `follow --session` each; answer a question from the
  second; fork `main` on Claude; `--fork` refused on Copilot; suspend, resume, prompt the second
  session again.
