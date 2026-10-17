# Several agent sessions in one task

Status: draft for review, 2026-10-17. Umbrella: `docs/architecture.md`. Extends sub-project 2
(tasks): a task holds several named agent sessions instead of one. Keeps the container, the bridge,
the API's routes, the gate and the task verbs.

## 1. Outcome

A task is a workspace: one container, one checkout or worktree, one branch, one agent (Claude or
Copilot). Inside it the user opens several **named sessions**, each a native conversation of that
agent with its own context and, if wanted, its own model. Each session is prompted, answered,
cancelled and followed on its own; sessions may run at the same time.

This is a mechanism, not a workflow. Roles such as "plan", "implement" and "review", and any handoff
between sessions, are built on top by the user, a script or another agent through the CLI and the
API. Nothing about roles or handoffs goes into this repository.

    agentic session add ID NAME [--model M] [--fork FROM] ["prompt"]   open a session in task ID
    agentic session list ID [--json]                                     the task's sessions
    agentic send ID [--session NAME] "text"           (likewise answer, cancel, follow, takeover)

Success criteria:

- `agentic run "..."` behaves exactly as today; its session is named `main`, and every verb without
  `--session` acts on `main` (or, for `answer`, on the oldest open question of any session).
- `session add` opens a fresh session, or forks one of the task's sessions on Claude; on Copilot
  `--fork` is refused with "copilot does not support forking a session".
- Each session can have its own model on both agents.
- Two sessions of one task can run turns at the same time; questions, permission requests, events
  and the transcript say which session they belong to.
- `make test`, `make lint` and `make smoke` pass; `docs/tasks.md` and `agentic help` describe it.

## 2. Verified facts (2026-10-17, Claude adapter 0.89.1, Copilot CLI 1.0.98)

