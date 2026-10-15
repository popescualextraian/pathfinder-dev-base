# Scheduled runs

`agentic schedule add` runs a [detached task](detached-mode.md) at a set time, once or on a cron
schedule: an agentic colleague that updates dependencies every night, refreshes the wiki every
week or writes a report on Monday morning. Each run starts a fresh container, works in its own
worktree, ends with a short summary and leaves nothing running. You read the summary when you are
back.

## Before the first schedule

1. The project runs detached tasks: `agentic run "..."` works (see [detached mode](detached-mode.md)).
2. cron runs on your machine. `agentic doctor` checks it. On WSL, set `systemd=true` in
   `/etc/wsl.conf` (then `wsl --shutdown`), or start it with `sudo service cron start`.
3. Settings the run needs at its time go in `.agentic/.env`, not in your shell: tokens, git
   credentials, and `AGENTIC_NOTIFY_WEBHOOK` if you want to be told. `AGENTIC_MAX_RUNNING` and
   `AGENTIC_BRANCH_PREFIX` are read by the host from its own environment, not from `.agentic/.env`,
   so under cron they are the defaults unless you set them in the crontab's environment.
4. Your machine must be on at the time. A firing missed while it sleeps is not caught up.

## Commands

| Command | What it does |
|---|---|
| `agentic schedule add NAME --cron "0 2 * * 1-5" [options] "prompt"` | A recurring run, in cron's five fields, local time. |
| `agentic schedule add NAME --at "2026-10-16 22:00" [options] "prompt"` | A one-off run, local time, in the future and within a year; the schedule removes itself after it fired. |
| `agentic schedule list [--json]` | The project's schedules, their last result, whether cron has them, and the task id of a run in progress. |
| `agentic schedule run NAME` | Fires a schedule now, in your terminal, to try it out. |
| `agentic schedule follow NAME [--since N] [--raw]` | Streams the run in progress, from wherever cron started it, to its end and its summary. |
| `agentic schedule results NAME [--all]` | The newest result, or all of them (newest first, with their paths). |
| `agentic schedule remove NAME` | Removes the schedule. Its results stay. |

`NAME` is lowercase letters, digits and `-`, at most 40 characters, and unique in the project; `add`
refuses an existing name, so `remove` it first to change a schedule. `add` also takes the prompt
from a file with `--prompt-file`.

`add` options:

- `--allow push|open-pr|deploy:<target>`, `--agent`, `--model`, `--target`: as for `agentic run`.
- `--timeout 2h`: the longest a run may work, as `90m`, `2h` or seconds, from 1 minute to 24 hours
  (default 2 hours). At the limit the agent is stopped and asked for its summary; see below.
- `--no-worktree`: work directly in your checkout instead of a worktree of its own. Your files
  change while the run works; avoid it unless the run only reads.
- `--keep`: keep everything for a look afterwards: nothing is cleaned up, the container is stopped
  but kept, with the worktree, its branch and the task files.
- `--keep-on-failure`: keep the container, the worktree and the task files only when the run fails.

## A typical schedule

```bash
agentic schedule add nightly-deps --cron "0 2 * * 1-5" --allow open-pr \
  "Update the dependencies that have patch or minor releases, run the tests and open a pull request"
agentic schedule run nightly-deps          # try it once now
agentic schedule results nightly-deps      # read what it did
```

What happens at 02:00:

1. cron runs the schedule's launcher (`~/.agentic/projects/<project>/schedules/nightly-deps/fire`),
   which calls `agentic schedule fire nightly-deps` in your project. If the previous run of this
   schedule still runs, or three tasks already run (`AGENTIC_MAX_RUNNING`), the firing is skipped
   and the skip is recorded as a result.
2. A fresh task container starts, the agent works in `.worktrees/<id>` on a new branch, with the
   grants you gave. It is told that nobody is watching: it decides what it can and does not wait
   for answers.
3. When the agent ends its turn, the bridge asks it for a summary of about 300 words: what it did,
   where the result is (branch, pull request), the decisions it made, its open questions and what
   you should do next. A run never waits for you and never suspends.
4. The task stops. The container is stopped and removed, the worktree and the task files with it,
   unless you asked to keep them or they hold unpushed work. When the bridge did not remove the
   worktree itself (a failed or stopped run), the host removes it in the container before the stop,
   as `agentic clean` does. Only the summary stays, in
   `~/agentic-workspaces/<project>/results/nightly-deps/`, one file per firing named
   `<YYYYMMDD-HHMM>-<task id>.md`, the time of the firing.

If the run is still working at its `--timeout`, the bridge cancels the turn and asks for the
summary with a note that time is up. If no summary comes within five minutes, the run stops with
the state `stopped (timeout)` and the result says `No summary: the run timed out.` plus the
agent's last message. A firing that is still running ten minutes after its timeout is stopped by
the host, and its state is `stopped (timeout)`.

