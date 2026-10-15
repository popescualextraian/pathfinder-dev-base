# Scheduled runs

Status: implemented, 2026-10-15. Umbrella: `docs/architecture.md`. Builds on sub-project 2
(tasks, `docs/tasks.md`) and the thin relay (`docs/specs/2026-10-14-run-thin-relay-design.md`).
Pillar 3 of the philosophy: agentic colleagues on a schedule.

## 1. Outcome

`agentic schedule add nightly-deps --cron "0 2 * * 1-5" --allow open-pr "Update the dependencies
and open a pull request"` runs that task every weekday at 02:00 without anyone watching. Each run
gets a fresh container, works in its own worktree, ends with a short summary, and leaves nothing
running: the container is always stopped and, unless asked otherwise, removed with the task. The
summary stays as the run's result. A one-off run (`--at "2026-10-16 22:00"`) works the same way
and fires once.

Remotely, the platform's own scheduler starts the image; the scheduled behaviour lives in the
bridge, so it is the same in both places.

Success criteria:

- A recurring and a one-off schedule fire at their time, run the task and leave no running
  container, no `waiting` task and no idle bridge.
- Every firing leaves one result file, also when it was skipped, refused or failed.
- No unpushed work is ever deleted by the cleanup.
- The host still only starts and stops containers (T1 of the thin relay); no daemon is added.
- The bridge API stays at version 1; the new behaviour is two environment variables.
- `make test`, `make lint` and `make smoke` pass.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| S1 | **The trigger is outside the container.** Locally a line in the user's crontab; remotely the platform's scheduler (a VM crontab, a managed scheduled job). | A container that waits for its next run runs, and costs, all the time. A scheduler container would need the Docker socket, which is host root for the agent side. |
| S2 | **The scheduled behaviour lives in the bridge**, behind `AGENTIC_SCHEDULED=1` and `AGENTIC_RUN_TIMEOUT`. | Remotely no host process waits for the run; the bridge must end it by itself. One behaviour for every host. |
| S3 | Recurring (`--cron`) and one-off (`--at`) schedules. A one-off is a crontab line that removes itself after it fires. | One-off costs almost nothing on top of recurring. |
| S4 | A schedule definition is **host-private and per user**: `$AGENTIC_DATA/projects/<project>/schedules/<name>/`, never mounted, not checked in. | An agent cannot rewrite its own schedule. Checked-in schedules would fire once per developer's crontab (R13: one container per user). |
| S5 | **Scheduled defaults:** worktree on (`--no-worktree` turns it off), auto-clean on, the container always stopped and removed unless `--keep`. Grants (`--allow`) as in `run`. | Unattended runs should leave nothing behind; keeping is the explicit choice. |
| S6 | **A run always ends with a summary.** When a turn ends, whatever the state, the bridge sends one summary prompt; that turn's final message is the result (`result.md`). Then the bridge stops the task. | Nobody answers questions at 02:00. The summary is the one thing a user reads the next morning. |
| S7 | **Only the result survives the cleanup.** The host copies `result.md` with a header into `results/<name>/`; transcript, logs and harness homes go with the task unless `--keep`. Keeping anything bigger is the prompt's job (push, PR, a file in the repository). | Results that matter leave through git; everything else is debugging material. |
| S8 | **Unpushed work is never deleted.** When the worktree has uncommitted changes or commits on no remote branch, the run is kept (container stopped, task files kept), as with `--keep`, and the result says so. A worktree that cannot be checked (its container is gone, its folder is still there) is kept as well; the record's `cleaned` is not trusted. | The cleanup must not lose work. `agentic clean ID` later decides, as for any task. |
| S9 | **A firing never queues.** It is skipped when the previous firing of the same schedule still runs or the running cap is reached; the skip is a result. | No pile-up after a sleep or a long run; the next firing tries again. |
| S10 | **A scheduled run always gets a fresh container.** No `--in`. | One bridge per container at a time (T6); a nightly job never runs in a container you work in. |
| S11 | **The bridge contract stays environment variables.** No session API now. | A platform scheduler can set env and a command, not POST a definition. The tokens come by env anyway. A session API comes with several tasks per container (backlog). |

