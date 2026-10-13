# Detached tasks

A task is one container, one bridge and one agent session. The bridge (`agentic-bridge`, a small
TypeScript program in the image) drives Claude Code or Copilot CLI through the Agent Client
Protocol and serves a light HTTP + WebSocket API. Start a task locally with `agentic run`, then
follow it, answer its questions, cancel, stop, resume and clean it with the other verbs. A task
hub uses the same image, the same action gate and the same API; it brings its own driver and no
hub is named in this repository. Design: `docs/specs/2026-10-12-sub-project-2-acp-bridge-design.md`.

## Quick start

```bash
agentic run --allow open-pr "Fix the failing login test and open a pull request"   # prints the task id
agentic follow T-20261012-a3f1                      # readable events until the task waits, idles or ends
agentic status                                      # all tasks of this project; `status ID` shows open questions
agentic answer T-20261012-a3f1 Q1 "Yes, use the staging config" --allow push
agentic stop T-20261012-a3f1
agentic clean T-20261012-a3f1                       # container, worktrees, local branch, record
```

`answer` takes the question id optionally: `agentic answer ID "text"` answers the oldest open
question. A text that starts with `-` goes after `--`. `send ID "text"` is a new prompt;
`cancel ID` ends the current turn; `resume ID` continues an interrupted or failed task; `logs ID
[--transcript|--bridge|--start]` shows the files; `shell ID` opens a shell in the container;
`takeover ID` stops the task and continues its session interactively.

`follow ID [--since N] [--raw] [--forever]` streams the events after `N` (default: from the start)
over the WebSocket; `--raw` prints the JSON objects, `--forever` keeps streaming instead of
exiting once the task waits, idles, stops or fails. `status [ID] [--all] [--json]` lists the tasks
of this project (`--all`: every project; `--json`: one JSON object, or an array for a list).

`run` options: `--prompt-file F`, `--agent claude|copilot`, `--model M`, `--repo R` (repeatable),
`--base REF`, `--branch B`, `--allow push|open-pr|deploy:<target>` (repeatable), `--id ID`,
`--keep-on-failure`, `--json`. `run` validates before it creates anything and rolls back on any
failure.

`status` shows the task's state; a task recorded as active whose container is gone shows
`interrupted`, and one whose container state cannot be read (Docker failed) shows `unknown`, as
does one whose `state.json` is not a single JSON object; questions that are not objects are skipped.
`status ID` lists the open questions and the `reply:` hint also when the container has exited; it
then reads them from the task files (`state.json`, `questions.jsonl`). `status ID --json` prints
one shape whether or not the bridge is live: the status object (see The status object).

`clean` refuses a running task, and a task whose worktree has uncommitted changes or commits on no
remote branch, unless `--force` (which stops a running task first). It also refuses when it cannot
check. Remote branches stay.

## States

```
            first prompt                      turn ends, question open
(new) ─▶ starting ─▶ running ─────────────────────────────────────▶ waiting ─┐
                       ▲  │ turn ends, nothing open                          │ idle timeout
                       │  ▼                                                  ▼
                       ├── idle ───────── idle timeout ─────────────────▶ suspended
                       │                                                     │
                       └── prompt / answer ◀─────────────────────────────────┘
 stop ─▶ stopped      agent exits or ACP error ─▶ failed      container gone without stop ─▶ interrupted (host)
```

Further transitions: `idle → waiting` when `agentic-ask` is called while no turn runs; `running →
waiting` when the agent asks for permission mid-turn, back to `running` when the last pending
permission is answered; `suspended`, `interrupted` and `failed → starting → running` on a prompt
or answer (the agent is respawned and the session loaded); `stopped` is final.

- **Start.** Without `state.json` the bridge creates the record, spawns the agent, opens a
  session, applies bypass and sends `prompt.md` (else `AGENTIC_PROMPT`); `starting → running`.
  With a record the bridge starts lazily: it serves the API and spawns nothing until a prompt or
  answer arrives, so a plain `docker start` spends no tokens. If nothing wakes it within
  `AGENTIC_IDLE_TIMEOUT`, the bridge exits 0 with the state unchanged and the container exits
  again (also after a refused request, such as an answer to an unknown question). A record in `starting`, `running`,
  `waiting` or `idle` found at start is an unclean end: the bridge sets `interrupted` and waits.
- **Turn end.** `session/prompt` returns. With an open question the task is `waiting`, else
  `idle`. The summary is the agent's text after its last tool call in the turn (300 characters at most). If the inbox is
  not empty, its items are joined into the next prompt at once.