## Results

`agentic schedule results NAME` prints the newest result: a header (task id, state, branch,
allowed actions, open questions, whether anything was kept) and the agent's summary. Every firing
writes one, also one that was skipped, refused, failed or interrupted. The state is one of:

- `stopped (scheduled-done)`: the run worked and wrote its summary.
- `stopped (timeout)`: the time was up.
- `failed (<reason>)`: the agent or the bridge failed; the body is the reason and the last 20 lines
  of the bridge log, with no summary.
- `skipped (<reason>)`: the previous run still ran, or the running cap was reached.
- `refused (<message>)`: `agentic run` would not start it (no layout, no target, no login, ...).
- `interrupted (the firing ended before its run)`: a firing died, and the next one found its lock.
  The task it started is kept.

`agentic schedule list` shows each schedule with its last state, whether cron has its line
(`MISSING` if not) and, while a firing runs, its task id (`RUNNING`). A running firing is an
ordinary task: `agentic schedule follow NAME` watches it, and `agentic status ID`, `logs ID`,
`send ID` and `stop ID` work on it as on any task. With `AGENTIC_NOTIFY_WEBHOOK` set, the summary also goes to your webhook when
the run ends, in the `result` field (at most 4 KB).

The summary is all that survives a normal run. Anything bigger has to leave through the prompt:
ask the agent to push a branch, open a pull request or commit a report file. Use `--keep` when you
want the transcript and logs (`agentic logs ID --transcript`).

## What is kept

| The run | Container | Worktree and task files | You |
|---|---|---|---|
| Ended normally | removed | removed | read the result |
| Ended with unpushed work in its worktree (checked while the container ran) | stopped, kept | kept | `agentic clean ID` once you have looked (or `--force`) |
| Ended, its container is no longer running, and the worktree folder is still in the checkout | stopped, kept | kept, "worktree not checked" | look, then `agentic clean ID` |
| Failed | removed (kept with `--keep-on-failure`) | removed (kept with `--keep-on-failure`) | read the result; `agentic logs ID` when kept |
| Timed out | as for a normal end | as for a normal end | the summary says how far it got |
| Interrupted firing | kept | kept | `agentic clean ID` |
| Any, with `--keep` | stopped, kept | kept (no cleanup at all) | `agentic clean ID` |

The result's `Kept` line names the reason and the `agentic clean ID` command. The container is
always stopped at the end. Unpushed work is never deleted by the cleanup. With `--no-worktree`
nothing is checked: the run works in your checkout, which is yours to look at.

## What the agent may do

The same as any detached task: no permission prompts, and the action gate refuses push, pull
requests and deploys that were not allowed with `--allow`. No one answers questions during a
scheduled run, so grant up front what the task needs. When the agent hits a refusal or a question,
it lists it in its summary; you continue by hand, run it again with a grant, or change the prompt.

## Running on a remote host

On a VM with Docker, install the CLI there and use `agentic schedule` as on your laptop.

On a managed container service, the platform's own scheduler (a scheduled job or task) starts the
image; nothing of this repository runs a scheduler there. Give the job the variables of a detached
task plus two for the scheduled behaviour. Leave out `AGENTIC_WORKTREE`: the job works in a fresh
clone, which needs no worktree.

```
command:  agentic-bridge
env:      AGENTIC_REPO_URL=https://git.example.com/team/orders.git
          AGENTIC_PROMPT=Update the dependencies and open a pull request
          AGENTIC_ALLOWED_ACTIONS=open-pr
          AGENTIC_SCHEDULED=1
          AGENTIC_RUN_TIMEOUT=7200
          AGENTIC_NOTIFY_WEBHOOK=https://hooks.example.com/agentic
secrets:  AGENTIC_TASK_TOKEN, AGENTIC_AGENT_TOKEN, the harness and git tokens
```

The run clones, works, writes its summary to `/task/result.md` and the webhook (`result` field),
and the bridge exits, so the container ends. See [remote](remote.md) for the rest of the container contract.

## When something is off

- Nothing happened at the time: `agentic doctor` (is cron running, is the schedule in the
  crontab?), then `~/.agentic/projects/<project>/schedules/<name>/fire.log` (the last 1000 lines
  of what each firing printed; `AGENTIC_DATA` moves `~/.agentic`).
- The result says `refused`: the same message `agentic run` would print; fix it, then
  `agentic schedule run NAME`.
- The result says `skipped`: the previous run was still running or the cap was reached.
- The summary lists a refused push or pull request: add the grant with `remove` and `add`.
- `agentic doctor` reports `error schedule NAME`: the definition and its crontab line do not
  match; `agentic schedule remove NAME`, then `add` it again. If the crontab cannot be read,
  `add` and `remove` stop and leave it as it is.
