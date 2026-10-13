# Detached mode

`agentic run "prompt"` starts an unattended task: its own container, its own git worktree, and
one agent session (Claude Code or Copilot CLI) driven by a small bridge in the image. You leave it
working and come back when it asks something or is done. Several tasks run side by side. Use
[dev mode](dev-mode.md) when you want to sit with an agent; use detached mode when you want to
hand a task off.

This guide is how to use it. The full contract (states, API, events, files, every variable) is
[`tasks.md`](tasks.md).

## Before the first task

1. The project is set up as for dev mode: `agentic init`, `agentic build`, `agentic login`
   (or tokens in `.agentic/.env`). `agentic doctor` should pass.
2. The repository's `origin` is a real remote: `https://`, `ssh://`, `git://` or `host:path`. A
   repository without `origin` also works (the task clones your checkout). Local paths and
   `file://` remotes are refused.
3. If the task should push or open a pull request, the container needs the git credentials your
   project already uses in dev mode (for example a token in `.agentic/.env`).

## Commands

| Command | What it does |
|---|---|
| `agentic run "prompt" [options]` | Starts a task and prints its id, for example `T-20261013-a6ec`. |
| `agentic status [ID] [--all] [--json]` | Lists this project's tasks; with an id, the task, its open questions and how to reply. |
| `agentic follow ID [--raw] [--forever]` | Streams what the agent does until the task waits, idles or ends. `Ctrl-c` only stops watching. |
| `agentic answer ID [QID] "text" [--allow A]` | Answers the oldest (or the named) open question; `--allow` grants an action at the same time. |
| `agentic send ID "text"` | A new prompt: more work, a correction. It wakes a suspended task. |
| `agentic cancel ID` | Ends the current turn; the task stays and takes the next prompt. |
| `agentic stop ID` | Ends the task for good. The worktree and files stay. |
| `agentic resume ID` | Continues an interrupted or failed task. |
| `agentic logs ID [--transcript\|--bridge\|--start]` | The readable transcript, the bridge's log, or the container start log. |
| `agentic shell ID` | A shell in the running task container, to look around. |
| `agentic takeover ID` | Stops the task and opens its session interactively, with the same history. |
| `agentic clean ID [--force]` | Removes the container, the worktree, the local branch and the task files. |

`run` options: `--prompt-file F` (a long prompt from a file), `--agent claude|copilot`,
`--model M`, `--allow push|open-pr|deploy:<target>` (repeatable), `--repo R` (repeatable, see
below), `--base REF`, `--branch B`, `--id ID`, `--keep-on-failure`, `--json`.

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
   and the container exits, so it costs nothing. `answer` or `send` wakes it with the same session.
6. When you are done: `agentic stop ID`, then `agentic clean ID` once its work is pushed.

## States

| State | Meaning | What you do |
|---|---|---|
| `starting`, `running` | The agent is working. | `follow`; `cancel` to end the turn. |
| `waiting` | A question is open. | `status ID`, then `answer`. |
| `idle` | Turn done, nothing open. | `send` more work, or `stop`. |
| `suspended` | Idle too long; the container exited. | `answer` or `send` wakes it. |
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

## Git: worktrees, branches, getting the work out

- Each task works in its own worktree on a new branch, `agentic/<ID>-<words from the prompt>`
  (`--branch` to choose; `--base` for the starting point, default the remote's default branch).
  The worktree belongs to a clone of the repository under `~/agentic-workspaces/<project>/repos/`,
  not to your checkout, so your own work is never touched.
- The work leaves the task through a push or a pull request, so allow one of them when you want
  the result back. Inside the task, a plain `git push` has no upstream: the agent uses
  `git push origin HEAD`.
- Without `--repo` the task works on the project's own repository. `--repo R` (repeatable) names
  the repositories instead: clone each one into
  `~/agentic-workspaces/<project>/repos/R` once, then name it. The first `--repo` is the working
  tree at `/work`; the others appear at `/workspaces/R`, and clones not named are mounted
  read-only.
- `clean` refuses while the worktree has uncommitted changes or commits on no remote branch;
  `--force` cleans anyway. Remote branches stay.
- Files stored with Git LFS arrive as pointer files in a task's worktree.

## Several tasks

Run as many as you like; at most three run at once (`AGENTIC_MAX_RUNNING`), because they share one
account's rate limits. `run`, and waking a suspended task, refuse at the cap with a message; stop
or wait for one to suspend. `agentic status` lists them all, `agentic status --all` every project.

## Being told when a task needs you

Set `AGENTIC_NOTIFY_WEBHOOK` (on the host when you run, or in `.agentic/.env`) to a URL. When a
task waits, idles, fails or stops, the bridge POSTs a small JSON message with the question and a
ready `agentic answer ...` reply line. Every state change is also appended to
`~/agentic-workspaces/<project>/events/events.jsonl`, which any tool can watch.

## Safety in brief

A task can change its own worktree, commit, and use the network for its work. It cannot run
anything on your machine outside its container: its git repository is only ever touched by git
inside short-lived containers with no network, your machine only fetches into private copies the
task cannot reach, and the task's tokens and settings live in a host-only directory. Dev-mode
containers see only `repos/`, never other tasks' files. What remains, and the reasoning, is in the
threat model of [`tasks.md`](tasks.md).

## When something is off

- `run` refused or failed: it rolled back and printed the reason (with `--keep-on-failure` the
  container and files stay for a look).
- `status` says `unknown`: Docker did not answer; check `docker ps`.
- A task waits but you do not see the question: `agentic status ID` lists it, also when the
  container has exited.
- `has no container`: the container was removed (for example by `docker container prune`); the
  task cannot be resumed. `clean` still works.
- The agent says it is not logged in: `agentic doctor`, then `agentic login`, then `resume`.
- You want to finish a task yourself: `agentic takeover ID` continues the same session in your
  terminal.
