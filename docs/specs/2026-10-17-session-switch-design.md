# Continue a saved agent session as a task

Status: draft for review, 2026-10-17. Umbrella: `docs/architecture.md`. Extends sub-project 2
(tasks): a task can start from a saved conversation instead of an empty one. Keeps the bridge, the
API, the gate and the task verbs.

## 1. Outcome

From the host the user lists the agent conversations saved for a project and continues any of them
as a normal detached task: the gate, questions, `follow`, `status`, `send`, `takeover` and `clean`
work as for any other task. With `--fork` (Claude only) the task continues a branch of the
conversation under a new session id.

    agentic sessions [--json]                       saved sessions: the project's and each task's
    agentic run --session REF [--fork] "prompt" ... a new task that continues (or forks) REF

Success criteria:

- `agentic sessions` lists the sessions of `agentic dev`, `shell` and `setup` (and Claude's own
  background sessions there) for both agents, plus one row per task that has a session.
- `run --session REF "prompt"` starts a task whose agent remembers the earlier conversation, for
  Claude and Copilot, with or without `--worktree`.
- `run --session REF --fork` gives a new session id on Claude; on Copilot it fails with "copilot
  does not support forking a session" before the task's bridge starts, and the task is rolled back
  (nothing is left behind).
- The source conversation is never written by the new task.
- `make test`, `make lint` and `make smoke` pass; `docs/tasks.md` and `agentic help` describe both
  commands.

## 2. What the code and the agents do today (verified 2026-10-17)

- **Session stores are per container kind, not shared.** `agentic dev`, `shell`, `setup` and
  `doctor` mount the project's harness homes (`$AGENTIC_DATA/projects/<p>/harness/{claude,copilot}`
  at `/home/dev/.claude` and `/home/dev/.copilot`, `build_run_args`). A task has its own homes under
  `tasks/<id>/home/{claude,copilot}` (`image/start.d/06-task-home.sh`), and `takeover` resumes in
  them. The task brief assumed one mounted home that holds every conversation; that is not so, and
  this design follows from it.
- Every task container mounts the workspace's `tasks/` at `/tasks`, so all task homes are visible
  there. Task containers do not mount the project's harness homes.