- **Prompt.** Accepted in `idle`, `waiting`, `suspended`, `interrupted` and `failed`; 409 in
  `starting`, `running`, `stopped`. In `suspended`, `interrupted` or `failed` the bridge spawns
  the agent and calls `session/load` first. A prompt the agent rejects fails the task (exit 1) and
  its text is kept at the head of the inbox, so a later prompt or `resume` delivers it again.
- **Answer.** Accepted whenever the question is open, in any state but `stopped`. The question is
  recorded as answered and a grant is added to `allowed_actions` immediately (a reject answer to a
  permission question adds none). A permission question still pending in the agent is answered
  through ACP; otherwise the text `Answer to Q<n>: <text>` (plus `Allowed for this task:
  <grants>.`) goes into the inbox and is delivered as soon as no prompt is outstanding.
- **Suspension.** `waiting` or `idle` longer than `AGENTIC_IDLE_TIMEOUT` (default 900 s; any input
  resets it): a pending permission request is answered `cancelled` (its question stays open), the
  agent ends, `state = suspended`, the bridge exits 0 and the container exits.
- **Resume.** The host starts the container (`docker start`), waits for `GET /status`, then sends.
  The bridge spawns the agent and calls `session/load` with the stored session id; history replayed
  before the load returns is dropped. If the session is missing, the bridge opens a new session
  seeded with `prompt.md`, the questions and answers, and `git log --oneline -20` of `/work`, and
  emits an `error` event saying so.
- **Removed container.** A task whose container was removed (for example by `docker container
  prune`) cannot be resumed by the CLI in version 1: `send`, `answer`, `resume`, `stop` and
  `takeover` of a task that is not stopped refuse with `has no container`. The task files are
  kept, and `clean` still works.
- **Interrupted.** `agentic resume ID` starts the container and sends `You were interrupted. Check
  git status and continue.`
- **Cancel.** Accepted only while a prompt is outstanding: in `running`, or in `waiting` on a
  permission request raised mid-turn (every pending permission question is answered as cancelled,
  then the turn is cancelled). Otherwise 409 `no turn in progress`; so a task that is `waiting`
  on an `agentic-ask` question after its turn ended cannot be cancelled (answer it, or stop it).
  The task stays as it is until the prompt returns `cancelled`, then follows the turn-end rule.
  Repeating a cancel is harmless.
- **Stop.** Cancels a running turn, ends the agent (no `session/close` is sent), sets
  `stopped`, `stopped_by_user = true`, and the bridge exits 0. No restart policy.
- **Failed.** The agent process exits outside a stop or suspension, or an ACP call fails (a
  rejected prompt included): `failed` with the reason; the bridge exits 1 and the container stays
  for inspection. `resume` may retry.

## API, version 1

### Transport and authentication

The bridge listens on `0.0.0.0:8765` inside the container (`AGENTIC_BRIDGE_PORT`); `bin/agentic`
publishes it as `127.0.0.1::8765` (a random host port, loopback only) and reads the port with
`docker port` on every call, because `docker start` may change it.

Every request, WebSocket upgrade included, needs `Authorization: Bearer <token>`:

- **task token** (`AGENTIC_TASK_TOKEN`): every route.
- **agent token** (`AGENTIC_AGENT_TOKEN`): only `POST /ask` and `POST /gate`. The bridge passes it
  to the agent's environment with `AGENTIC_BRIDGE_URL=http://127.0.0.1:<port>` and removes the
  task token from that environment.

Each token is at least 16 characters (`run` generates 32 random bytes) and the two must differ,
or the bridge refuses to start. `run` keeps them in the host-only `env` file (mode 600, see Files) and passes the
file with `--env-file`; they are never put on a command line. Token comparison is constant-time.

A `Host` header that is not a loopback name (`127.0.0.1`, `localhost`, `[::1]`) on any port, and
not a name listed in `AGENTIC_BRIDGE_HOSTS`, gets 403; matching is case-insensitive. Any `Origin`
header not listed in `AGENTIC_BRIDGE_ORIGINS` gets 403. Request headers are never logged. A body
over the size limit gets 413.

Threat model: the bridge and the agent run as one user in one container, so the agent could read
the bridge's environment or edit `state.json`. The tokens keep other host processes and browsers
(DNS rebinding) out; they do not contain the agent. The gate guards against slips, not a hostile
agent. Anyone with access to the Docker socket can read the tokens (`docker inspect`) and is root
on the host anyway.

