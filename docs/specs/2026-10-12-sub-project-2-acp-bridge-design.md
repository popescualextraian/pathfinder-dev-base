# Sub-project 2 — detached tasks through an ACP bridge

Status: design approved in dialogue, 2026-10-12; awaiting review of this file. Umbrella:
`docs/architecture.md`. Builds on sub-project 1 (`2026-10-07-sub-project-1-base-image-design.md`).
Replaces the tmux design kept under the tag `archive/sub-project-2-tmux`.

## 1. Outcome

A developer, or a simple integration, starts a detached task in a container built from our
image, follows it, answers its questions (with grants that unblock the action gate), cancels a
turn, resumes and stops it, through a small HTTP + WebSocket API and the `agentic` CLI. The agent
is driven through the Agent Client Protocol (ACP), not through its terminal UI. Claude Code and
Copilot CLI behave the same.

The runtime is deliberately small and hub-less. A task hub brings its own driver and uses only our
image, the gate and the worker-mode hook; no hub is named in this repository.

Success criteria:

- `agentic run "<prompt>"` prints a task id; the task runs unattended with Claude or Copilot, and
  every verb behaves the same for both.
- A question asked with `agentic-ask` moves the task to `waiting`, raises a notification, and
  `agentic answer` (optionally with `--allow`) delivers the answer whether the container is
  running or has exited.
- A waiting or idle task suspends after the idle timeout (its container exits) and resumes the
  same agent session on the next prompt or answer, also in a new container on the same volume.
- `git push`, PR creation and deploys are blocked unless allowed by `--allow` or a grant; merges
  and protected environments are always blocked. The agent sees the reason.
- `make test`, `make lint` and `make smoke` pass.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | The runtime (bridge, hooks, gate) lives in the image | Any launcher (CLI, hub, VM) gets the same runtime and gate |
| D6 | Repositories without config: any clone in the project workspace is available; `--repo` picks which get a task worktree | Simple; multi-repo from the start |
| D8 | No choosers; questions go through `agentic-ask` and the runtime | A chooser in a detached session cannot be answered |
| D9 | The gate is per task: `--allow` at start, grants with answers; no gate config in `agentic.yaml` | Narrow guard inside permission-bypass mode |
| D10 | No automatic resume after a crash; the task shows `interrupted` | Nothing spends tokens unobserved |
| D11 | Workflows (pipelines, reviews, reports, `/design`) stay out of the base | They belong to overlays and projects |
| D12 | Agents are driven over ACP: Claude through `claude-agent-acp`, Copilot through `copilot --acp` | Structured stream, cancel, permission requests and session load without terminal scraping (spike, §13) |
| D13 | The bridge is TypeScript on Node 22 with `@agentclientprotocol/sdk`; its dependencies are pinned and built into the image; nothing is fetched at run time | Both agents are Node programs; no second runtime |
| D14 | One bridge per task, inside the task container, as its main process | Isolation per task; same shape locally and in the cloud |
| D15 | State lives in files on one task volume; one writer (the bridge); no database | The gate (bash) and the host CLI read plain files; SQLite locking is unreliable on WSL drvfs and network volumes; the data is small and linear |
| D16 | Light HTTP + WebSocket API, version 1, per container, bound to loopback on the host | A CLI and simple integrations need no more |
| D17 | `AGENTIC_GATE` switches the hooks on; on by default for the bridge and worker mode, off for dev mode | A hub's worker gets the gate too |
| D18 | Suspended containers exit; listing combines live bridges, container labels and the task files | A waiting task holds no memory |

## 3. Components

