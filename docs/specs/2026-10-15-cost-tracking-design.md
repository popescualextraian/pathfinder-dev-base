# Cost tracking

Status: design, 2026-10-15. Umbrella: `docs/architecture.md`. Builds on tasks (`docs/tasks.md`),
scheduled runs (`docs/specs/2026-10-15-schedule-design.md`) and the setup lines
(`docs/setup.md`). Pillar 16 of the philosophy: measure.

## 1. Outcome

A project that installs the cost plugin knows what its agents spend: per task, per scheduled
run, per interactive session, per model, over any time window. `agentic cost` prints it;
`agentic cost --json` returns the same numbers in a versioned shape that a UI can consume later
without any change to the recording side.

```
$ agentic cost --since 2026-10-01
GROUP                 SESSIONS  INPUT     OUTPUT   CACHE R    CACHE W   EST. USD  COPILOT CREDITS
task 20261014-ab12          2   1.2M      84k      9.1M       410k        18.40         -
schedule nightly-deps       9   3.0M      150k     22M        1.1M        41.75        12.30
dev                        14   5.5M      300k     40M        2.0M        77.10         3.00
```

Success criteria:

- Claude and Copilot sessions are recorded in all three modes: interactive (`agentic dev`), task
  (`agentic run`) and scheduled (`agentic schedule`), tagged with task, schedule and project.
- The numbers survive `agentic clean`, auto-clean and container recreation.
- A killed container loses at most the last turn; a rerun never counts twice.
- A new harness is added by dropping one collector file, without changing the core, the record
  or the readers.
- `agentic cost --json` is a documented, versioned contract (`cost-summary/v1`).
- The host stays a thin relay: it mounts one folder and reads one file.
- `make test`, `make lint` and `make smoke` pass.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| C1 | **Recording is a plugin**, `cost@agentic`, in a marketplace shipped in the image (`/opt/agentic/marketplace`). `config/recommended` adds it for both targets; a project deletes the lines to opt out. | Recommended, not imposed (architecture). A plugin is the harnesses' own extension point and loads in every mode, also under ACP. |
| C2 | **ccusage is the reader of the harnesses' own usage files and the pricing authority**, pinned in the Dockerfile, with a pricing-overrides file in the plugin. We never parse transcripts ourselves. | It already reads Claude, Copilot, Codex, Gemini and opencode and prices with the LiteLLM table. Pinned because a release silently dropped Claude Code 2.1+ lines. |
| C3 | **A record is a cumulative snapshot of one session**, written after every turn and at session end. The ledger is append-only; readers keep the latest record per `(harness, session)`. | Idempotent: reruns and duplicate hooks never count twice. A killed container loses at most the last turn. No locking or rewriting. |
| C4 | **Collectors are the extension point for harnesses**: one executable per harness that reads the hook payload and prints records. The image ships `claude` and `copilot`; a project adds more in `.agentic/cost/collectors/`. | The core never names a harness (setup.md: no per-technology code). Same pattern as `hooks.d`. |
| C5 | **Three versioned contracts**: the record (`cost-record/v1`), the collector interface, the summary (`cost-summary/v1`). JSON Schemas in `schema/`. | Producers, the CLI and a future UI evolve independently. Adding fields is compatible; anything else is v2. |
| C6 | **One ledger per project on the host**, `$AGENTIC_WORKSPACES/<project>/cost/ledger.jsonl`, mounted at `/cost` in task **and** dev containers. | `/events` is not mounted in dev containers; task homes go with `clean`. A dedicated folder holds only what the cost plugin writes. |
| C7 | **Costs keep their kind.** `cost_source` is `estimate` (list price from tokens, Claude), `billed-credits` (Copilot AI credits) or `unknown`. Kinds are never summed; unpriced is `unknown`, not zero. | Copilot bills credits per seat, Claude via the API or a subscription; one total would mislead. |
| C8 | **The summary is one jq program**, `cost/summary.jq`, the only place that aggregates. `agentic cost` runs it on the host; a UI or a later bridge endpoint runs the same program. | One definition of the numbers for every consumer. |
| C9 | **The ledger is untrusted on the host**: the agent can write it. The host reads it with the safe-read rules (no symlink, regular file, size cap) and validates each line against the record schema; bad lines are skipped and counted. | Same rule as the scheduled run results. |
| C10 | **Recording never disturbs a turn.** Hooks start the snapshot in the background, time-boxed, and always exit 0. | Cost is diagnostics; a broken ccusage must not block work. |