- One agent process hosts several ACP sessions on one connection. Two `session/prompt` calls on two
  sessions at once both complete with the right replies, on both agents (Claude's overlapped in
  time; Copilot's took 4 s and 10 s, so it may run them one after the other; either is fine).
- Both agents offer a `model` config option per session (`session/set_config_option`); setting it
  on one session leaves the other's unchanged.
- Capabilities from `initialize`:

  | | `session/load` | `session/list` | `session/resume` | `session/fork` |
  |---|---|---|---|---|
  | Claude | yes | yes | yes | yes |
  | Copilot | yes | yes | no | no |

- Claude fork: `session/fork` returns a new id with the full history; that id must be loaded
  (`session/load`) before it takes a prompt, or the prompt fails with "Session not found". The
  source need not be loaded in the agent process first.
- While one session runs a turn, another session of the same process can be forked, loaded and
  prompted; the running turn is unaffected (Claude, checked). Replayed history arrives as
  `session/update` notifications of the loading session only, so muting the replay is per session.
- The agent's tool shells know their session: Claude sets `CLAUDE_CODE_SESSION_ID`, Copilot sets
  `COPILOT_AGENT_SESSION_ID`, each equal to the ACP session id. Hook payloads carry `session_id`
  (`payload_session` in `image/task/lib/harness.sh`). ACP permission requests carry `sessionId`.
- All sessions of a task live in the task's harness home (`tasks/<id>/home/<agent>`), so loading
  any of them after a suspension needs nothing but its id.

## 3. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **Sessions are the agent's own.** Each named session is a native ACP session: opened with `session/new`, `session/fork` + `session/load`, or `session/load` after a suspension. The bridge only names them and puts one API over both agents. | The user's ask: use the agents' mechanisms, unify the API. Native sessions also work with `takeover` and the agents' own tools. |
| D2 | **One agent process per task.** All sessions share it. Its exit fails the task, as today. | Verified to work (§2); one process means one set of credentials, hooks and environment. Mixed agents in a task are out of scope. |
| D3 | **Capabilities, not agent names.** `AgentProcess` keeps the `agentCapabilities` from `initialize` (recorded in `state.json` as `capabilities`), gains `forkSession(id)`, and refuses an absent capability with "<agent> does not support forking a session". No per-agent classes; non-ACP facts stay in `HarnessSpec`. | Both agents speak ACP; Copilot gets fork without a code change once it advertises it. |
| D4 | **Names.** The first session is `main`. `session add` takes a name matching `[a-z0-9][a-z0-9_-]{0,31}`, unique in the task. At most 16 sessions per task. | Names are what scripts and people address; the ACP ids stay visible in `session list` and events. The cap keeps a runaway script from opening hundreds. |
| D5 | **Per-session state, task-wide rest.** Each session has its own state (`starting`, `running`, `waiting`, `idle`), reason, inbox, outstanding turn, pending permission requests, summary and model. Task-wide stay: the agent process, the gate and `allowed_actions`, the question numbering (`Q1`, `Q2`, … across sessions), the idle timer, stop, suspension and the terminal states (`suspended`, `stopped`, `failed`, `interrupted`). | A session is a conversation; the container, the gate and the lifecycle are the task's. |
| D6 | **The task state is derived.** `starting` while the agent process starts; else `running` if any session runs; else `waiting` if any question is open; else `idle`. Terminal states are set on the task and apply to every session. The idle timeout counts from the moment no session runs, as today. | `status`, the webhook and `follow` without `--session` keep their meaning. |
| D7 | **Parallel turns are allowed.** A prompt to an idle session is delivered at once whatever the other sessions do. The bridge does not order or lock work between sessions; sessions share the worktree, and keeping them out of each other's files is the caller's job. | The agents accept it (§2); the ask was "if it is easy and already offered". |
| D8 | **Questions belong to a session.** A permission request is tagged with the session of its ACP `sessionId`. `agentic-ask` sends the session id from the agent's environment variable (a `harness.sh` fact, D3); the bridge maps it to the name, and an unknown or missing id means `main`. A non-permission answer goes into that session's inbox. Question ids stay task-wide, so `answer ID Q3` needs no session. | The agent that asked gets the answer; existing scripts that answer by question id keep working. |
| D9 | **Models.** `run --model` is `main`'s model and the default for new sessions; `session add --model` overrides it. Both agents get the model through `set_config_option` after the session opens (Copilot today gets it through `--model` on its command line; that flag stays as the default and the per-session call is added). | Verified on both agents (§2). |
| D10 | **Fork.** `--fork FROM` forks a session of the same task: `forkSession(FROM's id)` then `loadSession(new id)`. It is refused when FROM is running a turn ("FROM is running; fork it when it is idle"), and when the agent cannot fork (D3). | A fork of a moving transcript is not well defined; the capability check keeps Copilot honest. |
| D11 | **No import.** A session never starts from a conversation outside its task. A caller that wants an earlier conversation reads it itself and sends it as the new session's first prompt. | The user's call: the consumer owns cross-task context. |
| D12 | **Sessions reopen lazily.** After a suspension or a bridge restart, a session's agent session is loaded when it next gets a prompt or an answer, not all at once. A failed load of `main` falls back as today (a new session seeded with the task history; `bridge.ts` `seed`). A failed load of any other session marks that session `failed` with "its conversation could not be restored: …" and seeds nothing; the task and the other sessions go on, and the caller can add a new session. | Most sessions of a resumed task are not needed again. The task seed ends "continue the task", which would send a review or plan session off implementing in the shared worktree. |
| D15 | **Every question notifies.** A new question (permission or `ask`) triggers the webhook and the notify log at once, with its session's name, whatever the derived task state; task-state notifications (D6) stay as today. | With parallel sessions the task can be `running` while one session is blocked on a permission request; the human must hear of it then, not when every other session has finished. |
| D16 | **Unfinished turns come back per session.** When the agent exits or the bridge is interrupted, each session that was mid-turn gets its unfinished prompt back at the head of its own inbox, as today for one session. A prompt that resumes an interrupted or failed task (what `agentic resume` sends) goes to `main` and, in the same words, to every other session with a non-empty inbox; those sessions reload then (the one exception to D12). Sessions that were idle stay unloaded. | `resume` means "carry on what was running"; a session that was idle has nothing to carry on. |
| D13 | **Records stay readable.** `state.json` gains `sessions` (the per-session fields of D5 plus `name`, `session` id, `model`, `fork_of`, `created`, `updated`) and `capabilities`. A record without `sessions` (a task from before this change) is read as one session `main` built from the old top-level `session`, `inbox` and `summary`. The top-level `session` stays as `main`'s id (`takeover` and the cost records read it). | Tasks outlive image upgrades. |
| D14 | **Scheduled runs use `main` only.** The summary turn and the run timeout are unchanged; `session add` on a scheduled task is refused. | Keeps the unattended run's end well defined. |

## 4. API (version 1, additions)

- `GET /sessions` → `200 [{name, session, model, state, reason, summary, inbox, fork_of, created, updated}]`.
- `POST /sessions` `{name, model?, fork?, text?}` → `201` the new session's object; it starts in
  `starting`, then becomes `running` with `text` or `idle` without. `409` for a name in use, the
  16-session cap, a running fork source, a stopped task, an agent that cannot fork, or capabilities
  not yet known (the agent is still starting: "try again when the task is idle"); `400` for a bad
  name; `404` for an unknown `fork` source.
- `POST /prompt`, `POST /cancel`: optional `session` (a name); default `main`; `404` for an unknown
  name.
- `POST /answer`: optional `session` limits "the oldest open question" to that session; a given
  `question` id needs none.
- `POST /ask`: optional `session` (the ACP id from the agent's environment, D8).
- `POST /gate`: optional `session` (the hook payload's `session_id`); the `gate` event carries it.
- `GET /status`: adds `sessions` (as in `GET /sessions`); `state` is the derived task state (D6);
  `inbox` is the sum over sessions. Each question gains `session` (its name).
- `GET /events`: optional `session` (a name) filters. Every event's `session` stays the ACP session
  id, and a new field `name` holds the session name; task-level events (the derived task state,
  stop, suspension) have `session` and `name` null. `state` events are emitted per session, with
  the derived task state as task-level `state` events, as today.
- The routes are added to the existing `api.ts` switch; tokens and access rules are unchanged (the
  agent token may still only `ask` and `gate`).

## 5. CLI

- `agentic session add ID NAME [--model M] [--fork FROM] ["prompt"] [--json]`: `POST /sessions`
  (starting a suspended task first, as `send` does); prints the name, or the object with `--json`.
- `agentic session list ID [--json]`: `GET /sessions` from a running bridge, else the `sessions` of
  the record; text columns NAME, STATE, MODEL, UPDATED, SUMMARY (control characters stripped as in
  `status`).
- `--session NAME` on `send`, `answer`, `cancel`, `follow` (follows that session: ends when it
  waits, idles or the task ends; `agentic-bridge follow` gains the same option) and `takeover`
  (resumes that session's id interactively). Without it each verb behaves as today on `main`.
- `status ID` prints one line per session when the task has more than one; `status` (all tasks)
  is unchanged.
- `logs ID --transcript` prefixes lines of sessions other than `main` with `[NAME]`
  (`transcript.ts`).
- `run` gains nothing: a task starts with `main`, and further sessions are added after it.

## 6. Out of scope

- Roles, workflows, handoffs between sessions, or any orchestration (built on top, §1).
- Starting a session from a conversation outside the task (D11).
- Mixed agents in one task.
- Closing or deleting a session; an idle session costs nothing.
- Per-session gate grants (`allowed_actions` stay task-wide).
- Coordination between parallel sessions (D7).

## 7. Tests and checks

- vitest, written first: the machine per session (deliver, cancel, permission, answer to the right
  inbox, derived task state, idle timer with mixed session states, stop and agent exit across
  sessions, lazy reload and its fallback for `main` and failure for the others, a question
  notifying while another session runs, a resume reaching every session with an unfinished turn,
  the cap and name rules); `AgentProcess` capabilities and
  `forkSession` + load, prompts on two sessions at once, against the fake ACP agent
  (`AGENTIC_ACP_CMD`, extended to several sessions and fork); the new routes and the `session`
  parameters; reading an old record (D13); events and transcript with names.
- bats, written first: `session add` and `session list` (text and `--json`), `--session` on each
  verb, `status` with several sessions, `takeover --session`, `agentic-ask` sending the session id
  for both agents.
- `make smoke`: a task in the built image opens a second session and both answer.
- Manual: in one task, run `main` and a second session with another model in parallel, `follow`
  each with `--session`, answer a question from the second, fork `main` on Claude, see `--fork`
  refused on Copilot, suspend and resume the task and prompt the second session again.