```
host                                   task container agentic-<project>-task-<ID>
────                                   ──────────────────────────────────────────
bin/agentic run/status/follow/  ─HTTP/WS 127.0.0.1:<port>─▶  agentic-bridge  (main process after start.d)
  send/answer/cancel/stop/                                ├─ api       HTTP + WS, tokens, Host/Origin checks
  resume/logs/shell/takeover/                             ├─ task      state machine, questions, inbox, idle timer
  clean                                                   ├─ store     state.json · events.jsonl · questions.jsonl · transcript.md
                                                          ├─ agent     ACP client: spawn, initialize, new/load, prompt, cancel
  docker run/start/rm, git worktrees                      ├─ harness   per-agent facts: command, bypass, permission mapping
                                                          └─ notify    project events log, webhook
                                         agent ── hooks ──▶ hook.sh ─▶ gate.sh, ask-guard.sh, hooks.d
                                               └─ agentic-ask ──▶ bridge POST /ask (agent token)
```

Container labels: `agentic.kind=task`, `agentic.task=<ID>`, `agentic.project=<p>`,
`agentic.agent=<claude|copilot>`, `agentic.branch=<branch>`.

### 3.1 Bridge (`bridge/`)

A TypeScript package at the repository root with its own `package.json`, `package-lock.json`,
`tsconfig.json`, vitest and eslint config. Dependencies, pinned exactly:
`@agentclientprotocol/sdk`, `@agentclientprotocol/claude-agent-acp`, `ws`. HTTP uses `node:http`.

| Module | Responsibility |
|---|---|
| `main.ts` | reads env, wires the modules, handles signals |
| `task.ts` | the state machine (§6), pure: inputs are commands and agent events, outputs are effects |
| `store.ts` | the files of §5.1: atomic `state.json`, append-only JSONL with `seq`, transcript rendering |
| `agent.ts` | the ACP connection: spawn, `initialize`, `session/new`, `session/load`, `session/prompt`, `session/cancel`, `request_permission`; maps updates to events; drops replay |
| `harness.ts` | Claude and Copilot facts (§7.1) |
| `api.ts` | routes as plain functions `(request) → response`, served by `node:http` and `ws` (§8) |
| `notify.ts` | project events log and webhook (§10) |
| `redact.ts` | token patterns (§11) |

The routes are transport-neutral so that an outbound mode (§12) can serve them over another
connection.

### 3.2 Image additions

| Path | Purpose |
|---|---|
| `/opt/agentic/bridge/` | built bridge with production `node_modules` (a Dockerfile build stage runs `npm ci` and the build) |
| `/usr/local/bin/agentic-bridge` | starts the bridge |
| `/usr/local/bin/agentic-ask` | bash + curl: `POST /ask` with the agent token |
| `/opt/agentic/task/hook.sh`, `gate.sh`, `ask-guard.sh`, `lib/harness.sh` | ported from the archive (§9) |
| `/opt/agentic/start.d/45-hooks.sh` | installs the hooks when `AGENTIC_GATE=1` |
| `/opt/agentic/start.d/06-task-home.sh` | with `/task` mounted: creates `/task/home/{claude,copilot}` owned by the user, exports `CLAUDE_CONFIG_DIR` and `COPILOT_HOME` |
| `/opt/agentic/hooks.d/<event>/` | empty in the base; overlay extension point |
| `ENV COPILOT_AUTO_UPDATE=false` | Copilot otherwise downloads a newer CLI into its home and runs it on the next start |

The entrypoint sets `AGENTIC_GATE=1` before the start steps when it is unset and the command is
`agentic-bridge` or `AGENTIC_WORKER_MODE` is set; otherwise `0`.

### 3.3 Changes to sub-project 1

- Schema and defaults: `repos` removed; start step `15-repos` removed (archived commit 734a679).
- `docs/configuration.md` regenerated.
- `docs/architecture.md`: "No database, no server" becomes "no database, no central server; one
  small bridge per task container"; the sub-project 2 row and the component diagram follow this
  spec.
- `docs/overlay.md`: `hooks.d/<event>/`, `AGENTIC_GATE`, notify env, the task env.
- `CLAUDE.md`: a short TypeScript section (strict tsc, eslint, vitest test first, pinned
  dependencies, no run-time fetch) and the bridge in `make test` / `make lint`.

