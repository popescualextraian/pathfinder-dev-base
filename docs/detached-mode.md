# Detached mode

`agentic run "prompt"` starts an unattended task: a container set up like your dev container with
your checkout at `/work`, and one agent session (Claude Code or Copilot CLI) driven by a small bridge in the image. You leave it
working and come back when it asks something or is done. Several tasks run side by side. Use
[dev mode](dev-mode.md) when you want to sit with an agent; use detached mode when you want to
hand a task off.

This guide is how to use it. The full contract (states, API, events, files, every variable) is
[`tasks.md`](tasks.md).

## Before the first task

1. The project is set up as for dev mode: `agentic init`, `agentic build`, `agentic login`
   (or tokens in `.agentic/.env`). `agentic doctor` should pass.
2. `agentic.yaml` says what the project is: `layout: single` (the project root is a git
   repository) or `layout: multi` (git repositories in its subfolders, with a default `target:`).
   `agentic init` writes both; `agentic target NAME` sets the target.
3. If the task should push or open a pull request, the container needs the git credentials your
   project already uses in dev mode (for example a token in `.agentic/.env`).

## Commands

| Command | What it does |
|---|---|
| `agentic run "prompt" [options]` | Starts a task in a new container and prints its id, for example `T-20261013-a6ec`. |
| `agentic status [ID] [--all] [--json]` | Lists this project's tasks; with an id, the task, its open questions and how to reply. |
| `agentic follow ID [--raw] [--forever] [--status]` | Streams what the agent does until the task waits, idles or ends; `--status` only state changes, questions, answers and whole messages. `Ctrl-c` only stops watching. |
| `agentic answer ID [QID] "text" [--allow A]` | Answers the oldest (or the named) open question; `--allow` grants an action at the same time. |
| `agentic send ID "text"` | A new prompt: more work, a correction. It wakes a suspended task. |
| `agentic cancel ID` | Ends the current turn; the task stays and takes the next prompt. |
| `agentic stop ID` | Ends the task and stops its container. The worktree and files stay. |
| `agentic resume ID` | Continues an interrupted or failed task. |
| `agentic logs ID [--transcript\|--bridge\|--start]` | The readable transcript, the bridge's log and its own output (`bridge.out`), or the container start log. |
| `agentic shell ID` | A shell in the running task container, to look around. |
| `agentic takeover ID` | Stops the task and opens its session interactively, with the same history. |
| `agentic clean ID [--force]` | Removes the worktree and branch, the container the task created, and the task files. |