## 3. CLI

```
agentic schedule add NAME (--cron "MIN HOUR DOM MON DOW" | --at "YYYY-MM-DD HH:MM")
                     [--allow GRANT]... [--agent A] [--model M] [--target T]
                     [--no-worktree] [--keep] [--keep-on-failure] [--timeout DURATION]
                     ("prompt" | --prompt-file F)
agentic schedule list [--json]
agentic schedule remove NAME
agentic schedule run NAME            # fire now, in the foreground; for trying a schedule out
agentic schedule results NAME [--all]
agentic schedule fire NAME           # what the crontab line calls; not listed in help
```

- `NAME` matches `^[a-z0-9][a-z0-9-]{0,39}$`, unique per project. `add` refuses an existing name;
  `remove` then `add` replaces it.
- `--cron` takes the five cron fields as cron does (validated: five fields of `[0-9*,/-]` or the
  month and day names cron accepts; no `@reboot`). Host local time.
- `--at` takes local time, in the future and within 365 days. The crontab line names minute, hour,
  day and month; `fire` also checks the year and removes the line after it ran.
- `--timeout` is `90m`, `2h` or seconds; default `2h`; at most `24h`.
- `--keep`: the container is stopped, not removed, and the task files stay; `agentic clean ID`
  removes them later. `--keep-on-failure`: the same, only for a failed run.
- `list`: name, `cron` or `at`, the schedule, grants, keep, the last result's time and state, and
  whether the crontab line is present. `--json`: an array.
- `remove`: the crontab line and the definition. Results stay (`results/<name>/`).
- `results NAME`: the newest result; `--all` lists them all, newest first (time, state, task id,
  path).
- `run NAME` is `fire NAME` with output to the terminal; it ignores `--at`'s date.

The prompt is stored as given; the scheduled instructions (section 6.2) come from the bridge, which adds them at the first prompt.

## 4. Files

```
$AGENTIC_DATA/projects/<project>/schedules/<name>/      host only, never mounted
├─ schedule        key=value: kind (cron|at), when, allow, agent, model, target, worktree,
│                  keep, keep_on_failure, timeout, created
├─ prompt.md       the prompt
├─ lock/           exists while a firing runs; holds pid (S9)
└─ fire.log        what fire printed, the last 1000 lines

$AGENTIC_WORKSPACES/<project>/results/<name>/           not mounted into any container
└─ <YYYYMMDD-HHMM>-<task id>.md
```

`schedule` is read with the same parser as `.env` (`dotenv_value`), written atomically. Both
directories are made by `bin/agentic` as the invoking user, mode 700 for `schedules/`.

### 4.1 The crontab line

```
0 2 * * 1-5 cd '/home/me/src/orders' && /usr/bin/env PATH='<PATH at add time>' '/opt/agentic-dev-base/bin/agentic' schedule fire nightly-deps >/dev/null 2>&1 # agentic:orders:nightly-deps
```

- `add` and `remove` rewrite the crontab with `crontab -l` and `crontab -`, touching only lines
  that end in `# agentic:<project>:<name>`. Other lines are kept byte for byte. A crontab that
  cannot be read or written fails the command and leaves the definition unchanged (add) or in
  place (remove). Only `crontab -l` saying "no crontab for" means an empty crontab; any other read
  failure fails `add` and `remove`, and the crontab is never replaced.
- The project root, `bin/agentic` and `PATH` are absolute and captured at `add` time, single-quoted;
  a path with a single quote or a newline is refused. Docker settings the CLI needs (`DOCKER_HOST`,
  `DOCKER_CONTEXT`, `AGENTIC_DATA`, `AGENTIC_WORKSPACES`) are captured the same way when set.
