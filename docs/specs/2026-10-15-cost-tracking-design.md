# Cost tracking

Status: implemented, 2026-10-15. Umbrella: `docs/architecture.md`. Builds on tasks (`docs/tasks.md`),
scheduled runs (`docs/specs/2026-10-15-schedule-design.md`) and the setup lines
(`docs/setup.md`). Pillar 16 of the philosophy: measure.

## 1. Outcome

A project that installs the cost plugin knows what its agents spend: per task, per scheduled
run, per interactive session, per model, over any time window. `agentic cost` prints it;
`agentic cost --json` returns the same numbers in a versioned shape that a UI can consume later
without any change to the recording side.

```
$ agentic cost --since 2026-10-01
GROUP                         SESSIONS  INPUT     OUTPUT    CACHE R   CACHE W   EST. USD  CREDITS USD
task 20261014-ab12                   2  1.2M      84k       9.1M      410k      18.40     -
scheduled 20261015-0200 nightly-deps 1  3.0M      150k      22M       1.1M      41.75     -
dev                                 14  5.5M      300k      40M       2.0M      77.10     0.03
total                               17  9.7M      534k      71.1M     3.5M      137.25    0.03
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
| C1 | **Recording is a plugin**, `cost@agentic`, in a marketplace shipped in the image (`/opt/agentic/marketplace`). `config/recommended` adds it for both targets; a project deletes the lines to opt out. One Claude-format `hooks/hooks.json` serves both harnesses (Copilot reads it); the snapshot tells them apart by `COPILOT_PLUGIN_ROOT`, which only Copilot sets. | Recommended, not imposed (architecture). A plugin is the harnesses' own extension point and loads in every mode, also under ACP. |
| C2 | **ccusage is the reader of the harnesses' own usage files and the pricing authority**, pinned in the Dockerfile (20.0.32), run `--offline`, with the project's `.agentic/cost/ccusage.json` as pricing overrides when it has one. We never parse transcripts ourselves. | It already reads Claude, Copilot, Codex, Gemini and opencode and prices with the LiteLLM table. Pinned and offline: the same version gives the same prices, also behind a proxy; a release once silently dropped Claude Code 2.1+ lines. |
| C3 | **A record is a cumulative snapshot of one session**, written after every turn and at session end. The ledger is append-only; readers keep the latest record per `(harness, session)`. | Idempotent: reruns and duplicate hooks never count twice. A killed container loses at most the last turn. No locking or rewriting. |
| C4 | **Collectors are the extension point for harnesses**: an executable that reads the hook payload and prints records. One generic collector, `ccusage-collector`, serves every harness ccusage reads (Claude and Copilot today; Codex, Gemini, opencode with only a hook). A project replaces it for one harness, or adds a harness ccusage does not read, with `.agentic/cost/collectors/<harness>`. | The core never names a harness (setup.md: no per-technology code). One file instead of one per harness. Same pattern as `hooks.d`. |
| C5 | **Three versioned contracts**: the record (`cost-record/v1`), the collector interface, the summary (`cost-summary/v1`). JSON Schemas in `schema/`. | Producers, the CLI and a future UI evolve independently. Adding fields is compatible; anything else is v2. |
| C6 | **One ledger per project on the host**, `$AGENTIC_WORKSPACES/<project>/cost/ledger.jsonl`, mounted at `/cost` in task **and** dev containers. | `/events` is not mounted in dev containers; task homes go with `clean`. A dedicated folder holds only what the cost plugin writes. |
| C7 | **Costs keep their kind.** `cost_source` is `estimate` (list price from tokens; ccusage prices both Claude's and Copilot's tokens this way), `billed-credits` (Copilot AI credits with no tokens yet: a session that has not shut down) or `unknown` (tokens without a price). Kinds are never summed; unpriced is `unknown`, not zero. | A list-price estimate, a seat's credits and an unpriced model are different numbers; one total would mislead. |
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
<collector> EVENT HARNESS            # EVENT: turn | end; hook payload on stdin
```

- Prints zero or more `cost-record/v1` lines on stdout, exit 0. It does not fill `project` or
  `context`: the core adds them from the environment. It does not write the ledger.
