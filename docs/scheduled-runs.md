# Scheduled runs

> **Planned:** scheduled runs are designed, not built yet
> (`docs/specs/2026-10-15-schedule-design.md`). Commands and behaviour may change.

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
   credentials, and `AGENTIC_NOTIFY_WEBHOOK` if you want to be told.
4. Your machine must be on at the time. A firing missed while it sleeps is not caught up.

## Commands

| Command | What it does |
|---|---|
| `agentic schedule add NAME --cron "0 2 * * 1-5" [options] "prompt"` | A recurring run, in cron's five fields, local time. |
| `agentic schedule add NAME --at "2026-10-16 22:00" [options] "prompt"` | A one-off run; the schedule removes itself after it fired. |
| `agentic schedule list [--json]` | The project's schedules, their last result, and whether cron has them. |
| `agentic schedule run NAME` | Fires a schedule now, in your terminal, to try it out. |
| `agentic schedule results NAME [--all]` | The newest result, or all of them. |
| `agentic schedule remove NAME` | Removes the schedule. Its results stay. |

`add` options:

- `--allow push|open-pr|deploy:<target>`, `--agent`, `--model`, `--target`, `--prompt-file F`: as
  for `agentic run`.
- `--timeout 2h`: the longest a run may take (default 2 hours, at most 24).
- `--no-worktree`: work directly in your checkout instead of a worktree of its own. Your files
  change while the run works; avoid it unless the run only reads.
- `--keep`: stop the container but keep it and the task files, for a look afterwards.
- `--keep-on-failure`: the same, only when the run fails.

## A typical schedule

```bash
agentic schedule add nightly-deps --cron "0 2 * * 1-5" --allow open-pr \
  "Update the dependencies that have patch or minor releases, run the tests and open a pull request"
agentic schedule run nightly-deps          # try it once now
agentic schedule results nightly-deps      # read what it did
```

What happens at 02:00:

1. cron calls `agentic schedule fire nightly-deps`. If the previous run of this schedule still
   runs, or three tasks already run (`AGENTIC_MAX_RUNNING`), the firing is skipped and the skip is
   recorded as a result.
2. A fresh task container starts, the agent works in `.worktrees/<id>` on a new branch, with the
   grants you gave. It is told that nobody is watching: it decides what it can and does not wait
   for answers.
3. When it is done, the bridge asks it for a summary: what it did, where the result is (branch,
   pull request), the decisions it made, its open questions and what you should do next.
4. The task stops. The container is stopped and removed, the worktree and the task files with it,
   unless you asked to keep them. Only the summary stays, in
   `~/agentic-workspaces/<project>/results/nightly-deps/`.

## Results

`agentic schedule results NAME` prints the newest result: a header (task id, state, branch,
allowed actions, open questions, whether anything was kept) and the agent's summary. Every firing
writes one, also one that was skipped, refused or failed. With `AGENTIC_NOTIFY_WEBHOOK` set, the
summary also goes to your webhook when the run ends.

The summary is all that survives a normal run. Anything bigger has to leave through the prompt:
ask the agent to push a branch, open a pull request or commit a report file. Use `--keep` when you
want the transcript and logs (`agentic logs ID --transcript`).

## What is kept

| The run | Container | Worktree and task files | You |
|---|---|---|---|
| Ended normally | removed | removed | read the result |
| Ended with work that is not pushed | stopped, kept | kept | `agentic clean ID` once you have looked (or `--force`) |
| Failed | removed (kept with `--keep-on-failure`) | removed (kept with `--keep-on-failure`) | read the result; `agentic logs ID` when kept |
| Timed out | as for a normal end, or kept when work is not pushed | the same | the summary says how far it got |
| Any, with `--keep` | stopped, kept | kept | `agentic clean ID` |

The container is always stopped at the end. Unpushed work is never deleted by the cleanup.

## What the agent may do

The same as any detached task: no permission prompts, and the action gate refuses push, pull
requests and deploys that were not allowed with `--allow`. No one answers questions during a
scheduled run, so grant up front what the task needs. When the agent hits a refusal or a question,
it lists it in its summary; you continue by hand, run it again with a grant, or change the prompt.

## Running on a remote host

On a VM with Docker, install the CLI there and use `agentic schedule` as on your laptop.

On a managed container service, the platform's own scheduler (a scheduled job or task) starts the
image; nothing of this repository runs a scheduler there. Give the job the variables of a detached
task plus two for the scheduled behaviour:

```
command:  agentic-bridge
env:      AGENTIC_REPO_URL=https://git.example.com/team/orders.git
          AGENTIC_PROMPT=Update the dependencies and open a pull request
          AGENTIC_ALLOWED_ACTIONS=open-pr
          AGENTIC_WORKTREE=1
          AGENTIC_SCHEDULED=1
          AGENTIC_RUN_TIMEOUT=7200
          AGENTIC_NOTIFY_WEBHOOK=https://hooks.example.com/agentic
secrets:  AGENTIC_TASK_TOKEN, AGENTIC_AGENT_TOKEN, the harness and git tokens
```

The run clones, works, writes its summary to `/task/result.md` and the webhook, and the container
ends. See [remote](remote.md) for the rest of the container contract.

## When something is off

- Nothing happened at the time: `agentic doctor` (is cron running, is the schedule in the
  crontab?), then `~/.agentic/projects/<project>/schedules/<name>/fire.log`.
- The result says `refused`: the same message `agentic run` would print; fix it, then
  `agentic schedule run NAME`.
- The result says `skipped`: the previous run was still running or the cap was reached.
- The summary lists a refused push or pull request: add the grant with `remove` and `add`.