Host git on task clones: no host git process opens a `.git` directory a task can write.

- Each changed clone's `.git` is mounted read-write into its task (commits, refs, objects), with
  its `config`, `info/` (attributes, exclude) and `hooks/` read-only over it, so the agent cannot
  add a remote, a credential helper, an ssh command, a proxy, a filter driver or a hook. Inside the
  task, commit, branch, fetch and `git push origin HEAD` work; worktree branches have no upstream,
  `git push -u` pushes but cannot record one, and `git config` needs `--global`.
- The host fetches with the user's credentials only into a private bare mirror per clone,
  `$AGENTIC_DATA/projects/<project>/mirrors/<name>.git`, which is never mounted into a container
  (not even the dev container, which mounts the workspace). The mirror fetches from the project's
  remote (the checkout's `origin`, credentials stripped, else the checkout itself); for a `--repo`
  clone, from the origin its mirror recorded on first use, read from the clone before any task had
  write access to it. Host git on a mirror keeps the user's own settings for what could run a
  command (the ssh command and askpass from the user's config, credential helpers reset and
  replayed from the system and global config, a `git://` proxy only from the user, `ext::` off), no
  hooks, no fsmonitor, `gc.auto=0`, `maintenance.auto=false`.
- Every operation on a clone (fetch from the mirror into `refs/remotes/origin/`, `worktree add`,
  `clean`'s `status` and `log`, rollback's `worktree remove`, `worktree prune`, `branch -D`) runs in a
  throwaway container of the task's image: `--network none`, the invoking user, `--cap-drop ALL`,
  `no-new-privileges`, a read-only root with a `/tmp` tmpfs as `HOME`, `GIT_DIR` and
  `GIT_COMMON_DIR` pinned, the clone's `.git` with `config`, `info/` and `hooks/` read-only, the
  mirror read-only when fetching from it, and only the one worktree a call needs (`prune` sees
  `.worktrees/` read-only). No hooks, no fsmonitor, no automatic gc, no `FETCH_HEAD`. A filter,
  command or symlink the agent planted acts inside that container and points at nothing on the host.
- The only host git on a clone is its creation: a brand-new clone is made by the host from the
  mirror, in a fresh directory no task has seen, before any agent exists.
- What remains: clones from before this design may carry config an agent planted then (delete
  them to start fresh); a checkout in the container sees neither the network
  nor the user's global config, so Git LFS files of a worktree are pointer files; `clean` trusts what
  the agent left in its worktree.
- Tasks that share a clone share its refs and objects: one agent can forge `refs/remotes/origin/*`
  or objects that a later task checks out from, and that `clean`'s unpushed check of another task
  compares against. The mirror fetch refreshes `refs/remotes/origin/*` before each new worktree,
  but not in between.

Other host reads and writes: the host's own task files (tokens, mounts, repos) live under
`$AGENTIC_DATA` (see Files), which no container mounts; the mounts file is checked on every read
(only the `-v` forms `run` writes). Files the agent writes in the task directory (`state.json`,
`questions.jsonl`, `transcript.md`, `bridge.log`) are read only when they are regular files and no
symlinks, so the terminal never shows a host file and never blocks on a FIFO; what is printed has
control characters removed, also git's messages from the throwaway containers. Rollback and
`clean` remove only paths inside the workspace with no symlink below its root.

Outside the model: an image built with the Docker socket label (`agentic.docker_socket`) mounts
the Docker socket into every task, which is host root access for the agent.

### Routes

| Route | Body | Success | Errors |
|---|---|---|---|
| `POST /prompt` | `{text}` | 202, status | 400 empty, 409 state |
| `POST /answer` | `{question?, text, grant?: [..]}` (default: the oldest open question) | 202, status | 400 empty or bad grant, 404 unknown question, 409 nothing open or stopped |
| `POST /cancel` | none | 202, status | 409 `no turn in progress` |
| `POST /stop` | none | 202, status | none |
| `GET /status` | none | 200, status | none |
| `GET /events?since=SEQ&limit=N` | none | 200, `application/x-ndjson`, events with `seq > SEQ`; `since` defaults to 0, `limit` to 1000 (1 to 1000) | 400 |
| `WS /events?since=SEQ` | none | the backlog, then live events, one JSON object per text frame; ping every 30 s | upgrade refused with 400 (bad target), 401, 403 (Host, Origin, or the agent token), 404 (other path) |
| `POST /ask` (agent token) | `{text, options?, recommend?}` | 201 `{id}` | 400 empty, 409 stopped |
| `POST /gate` (agent token) | `{rule, command}` | 204 | none |

The agent token on any other route gets 403; an unknown route gets 404. Grants: `push`, `open-pr`, `deploy:<target>` (`deploy:[A-Za-z0-9_.-]+`). Errors share one body:
`{"error":{"code":"<bad_request|unauthorized|forbidden|not_found|conflict|starting|internal>","message":"…"}}`;
401 carries the code `unauthorized` and no detail; 500 `internal` for an unexpected failure; 503
`starting` until the bridge can take commands.

### The status object

`state.json` (see Files) without `inbox` items (their count instead) plus `questions`, the open
ones: `{id, source, text, options, recommendation, asked}`. `agentic status ID --json` prints it
from the bridge when it is live, else builds the same object from the task files with the state
derived as described under `status`.

## Events

One JSON object per line in `events.jsonl` and per WebSocket frame:

```json
{"seq":42,"ts":"2026-10-12T10:00:00Z","task":"T-20261012-a3f1","session":"52e7…","agent":"claude",
 "type":"tool","data":{"id":"toolu_…","title":"git push origin HEAD","kind":"execute","status":"failed",
 "output_tail":"…"}}
```

| Type | Data | Source |
|---|---|---|
| `state` | `{state, reason}` | the state machine |
| `message` | `{role: agent\|user, text, final}` | `agent_message_chunk` buffered, flushed at most once a second and at tool and turn boundaries with `final:false`; one `final:true` with the whole message at turn end; prompts and answers as `role:user` |
| `tool` | `{id, title, kind, status: pending\|running\|done\|failed, output_tail}` | `tool_call`, `tool_call_update`, emitted on a status change only; `output_tail` (last 20 lines, 2 KB at most) on `done` and `failed` |
| `plan` | `{entries}` | `plan` |
| `question` | `{id, source: permission\|ask, text, options, recommendation}` | `/ask`, `request_permission` |
| `answer` | `{question, text, grant}` | `/answer` |
| `gate` | `{rule, command}` | `/gate` |
| `error` | `{message}` | bridge and agent errors, a failed notify webhook included |

Not emitted in version 1: thoughts, usage, available commands, config options, session titles, and
history replayed by `session/load`. `seq` increases by one per event and is the cursor.
`agentic follow` strips control characters from what it prints.

## Files

```
$AGENTIC_WORKSPACES/<project>/
├─ repos/<name>/                    clones; worktrees in .worktrees/<ID>
├─ events/events.jsonl              project-wide notify log            ─▶ /events
└─ tasks/
   ├─ <ID>/                                                            ─▶ /task
   │  ├─ state.json                 the task record, written only by the bridge
   │  ├─ events.jsonl               every event
   │  ├─ questions.jsonl            asked and answered records; the last line per id wins
   │  ├─ transcript.md              readable rendering
   │  ├─ prompt.md                  the first prompt
   │  ├─ bridge.log                 bridge diagnostics, redacted
   │  └─ home/claude/, home/copilot/   CLAUDE_CONFIG_DIR, COPILOT_HOME: sessions survive containers

$AGENTIC_DATA/projects/<project>/      host only: never mounted into a task or the dev container
├─ mirrors/<name>.git               private bare mirror of each clone; the only repositories host git opens
├─ events.jsonl                     the host's own log: interrupted lines
└─ tasks/<ID>/
   ├─ env                           mode 600: AGENTIC_TASK_TOKEN, AGENTIC_AGENT_TOKEN
   ├─ mounts                        the task's -v arguments (checked on every read)
   ├─ repos                         clone, worktree and branch per line, for clean and rollback
   └─ interrupted                   marker: the interruption was logged
```

Tasks created before these files left the workspace (`tasks/<ID>.env`, `.mounts`, `.repos`,
`.interrupted`) have them moved here the first time a command touches the task.

`bin/agentic` creates every directory as the invoking user, so no volume comes up owned by root.
In the cloud, `/task` is one volume and start step `06-task-home` creates the homes. At creation
the homes are seeded from the project login (credentials and config, mode 600); tokens in
`.agentic/.env` work as in dev mode. The repository's `.env` tokens reach the container through
`--env-file`, never on a command line.

### `state.json`

```json
{"version":1,"task":"T-20261012-a3f1","project":"orders","agent":"claude","model":null,
 "state":"waiting","reason":"question Q2","session":"52e775a2-…","branch":"agentic/T-…-fix-login",
 "created":"…","updated":"…","seq":118,"allowed_actions":["open-pr"],
 "inbox":[{"kind":"answer","question":"Q2","text":"…"}],"summary":"…","stopped_by_user":false}
```

Written atomically (temp file, `fsync`, rename). A corrupt `state.json` stops the bridge with a
message naming the file; it is never reset. A torn last line in a JSONL file is skipped on read.

### Transcript

Markdown, appended as the task goes: each user prompt and answer as a quote, each final agent
message as text, each tool call as one line `▸ <title> — <status>` followed, for `done` and
`failed`, by the last 10 lines of output in a fenced block; questions, answers with grants, gate
blocks and state changes as one-line callouts. Redacted.

## Questions and the gate

An agent that needs a human decision runs `agentic-ask "text" [--option X]… [--recommend X]`. It
POSTs `/ask` with the agent token and prints `Recorded Q<n>. Continue with work that does not
depend on it; when nothing else can move, end your turn.` Without `AGENTIC_BRIDGE_URL` it exits 1
with `agentic-ask works only inside a task`. The task becomes `waiting` at the turn end, a
notification goes out, and `agentic answer` (optionally with `--allow`) delivers the answer.

Permission requests from the agent (none arrive under bypass) become questions with `source:
permission`, the tool call's title and command, and the option names as `options`. The answer
text must match an option's name or kind (`allow`, `allow once`, `allow always`, `reject`;
case-insensitive), else 400.