## 4. Repositories and worktrees

As in the archived design (D6):

- Clones live in `$AGENTIC_WORKSPACES/<project>/repos/<name>/`. The project's own repository is
  cloned there on the first `run` from its `origin` URL (credentials stripped). Any other clone
  present is available.
- `run --repo R` (repeatable) names the repositories the task changes; the first is mounted at
  `/work`, others at `/workspaces/<name>`; clones not named are mounted read-only.
- Each changed repository gets a worktree `repos/<R>/.worktrees/<ID>` on one branch, created from
  `--base` (default `origin/HEAD`) after a `git fetch`. Branch: `agentic/<ID>-<slug>`, or
  `--branch`, or `AGENTIC_BRANCH_PREFIX`.
- Each clone's git directory is mounted at its host path, so worktree pointers resolve on both
  sides.
- Without a mounted worktree (cloud), start step `05-workspace` clones `AGENTIC_REPO_URL`.

## 5. Task state on disk

### 5.1 Layout

```
$AGENTIC_WORKSPACES/<project>/
├─ repos/<name>/                    clones; worktrees in .worktrees/<ID>
├─ events/events.jsonl              project-wide notify log            ─▶ /events
└─ tasks/
   ├─ <ID>/                                                            ─▶ /task
   │  ├─ state.json                 the task record (§5.2), written only by the bridge
   │  ├─ events.jsonl               every event (§8.3)
   │  ├─ questions.jsonl            asked and answered records; the last line per id wins
   │  ├─ transcript.md              readable rendering (§5.3)
   │  ├─ prompt.md                  the first prompt
   │  ├─ bridge.log                 bridge diagnostics, redacted
   │  └─ home/claude/, home/copilot/   CLAUDE_CONFIG_DIR, COPILOT_HOME: sessions survive containers
   └─ <ID>.env                      host only, mode 600: AGENTIC_TASK_TOKEN, AGENTIC_AGENT_TOKEN
```

`bin/agentic` creates every directory as the invoking user, so no volume comes up owned by root.
In the cloud, `/task` is one volume and `06-task-home` creates the homes. At creation the homes
are seeded from the project login (`~/.agentic/projects/<p>/harness/<h>`: credentials and config,
mode 600); tokens in `.agentic/.env` work as today.

### 5.2 `state.json`

```json
{"version":1,"task":"T-20261012-a3f1","project":"orders","agent":"claude","model":null,
 "state":"waiting","reason":"question Q2","session":"52e775a2-…","branch":"agentic/T-…-fix-login",
 "created":"…","updated":"…","seq":118,"allowed_actions":["open-pr"],
 "inbox":[{"kind":"answer","question":"Q2","text":"…"}],"summary":"…","stopped_by_user":false}
```

Written atomically (temp file, `fsync`, rename). A corrupt `state.json` stops the bridge with a
message naming the file; it is never reset. A torn last line in a JSONL file is skipped on read.

### 5.3 Transcript

Markdown, appended as the task goes: each user prompt and answer as a quote, each final agent
message as text, each tool call as one line `▸ <title> — <status>` followed, for `done` and
`failed`, by the last 10 lines of output in a fenced block; questions, answers with grants, gate
blocks and state changes as one-line callouts. Redacted.

## 6. States

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

- **Start.** Without `state.json` the bridge creates the record, spawns the agent, opens a
  session, applies bypass (§7.1) and sends `prompt.md` (else `AGENTIC_PROMPT`); `starting →
  running`. With a record the bridge starts **lazily**: it serves the API and spawns nothing until
  a prompt or answer arrives, so a plain `docker start` spends no tokens (D10). A record in
  `starting`, `running`, `waiting` or `idle` found at start is an unclean end: the bridge sets
  `interrupted` and waits.