`run` options: `--prompt-file F` (a long prompt from a file), `--agent claude|copilot`,
`--model M`, `--allow push|open-pr|deploy:<target>` (repeatable), `--target T` (multi layout: the
repository to work in), `--in ID` (run in that task's container, one task at a time),
`--worktree` (own worktree and branch), `--auto-clean` (clean up after a normal end),
`--publish PORT` (repeatable: open an app the task runs, see below), `--id ID`,
`--keep-on-failure`, `--json`.

## A typical task

```bash
agentic run --allow open-pr "Fix the failing login test and open a pull request"
# T-20261013-a6ec
agentic follow T-20261013-a6ec      # watch it work; Ctrl-c whenever you like
```

1. The task starts in `running`. `follow` shows its messages and each tool call as it happens.
2. When the agent needs a decision, it asks with `agentic-ask` and keeps working on what does not
   depend on the answer. When nothing else can move, its turn ends and the task is `waiting`.
3. `agentic status` shows the question and a ready reply line:

   ```bash
   agentic status T-20261013-a6ec
   agentic answer T-20261013-a6ec Q1 "Yes, use the staging config" --allow push
   ```

4. When a turn ends with nothing open, the task is `idle`. Give it more with `agentic send`.
5. After 15 minutes `waiting` or `idle` (`AGENTIC_IDLE_TIMEOUT`), the task suspends: the agent ends
   and the bridge exits. The container keeps running (it costs memory, not tokens) until
   `agentic stop` or `agentic clean`. `answer` or `send` starts the bridge again (and the container,
   if it was stopped) with the same session.
6. When you are done: `agentic stop ID`, then `agentic clean ID` once its work is pushed.

## States

| State | Meaning | What you do |
|---|---|---|
| `starting`, `running` | The agent is working. | `follow`; `cancel` to end the turn. |
| `waiting` | A question is open. | `status ID`, then `answer`. |
| `idle` | Turn done, nothing open. | `send` more work, or `stop`. |
| `suspended` | Idle too long; the bridge exited, the container runs on. | `answer` or `send` wakes it. |
| `interrupted` | The container went away without a stop (reboot, `docker kill`). | `resume`. |
| `failed` | The agent crashed or refused the prompt. The container stays for inspection. | `logs`, then `resume`. |
| `stopped` | Ended by you. Final. | `takeover` to continue by hand, or `clean`. |

## What the agent may do

The task's agent runs without permission prompts, so an action gate guards what reaches the
outside world:

- `git push`, opening a pull request and deploy-like commands are refused unless allowed with
  `--allow push`, `--allow open-pr` or `--allow deploy:<target>`, on `run` or on any `answer`.
  A refused agent sees why and can ask for the grant with `agentic-ask`.
- Merges, and deploys to targets named like `prod` (`AGENTIC_GATE_PROTECTED`), are always refused.
- Interactive choosers are blocked; the agent asks through `agentic-ask` instead, so every question
  reaches you as a question you answer with `agentic answer`.

## The checkout, worktrees, getting the work out

- The task works on your checkout, mounted at `/work`, as the dev container does. In a multi
  layout the agent starts in the target repository (`--target`, else `target:`). Without
  `--worktree` its changes land in your checkout, so run one such task at a time.
- With `--worktree` the task works in `.worktrees/<ID>` of the target on a new branch,
  `agentic/<ID>-<words from the prompt>`, made inside the container from the target's current
  `HEAD`. Your own files are not touched.
- The work leaves the task through a push or a pull request, so allow one of them when you want
  the result back. Your machine never runs git on the project; the credentials the container
  uses are the ones your project already passes in dev mode.
- `--in ID` runs a new task in the container of task `ID`, one task at a time.
- `--publish 3100` lets you open an app the task starts on port 3100: `agentic status ID` shows
  `port 3100 -> 127.0.0.1:49213`, so you browse `http://127.0.0.1:49213`. The app must listen on
  `0.0.0.0` inside the container (many dev servers default to `localhost`). The port is reachable
  from your machine only, with no authentication added. The host port changes when the container
  restarts, and ports cannot be added later (`--in` refuses `--publish`).
- A container is kept after its task ends, so you can look at it. `clean` removes it; with
  `--auto-clean` a task that ends normally cleans up by itself.
- `clean` refuses while the worktree has uncommitted changes or commits on no remote branch;
  `--force` cleans anyway. Remote branches stay. Without `--worktree`, `clean` leaves `/work` as
  it is.
- Files stored with Git LFS arrive as pointer files in a task's worktree.

## Several tasks

Run as many as you like; at most three run at once (`AGENTIC_MAX_RUNNING`), because they share one
account's rate limits. `run`, and waking a suspended task, refuse at the cap with a message; stop
or wait for one to suspend. `agentic status` lists them all, `agentic status --all` every project.

To start a task at a set time, once or on a cron schedule, see [scheduled runs](scheduled-runs.md):
`agentic schedule add` runs a detached task from your crontab and keeps its summary.

## Being told when a task needs you

Set `AGENTIC_NOTIFY_WEBHOOK` (on the host when you run, or in `.agentic/.env`) to a URL. When a
task waits, idles, fails or stops, the bridge POSTs a small JSON message with the question and a
ready `agentic answer ...` reply line. Every state change is also appended to
`~/agentic-workspaces/<project>/events/events.jsonl`, which any tool can watch.

A UI or orchestrator watching many tasks can subscribe to `WS /events?view=status` on each bridge:
state changes, questions, answers, errors and whole messages at the end of a turn, without the
message chunks and tool updates of the full stream (see Views in [`tasks.md`](tasks.md#events)).

## Safety in brief

A task can change your checkout (a worktree limits that to its own branch), commit, and use the
network for its work. It cannot run anything on your machine outside its container: your machine
runs no git on the project, and the task's tokens and settings live in a host-only directory. The
checkout, `.git` included, is writable by the task, as in dev mode, and the project's task
containers share `/tasks`. What remains, and the reasoning, is in the threat model of
[`tasks.md`](tasks.md).

## When something is off

- `run` refused or failed: it rolled back and printed the reason (with `--keep-on-failure` the
  container and files stay for a look).
- `status` says `unknown`: Docker did not answer; check `docker ps`.
- A task waits but you do not see the question: `agentic status ID` lists it, also when the
  container has exited.
- `has no container`: the container was removed (for example by `docker container prune`); the
  task cannot be resumed. `clean` still works.
- `no layout in .agentic/agentic.yaml`: run `agentic init` again. For several repositories and
  no target, `agentic target NAME`.
- The agent says it is not logged in: `agentic doctor`, then `agentic login`, then `resume`.
- You want to finish a task yourself: `agentic takeover ID` continues the same session in your
  terminal.