- No token or project setting goes into the line. Anything the run needs at its time comes from
  `.agentic/.env`, as for `run`; `AGENTIC_NOTIFY_WEBHOOK` belongs there for scheduled runs.
- `fire` writes its own log (`fire.log`, the last 1000 lines); cron's mail is not used.
- `sweep_cleaned` (the host's removal of auto-cleaned tasks) leaves scheduled tasks alone: their
  firing removes them after it copied the result.

## 5. A firing (`schedule fire NAME`)

1. Read the definition; a missing one removes its crontab line and exits 0 (`remove` raced it).
   For `at`: a year that does not match exits 0 without a result.
2. Take the lock (`mkdir lock`, write the pid). A lock whose pid is gone is taken over. A stale
   lock's task is reported as `interrupted (the firing ended before its run)` and kept (its work
   may not be pushed; `agentic clean <id>`). A live lock writes a `skipped` result ("the previous
   run still runs") and exits 0.
3. Run the equivalent of `agentic run` with the definition's options, plus `--worktree` (unless
   `--no-worktree`), `--auto-clean`, a generated id and two more lines in the task's env file:
   `AGENTIC_SCHEDULED=1` and `AGENTIC_RUN_TIMEOUT=<seconds>`. The running cap is checked first
   and is a `skipped` result; any refusal of `run` is a `refused` result.
4. Wait in the foreground until the bridge has exited (`bridge_running` false, or the container
   gone). Safety net: at `timeout + 10 minutes` the host calls `POST /stop`, then `docker stop`.
5. Read the outcome from the host's view: the record's state (read as `status` reads it) and the
   worktree. The record's `cleaned` is not trusted. A running container gets the in-container
   check (`agentic-worktree check`); unpushed work keeps the run ("unpushed work"). A container
   that is not running (the normal case once the bridge auto-cleaned and released it) keeps the run
   as "worktree not checked" only when the worktree folder still exists in the checkout (a host
   file test, no git); otherwise the run is removed.
6. Write the result file (section 7).
7. Clean up:
   - always: the container is stopped;
   - with `--keep`, `--keep-on-failure` on a failed run, or unpushed work (S8): nothing else; the
     result names `agentic clean <id>`;
   - otherwise: `rollback_task` removes the container and the task files, as `clean` does.
8. For `at`: remove the crontab line and the definition. Release the lock.

`fire` exits 0 whenever it wrote a result, so cron does not mail; failures are in the result and
`fire.log`.

## 6. The bridge

### 6.1 Contract

The bridge is configured by environment variables only (S11). Whoever starts it sets them:

| Variable | Local CLI | Remote platform |
|---|---|---|
| tokens, ids, directories, port (as today) | the host-only task env file, passed with `docker exec --env-file` | the job definition's env, tokens from the platform's secret store |
| `AGENTIC_SCHEDULED` | `1`, written by `schedule fire` into the same env file | `1` in the job definition |
| `AGENTIC_RUN_TIMEOUT` | seconds from `--timeout` | seconds, in the job definition |

The env file is how our CLI fulfils the contract, not part of it: the contract is the variables in
the bridge's process plus a writable task directory (`AGENTIC_TASK_DIR`). Env belongs to the bridge
process, not the container, so a later task in a reused container (`run --in`) gets its own.

`docs/tasks.md` splits its bridge table in two: process settings (tokens, port, hosts, origins,
directories, idle timeout) and the task definition (prompt, agent, model, allowed actions, target,
worktree, branch, auto-clean, scheduled, run timeout). The second group is what a future session
API would take as its body.

### 6.2 Behaviour under `AGENTIC_SCHEDULED=1`

- **First prompt.** A note follows the prompt, after a `[scheduled run]` line: nobody answers
  during this run; decide what you can decide, do not wait for answers, note each decision, ask
  with `agentic-ask` only when a human must decide; you will be asked for the summary at the end.
  It is not an image paragraph: Copilot reads the image's paragraph from its instructions file at
  start, not per task. The texts are constants in `bridge/src/scheduled.ts`, not image files.