The gate runs as a `PreToolUse` hook (`hook.sh`, installed by start step `45-hooks` when
`AGENTIC_GATE=1`):

- **Rules.** `git push`, PR creation and deploy-like commands are blocked unless allowed by
  `--allow` or a grant (`push`, `open-pr`, `deploy:<target>`); merges and protected words
  (`AGENTIC_GATE_PROTECTED`) are always blocked.
- **Allowed actions.** From `/task/state.json` when present, else `AGENTIC_ALLOWED_ACTIONS`
  (comma-separated; each entry validated against the grant pattern).
- **Dispatch.** On `pretooluse`, `hook.sh` runs `gate.sh`, `ask-guard.sh`, then
  `hooks.d/pretooluse/*.sh` of the image (`/opt/agentic/hooks.d/`) and of the project
  (`/agentic-config/hooks.d/`); any other event runs only its `hooks.d/<event>/` scripts, whose result is ignored. The payload
  arrives on stdin. `gate.sh` and `ask-guard.sh` block on any exit but 0 (2 is the refusal); a
  `hooks.d/pretooluse` script blocks only by exiting 2 (its stderr is the reason), any other exit
  is ignored.
- **Block format.** Claude: exit 2, the reason on stderr. Copilot: stdout
  `{"permissionDecision":"deny","permissionDecisionReason":"<reason>"}`, exit 0. Reason: `agentic
  gate: <why>; not allowed in this task. Use agentic-ask if you need it.`