- **Turn end.** `session/prompt` returns. With an open question the task is `waiting`, else
  `idle`. The summary is the turn's final agent message (300 characters at most). If the inbox is
  not empty, its items are joined into the next prompt at once.
- **Prompt.** Accepted in `idle`, `waiting`, `suspended`, `interrupted` and `failed`; 409 in
  `starting`, `running`, `stopped`. In `suspended`, `interrupted` or `failed` the bridge spawns the agent and calls
  `session/load` first.
- **Answer.** Accepted whenever the question is open, in any state but `stopped`. The question is
  recorded as answered and a grant is added to `allowed_actions` immediately. A permission
  question that is still pending in the agent is answered through ACP (§7.2); otherwise the text
  `Answer to Q<n>: <text>` (plus `Allowed for this task: <grants>.`) goes into the inbox and is
  delivered as soon as no prompt is outstanding (resuming the session if needed).
- **Suspension.** `waiting` or `idle` longer than `AGENTIC_IDLE_TIMEOUT` (default 900 s; any
  input resets it): a pending permission request is answered `cancelled` (its question stays
  open), the agent process ends, `state = suspended`, the bridge exits 0 and the container exits.
- **Resume.** The host starts the container (`docker start`), waits for `GET /status`, then sends.
  The bridge spawns the agent and calls `session/load` with the stored session id; history updates
  replayed before the load returns are dropped. If the load fails because the session is missing,
  the bridge opens a new session seeded with `prompt.md`, the questions and answers, and
  `git log <base>..HEAD` of `/work`, and emits an `error` event saying so.
- **Interrupted.** `agentic resume ID` starts the container and sends `You were interrupted.
  Check git status and continue.`
- **Cancel.** Accepted only in `running` with a prompt outstanding (an earlier cancel arriving
  late was applied to the next prompt by the Claude adapter in the spike); otherwise 409. The task
  stays `running` until the prompt returns `cancelled`, then follows the turn-end rule.
- **Stop.** Cancels a running turn, closes the session where supported, ends the agent, sets
  `stopped`, `stopped_by_user = true`, and the bridge exits 0. No restart policy.
- **Failed.** The agent process exits outside a stop or suspension, or an ACP call fails: `failed`
  with the reason; the bridge exits 1 and the container stays for inspection. `resume` may retry.

## 7. Agents

### 7.1 Harness facts

| | Claude | Copilot |
|---|---|---|
| Command | `node /opt/agentic/bridge/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js` with `CLAUDE_CODE_EXECUTABLE=/usr/local/bin/claude` (one Claude version per image) | `copilot --acp --allow-all` |
| Bypass | `session/set_mode bypassPermissions` after `session/new`; restored by `session/load` | the `--allow-all` flag |
| Task paragraph | `_meta.systemPrompt.append` on `session/new` and `session/load` | a managed block in `$COPILOT_HOME/copilot-instructions.md` |
| Model | the adapter's `model` config option (listed in `configOptions`), set after `session/new` when `--model` is given | `--model` flag |
| Session resume | `session/load` | `session/load` |
| Takeover | `claude --resume <session>` | `copilot --resume=<session>` |

`AGENTIC_ACP_CMD` (JSON array) replaces the command; it exists for tests (the fake agent, §14).

Task paragraph (both): "You run unattended in a container; nobody watches this session. When you
need a human decision, run `agentic-ask`, continue with any work that does not depend on the
answer, and end your turn when nothing else can move. Answers arrive as `Answer to Q<n>: ...`.
Outward actions not allowed for this task are blocked; ask if you need one."

### 7.2 Permission requests