- The homes are set once per container, at its start (`06-task-home.sh` writes `CLAUDE_CONFIG_DIR`
  and `COPILOT_HOME` into `~/.agentic/env` from the creating task's directory). A task started with
  `--in` therefore runs its agent in the **creator's** home, `/tasks/<creator>/home/...`; the creator
  is the task whose record has the same `container` and `created_container: true`.
- Claude's `session/list` without a cwd returns the sessions of every project folder in the home
  (85 sessions across 17 folders in the check); with a cwd it returns that folder's only.
- ACP capabilities, as each agent advertises them in `initialize`:

  | | `session/list` | `session/load` | `session/resume` | `session/fork` |
  |---|---|---|---|---|
  | Claude adapter 0.89.1 | yes | yes | yes | yes |
  | Copilot CLI 1.0.98 | yes | yes | no | no |

- Spike (host, throwaway homes): a session's files copied into a fresh home and loaded with a
  **different cwd** keep their history and take a new prompt, for both agents.
  - Claude: `projects/<slug>/<id>.jsonl` (and the `<id>/` folder when present) copied into
    `projects/<slug of the new cwd>/`. The slug is the cwd with every character outside
    `[A-Za-z0-9]` replaced by `-`.
  - Copilot: `session-state/<id>/` copied whole. The copy loads, but Copilot's `session/list` does
    not show it (the list reads `session-store.db`); this design never lists task homes through ACP.
  - Claude fork: `session/fork` writes a new transcript titled "… (fork)" and returns its id; the id
    must then be loaded (`session/load`) before `session/prompt`, or the prompt fails with "Session
    not found".

## 3. Decisions

| # | Decision | Why |
|---|---|---|
| S1 | **A task starts from a copy.** `run --session` copies the source session's files into the new task's home, then the bridge loads it. The source home is never written. | Homes are per task (§2). Copying also removes the two-writer risk of task brief item 4 by construction: nothing to detect, nothing to lock. The cost: work done in the task does not show up in the source home; the task's session is the continuation (listed as its own row, continued with `send`, `takeover` or another `run --session`). |
| S2 | **One agent layer, driven by capabilities.** `AgentProcess` keeps the `agentCapabilities` from `initialize` and gains `listSessions()` and `forkSession(id)`; each refuses with "<agent> does not support <listing\|forking> a session" when the capability is absent. No per-agent classes. Per-agent facts that are not ACP (where session files live) go into `HarnessSpec` (`bridge/src/harness.ts`), next to the existing ones. | Both agents speak ACP; the differences are capabilities and file layout. Copilot gains fork with no code change once it advertises it. |
| S3 | **Load, not resume.** The bridge continues a session with `session/load` (replayed history is already dropped). | Both agents support it; `resume` is Claude only and saves only the replay. |
| S4 | **The session work runs in the container, in one-shot runs.** `agentic sessions` and the copy step of `run --session` start a throwaway container of the project image with the same arguments as `agentic shell` (`build_run_args`, so the project's harness homes are mounted) plus the workspace's `tasks/` at `/tasks`, running `agentic-bridge sessions ...` (§5). The host never reads a harness home or a transcript. | CLAUDE.md: thin host; the host must not read `~/.claude` (task brief item 1). Needs no running task or dev container. |
| S5 | **Task rows come from task records, not from ACP.** The in-container list reads `/tasks/*/state.json` for tasks with a session: the session id, agent, `updated`, and the first line of `prompt.md` as the title. A task's session files are in its own home, or, for a task that ran with `--in` (`created_container: false`), in its creator's home (§2); the copy reads them from there. | One ACP start per task home would be slow; the record already holds the task's current session. |
| S6 | **Fork is Claude only for now, by capability.** `--fork` is refused before the task is created when the agent does not advertise `session/fork`. In the bridge, fork is `forkSession(S)` then `loadSession(new id)`. | Copilot 1.0.98 has no fork. Faking it (a new session seeded with the old transcript) would not be the same conversation. |
| S7 | **A failed first load ends the task.** When the first spawn of a `--session` task cannot load (or fork) its session, the task fails with "session S could not be loaded: …". The existing fallback (a new session seeded with the task history, `bridge.ts` `spawn`) still applies to later resumes. | Silently starting an empty conversation is exactly what the user asked not to get. |
| S8 | **Pagination is internal.** `listSessions()` follows `nextCursor` to the end (at most 100 pages, then a warning); `--json` prints the full list. | The lists are small (tens); a cursor in the CLI is complexity nobody needs. |
| S9 | **The record names the origin.** A `--session` task's `state.json` gets `origin: {from: "dev" \| <task id>, session: <source id>, fork: bool}`; tasks without it have `origin: null`. `status ID` prints `from <session> of <from>` and `(fork)`; `status --json` carries the field as is. The task id is chosen as for any `run` (`--id` or a new id). | Shows where a task came from without a naming scheme. |
| S10 | **Copying refuses links.** The copy reads only regular files and directories; any symlink in the source, or a session id outside `[A-Za-z0-9-]{1,128}`, is refused. A task id is checked with the existing rule (`[A-Za-z0-9._-]+`). | Task homes are written by agents and `tasks/` is shared between task containers (the CLI already treats it as untrusted). |
| S11 | **`--session` refuses `--in`.** "--session cannot be used with --in: a task in another task's container shares that task's harness home". | Such a task runs in the creator's home (§2): a copy into its own home is never read, and a copy into the creator's home can overwrite the source (same slug), breaking S1. Giving each `--in` task its own home changes `takeover`, cost collection and every `--in` task; not worth it for this feature. |

## 4. CLI

### 4.1 `agentic sessions [--json]`

Runs the one-shot (S4) with `agentic-bridge sessions list` and prints its rows, newest first:

    SESSION                               AGENT    FROM        UPDATED            TITLE
    1426ba4f-5b33-407c-ac8b-db37afd399c5  claude   dev         2026-10-17 08:32   Agentic YAML tools installation
    0b84d854-bd6f-4af1-aa2f-fafef3a297b0  copilot  t-20261016  2026-10-16 11:35   Fix the login test

- `FROM` is `dev` for the project's harness homes, else the task id.
- `--json` prints a JSON array of `{session, agent, from, cwd, title, updated, can_fork}`
  (`cwd` is null for task rows; `can_fork` is the agent's capability). Text output strips control
  characters, as `status` does.
- All sessions of the project's homes are listed, not filtered by work dir: the homes are per
  project already, and Claude's background sessions run in worktree cwds.
- An agent that cannot list (not logged in, missing binary, no `session/list`) is skipped with one
  warning line on stderr; the command fails only when no agent could list.

### 4.2 `agentic run --session REF [--fork] "prompt" [other run options]`

- `REF` is a task id (that task's current session) or a session id. A session id is looked up in
  the project's homes and in the task records; found in more than one place (a dev session already
  continued by a task has the same id in both), it is refused naming the candidates: "session S is
  in dev and in task T; give --session T for the task's".
- The agent is the session's. `--agent` is allowed only when it names the same agent.
- All other `run` options work as usual (`--worktree`, `--target`, `--allow`, `--publish`, `--id`,
  `--json`); `--in` is refused (S11). `--scheduled` and `schedule add` do not take `--session` (out of scope).
- Order inside `cmd_run`: everything that can refuse first, as today. After the task directory is
  made (inside the rollback window) the copy one-shot runs `agentic-bridge sessions copy` (§5); its
  failure, including a refused `--fork`, rolls the task back like any other `run` failure. Then the
  env file gets `AGENTIC_SESSION`, `AGENTIC_SESSION_FROM` and, with `--fork`, `AGENTIC_SESSION_FORK=1`.
- The destination cwd is the task's work dir, or `<work>/.worktrees/<id>` with `--worktree` (the
  rule `takeover` already uses).
- When the source is a task whose bridge is running, `run` prints "warning: task T is running; the
  copy ends at its current turn" and goes on (S1: the copy is a snapshot).

## 5. Bridge

- `agentic-bridge sessions list`: for each agent (`claude`, `copilot`), starts `AgentProcess` with
  the project's home (the container's defaults), calls `listSessions()` with no cwd filter, and
  prints the dev rows; then the task rows from `/tasks/*/state.json` (S5). Output: one JSON array on
  stdout, warnings on stderr.
- `agentic-bridge sessions copy REF --to TASK --cwd DIR [--fork]`: resolves `REF` (§4.2), copies the
  files into `/tasks/TASK/home/<agent>` with the layout from `HarnessSpec` (§2), and prints
  `{agent, session, from, can_fork}`. With `--fork` it starts the agent once to read its
  capabilities and refuses when `session/fork` is absent (S6).
- `HarnessSpec` gains the session file facts: for Claude, the transcript and its folder under
  `projects/<slug>/`, moved to the slug of the destination cwd; for Copilot, `session-state/<id>/`.
- Config: `AGENTIC_SESSION` (the session to load at the first spawn), `AGENTIC_SESSION_FROM`,
  `AGENTIC_SESSION_FORK=1`. A fresh boot with `AGENTIC_SESSION` sets `record.session` and
  `record.origin` (S9) and spawns `load`, or `fork` with the flag; the spawn modes become
  `new | load | fork`. S7 governs a failed first spawn.
- The HTTP API is unchanged: `origin` reaches `GET /status` through the record.

## 6. Out of scope

- Driving Claude's own agent view or `claude --bg` / `claude agents` from the host or the bridge.
- Writing a task's continuation back into the source home (S1).
- Changing the session of a running task, or more than one session per task.
- `--session` for scheduled runs.
- Listing extra sessions a `takeover` created inside a task home (the record names the task's
  session; that is the one listed).

## 7. Tests and checks

- vitest, written first: `AgentProcess` capabilities, `listSessions` paging and the refusals,
  `forkSession` + load, against the existing fake ACP agent (`AGENTIC_ACP_CMD`); the session file
  copy per harness (slug move, link and id refusals) on temporary dirs; the list's task rows from
  records; the bridge's fresh boot with `AGENTIC_SESSION` (load, fork, S7 failure, `origin`).
- bats, written first: `sessions` text and `--json` from a stubbed one-shot; `run --session` writes
  the env lines, refuses a mismatched `--agent`, an ambiguous REF, `--in` and `--scheduled`, and rolls back
  when the copy fails; `status` shows the origin.
- `make smoke`: `agentic-bridge sessions list` runs in the built image (the bridge entry is in it).
- Manual: list sessions; continue a Claude dev session with `run --session`, `follow` it; continue a
  Copilot one; fork a Claude one and see both rows in `sessions`; `--fork` on Copilot is refused.