## 3. Contracts

### 3.1 Record (`cost-record/v1`)

One JSON object per line in `ledger.jsonl`. Schema: `schema/cost-record.schema.json`.

```json
{
  "schema": "cost-record/v1",
  "ts": "2026-10-15T14:03:11Z",
  "project": "shop",
  "harness": "claude",
  "session": "5d1c…",
  "context": { "kind": "task", "task": "20261014-ab12", "schedule": "nightly-deps" },
  "models": [
    { "model": "claude-opus-5-5", "input": 1200, "output": 840, "cache_read": 91000,
      "cache_write": 4100, "cost": 1.84, "cost_source": "estimate" }
  ],
  "totals": { "input": 1200, "output": 840, "cache_read": 91000, "cache_write": 4100,
              "cost": { "estimate": 1.84 } },
  "producer": { "collector": "claude", "ccusage": "x.y.z" }
}
```

- `context.kind` is `task`, `scheduled` or `dev`; `task` and `schedule` are present when known.
- Token fields are integers, separate per kind; `input` excludes the cache. A UI shows "prompt
  input" as `input + cache_read + cache_write`.
- `totals.cost` is an object keyed by `cost_source`, so kinds cannot be added by accident.
- Optional fields may be added in v1 (`credits`, `requests`, `reasoning`); consumers ignore what
  they do not know.

### 3.2 Collector interface

```
<collectors>/<harness> EVENT        # EVENT: turn | end; hook payload on stdin
```

- Prints zero or more `cost-record/v1` lines on stdout, exit 0. It does not fill `project` or
  `context`: the core adds them from the environment. It does not write the ledger.
- Looked up in `/agentic-config/cost/collectors/` (project) first, then
  `/opt/agentic/cost/collectors/` (image); an overlay replaces image files.
- Gets `AGENTIC_COST_CCUSAGE_CONFIG` (the pricing overrides) and 60 s.

### 3.3 Summary (`cost-summary/v1`)

`agentic cost --json` and anything else that runs `summary.jq`. Schema:
`schema/cost-summary.schema.json`.

```json
{
  "schema": "cost-summary/v1",
  "project": "shop",
  "filter": { "since": "2026-10-01", "until": null, "task": null, "schedule": null, "group_by": "context" },
  "groups": [
    { "key": { "kind": "scheduled", "schedule": "nightly-deps" }, "sessions": 9,
      "first": "…", "last": "…",
      "totals": { "input": 0, "output": 0, "cache_read": 0, "cache_write": 0,
                  "cost": { "estimate": 41.75, "billed-credits": 12.30 } },
      "models": [ { "model": "…", "harness": "…", "input": 0, "output": 0, "cache_read": 0,
                    "cache_write": 0, "cost": { "estimate": 0 } } ] }
  ],
  "totals": { "…": "same shape as a group's totals" },
  "skipped_lines": 0
}
```

- `group_by`: `context` (default), `task`, `schedule`, `session`, `model`, `day`.
- Filters: `--since`, `--until` (on `ts`), `--task`, `--schedule`, `--kind`.

## 4. Components

```
marketplace/                                  → /opt/agentic/marketplace
  .claude-plugin/marketplace.json             name "agentic"
  plugins/cost/                               hooks for both harnesses, ccusage.json
image/cost/                                   → /opt/agentic/cost
  snapshot                                    hook entry: collector → tag → append
  collectors/claude, collectors/copilot
  summary.jq                                  the one aggregation (C8)
schema/cost-record.schema.json, schema/cost-summary.schema.json
bin/agentic, lib/host/cost.sh                 agentic cost; the /cost mount
```