- **Report.** On a block the gate POSTs `{rule, command}` to `$AGENTIC_BRIDGE_URL/gate` with the
  agent token (in a mode 600 header file, never on a command line; `--noproxy '*'`), best-effort
  (1 s timeout), skipped without a bridge. The bridge emits a `gate` event.
- **Ask-guard.** Blocks `AskUserQuestion` and `ExitPlanMode` (Claude) and `ask_user` and
  `exit_plan_mode` (Copilot) with `Use agentic-ask; nobody can answer a chooser here.`

### Notify

Every `state` event is appended as one line to `/events/events.jsonl` when `/events` is mounted.
On `waiting`, `idle`, `failed` and `stopped`, when `AGENTIC_NOTIFY_WEBHOOK` is set, the bridge
POSTs `{"task","project","state","question":{id,text,options,recommendation}|null,"summary",
"reply":"agentic answer <ID> Q<n> \"…\"" (or `agentic send <ID> \"…\"` when no question is open),"ts"}` (5 s timeout, one retry). A failure goes to
`bridge.log` and an `error` event; it never blocks. The host appends `interrupted` when `status`
first derives it, to its own log `$AGENTIC_DATA/projects/<project>/events.jsonl`, not to the
shared log: tasks write `/events`, so the host never writes there.

## Environment

Read by the bridge (`bridge/src/config.ts`):