With bypass, neither agent sent `session/request_permission` in the spike; the bridge still
handles them. Each becomes a `question` with `source: permission`, the tool call's title and
command (`rawInput.command`; Copilot's title is a model-written summary), and the option names as
`options`. The answer text must match an option's name or kind (`allow`, `allow once`, `allow
always`, `reject`; case-insensitive), else 400; the bridge replies with that `optionId`.

## 8. API, version 1

### 8.1 Transport and auth

The bridge listens on `0.0.0.0:8765` inside the container; `bin/agentic` publishes it as
`127.0.0.1::8765` (a random host port, loopback only, never all interfaces) and reads the port with
`docker port` on every call, because `docker start` may change it.

Every request, WebSocket upgrade included, needs `Authorization: Bearer <token>`:

- **task token** (`AGENTIC_TASK_TOKEN`): every route.
- **agent token** (`AGENTIC_AGENT_TOKEN`): only `POST /ask` and `POST /gate`. The bridge passes it
  to the agent's environment with `AGENTIC_BRIDGE_URL=http://127.0.0.1:8765`, and removes the task
  token from that environment.

Both are 32 random bytes, generated by `run`, kept in `tasks/<ID>.env` (mode 600) and passed with
`--env-file`. A `Host` header other than `127.0.0.1:<port>`, `localhost:<port>` or a name in
`AGENTIC_BRIDGE_HOSTS` gets 403; any `Origin` header not listed in `AGENTIC_BRIDGE_ORIGINS` gets
403. Request headers are never logged. Comparison of tokens is constant-time.

Threat model: the bridge and the agent run as one user in one container, so the agent could read
the bridge's environment or edit `state.json`. The tokens keep other host processes and browsers
(DNS rebinding) out; they do not contain the agent. The gate guards against slips, not a hostile
agent. Anyone with access to the Docker socket can read the tokens (`docker inspect`) and is root
on the host anyway.

### 8.2 Routes

| Route | Body | Success | Errors |
|---|---|---|---|
| `POST /prompt` | `{text}` | 202, status | 400 empty, 409 state |
| `POST /answer` | `{question?, text, grant?: [..]}` (default: the oldest open question) | 202, status | 400 empty or bad grant, 404 unknown question, 409 nothing open or stopped |
| `POST /cancel` | — | 202, status | 409 not running |
| `POST /stop` | — | 202, status | — |
| `GET /status` | — | 200, status | — |
| `GET /events?since=SEQ&limit=N` | — | 200, `application/x-ndjson`, events with `seq > SEQ` | 400 |
| `WS /events?since=SEQ` | — | the backlog, then live events, one JSON object per text frame; ping every 30 s | — |
| `POST /ask` (agent token) | `{text, options?, recommend?}` | 201 `{id}` | 400 empty, 409 stopped |
| `POST /gate` (agent token) | `{rule, command}` | 204 | — |

Grants: `push`, `open-pr`, `deploy:<target>`. Errors share one body:
`{"error":{"code":"<bad_request|unauthorized|forbidden|not_found|conflict|starting>","message":"…"}}`;
401 carries no detail; 503 `starting` until the bridge can take commands. The status object is
`state.json` without `inbox` items (their count instead) plus `questions` (the open ones:
`{id, source, text, options, recommendation, asked}`).

### 8.3 Events

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
| `error` | `{message}` | bridge and agent errors |

Not emitted in version 1: thoughts, usage, available commands, config options, session titles,
and history replayed by `session/load`. `seq` increases by one per event and is the cursor.

## 9. Gate, hooks, questions

Ported from the archive with their tests (72eb25d, e679770, 429eb72, 16145d1, edd0d15, 29b3a82),
with these changes:

- **Trigger.** `45-hooks` runs when `AGENTIC_GATE=1` (was: `AGENTIC_TASK_ID` set). An unreadable
  `settings.json` fails the start: a task must not run unguarded. `--check` as for every step.
- **Installation.** Claude: a managed block in `$(claude_dir)/settings.json`, other hooks left
  alone. Copilot: `$(copilot_dir)/hooks/agentic.json` with the camelCase events `sessionStart`,
  `userPromptSubmitted`, `preToolUse`, `postToolUse`, `agentStop` (confirmed under `--acp`, §13).
  The installed command names the harness: `bash /opt/agentic/task/hook.sh <claude|copilot> <event>`.
- **Dispatch.** `hook.sh` keeps no record (the bridge owns state). On `pretooluse` it runs
  `gate.sh`, `ask-guard.sh`, then `hooks.d/pretooluse/*.sh` of the image and of the project
  (`/agentic-config/hooks.d/`); any other event runs only the `hooks.d/<event>/` scripts. A guard
  that exits anything but 0 or 2 blocks. Nothing else fails a turn.
- **Block format.** Claude: exit 2, the reason on stderr. Copilot: stdout
  `{"permissionDecision":"deny","permissionDecisionReason":"<reason>"}`, exit 0 (exit 2 loses the
  reason under Copilot, §13). Reason: `agentic gate: <why>; not allowed in this task. Use
  agentic-ask if you need it.`
- **Allowed actions.** From `/task/state.json` when present, else `AGENTIC_ALLOWED_ACTIONS`
  (comma-separated; hub mode). Rules unchanged (archived §8: push, open-pr, deploy-like commands
  with `deploy:<target>`, merges and protected words always blocked).
- **Report.** On a block the gate POSTs `{rule, command}` to `$AGENTIC_BRIDGE_URL/gate` with the
  agent token, best-effort (1 s timeout), skipped without a bridge.
- **Ask-guard.** Blocks `AskUserQuestion` and `ExitPlanMode` (Claude) and `ask_user` and
  `exit_plan_mode` (Copilot) with `Use agentic-ask; nobody can answer a chooser here.` The Claude
  adapter already hides `AskUserQuestion` from clients without form elicitation; the guard covers
  dev mode and hubs.
- **`agentic-ask "text" [--option X]… [--recommend X]`.** POSTs `/ask`; prints `Recorded Q<n>.
  Continue with work that does not depend on it; when nothing else can move, end your turn.`
  Without `AGENTIC_BRIDGE_URL` it exits 1 with `agentic-ask works only inside a task`.

## 10. Notify

- Every `state` event is appended as one line to `/events/events.jsonl` when `/events` is mounted
  (single `write` with `O_APPEND`; lines stay under 4 KB, so concurrent bridges do not interleave).
- On `waiting`, `idle`, `failed` and `stopped`, when `AGENTIC_NOTIFY_WEBHOOK` is set, the bridge
  POSTs: `{"task","project","state","question":{id,text,options,recommendation}|null,"summary",
  "reply":"agentic answer <ID> Q<n> \"…\"","ts"}`; 5 s timeout, one retry. Failures go to
  `bridge.log` and an `error` event; they never block.
- `interrupted` is appended by the host when `status` first derives it.
- Desktop toasts and `agentic watch` are later.

## 11. Security and secrets

- No secret in `state.json`, events, questions, the transcript, notify payloads or logs.
  `redact.ts` masks `sk-ant-…`, `gh[opsu]_…`, `github_pat_…`, `Bearer …`, `AKIA…` and the task's own
  two tokens; the bash side keeps its `REDACT_SED`.
- Copied credentials keep mode 600; `tasks/<ID>.env` is 600 and never mounted.
- The bridge never logs request headers or bodies of `/answer` beyond what events carry.

## 12. Cloud and limits

- The container runs from env alone: `docker run -v <volume>:/task -e AGENTIC_REPO_URL=… -e
  AGENTIC_TASK_TOKEN=… -e AGENTIC_AGENT_TOKEN=… -e AGENTIC_PROMPT=… <image> agentic-bridge`. All
  state, including the harness sessions, is on the `/task` volume, so a suspended task resumes in a
  new container.
- `AGENTIC_MAX_RUNNING` (default 3) caps running task containers per host (all tasks share one
  account's rate limits). `run` and starting a suspended or interrupted task refuse at the cap with
  a clear message; no queue in version 1.
- **Outbound mode (designed, not built).** With `AGENTIC_RELAY_URL` the bridge would dial a relay
  over WSS instead of listening, authenticate with the task token, receive requests as frames
  `{id, method, path, headers, body}`, answer them through the same route functions, and push
  events on the same connection. TLS and user authentication beyond the host are a hub's or
  reverse proxy's job.

## 13. Spike results (2026-10-12)

On `agentic-dev-base:local` (Claude Code 2.1.295, Copilot CLI 1.0.94, `claude-agent-acp` 0.89.1,
`@agentclientprotocol/sdk` 1.8.0), in throwaway containers, with a raw JSON-RPC client.

| | Claude via `claude-agent-acp` | Copilot via `copilot --acp` |
|---|---|---|
| `initialize` | `loadSession: true`; session close, delete, fork, list, resume; prompt queueing | `loadSession: true`; session close, list |
| Multi-turn, streaming | yes: message chunks, tool calls and updates | yes, plus many `agent_thought_chunk` |
| Cancel (foreground command) | `stopReason: cancelled`; next prompt fine | same |
| `session/load` after a process restart, and in a new container sharing only the harness home and `/work` volumes | yes; history is replayed as `user_message_chunk` / `agent_message_chunk` before the response; bypass mode restored | yes; history replayed |
| Loads | project and user CLAUDE.md, user skills, baked plugins, MCP servers from `~/.claude.json` (behind tool search) | `AGENTS.md`, `~/.copilot/copilot-instructions.md`, user skills |
| Hooks under ACP | SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop (per turn), SessionEnd | sessionStart, userPromptSubmitted, preToolUse, postToolUse, agentStop; camelCase payloads (`sessionId`, `toolName`, `toolArgs` as an object) |
| Gate block reaches the agent | exit 2 + stderr: `PreToolUse:Bash hook error: […]: agentic gate: …` | only with the JSON deny on stdout: `Denied by preToolUse hook: agentic gate: …`; exit 2 gives `hook exited with code 2` |
| Bypass | `session/set_mode bypassPermissions` (session starts in `default`) | `--allow-all`; modes are `agent`, `plan`, `autopilot` |
| `request_permission` with bypass | none | none |
| `request_permission` without bypass | options `allow-once`/`allow_once` "Yes", `allow-with-updates`/`allow_always`, `reject`/`reject_once` "No"; title = the command; `rawInput {command, description}` | options `allow_once` "Allow once", `allow_always` "Always allow", `reject_once` "Deny"; title = a model summary; `rawInput {command, commands}` |

Other findings, reflected above:

- Claude may move a long command into the background by itself; the turn then ends before a
  cancel arrives. A cancel sent as a turn ended was applied by the adapter to the next prompt
  (§6, Cancel).
- Without `CLAUDE_CODE_EXECUTABLE` the adapter runs the native Claude binary bundled with its SDK,
  a second Claude version in the image (§7.1).
- Copilot downloaded 1.0.95 into its home during the spike and ran it on the next start
  (`COPILOT_AUTO_UPDATE=false`, §3.2).
- Named volumes mounted at paths absent from the image come up owned by root, and the start steps
  fail (§5.1).
- Copilot accepts a fine-grained token with "Copilot Requests", or the OAuth token of the GitHub
  CLI (`gh auth token`); classic `ghp_` tokens are refused.

## 14. Testing

Tests are written before the code.

| Layer | Covers | Command |
|---|---|---|
| vitest, unit | `task.ts`: every transition, inbox delivery, idle timer, cancel only while running, interrupted at start; `store.ts`: atomic writes, `seq`, torn last line, transcript rendering; `redact.ts`; `agent.ts` update mapping with recorded spike transcripts of both agents as fixtures (redacted, leak-checked), replay dropped on load; `api.ts`: tokens and scopes, Host and Origin, the error model, `since` cursors; `notify.ts` | `make test` |
| vitest, integration | the bridge against a fake ACP agent (`bridge/test/fake-agent.ts`: scripted replies, tool calls, permission requests, cancel, load with replay, crash) | `make test` |
| bats | `hook.sh` per harness and block format; gate and ask-guard (ported); `45-hooks` and the `AGENTIC_GATE` defaults; `06-task-home`; `agentic-ask` against a stub server; `bin/agentic` verbs with Docker stubbed; worktree and mount assembly on temporary repositories; status merge and `interrupted`; `clean` refusal | `make test` |
| lint | tsc (strict), eslint, shellcheck, leak check | `make lint` |
| smoke | the real image with the fake agent: `run` → idle; ask → waiting → `answer --allow push` → the gate lets the retry pass; short idle timeout → container exits → `send` → load → running; `stop`; `docker kill` → interrupted → `resume` | `make smoke` |
| manual | `tests/e2e/`: the spike flow against real Claude and Copilot with the developer's tokens | by hand |

## 15. Host CLI

| Verb | Arguments | Does |
|---|---|---|
| `run` | `"prompt"` or `--prompt-file F`; `[--agent claude\|copilot] [--model M] [--repo R]… [--base REF] [--branch B] [--allow A]… [--id ID] [--keep-on-failure] [--json]` | worktrees, task directory, tokens, `prompt.md`; `docker run -d` with labels, `-p 127.0.0.1::8765`, mounts, `--env-file .agentic/.env`, `--env-file tasks/<ID>.env`, `AGENTIC_ALLOWED_ACTIONS`, command `agentic-bridge`; waits until `starting` is left; prints the id, and `follow: agentic follow <ID>` on stderr; `--json` prints `{task, container, port, branch}`; rolls back on failure |
| `status` | `[ID] [--all] [--json]` | per task: live `GET /status`, else `state.json`, else `interrupted`; table `TASK STATE AGENT QUESTIONS AGE BRANCH`; `--all` every project |
| `follow` | `ID [--since SEQ] [--raw] [--forever]` | WebSocket; readable lines (`--raw`: JSON); exits on waiting, idle, stopped or failed unless `--forever` |
| `send` | `ID "text"` | `POST /prompt`, starting a suspended container first |
| `answer` | `ID [QID] "text" [--allow A]…` | `POST /answer`, starting a suspended container first |
| `cancel`, `stop` | `ID` | `POST /cancel`, `POST /stop` (`docker stop` if the bridge does not answer) |
| `resume` | `ID` | interrupted or failed tasks: start and send the resume prompt |
| `logs` | `ID [--transcript\|--bridge\|--start]` | the files, live or not |
| `shell` | `ID` | `docker exec -it` a shell in the running container |
| `takeover` | `ID` | stops the task, then runs an interactive container on the same state with `claude --resume <session>` or `copilot --resume=<session>`; no hand-back in version 1 |
| `clean` | `ID [--force]` | removes the container, worktrees, local branch, record and `<ID>.env`; refuses when a worktree has commits not on its remote branch, unless `--force` |

Task id: `T-<yyyymmdd>-<4 hex>` unless `--id` (`[A-Za-z0-9._-]+`). Agent and model default to
`harness.default` and `harness.<h>.model` from `agentic.yaml`. `agentic dev`, `shell`, `setup` and
`login` are unchanged.

## 16. Documentation

- This spec.
- `docs/tasks.md`: the contract a hub or integration uses: API, events, states, files, env.
- `docs/architecture.md`, `docs/overlay.md`, `docs/configuration.md`, `CLAUDE.md` as in §3.3.
- `README.md`: a "Detached tasks" quick start.

## 17. Out of scope (version 1)

Several conversations per task and `switch`; workflows (D11); thought and usage events; prompt
queueing; a web UI; desktop toasts and `agentic watch`; takeover hand-back; automatic resume
(D10); the relay implementation; a database; any hub adapter.