- Looked up as `/agentic-config/cost/collectors/<harness>` (project), then
  `/opt/agentic/cost/collectors/<harness>` (an overlay's), then
  `/opt/agentic/cost/ccusage-collector`, the generic one.
- Has 60 s.

### 3.3 Summary (`cost-summary/v1`)

`agentic cost --json` and anything else that runs `summary.jq`. Schema:
`schema/cost-summary.schema.json`.

```json
{
  "schema": "cost-summary/v1",
  "project": "shop",
  "filter": { "since": "2026-10-01", "until": null, "task": null, "schedule": null, "by": "context" },
  "groups": [
    { "key": { "kind": "scheduled", "task": "20261015-0200", "schedule": "nightly-deps" }, "sessions": 9,
      "last": "2026-10-15T02:41:07Z",
      "totals": { "input": 0, "output": 0, "cache_read": 0, "cache_write": 0,
                  "cost": { "estimate": 41.75, "billed-credits": 12.30 } },
      "models": [ { "model": "…", "harness": "…", "input": 0, "output": 0, "cache_read": 0,
                    "cache_write": 0, "cost": { "estimate": 0 } } ] }
  ],
  "sessions": 25,
  "totals": { "…": "same shape as a group's totals" },
  "skipped_lines": 0
}
```

- `by`: `context` (default: one group per task run, scheduled run, and `dev`), `model`, `day`.
  A new value is a compatible change; a UI that needs another grouping adds it to `summary.jq`.
- Filters: `--since`, `--until` (days, both inclusive, on `ts`), `--task`, `--schedule`.
  A session counts in the window of its latest snapshot.
- `last` is the latest snapshot's `ts` in the group.

## 4. Components

```
marketplace/                                  → /opt/agentic/marketplace
  .claude-plugin/marketplace.json             name "agentic"
  plugins/cost/                               hooks/hooks.json (both harnesses)
image/cost/                                   → /opt/agentic/cost
  snapshot                                    hook entry: collector → tag → append
  ccusage-collector                           the generic collector (C4)
  record.jq                                   valid_record, the readers' check of the schema
  summary.jq                                  the one aggregation (C8)
schema/cost-record.schema.json, schema/cost-summary.schema.json
bin/agentic, lib/host/cost.sh                 agentic cost; the /cost mount
```

### 4.1 Recording flow

1. The plugin's hooks fire on `Stop` (turn) and `SessionEnd` (end); Copilot maps them to its own
   events. Each runs `/opt/agentic/cost/snapshot EVENT` and returns; the harness is `copilot` when
   `COPILOT_PLUGIN_ROOT` is set, else `claude`.
2. `snapshot` detaches, finds the collector, runs it with the payload and a timeout.
3. For each record it adds `project` (`AGENTIC_PROJECT`) and `context` (`AGENTIC_TASK_ID`,
   `AGENTIC_SCHEDULED`, `AGENTIC_SCHEDULE`; none set → `dev`) and appends it to
   `/cost/ledger.jsonl` with one `write` under `flock`. It does not check the schema: the readers
   skip what is not a `cost-record/v1` (C9).
4. No `/cost` (an old container, a remote host without the mount): a warning in
   `~/.agentic/cost.log`, nothing else.

The generic collector calls `ccusage <harness> session --json --offline` and keeps the payload's
session (ccusage's `--id` exists for Claude only and drops the per-model split; the list takes
0.3 s on 380 MB of transcripts).

### 4.2 Host changes

- `common.sh` `project_run_args` (dev and task containers) mounts `$AGENTIC_WORKSPACES/<project>/cost` at
  `/cost`, created first and refused when it is a symlink (`bind_src_ok`), like `tasks/` and
  `events/`.
- `sched_fire` passes `AGENTIC_SCHEDULE=<name>` to the run.
- `agentic cost [--since D] [--until D] [--task ID] [--schedule NAME] [--by context|model|day]
  [--json]`: safe-read the ledger (C9), run
  `summary.jq`, print the table or the JSON. Implemented in `lib/host/cost.sh`.

## 5. Harness facts

Measured on 2026-10-15 in `agentic-dev-base:local` and recorded in
`docs/plans/2026-10-15-cost-harness-facts.md`: ccusage 20.0.32 counts Claude Code 2.1.300 lines,
deduplicates by request and adds subagents to their parent session; `ccusage copilot` reads
`session-state` without OTel; one plugin directory serves both harnesses; Claude `--resume` and
Copilot `--resume` keep the session id, and ccusage takes Copilot's last cumulative shutdown. Not
measurable without a login: a real Stop payload and a real Copilot hook firing; the plan checks
them by hand once.

## 6. Testing

- bats, written first: `snapshot` with stub collectors (tagging, lookup order, no `/cost`,
  timeout, always exit 0); the generic collector with a stub `ccusage` and recorded fixtures;
  `summary.jq` on fixture ledgers (latest-per-session, every `by`, filters, kinds kept
  apart, bad lines counted); `agentic cost` (symlinked ledger refused, size cap, table, `--json`
  valid against the schema); the `/cost` mount and `AGENTIC_SCHEDULE`.
- Schema: both schemas checked by `make lint`; fixtures validated against them.
- Smoke: the plugin is installed for both harnesses and `/cost` is mounted; in the image, the
  snapshot with the pinned ccusage on the synthetic transcripts gives the measured counts. A real
  session needs a login and is checked by hand once.

## 7. Out of scope (backlog)

- **Live cost in the bridge**: map ACP `usage_update` (Claude: cumulative USD) and
  `PromptResponse.usage` to events, and serve `GET /cost` with `cost-summary/v1` from
  `summary.jq`.
- **Budgets and caps**: stop or warn a task at a spending limit; needs the live cost.
- **A UI**: consumes `cost-summary/v1`; nothing in this design needs to change for it.
- **Remote hosts**: the ledger stays on the remote host until a relay or a shared store reads it.
- **Other harnesses**: one collector each, when a project adds the harness.