| Variable | Default | Meaning |
|---|---|---|
| `AGENTIC_TASK_TOKEN` | required | task token, 16 or more characters, must differ from the agent token |
| `AGENTIC_AGENT_TOKEN` | required | agent token (`/ask`, `/gate`), 16 or more characters |
| `AGENTIC_AGENT` | `claude` | `claude` or `copilot` |
| `AGENTIC_MODEL` | none | model name passed to the agent |
| `AGENTIC_TASK_ID` | `task` | task id |
| `AGENTIC_PROJECT` | `project` | project name |
| `AGENTIC_BRANCH` | none | the task's branch |
| `AGENTIC_PROMPT` | none | first prompt when `prompt.md` is absent (cloud) |
| `AGENTIC_TASK_DIR` | `/task` | the task's state directory |
| `AGENTIC_WORK` | `/work` | the working tree |
| `AGENTIC_EVENTS_DIR` | `/events` | project notify log directory |
| `AGENTIC_IDLE_TIMEOUT` | `900` | seconds in `waiting` or `idle` before suspension |
| `AGENTIC_BRIDGE_PORT` | `8765` | listen port, 1 to 65535 |
| `AGENTIC_BRIDGE_HOSTS` | none | extra accepted `Host` names, comma-separated |
| `AGENTIC_BRIDGE_ORIGINS` | none | accepted `Origin` values, comma-separated |
| `AGENTIC_NOTIFY_WEBHOOK` | none | webhook URL for `waiting`, `idle`, `failed`, `stopped` |
| `AGENTIC_ALLOWED_ACTIONS` | none | comma-separated grants for the initial allowed actions |
| `AGENTIC_DIR` | `/opt/agentic` | image directory (holds `task/task-prompt.md`) |
| `AGENTIC_ACP_CMD` | none | JSON array replacing the agent command (test hook) |

Read by the image and the host:

| Variable | Default | Meaning |
|---|---|---|
| `AGENTIC_GATE` | `1` for `agentic-bridge` and worker mode, else `0` | installs the hooks and turns the gate on; a value in `.agentic/.env` reaches every task and wins, so `run` warns when it is not `1` |
| `AGENTIC_GATE_PROTECTED` | `prod production` | words that always block a deploy-like command |
| `AGENTIC_MAX_RUNNING` | `3` | cap on running task containers per host; `run`, and any verb that has to start a task's container (`send`, `answer`, `resume`, `stop`, `takeover`), refuse at the cap; a verb on an already running container does not count |
| `AGENTIC_WORKSPACES` | `~/agentic-workspaces` | host directory holding the per-project workspaces (see Files) |
| `AGENTIC_START_TIMEOUT` | `120` | seconds the host waits for the bridge to leave `starting` |
| `AGENTIC_BRANCH_PREFIX` | `agentic/` | prefix of the generated branch name |
| `AGENTIC_TASK_DOCKER_ARGS` | none | extra `docker run` arguments (test hook) |
| `AGENTIC_REPO_URL` | none | cloud: start step `05-workspace` clones it when no worktree is mounted |

`run` passes `AGENTIC_IDLE_TIMEOUT`, `AGENTIC_NOTIFY_WEBHOOK` and `AGENTIC_GATE_PROTECTED` into
the container when they are set on the host.

## Cloud

The container runs from env alone: `docker run -v <volume>:/task -e AGENTIC_REPO_URL=… -e
AGENTIC_TASK_TOKEN=… -e AGENTIC_AGENT_TOKEN=… -e AGENTIC_PROMPT=… <image> agentic-bridge`. All
state, including the harness sessions, is on the `/task` volume, so a suspended task resumes in a
new container.

`AGENTIC_MAX_RUNNING` (default 3) caps running task containers per host, because all tasks share
one account's rate limits. `run` and starting a suspended, interrupted or failed task refuse at the cap
with a clear message; there is no queue in version 1.

**Outbound mode (designed, not built).** With `AGENTIC_RELAY_URL` the bridge would dial a relay
over WSS instead of listening, authenticate with the task token, receive requests as frames
`{id, method, path, headers, body}`, answer them through the same route functions, and push
events on the same connection. The routes are already transport-neutral. TLS and user
authentication beyond the host are a hub's or reverse proxy's job.

## Spike results

Measurements of both agents under ACP (capabilities, hooks, bypass, permission requests, resume)
are in section 13 of the design: `docs/specs/2026-10-12-sub-project-2-acp-bridge-design.md`.