- **Questions.** `agentic-ask` still records the question (`POST /ask`, unchanged). Under
  `AGENTIC_SCHEDULED=1` (inherited by the agent's environment) it prints instead: `Recorded Q<n>.
  Nobody answers during a scheduled run: decide yourself where you can, otherwise leave it and list
  it in your summary.`
- **Turn end.** When a turn ends (not the summary turn), whatever the state, the bridge puts the
  summary prompt (a constant in `bridge/src/scheduled.ts`) into the inbox; a prompt is accepted in `idle` and
  `waiting`, so no state rule changes. The summary prompt asks for: what was done, the result
  (branch, pull request, files), decisions made, open questions, what a human should do next; at
  most about 300 words.
- **Summary turn end.** The final agent message of that turn is written to `result.md` in the task
  directory (atomic, redacted, whole message, not the 300-character `summary`). Then, with
  auto-clean, the auto-clean path runs, without its "no open question" condition; without
  auto-clean the task stops with reason `scheduled-done`. Either way the bridge exits 0.
- **Timeout.** `AGENTIC_RUN_TIMEOUT` seconds after the first prompt (default 7200, 60 to 86400), a
  running turn is cancelled as `POST /cancel` does, and the summary prompt is sent with a first line
  saying time ran out. If the summary turn has not ended 5 minutes later, the bridge stops the task
  with reason `timeout`, and `result.md` holds `No summary: the run timed out.` and the record's
  300-character `summary`.
- **Failure.** An agent crash or ACP error fails the task as today (exit 1); no summary is asked
  for. The host writes the result from the record (section 7).
- **Idle timeout.** Not armed: a scheduled run never suspends; it ends through the summary.
- **Webhook.** The `stopped` and `failed` notifications carry a new field `result` (the
  `result.md` text, redacted, at most 4 KB) when the run is scheduled. Additive; the field is
  absent otherwise.
- **Record.** `state.json` gets `scheduled: true` and `run_timeout`. `status`, `follow` and `logs`
  show a scheduled run like any task while it exists.

Remotely the bridge is the container's command; when it exits, the container ends and the
platform removes it. The result reaches the user through the webhook, the pushed branch or pull
request, and `/task/result.md` when the platform keeps a volume.

## 7. The result file

```markdown
# nightly-deps — 2026-10-16 02:00

| | |
|---|---|
| Task | T-20261016-1f2a |
| State | stopped (scheduled-done) |
| Branch | agentic/T-20261016-1f2a-update-the-dependencies (pushed) |
| Allowed | open-pr |
| Open questions | Q1: Upgrade the major version of the HTTP client? |
| Kept | no |

<the agent's summary from result.md>
```

- State is one of `stopped (scheduled-done)`, `stopped (timeout)`, `failed (<reason>)`,
  `skipped (<reason>)`, `refused (<run's message>)`, `interrupted (...)`. Whether auto-clean ran
  is the record's `cleaned`; it does not change the state text.
- `Kept` is `no`, or the reason (`--keep`, `--keep-on-failure`, `unpushed work`) and the command
  `agentic clean <id>`.
- A failed run has no summary; the body is the reason plus the last 20 lines of `bridge.log`.
- `result.md` is read capped at 64 KiB, without a pipe (no SIGPIPE). Header values are capped at
  500 characters.
- The host reads `result.md`, `state.json` and `questions.jsonl` with the existing safe-read rules
  (regular files, no symlinks, size-capped, control characters removed). The agent writes these
  files, so the result is a report, not evidence; the header's state comes from the host's own
  view where it has one (exit, container state, worktree check).

## 8. Doctor

`agentic doctor` adds:

- `cron`: a cron daemon is running (`pgrep -x cron`, `crond` or `cronie`), when the project has
  schedules. Otherwise the hint for the platform: on WSL, `systemd=true` in `/etc/wsl.conf` or
  `sudo service cron start`.
- `schedules`: every definition has its crontab line and every crontab line of this project has a
  definition; a mismatch names `agentic schedule remove NAME` or `add`.

Both checks print only when the project has schedules or marked crontab lines. The tests are in
`tests/bats/cli-schedule.bats` (the host doctor). `doctor` exits non-zero when the schedules
section has an error.

## 9. Error handling

| Case | Result |
|---|---|
| `add` with an existing name, a bad `--cron`, `--at` in the past or beyond 365 days | refused; nothing written |
| `crontab` missing, unreadable (any `crontab -l` failure but "no crontab for") or unwritable | `add` refused, nothing written; `remove` refused, definition kept; the crontab is never replaced |
| No cron daemon | `add` succeeds and warns, as `doctor` does |
| Firing while the previous one runs | `skipped` result |
| Running cap reached | `skipped` result |
| `run` refuses (no layout, no target, image missing, no login) | `refused` result with the message |
| The agent fails | `failed` result; cleaned unless `--keep-on-failure` |
| The run times out | summary attempt, then `stopped (timeout)`; cleaned unless unpushed work |
| Unpushed work | kept (S8), result says how to clean |
| The host was off at the time | the firing is missed; cron does not catch up. Documented. |

## 10. Testing

Tests are written first.

- bats (`tests/bats/cli-schedule.bats`), with `crontab` and docker stubbed:
  - `add` writes the definition and exactly one marked line; other crontab lines untouched;
  - `add` refusals of 9; quoting of paths; refused paths with a quote;
  - `remove` removes both; `list` and `--json`; `results` ordering;
  - `fire`: lock (live and stale), cap skip, refusal result, the env file holds
    `AGENTIC_SCHEDULED=1` and `AGENTIC_RUN_TIMEOUT`, `--worktree` and `--auto-clean` by default,
    `--no-worktree`;
  - cleanup: removed by default, kept with `--keep`, with `--keep-on-failure` on failure, and on
    unpushed work; the result's header in each case;
  - `at`: year mismatch, line and definition removed after the firing;
  - `doctor`: cron and the line/definition match; the exit status.
- bats (`tests/bats/agentic-ask.bats`): the scheduled message.
- vitest:
  - the summary prompt after a turn end in `idle` and in `waiting`;
  - `result.md` from the summary turn, whole and redacted;
  - auto-clean after the summary despite an open question;
  - timeout: cancel, summary with the note, and the 5-minute fallback;
  - no idle timer when scheduled;
  - the webhook's `result` field only when scheduled;
  - config validation of the two variables.
- smoke: `schedule add --at` one minute ahead is not practical in CI; smoke runs `schedule run NAME`
  against a stub agent and checks the result file, the removed container and task files.
- Manual, recorded in the PR: one real `--cron` firing on WSL with cron running.

## 11. Documentation

- `docs/scheduled-runs.md`: the user guide.
- `README.md`: a "Scheduled runs" section after "Detached tasks".
- `docs/tasks.md`: the two variables, the split table (6.1), `result.md` in Files, `scheduled` and
  `run_timeout` in the record, the webhook's `result`.
- `docs/detached-mode.md`: a pointer to the guide.
- `docs/remote.md`: the scheduled job contract (6.1) and the example.
- `docs/architecture.md`: the scheduler line ("not built here") becomes: local scheduling through
  the user's crontab; remote scheduling is the platform's.
- `docs/philosophy.md`: pillar 3's status.
- `docs/backlog.md`: the scheduling item replaced by section 12.

## 12. Out of scope and backlog

- **Session API** (`POST /sessions`) and several tasks in one container; env stays the contract
  until then (S11).
- **A schema for the task definition** (`schema/task-definition.schema.json`) that every launcher
  can validate against.
- **Catch-up** of firings missed while the host was off.
- **systemd timers and launchd** as alternative local triggers.
- **Schedules in `agentic.yaml`** shared by a team, which needs one runner for the team, not one
  per developer.
- **Result retention**: results are kept until removed by hand.
- **Chained schedules** (run B after A) and conditions (run only when CI is red).