### 4.1 Recording flow

1. The plugin's hooks fire: Claude `Stop` (turn) and `SessionEnd` (end), Copilot `agentStop`
   and `sessionEnd`. Each runs `/opt/agentic/cost/snapshot HARNESS EVENT` and returns.
2. `snapshot` detaches, finds the collector, runs it with the payload and a timeout.
3. For each record it adds `project` (`AGENTIC_PROJECT`) and `context` (`AGENTIC_TASK_ID`,
   `AGENTIC_SCHEDULED`, `AGENTIC_SCHEDULE`; none set → `dev`), checks it against the schema and
   appends it to `/cost/ledger.jsonl` with one `write` under `flock`.
4. No `/cost` (an old container, a remote host without the mount): a warning in
   `~/.agentic/cost.log`, nothing else.

The collectors call `ccusage <harness> session --json` for the payload's session and map its
output to the record. They know the harness; nothing else does.

### 4.2 Host changes

- `common.sh` `build_run_args` and `cmd_run` mount `$AGENTIC_WORKSPACES/<project>/cost` at
  `/cost`, created first and refused when it is a symlink (`bind_src_ok`), like `tasks/` and
  `events/`.
- `sched_fire` passes `AGENTIC_SCHEDULE=<name>` to the run.
- `agentic cost [--since D] [--until D] [--task ID] [--schedule NAME] [--kind K]
  [--by context|task|schedule|session|model|day] [--json]`: safe-read the ledger (C9), run
  `summary.jq`, print the table or the JSON. Implemented in `lib/host/cost.sh`.

## 5. Step 1: confirm the harness facts

Before the build, measured in `agentic-dev-base:local` and written to
`docs/plans/2026-10-15-cost-harness-facts.md`, like the revamp's harness facts:

1. Which ccusage version is current and reads Claude Code ≥ 2.1 transcripts correctly; pin it.
2. Whether `ccusage copilot` reads `session-state/<id>/events.jsonl` (`session.shutdown`,
   `usage_checkpoint`) or needs the OTel file export. If OTel: the two variables go into
   `.env.example` and the agentic-setup skill, not into code.
3. Whether ccusage filters one session cheaply (`--id` or similar), or each turn rescans all.
4. Whether one plugin directory carries hooks for both harnesses, and in which files.
5. Whether `--resume` (Claude) and `--resume`/`session/load` (Copilot) make a new session that
   repeats the old one's usage; if so, the collector subtracts it.
6. Whether subagent transcripts are included in their parent session's numbers.
7. Whether the hooks fire under ACP with the per-task harness homes (`06-task-home.sh`).

A fact that contradicts this design is brought back to the user before the plan is written.

## 6. Testing

- bats, written first: `snapshot` with stub collectors (tagging, schema rejection, no `/cost`,
  timeout, always exit 0); each collector with a stub `ccusage` and recorded fixtures;
  `summary.jq` on fixture ledgers (latest-per-session, every `group_by`, filters, kinds kept
  apart, bad lines counted); `agentic cost` (symlinked ledger refused, size cap, table, `--json`
  valid against the schema); the `/cost` mount and `AGENTIC_SCHEDULE`.
- Schema: both schemas checked by `make lint`; fixtures validated against them.
- Smoke: a task run with the plugin installed leaves at least one valid record for its task id.

## 7. Out of scope (backlog)

- **Live cost in the bridge**: map ACP `usage_update` (Claude: cumulative USD) and
  `PromptResponse.usage` to events, and serve `GET /cost` with `cost-summary/v1` from
  `summary.jq`.
- **Budgets and caps**: stop or warn a task at a spending limit; needs the live cost.
- **A UI**: consumes `cost-summary/v1`; nothing in this design needs to change for it.
- **Remote hosts**: the ledger stays on the remote host until a relay or a shared store reads it.
- **Other harnesses**: one collector each, when a project adds the harness.
