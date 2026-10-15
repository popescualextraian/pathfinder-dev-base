# Cost Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Claude and Copilot session in a project's containers (dev, task, scheduled) leaves a cumulative cost snapshot in one ledger per project, and `agentic cost [--json]` sums it through a versioned summary contract that a UI can consume later.

**Architecture:** A plugin (`cost@agentic`, shipped in an in-image marketplace) hooks `Stop` and `SessionEnd` in both harnesses and calls `/opt/agentic/cost/snapshot`. The snapshot runs the harness's collector (ccusage underneath), tags the record with project, task and schedule, and appends it to `/cost/ledger.jsonl`, a host folder mounted into every container of the project. `summary.jq` is the only aggregation. The host's `agentic cost` reads the ledger as untrusted and runs it.

**Tech Stack:** bash, jq 1.7, ccusage 20.0.32 (pinned, `--offline`), JSON Schema 2020-12 (checked in tests with python3 `jsonschema`), bats.

**Spec:** `docs/specs/2026-10-15-cost-tracking-design.md`. Measured facts: `docs/plans/2026-10-15-cost-harness-facts.md`.

## Global Constraints

- bash: `set -euo pipefail` (hooks and the snapshot: `set -uo pipefail`, they must never fail a turn), short comments, `shellcheck -x` clean, a bats test for every behaviour, written first.
- No company names, hosts or URLs; examples use `example.com`. `tools/leak-check.sh` must pass.
- ccusage pinned to exactly `20.0.32`, always run with `--json --offline --config FILE`.
- Record and summary versions: `cost-record/v1`, `cost-summary/v1`. Adding an optional field is compatible; anything else is v2.
- `cost_source` values: `estimate`, `billed-credits`, `unknown`. Never added together.
- Ledger: `$AGENTIC_WORKSPACES/<project>/cost/ledger.jsonl` on the host, `/cost/ledger.jsonl` in the container.
- The host never trusts the ledger: no symlink, regular file only, at most `AGENTIC_COST_LEDGER_MAX` bytes (default 67108864), control characters stripped before printing.
- Commits: conventional messages, no `Co-Authored-By` or other attribution lines. Do not push.
- Before committing code: `make test` and `make lint`. Tasks 4 and 7 touch `image/`, `config/`, `schema/`: also `make smoke` once, at the end of Task 7.

## Review Focus

- A ledger line whose strings carry terminal escapes (`\u001b[2J`) is printed by `agentic cost` without them (Task 6, test "control characters...").
- Two containers of the project snapshotting at the same moment leave whole lines, never interleaved (Task 2, test "parallel snapshots...").
- A container killed mid-write leaves a truncated last line: it is skipped and counted, and everything before it still sums (Task 1, fixture's last line).
- A Copilot session killed before shutdown has credits but no tokens: it shows under `billed-credits`, not as a free or estimated session (Task 3, test "an open Copilot session...").
- A long-lived project's ledger grows with every turn: past the cap, `agentic cost` refuses with a hint to move the file aside, instead of reading gigabytes (Task 6, test "an oversized ledger...").

---

## File Structure

| File | Responsibility |
|---|---|
| `schema/cost-record.schema.json` | contract: one ledger line |
| `schema/cost-summary.schema.json` | contract: what `agentic cost --json` and any UI get |
| `image/cost/record.jq` | `valid_record`, the readers' check of the record schema |
| `image/cost/summary.jq` | the one aggregation |
| `image/cost/snapshot` | hook entry: collector → tag → append |
| `image/cost/lib.sh` | shared by collectors: payload session, ccusage call, mapping to records |
| `image/cost/collectors/claude`, `.../copilot` | one per harness: the extension point |
| `image/cost/ccusage.json` | the image's pricing overrides (empty) |
| `marketplace/` | the in-image marketplace `agentic` with the `cost` plugin |
| `lib/host/cost.sh` | `agentic cost`: safe read, summary, table |
| `docs/cost.md` | user documentation and the three contracts |

---

### Task 1: Contracts: schemas, `valid_record`, `summary.jq`

**Files:**
- Create: `schema/cost-record.schema.json`, `schema/cost-summary.schema.json`, `image/cost/record.jq`, `image/cost/summary.jq`, `tests/fixtures/cost/ledger.jsonl`, `tests/fixtures/cost/validate.py`, `tests/bats/cost-summary.bats`
- Modify: `Makefile` (lint: every schema)

**Interfaces:**
- Produces: `include "record"; valid_record` (jq, needs `-L image/cost`). `summary.jq`: run as `jq -n -R -L <dir> -f <dir>/summary.jq` with `--arg project P --arg since D --arg until D --arg task T --arg schedule S --arg kind K --arg by B` (empty string = not set), raw ledger lines on stdin, prints one `cost-summary/v1`. `tests/fixtures/cost/validate.py SCHEMA FILE`: prints `ok`, `bad` or `invalid-json` per non-empty line.

- [ ] **Step 1: Write the fixture ledger**

`tests/fixtures/cost/ledger.jsonl` (the last line is deliberately cut off, with no newline at the end):

```
{"schema":"cost-record/v1","ts":"2026-10-01T10:00:00Z","project":"demo","harness":"claude","session":"s1","context":{"kind":"dev"},"models":[{"model":"claude-sonnet-4-5","input":100,"output":10,"cache_read":1000,"cache_write":50,"cost":1.0,"cost_source":"estimate"}],"totals":{"input":100,"output":10,"cache_read":1000,"cache_write":50,"cost":{"estimate":1.0}},"producer":{"collector":"claude","ccusage":"20.0.32"}}
{"schema":"cost-record/v1","ts":"2026-10-01T10:05:00Z","project":"demo","harness":"claude","session":"s1","context":{"kind":"dev"},"models":[{"model":"claude-sonnet-4-5","input":200,"output":20,"cache_read":2000,"cache_write":100,"cost":2.0,"cost_source":"estimate"}],"totals":{"input":200,"output":20,"cache_read":2000,"cache_write":100,"cost":{"estimate":2.0}},"producer":{"collector":"claude","ccusage":"20.0.32"}}
{"schema":"cost-record/v1","ts":"2026-10-02T09:00:00Z","project":"demo","harness":"claude","session":"s2","context":{"kind":"task","task":"t1"},"models":[{"model":"claude-opus-5-5","input":10,"output":5,"cache_read":0,"cache_write":0,"cost":0.5,"cost_source":"estimate"},{"model":"mystery-1","input":7,"output":3,"cache_read":0,"cache_write":0,"cost":0,"cost_source":"unknown"}],"totals":{"input":17,"output":8,"cache_read":0,"cache_write":0,"cost":{"estimate":0.5,"unknown":0}}}
{"schema":"cost-record/v1","ts":"2026-10-03T02:00:00Z","project":"demo","harness":"copilot","session":"c1","context":{"kind":"scheduled","task":"t2","schedule":"nightly"},"models":[],"totals":{"input":0,"output":0,"cache_read":0,"cache_write":0,"cost":{"billed-credits":0.03}}}
not json
{"schema":"cost-record/v1","harness":"../x"}
{"schema":"cost-record/v1","ts":"2026-10-04T02:00:00Z","project":"demo","harness":"copilot","session":"c2","context":{"kind":"scheduled","task":"t3","schedule":"nightly"},"models":[{"model":"claude-sonnet-4.5","input":1000,"output":100,"cache_read":0,"cache_write":0,"cost":0.25,"cost_source":"estimate"}],"totals":{"input":1000,"output":100,"cache_read":0,"cache_write":0,"cost":{"estimate":0.25}}}
{"schema":"cost-record/v1","ts":"2026-10-04T03:00:00Z","project":"demo","harness":"claude","session":"s9","context":{"kind":"dev"},"models":[],"totals":{"input":"5","output":0,"cache_read":0,"cache_write":0,"cost":{}}}
{"schema":"cost-record/v1","ts":"2026-10-04T04:00:00Z","project":"demo","harness":"claude","sess
```

Write it with `printf '%s' "$(cat <<'EOF' ... EOF)" > tests/fixtures/cost/ledger.jsonl` or an editor, and check `tail -c 5 tests/fixtures/cost/ledger.jsonl | od -c` ends in `s s` with no `\n`.

`tests/fixtures/cost/validate.py`:

```python
"""validate.py SCHEMA FILE: one verdict per non-empty line of FILE (ok, bad or invalid-json)."""
import json
import sys

import jsonschema

validator = jsonschema.Draft202012Validator(json.load(open(sys.argv[1])))
for line in open(sys.argv[2]):
    line = line.strip()
    if not line:
        continue
    try:
        doc = json.loads(line)
    except ValueError:
        print("invalid-json")
        continue
    print("ok" if validator.is_valid(doc) else "bad")
```

- [ ] **Step 2: Write the failing tests**

`tests/bats/cost-summary.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  C="$REPO_ROOT/image/cost"
  L="$REPO_ROOT/tests/fixtures/cost/ledger.jsonl"
  V="$REPO_ROOT/tests/fixtures/cost/validate.py"
}

# summary [FILE]: the summary of FILE (default: the fixture ledger), filters from SINCE UNTIL TASK SCHED KIND BY.
summary() {
  jq -n -R -L "$C" --arg project demo --arg since "${SINCE:-}" --arg until "${UNTIL:-}" --arg task "${TASK:-}" \
    --arg schedule "${SCHED:-}" --arg kind "${KIND:-}" --arg by "${BY:-}" -f "$C/summary.jq" < "${1:-$L}"
}

@test "valid_record and the record schema agree on every fixture line" {
  run python3 "$V" "$REPO_ROOT/schema/cost-record.schema.json" "$L"
  [ "$status" -eq 0 ]
  py="$output"
  jqv="$(jq -R -r -L "$C" 'include "record"; try (fromjson | if valid_record then "ok" else "bad" end) catch "invalid-json"' "$L")"
  [ "$py" = "$jqv" ]
  [ "$(paste -sd' ' <<<"$jqv")" = "ok ok ok ok invalid-json bad ok bad invalid-json" ]
}

@test "the summary is a cost-summary/v1 for every grouping" {
  for by in context task schedule session model day; do
    BY="$by" summary | jq -c . > "$BATS_TEST_TMPDIR/s.json"
    [ "$(python3 "$V" "$REPO_ROOT/schema/cost-summary.schema.json" "$BATS_TEST_TMPDIR/s.json")" = ok ] || { echo "by $by"; false; }
  done
}

@test "a session counts once, with its latest snapshot; bad and cut-off lines are skipped and counted" {
  run summary
  [ "$(jq .sessions <<<"$output")" = 4 ]
  [ "$(jq .skipped_lines <<<"$output")" = 4 ]
  [ "$(jq -c '.totals | [.input, .output, .cache_read, .cache_write]' <<<"$output")" = "[1217,128,2000,100]" ]
  UNTIL=2026-10-01 run summary
  [ "$(jq -c '[.sessions, .totals.input, .totals.cost.estimate]' <<<"$output")" = "[1,200,2]" ]
}

@test "estimates, billed credits and unpriced tokens are never added together" {
  run summary
  [ "$(jq -c '.totals.cost | to_entries | sort_by(.key) | from_entries' <<<"$output")" = '{"billed-credits":0.03,"estimate":2.75,"unknown":0}' ]
}

@test "by context: one group per dev, task run and scheduled run, newest first" {
  run summary
  [ "$(jq -c '[.groups[].key]' <<<"$output")" = '[{"kind":"scheduled","task":"t3","schedule":"nightly"},{"kind":"scheduled","task":"t2","schedule":"nightly"},{"kind":"task","task":"t1"},{"kind":"dev"}]' ]
  [ "$(jq -r '.groups[0].last' <<<"$output")" = 2026-10-04T02:00:00Z ]
}

@test "by schedule, model and day" {
  BY=schedule run summary
  [ "$(jq -c '[.groups[] | [.key.schedule, .sessions]]' <<<"$output")" = '[["nightly",2],[null,2]]' ]
  BY=model run summary
  [ "$(jq '.groups | length' <<<"$output")" = 5 ]
  [ "$(jq -c '.groups[] | select(.key.model == "unknown") | [.key.harness, .totals.cost]' <<<"$output")" = '["copilot",{"billed-credits":0.03}]' ]
  BY=day run summary
  [ "$(jq -c '[.groups[].key.day]' <<<"$output")" = '["2026-10-04","2026-10-03","2026-10-02","2026-10-01"]' ]
}

@test "filters: days inclusive, task, schedule, kind; the filter is echoed" {
  SINCE=2026-10-03 run summary
  [ "$(jq .sessions <<<"$output")" = 2 ]
  [ "$(jq -c .filter <<<"$output")" = '{"since":"2026-10-03","until":null,"task":null,"schedule":null,"kind":null,"by":"context"}' ]
  SINCE=2026-10-02 UNTIL=2026-10-02 run summary
  [ "$(jq -c '[.groups[].key.task]' <<<"$output")" = '["t1"]' ]
  TASK=t1 run summary;     [ "$(jq .sessions <<<"$output")" = 1 ]
  SCHED=nightly run summary; [ "$(jq .sessions <<<"$output")" = 2 ]
  KIND=dev run summary;    [ "$(jq .totals.input <<<"$output")" = 200 ]
}

@test "an empty or missing ledger gives an empty summary" {
  : > "$BATS_TEST_TMPDIR/empty"
  run summary "$BATS_TEST_TMPDIR/empty"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.sessions, .groups, .totals.cost, .skipped_lines]' <<<"$output")" = '[0,[],{},0]' ]
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `bats tests/bats/cost-summary.bats`
Expected: FAIL (no `schema/cost-record.schema.json`, no `image/cost/summary.jq`).

- [ ] **Step 4: Write the schemas**

`schema/cost-record.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "cost-record/v1: a cumulative cost snapshot of one agent session, one line of ledger.jsonl",
  "type": "object",
  "required": ["schema", "ts", "project", "harness", "session", "context", "models", "totals"],
  "properties": {
    "schema": { "const": "cost-record/v1" },
    "ts": { "type": "string", "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$",
            "description": "When the snapshot was taken, UTC." },
    "project": { "type": "string" },
    "harness": { "type": "string", "pattern": "^[a-z0-9][a-z0-9-]{0,39}$",
                 "description": "The collector's name: claude, copilot, or one a project adds." },
    "session": { "type": "string", "minLength": 1, "maxLength": 200,
                 "description": "The harness's session id; a later record of the same harness and session replaces this one." },
    "context": {
      "type": "object",
      "required": ["kind"],
      "properties": {
        "kind": { "enum": ["task", "scheduled", "dev"] },
        "task": { "type": "string" },
        "schedule": { "type": "string" }
      }
    },
    "models": { "type": "array", "items": { "$ref": "#/$defs/model" } },
    "totals": {
      "allOf": [{ "$ref": "#/$defs/tokens" }],
      "required": ["cost"],
      "properties": { "cost": { "$ref": "#/$defs/costs" } }
    },
    "producer": {
      "type": "object",
      "properties": { "collector": { "type": "string" }, "ccusage": { "type": "string" } }
    }
  },
  "$defs": {
    "count": { "type": "integer", "minimum": 0 },
    "tokens": {
      "type": "object",
      "required": ["input", "output", "cache_read", "cache_write"],
      "properties": {
        "input": { "$ref": "#/$defs/count", "description": "Prompt tokens without the cache." },
        "output": { "$ref": "#/$defs/count" },
        "cache_read": { "$ref": "#/$defs/count" },
        "cache_write": { "$ref": "#/$defs/count" }
      }
    },
    "source": {
      "enum": ["estimate", "billed-credits", "unknown"],
      "description": "estimate: list price from tokens; billed-credits: AI credits a seat was billed; unknown: tokens without a price. Never summed together."
    },
    "costs": {
      "type": "object",
      "propertyNames": { "$ref": "#/$defs/source" },
      "additionalProperties": { "type": "number", "minimum": 0 },
      "description": "USD per kind of cost."
    },
    "model": {
      "allOf": [{ "$ref": "#/$defs/tokens" }],
      "required": ["model", "cost", "cost_source"],
      "properties": {
        "model": { "type": "string" },
        "cost": { "type": "number", "minimum": 0 },
        "cost_source": { "$ref": "#/$defs/source" }
      }
    }
  }
}
```

`schema/cost-summary.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "cost-summary/v1: what agentic cost --json and every other reader of summary.jq return",
  "type": "object",
  "required": ["schema", "project", "filter", "groups", "sessions", "totals", "skipped_lines"],
  "properties": {
    "schema": { "const": "cost-summary/v1" },
    "project": { "type": "string" },
    "filter": {
      "type": "object",
      "required": ["since", "until", "task", "schedule", "kind", "by"],
      "properties": {
        "since": { "type": ["string", "null"], "description": "First day, inclusive." },
        "until": { "type": ["string", "null"], "description": "Last day, inclusive." },
        "task": { "type": ["string", "null"] },
        "schedule": { "type": ["string", "null"] },
        "kind": { "enum": ["task", "scheduled", "dev", null] },
        "by": { "enum": ["context", "task", "schedule", "session", "model", "day"] }
      }
    },
    "groups": {
      "type": "array",
      "description": "Newest first.",
      "items": {
        "type": "object",
        "required": ["key", "sessions", "last", "totals", "models"],
        "properties": {
          "key": { "type": "object", "description": "The group's identity; its fields depend on filter.by." },
          "sessions": { "$ref": "#/$defs/count" },
          "last": { "type": "string", "description": "The latest snapshot in the group." },
          "totals": { "$ref": "#/$defs/totals" },
          "models": {
            "type": "array",
            "items": {
              "allOf": [{ "$ref": "#/$defs/totals" }],
              "required": ["harness", "model"],
              "properties": { "harness": { "type": "string" }, "model": { "type": "string" } }
            }
          }
        }
      }
    },
    "sessions": { "$ref": "#/$defs/count" },
    "totals": { "$ref": "#/$defs/totals" },
    "skipped_lines": { "$ref": "#/$defs/count", "description": "Ledger lines that are not a cost-record/v1." }
  },
  "$defs": {
    "count": { "type": "integer", "minimum": 0 },
    "totals": {
      "type": "object",
      "required": ["input", "output", "cache_read", "cache_write", "cost"],
      "properties": {
        "input": { "$ref": "#/$defs/count" },
        "output": { "$ref": "#/$defs/count" },
        "cache_read": { "$ref": "#/$defs/count" },
        "cache_write": { "$ref": "#/$defs/count" },
        "cost": {
          "type": "object",
          "propertyNames": { "enum": ["estimate", "billed-credits", "unknown"] },
          "additionalProperties": { "type": "number", "minimum": 0 }
        }
      }
    }
  }
}
```

No `$id`: a relative `$id` breaks the `$ref` resolution of python's `jsonschema`; the `schema` field carries the version.

- [ ] **Step 5: Write `record.jq` and `summary.jq`**

`image/cost/record.jq`:

```jq
# The readers' check of schema/cost-record.schema.json: valid_record is true for a record every
# reader accepts. Keep the two in step; tests/bats/cost-summary.bats checks the fixtures with both.
def _count: type == "number" and . >= 0 and . == floor;
def _tokens: type == "object" and all(.input, .output, .cache_read, .cache_write; _count);
def _source: . == "estimate" or . == "billed-credits" or . == "unknown";
def _costs: type == "object" and all(to_entries[]; (.key | _source) and (.value | type == "number" and . >= 0));
def valid_record:
  type == "object" and .schema == "cost-record/v1"
  and (.ts | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and (.project | type == "string")
  and (.harness | type == "string" and test("^[a-z0-9][a-z0-9-]{0,39}$"))
  and (.session | type == "string" and length > 0 and length <= 200)
  and (.context | type == "object" and (.kind == "task" or .kind == "scheduled" or .kind == "dev")
       and ((.task // "") | type == "string") and ((.schedule // "") | type == "string"))
  and (.models | type == "array" and all(.[]; _tokens and (.model | type == "string")
       and (.cost | type == "number" and . >= 0) and (.cost_source | _source)))
  and (.totals | _tokens and (.cost | _costs));
```

`image/cost/summary.jq`:

```jq
# cost-summary/v1 of a ledger: raw lines on stdin, run as jq -n -R -L <this dir> -f summary.jq with
# --arg project, since, until, task, schedule, kind, by ("" = not set). The one place that
# aggregates (spec C8).
include "record";

def _set: if . == "" then null else . end;
def _addcost($b): reduce ($b | to_entries[]) as $e (.; .[$e.key] = ((.[$e.key] // 0) + $e.value));
def _sum: reduce .[] as $r ({input: 0, output: 0, cache_read: 0, cache_write: 0, cost: {}};
  .input += $r.input | .output += $r.output | .cache_read += $r.cache_read
  | .cache_write += $r.cache_write | .cost |= _addcost($r.cost));
# _rows: one row per model of a record; a record without models gives one row from its totals
def _rows: . as $r
  | (if (.models | length) > 0 then .models[] | .cost = {(.cost_source): .cost}
     else .totals + {model: "unknown"} end)
  | {sid: "\($r.harness)/\($r.session)", ts: $r.ts, context: $r.context, harness: $r.harness,
     session: $r.session, model, input, output, cache_read, cache_write, cost};
def _key($by):
  if $by == "task" then {task: (.context.task // null)}
  elif $by == "schedule" then {schedule: (.context.schedule // null)}
  elif $by == "session" then {harness, session}
  elif $by == "model" then {harness, model}
  elif $by == "day" then {day: .ts[0:10]}
  else .context end;
# _in: both days inclusive, compared at the precision given
def _in($since; $until): ($since == null or .ts[0:($since | length)] >= $since)
  and ($until == null or .ts[0:($until | length)] <= $until);

[inputs | select(length > 0) | (try fromjson catch null)] as $lines
| ($lines | map(select(. != null and valid_record))) as $ok
| {since: ($since | _set), until: ($until | _set), task: ($task | _set),
   schedule: ($schedule | _set), kind: ($kind | _set), by: (($by | _set) // "context")} as $f
# snapshots are cumulative and appended in order: a session's last line is its total (C3)
| ([reduce $ok[] as $r ({}; .["\($r.harness)/\($r.session)"] = $r) | .[]]
   | map(select(_in($f.since; $f.until)
       and ($f.task == null or .context.task == $f.task)
       and ($f.schedule == null or .context.schedule == $f.schedule)
       and ($f.kind == null or .context.kind == $f.kind)))
   | map(_rows)) as $rows
| {schema: "cost-summary/v1", project: $project, filter: $f,
   groups: ($rows | group_by(_key($f.by))
     | map({key: (.[0] | _key($f.by)), sessions: (map(.sid) | unique | length), last: (map(.ts) | max),
            totals: _sum,
            models: (group_by([.harness, .model]) | map(_sum + {harness: .[0].harness, model: .[0].model}))})
     | sort_by(.last) | reverse),
   sessions: ($rows | map(.sid) | unique | length),
   totals: ($rows | _sum),
   skipped_lines: (($lines | length) - ($ok | length))}
```

In `Makefile` lint, replace `jq empty schema/agentic.schema.json` with `jq empty schema/*.json`. In `CLAUDE.md`, change `(needs bats, jq, yq v4, python3, Node 22)` to `(needs bats, jq, yq v4, python3 with jsonschema, Node 22)`.

- [ ] **Step 6: Run the tests to see them pass**

Run: `bats tests/bats/cost-summary.bats`
Expected: 8 tests, all PASS.

- [ ] **Step 7: Commit**

```bash
git add schema/cost-*.schema.json image/cost/record.jq image/cost/summary.jq tests/fixtures/cost/ledger.jsonl \
  tests/fixtures/cost/validate.py tests/bats/cost-summary.bats Makefile CLAUDE.md
git commit -m "feat: cost contracts: cost-record/v1 and cost-summary/v1 schemas, valid_record and summary.jq"
```

---

### Task 2: The snapshot: collector → tag → append

**Files:**
- Create: `image/cost/snapshot` (mode 755), `tests/bats/cost-snapshot.bats`
- Modify: `Makefile` (`SHELL_SOURCES` += `image/cost/snapshot`)

**Interfaces:**
- Consumes: `valid_record` (Task 1) through `jq -L "$COST_DIR"`.
- Produces: `snapshot EVENT [HARNESS]`, payload on stdin, always exit 0. Environment: `AGENTIC_COST_DIR` (default `/opt/agentic/cost`), `AGENTIC_COST_LEDGER_DIR` (default `/cost`), `AGENTIC_CONFIG_MOUNT` (default `/agentic-config`), `AGENTIC_STATE` (log in `$AGENTIC_STATE/cost.log`), `AGENTIC_COST_TIMEOUT` (default 60), `AGENTIC_COST_FOREGROUND=1` (do not detach; tests and the smoke use it). Collector contract: `<dir>/collectors/<harness> EVENT`, payload on stdin, prints `cost-record/v1` lines without `project` and `context`.

- [ ] **Step 1: Write the failing tests**

`tests/bats/cost-snapshot.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  S="$REPO_ROOT/image/cost/snapshot"
  # an image cost dir with the real record.jq and stub collectors
  export AGENTIC_COST_DIR="$BATS_TEST_TMPDIR/cost"
  mkdir -p "$AGENTIC_COST_DIR/collectors"
  ln -s "$REPO_ROOT/image/cost/record.jq" "$AGENTIC_COST_DIR/record.jq"
  export AGENTIC_COST_LEDGER_DIR="$BATS_TEST_TMPDIR/ledger" AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/cfg"
  export AGENTIC_STATE="$HOME/.agentic" AGENTIC_COST_FOREGROUND=1 AGENTIC_PROJECT=demo
  mkdir -p "$AGENTIC_COST_LEDGER_DIR"
  unset AGENTIC_TASK_ID AGENTIC_SCHEDULED AGENTIC_SCHEDULE COPILOT_PLUGIN_ROOT
  LEDGER="$AGENTIC_COST_LEDGER_DIR/ledger.jsonl"
  REC='{"schema":"cost-record/v1","ts":"2026-10-15T10:00:00Z","harness":"claude","session":"s1","models":[],"totals":{"input":1,"output":2,"cache_read":0,"cache_write":0,"cost":{"estimate":0.5}}}'
}

# collector DIR NAME BODY: an executable collector script.
collector() { mkdir -p "$1"; printf '#!/usr/bin/env bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }

@test "a dev session's record gets the project and context and is appended" {
  collector "$AGENTIC_COST_DIR/collectors" claude "echo '$REC'"
  run "$S" turn <<<'{"session_id":"s1"}'
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.project, .context]' "$LEDGER")" = '["demo",{"kind":"dev"}]' ]
  run "$S" end <<<'{"session_id":"s1"}'
  [ "$(wc -l < "$LEDGER")" -eq 2 ]
}

@test "a task and a scheduled run are tagged from the environment" {
  collector "$AGENTIC_COST_DIR/collectors" claude "echo '$REC'"
  AGENTIC_TASK_ID=t1 "$S" turn </dev/null
  AGENTIC_TASK_ID=t2 AGENTIC_SCHEDULED=1 AGENTIC_SCHEDULE=nightly "$S" turn </dev/null
  [ "$(jq -sc 'map(.context)' "$LEDGER")" = '[{"kind":"task","task":"t1"},{"kind":"scheduled","task":"t2","schedule":"nightly"}]' ]
}

@test "the collector gets the event as its argument and the payload on stdin" {
  collector "$AGENTIC_COST_DIR/collectors" claude "echo \"\$1\" > '$BATS_TEST_TMPDIR/event'; cat > '$BATS_TEST_TMPDIR/payload'"
  "$S" end <<<'{"session_id":"abc"}'
  [ "$(cat "$BATS_TEST_TMPDIR/event")" = end ]
  [ "$(jq -r .session_id "$BATS_TEST_TMPDIR/payload")" = abc ]
}

@test "Copilot is told apart by COPILOT_PLUGIN_ROOT; a second argument names the harness" {
  collector "$AGENTIC_COST_DIR/collectors" claude "echo '$REC'"
  collector "$AGENTIC_COST_DIR/collectors" copilot "jq -c '.harness = \"copilot\"' <<<'$REC'"
  COPILOT_PLUGIN_ROOT=/x "$S" turn </dev/null
  "$S" turn </dev/null
  "$S" turn copilot </dev/null
  [ "$(jq -sc 'map(.harness)' "$LEDGER")" = '["copilot","claude","copilot"]' ]
}

@test "the project's collector wins over the image's" {
  collector "$AGENTIC_COST_DIR/collectors" claude "echo '$REC'"
  collector "$AGENTIC_CONFIG_MOUNT/cost/collectors" claude "jq -c '.session = \"mine\"' <<<'$REC'"
  "$S" turn </dev/null
  [ "$(jq -r .session "$LEDGER")" = mine ]
}

@test "a record that breaks the schema is not written, and is logged" {
  collector "$AGENTIC_COST_DIR/collectors" claude "echo '{\"schema\":\"cost-record/v1\",\"session\":\"x\"}'; echo 'not json'"
  run "$S" turn </dev/null
  [ "$status" -eq 0 ]
  [ ! -s "$LEDGER" ]
  grep -q 'claude' "$AGENTIC_STATE/cost.log"
}

@test "no ledger folder, no collector, a failing or a slow collector: nothing written, exit 0" {
  rmdir "$AGENTIC_COST_LEDGER_DIR"
  collector "$AGENTIC_COST_DIR/collectors" claude "echo '$REC'"
  run "$S" turn </dev/null
  [ "$status" -eq 0 ]; [ ! -e "$LEDGER" ]
  grep -q 'not recorded' "$AGENTIC_STATE/cost.log"
  mkdir -p "$AGENTIC_COST_LEDGER_DIR"
  run "$S" turn codex </dev/null
  [ "$status" -eq 0 ]; [ ! -e "$LEDGER" ]
  collector "$AGENTIC_COST_DIR/collectors" claude "exit 3"
  run "$S" turn </dev/null
  [ "$status" -eq 0 ]; [ ! -e "$LEDGER" ]
  collector "$AGENTIC_COST_DIR/collectors" claude "sleep 5; echo '$REC'"
  SECONDS=0
  AGENTIC_COST_TIMEOUT=1 run "$S" turn </dev/null
  [ "$status" -eq 0 ]; [ "$SECONDS" -lt 4 ]; [ ! -e "$LEDGER" ]
}

@test "a harness name that is not a plain word runs nothing" {
  printf '#!/bin/sh\ntouch "%s/ran"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/evil"; chmod +x "$BATS_TEST_TMPDIR/evil"
  run "$S" turn "../../../$BATS_TEST_TMPDIR/evil" </dev/null
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "the hook returns at once; the snapshot lands in the background" {
  unset AGENTIC_COST_FOREGROUND
  collector "$AGENTIC_COST_DIR/collectors" claude "sleep 3; echo '$REC'"
  SECONDS=0
  run "$S" turn <<<'{"session_id":"s1"}'
  [ "$status" -eq 0 ]; [ "$SECONDS" -lt 2 ]; [ ! -s "$LEDGER" ]
  for _ in $(seq 100); do [ -s "$LEDGER" ] && break; sleep 0.1; done
  [ "$(jq -r .session "$LEDGER")" = s1 ]
}

@test "parallel snapshots leave whole lines" {
  big="$(jq -c --arg m "$(printf 'm%.0s' $(seq 3000))" '.models = [range(20) | {model: $m, input: 1, output: 1, cache_read: 0, cache_write: 0, cost: 0.1, cost_source: "estimate"}]' <<<"$REC")"
  printf '%s\n' "$big" > "$BATS_TEST_TMPDIR/big.json"
  collector "$AGENTIC_COST_DIR/collectors" claude "cat '$BATS_TEST_TMPDIR/big.json'"
  for _ in $(seq 8); do "$S" turn </dev/null & done
  wait
  [ "$(wc -l < "$LEDGER")" -eq 8 ]
  jq -e . "$LEDGER" >/dev/null
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `bats tests/bats/cost-snapshot.bats`
Expected: FAIL (`image/cost/snapshot` does not exist).

- [ ] **Step 3: Write the snapshot**

`image/cost/snapshot`:

```bash
#!/usr/bin/env bash
# snapshot EVENT [HARNESS]: the cost plugin's hook entry (docs/specs/2026-10-15-cost-tracking-design.md
# §4.1). Runs the harness's collector on the hook payload (stdin), tags each record with the project
# and the task or schedule, and appends it to the project's ledger. Returns at once and always exits
# 0: cost is diagnostics and never disturbs a turn.
set -uo pipefail
COST_DIR="${AGENTIC_COST_DIR:-/opt/agentic/cost}"
LEDGER_DIR="${AGENTIC_COST_LEDGER_DIR:-/cost}"
PROJECT_COST="${AGENTIC_CONFIG_MOUNT:-/agentic-config}/cost"
LOG="${AGENTIC_STATE:-$HOME/.agentic}/cost.log"
ev="${1:-turn}"
# both harnesses run the plugin's one hooks.json; only Copilot sets COPILOT_PLUGIN_ROOT
harness="${2:-$(if [ -n "${COPILOT_PLUGIN_ROOT:-}" ]; then echo copilot; else echo claude; fi)}"

log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null && printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$harness" "$*" >> "$LOG" 2>/dev/null
  return 0
}

# collector: the project's collector for the harness, else the image's; the name is a plain word.
collector() {
  local f
  [[ "$harness" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || return 1
  for f in "$PROJECT_COST/collectors/$harness" "$COST_DIR/collectors/$harness"; do
    if [ -f "$f" ] && [ -x "$f" ]; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

# context: where the session runs, from what the host gave the container.
context() {
  jq -cn --arg t "${AGENTIC_TASK_ID:-}" --arg sch "${AGENTIC_SCHEDULED:-}" --arg s "${AGENTIC_SCHEDULE:-}" '
    if $t == "" then {kind: "dev"}
    else {kind: (if $sch == "1" then "scheduled" else "task" end), task: $t}
      + (if $s == "" then {} else {schedule: $s} end) end'
}

record() {
  local c out
  c="$(collector)" || { log "no collector"; return 0; }
  if [ ! -d "$LEDGER_DIR" ] || [ ! -w "$LEDGER_DIR" ]; then log "no writable $LEDGER_DIR; not recorded"; return 0; fi
  out="$(timeout "${AGENTIC_COST_TIMEOUT:-60}" "$c" "$ev" 2>>"$LOG")" || { log "collector failed ($?)"; return 0; }
  out="$(jq -c -L "$COST_DIR" --arg p "${AGENTIC_PROJECT:-}" --argjson ctx "$(context)" 'include "record";
      . + {project: $p, context: $ctx}
      | if valid_record then . else ("rejected: \(tojson[0:300])\n" | stderr | empty) end' <<<"$out" 2>>"$LOG")" \
    || { log "the collector printed something that is not JSON"; return 0; }
  [ -n "$out" ] || return 0
  # task and dev containers share the ledger: one locked write per snapshot keeps lines whole
  { flock 9 && printf '%s\n' "$out" >&9; } 9>>"$LEDGER_DIR/ledger.jsonl"
  return 0
}

if [ "${AGENTIC_COST_FOREGROUND:-0}" = 1 ]; then record; exit 0; fi
# the payload is read before detaching: the harness closes the pipe when the hook returns
payload="$(cat 2>/dev/null || true)"
printf '%s' "$payload" | AGENTIC_COST_FOREGROUND=1 setsid "$0" "$ev" "$harness" >/dev/null 2>&1 &
exit 0
```

`chmod 755 image/cost/snapshot`. In `Makefile`, add `image/cost/snapshot` to `SHELL_SOURCES`.

- [ ] **Step 4: Run the tests to see them pass**

Run: `bats tests/bats/cost-snapshot.bats && shellcheck -x image/cost/snapshot`
Expected: 10 tests PASS, shellcheck silent.

- [ ] **Step 5: Commit**

```bash
git add image/cost/snapshot tests/bats/cost-snapshot.bats Makefile
git commit -m "feat: cost snapshot: runs the harness's collector, tags the record, appends it to the ledger"
```

---

### Task 3: The Claude and Copilot collectors

**Files:**
- Create: `image/cost/lib.sh`, `image/cost/collectors/claude` (755), `image/cost/collectors/copilot` (755), `image/cost/ccusage.json`, `tests/fixtures/cost/ccusage-claude-session.json`, `tests/fixtures/cost/ccusage-copilot-session.json`, `tests/bats/cost-collectors.bats`
- Modify: `Makefile` (`SHELL_SOURCES` += `image/cost/lib.sh image/cost/collectors/*`)

**Interfaces:**
- Consumes: the collector contract of Task 2; `valid_record` of Task 1 (tests).
- Produces: `lib.sh` functions `payload_session` (stdin → session id), `ccusage_session_list HARNESS` (ccusage's JSON), `to_records HARNESS SESSION` (stdin: ccusage's list → the session's record, no `project`/`context`).

- [ ] **Step 1: Write the recorded ccusage outputs**

These are ccusage 20.0.32's outputs for the synthetic transcripts of the facts note (`docs/plans/2026-10-15-cost-harness-facts.md`), recorded in the image.

`tests/fixtures/cost/ccusage-claude-session.json`:

```json
{"sessions":[{"cacheCreationTokens":2000,"cacheReadTokens":3000,"firstActivity":"2026-10-15T10:00:01.000Z","inputTokens":1015,"lastActivity":"2026-10-15T10:00:05.000Z","modelBreakdowns":[{"cacheCreationTokens":2000,"cacheReadTokens":3000,"cost":0.01302,"inputTokens":1005,"modelName":"claude-sonnet-4-5","outputTokens":107},{"cacheCreationTokens":0,"cacheReadTokens":0,"cost":0.00044,"inputTokens":10,"modelName":"claude-opus-5-5","outputTokens":20}],"modelsUsed":["claude-sonnet-4-5","claude-opus-5-5"],"outputTokens":127,"projectPath":"-work","sessionId":"11111111-1111-1111-1111-111111111111","totalCost":0.01346,"totalTokens":6142},{"cacheCreationTokens":0,"cacheReadTokens":0,"firstActivity":"2026-10-15T11:00:00.000Z","inputTokens":1,"lastActivity":"2026-10-15T11:00:00.000Z","modelBreakdowns":[{"cacheCreationTokens":0,"cacheReadTokens":0,"cost":0.000018,"inputTokens":1,"modelName":"claude-sonnet-4-5","outputTokens":1}],"modelsUsed":["claude-sonnet-4-5"],"outputTokens":1,"projectPath":"-work","sessionId":"22222222-2222-2222-2222-222222222222","totalCost":0.000018,"totalTokens":2}],"totals":{"cacheCreationTokens":2000,"cacheReadTokens":3000,"inputTokens":1016,"outputTokens":128,"totalCost":0.013478,"totalTokens":6144}}
```

`tests/fixtures/cost/ccusage-copilot-session.json`:

```json
{"sessions":[{"cacheCreationTokens":0,"cacheReadTokens":90112,"firstActivity":"2026-10-15T09:05:00.000Z","inputTokens":38812,"lastActivity":"2026-10-15T09:05:00.000Z","messageCount":4,"modelBreakdowns":[{"cacheCreationTokens":0,"cacheReadTokens":90112,"cost":0.1723746,"inputTokens":38812,"modelName":"claude-sonnet-4.5","outputTokens":1927}],"modelsUsed":["claude-sonnet-4.5"],"outputTokens":1927,"projectPath":"GitHub Copilot CLI","sessionId":"33333333-3333-3333-3333-333333333333","totalCost":0.1723746,"totalTokens":130851},{"cacheCreationTokens":0,"cacheReadTokens":0,"firstActivity":"2026-10-15T08:01:00.000Z","inputTokens":0,"lastActivity":"2026-10-15T08:01:00.000Z","modelBreakdowns":[{"cacheCreationTokens":0,"cacheReadTokens":0,"cost":0.03196233,"inputTokens":0,"modelName":"unknown","outputTokens":0}],"modelsUsed":["unknown"],"outputTokens":0,"projectPath":"GitHub Copilot CLI","sessionId":"44444444-4444-4444-4444-444444444444","totalCost":0.03196233,"totalTokens":0}],"totals":{"cacheCreationTokens":0,"cacheReadTokens":90112,"inputTokens":38812,"outputTokens":1927,"totalCost":0.20433692999999997,"totalTokens":130851}}
```

- [ ] **Step 2: Write the failing tests**

`tests/bats/cost-collectors.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  export AGENTIC_COST_DIR="$REPO_ROOT/image/cost" AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/cfg"
  F="$REPO_ROOT/tests/fixtures/cost"
  # a ccusage stand-in: logs its arguments, prints the recorded list of the harness (or $STUB_OUT)
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/ccusage" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$BATS_TEST_TMPDIR/ccusage.args"
if [ "\$1" = --version ]; then echo "ccusage 20.0.32"; exit 0; fi
cat "\${STUB_OUT:-$F/ccusage-\$1-session.json}"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/ccusage"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# valid OUTPUT: every line of OUTPUT, completed as the snapshot does, is a valid record.
valid() {
  jq -e -L "$AGENTIC_COST_DIR" 'include "record"; . + {project: "p", context: {kind: "dev"}} | valid_record' <<<"$1" >/dev/null
}

@test "claude: the payload's session, per model, with ccusage's deduplicated totals" {
  run "$AGENTIC_COST_DIR/collectors/claude" turn <<<'{"session_id":"11111111-1111-1111-1111-111111111111","transcript_path":"/x"}'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  valid "$output"
  [ "$(jq -c '[.harness, .session, .totals.input, .totals.output, .totals.cache_read, .totals.cache_write]' <<<"$output")" \
    = '["claude","11111111-1111-1111-1111-111111111111",1015,127,3000,2000]' ]
  [ "$(jq -c '[.models[] | [.model, .cost_source]]' <<<"$output")" = '[["claude-sonnet-4-5","estimate"],["claude-opus-5-5","estimate"]]' ]
  jq -e '(.totals.cost.estimate - 0.01346 | fabs) < 1e-9 and .producer == {collector: "claude", ccusage: "20.0.32"}' <<<"$output"
  grep -qx "claude session --json --offline --config $AGENTIC_COST_DIR/ccusage.json" "$BATS_TEST_TMPDIR/ccusage.args"
}

@test "copilot: a camelCase payload; a shut-down session is a token estimate" {
  run "$AGENTIC_COST_DIR/collectors/copilot" end <<<'{"sessionId":"33333333-3333-3333-3333-333333333333"}'
  [ "$status" -eq 0 ]
  valid "$output"
  [ "$(jq -c '[.harness, .totals.input, .totals.cost]' <<<"$output")" = '["copilot",38812,{"estimate":0.1723746}]' ]
}

@test "an open Copilot session (credits, no tokens yet) is billed-credits, not an estimate" {
  run "$AGENTIC_COST_DIR/collectors/copilot" turn <<<'{"session_id":"44444444-4444-4444-4444-444444444444"}'
  valid "$output"
  [ "$(jq -c '[.models[0].cost_source, .totals.cost]' <<<"$output")" = '["billed-credits",{"billed-credits":0.03196233}]' ]
}

@test "tokens without a price are unknown, beside the priced ones" {
  jq '.sessions[0].modelBreakdowns[1].cost = 0' "$F/ccusage-claude-session.json" > "$BATS_TEST_TMPDIR/out.json"
  STUB_OUT="$BATS_TEST_TMPDIR/out.json" run "$AGENTIC_COST_DIR/collectors/claude" turn <<<'{"session_id":"11111111-1111-1111-1111-111111111111"}'
  valid "$output"
  [ "$(jq -c '[.models[1].cost_source, (.totals.cost | keys)]' <<<"$output")" = '["unknown",["estimate","unknown"]]' ]
}

@test "no session id, an unknown session, or a failing ccusage: no record, exit 0 for the first two" {
  run "$AGENTIC_COST_DIR/collectors/claude" turn <<<'{}'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run "$AGENTIC_COST_DIR/collectors/claude" turn <<<'not json'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run "$AGENTIC_COST_DIR/collectors/claude" turn <<<'{"session_id":"nope"}'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  printf '#!/bin/sh\nexit 2\n' > "$BATS_TEST_TMPDIR/bin/ccusage"
  run "$AGENTIC_COST_DIR/collectors/claude" turn <<<'{"session_id":"11111111-1111-1111-1111-111111111111"}'
  [ "$status" -ne 0 ]; [ -z "$output" ]
}

@test "the project's pricing overrides win over the image's" {
  mkdir -p "$AGENTIC_CONFIG_MOUNT/cost"; echo '{}' > "$AGENTIC_CONFIG_MOUNT/cost/ccusage.json"
  "$AGENTIC_COST_DIR/collectors/copilot" turn <<<'{"sessionId":"33333333-3333-3333-3333-333333333333"}' >/dev/null
  grep -qx "copilot session --json --offline --config $AGENTIC_CONFIG_MOUNT/cost/ccusage.json" "$BATS_TEST_TMPDIR/ccusage.args"
}

@test "the image's pricing overrides file is valid ccusage config" {
  jq -e 'type == "object"' "$AGENTIC_COST_DIR/ccusage.json"
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `bats tests/bats/cost-collectors.bats`
Expected: FAIL (no collectors).

- [ ] **Step 4: Write `lib.sh`, the collectors and the overrides file**

`image/cost/lib.sh`:

```bash
# Shared by the cost collectors (spec §3.2); sourced. ccusage reads the harness's own files and
# prices them (spec C2); this maps its session list to cost-record/v1.
COST_DIR="${AGENTIC_COST_DIR:-/opt/agentic/cost}"

# payload_session: the session id of the hook payload on stdin (Claude and Copilot spell it apart).
payload_session() { jq -r '.session_id // .sessionId // empty' 2>/dev/null || true; }

# ccusage_session_list HARNESS: ccusage's session list for HARNESS, offline, with the project's
# pricing overrides or else the image's.
ccusage_session_list() {
  local cfg="${AGENTIC_CONFIG_MOUNT:-/agentic-config}/cost/ccusage.json"
  [ -f "$cfg" ] || cfg="$COST_DIR/ccusage.json"
  ccusage "$1" session --json --offline --config "$cfg"
}

# to_records HARNESS SESSION: ccusage's session list (stdin) to SESSION's cost-record/v1, without
# project and context (the snapshot adds them). Nothing when the list does not have SESSION.
to_records() {
  jq -c --arg h "$1" --arg s "$2" --arg ts "$(date -u +%FT%TZ)" \
    --arg v "$(ccusage --version 2>/dev/null | awk '{print $NF}')" '
    # tokens with no price are unknown; a price with no tokens is Copilot credits (no shutdown yet)
    def src($cost; $tokens): if $tokens == 0 and $cost > 0 then "billed-credits"
      elif $cost == 0 and $tokens > 0 then "unknown" else "estimate" end;
    .sessions[]? | select(.sessionId == $s)
    | {schema: "cost-record/v1", ts: $ts, harness: $h, session: $s,
       models: [.modelBreakdowns[]?
         | {model: .modelName, input: .inputTokens, output: .outputTokens, cache_read: .cacheReadTokens,
            cache_write: .cacheCreationTokens, cost: .cost,
            cost_source: src(.cost; .inputTokens + .outputTokens + .cacheReadTokens + .cacheCreationTokens)}],
       totals: {input: .inputTokens, output: .outputTokens, cache_read: .cacheReadTokens,
                cache_write: .cacheCreationTokens, cost: {}},
       producer: {collector: $h, ccusage: $v}}
    | .totals.cost = (reduce .models[] as $m ({}; .[$m.cost_source] += $m.cost))'
}
```

`image/cost/collectors/claude`:

```bash
#!/usr/bin/env bash
# collectors/claude EVENT: the cost-record/v1 of the Claude session in the hook payload (stdin).
# ccusage reads $CLAUDE_CONFIG_DIR/projects, counts each request once and adds the subagents.
set -euo pipefail
# shellcheck source=SCRIPTDIR/../lib.sh
source "${AGENTIC_COST_DIR:-/opt/agentic/cost}/lib.sh"
sid="$(payload_session)"
[ -n "$sid" ] || exit 0
ccusage_session_list claude | to_records claude "$sid"
```

`image/cost/collectors/copilot`:

```bash
#!/usr/bin/env bash
# collectors/copilot EVENT: the cost-record/v1 of the Copilot session in the hook payload (stdin).
# ccusage reads $COPILOT_HOME/session-state; a resumed session's last cumulative shutdown counts.
set -euo pipefail
# shellcheck source=SCRIPTDIR/../lib.sh
source "${AGENTIC_COST_DIR:-/opt/agentic/cost}/lib.sh"
sid="$(payload_session)"
[ -n "$sid" ] || exit 0
ccusage_session_list copilot | to_records copilot "$sid"
```

`chmod 755 image/cost/collectors/*`. `image/cost/ccusage.json` is `{}` (the format is in `docs/cost.md`, Task 7). In `Makefile`, add `image/cost/lib.sh image/cost/collectors/*` to `SHELL_SOURCES`.

- [ ] **Step 5: Run the tests to see them pass**

Run: `bats tests/bats/cost-collectors.bats && shellcheck -x image/cost/lib.sh image/cost/collectors/*`
Expected: 7 tests PASS, shellcheck silent.

- [ ] **Step 6: Commit**

```bash
git add image/cost/lib.sh image/cost/collectors image/cost/ccusage.json tests/fixtures/cost/ccusage-*.json \
  tests/bats/cost-collectors.bats Makefile
git commit -m "feat: cost collectors for Claude and Copilot on ccusage, with pricing overrides"
```

---

### Task 4: The plugin, its marketplace, and the image

**Files:**
- Create: `marketplace/.claude-plugin/marketplace.json`, `marketplace/plugins/cost/.claude-plugin/plugin.json`, `marketplace/plugins/cost/hooks/hooks.json`, `tests/bats/cost-plugin.bats`
- Modify: `image/Dockerfile` (pin ccusage, copy `image/cost` and `marketplace`), `bin/agentic` (`base_hash` includes `marketplace`), `config/recommended`, `tests/bats/dockerfile.bats`

**Interfaces:**
- Consumes: `/opt/agentic/cost/snapshot EVENT` (Task 2).
- Produces: plugin `cost@agentic` in `/opt/agentic/marketplace`; recommended lines `add marketplace /opt/agentic/marketplace` and `add plugin cost@agentic`.

- [ ] **Step 1: Write the failing tests**

`tests/bats/cost-plugin.bats`:

```bash
#!/usr/bin/env bats
load helpers

M="$REPO_ROOT/marketplace"

@test "the agentic marketplace lists the cost plugin" {
  jq -e '.name == "agentic" and (.plugins | map(select(.name == "cost" and .source == "./plugins/cost")) | length == 1)' \
    "$M/.claude-plugin/marketplace.json"
  jq -e '.name == "cost" and (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$M/plugins/cost/.claude-plugin/plugin.json"
}

@test "the plugin's hooks snapshot after every turn and at session end, through the image's snapshot" {
  h="$M/plugins/cost/hooks/hooks.json"
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$h")" = "/opt/agentic/cost/snapshot turn" ]
  [ "$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$h")" = "/opt/agentic/cost/snapshot end" ]
  [ "$(jq -r '[.hooks[][].hooks[].type] | unique | join(",")' "$h")" = command ]
  # /opt/agentic/cost is image/cost in the repository: the commands exist and are executable
  for c in snapshot collectors/claude collectors/copilot; do [ -x "$REPO_ROOT/image/cost/$c" ]; done
}

@test "the recommended lines install the cost plugin for both harnesses" {
  grep -qx 'add marketplace /opt/agentic/marketplace' "$REPO_ROOT/config/recommended"
  grep -qx 'add plugin cost@agentic' "$REPO_ROOT/config/recommended"
}
```

In `tests/bats/dockerfile.bats`, first test: add `"image/cost /opt/agentic/cost" "marketplace /opt/agentic/marketplace"` to the `for pair in` list. In the `.dockerignore` test, add `marketplace` to `for p in skills config schema image derive`. Add a test:

```bash
@test "ccusage is pinned to an exact version" {
  grep -Eq '(^| )ccusage@[0-9]+\.[0-9]+\.[0-9]+( |$)' "$D"
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `bats tests/bats/cost-plugin.bats tests/bats/dockerfile.bats`
Expected: FAIL (no marketplace, no COPY lines, ccusage unpinned).

- [ ] **Step 3: Write the marketplace and the plugin**

`marketplace/.claude-plugin/marketplace.json`:

```json
{
  "name": "agentic",
  "owner": { "name": "agentic-dev-base" },
  "plugins": [
    { "name": "cost", "source": "./plugins/cost",
      "description": "Records the token cost of every session in the project's cost ledger; read it with agentic cost" }
  ]
}
```

`marketplace/plugins/cost/.claude-plugin/plugin.json`:

```json
{ "name": "cost", "version": "1.0.0",
  "description": "Records the token cost of every session in the project's cost ledger; read it with agentic cost" }
```

`marketplace/plugins/cost/hooks/hooks.json` (Claude's format; Copilot reads it too, facts note):

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "/opt/agentic/cost/snapshot turn", "timeout": 10 }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "/opt/agentic/cost/snapshot end", "timeout": 10 }] }]
  }
}
```

- [ ] **Step 4: Wire it into the image and the recommended lines**

In `image/Dockerfile`, in the `npm install -g` line, change `ccusage` to `ccusage@20.0.32`. In the agentic layer, after `COPY image/hooks.d /opt/agentic/hooks.d`, add:

```dockerfile
COPY image/cost /opt/agentic/cost
COPY marketplace /opt/agentic/marketplace
```

In `bin/agentic` `base_hash`, change `find image derive config schema skills templates` to `find image derive config schema skills templates marketplace`.

Append to `config/recommended`:

```
add marketplace /opt/agentic/marketplace
add plugin cost@agentic
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `bats tests/bats/cost-plugin.bats tests/bats/dockerfile.bats tests/bats/cli-init.bats`
Expected: all PASS (`cli-init` reads `config/recommended`, so the new lines go through `init`).

- [ ] **Step 6: Commit**

```bash
git add marketplace tests/bats/cost-plugin.bats tests/bats/dockerfile.bats image/Dockerfile bin/agentic config/recommended
git commit -m "feat: the cost plugin in an in-image marketplace, recommended for both harnesses; ccusage pinned"
```

---

### Task 5: The `/cost` mount and the schedule name

**Files:**
- Modify: `lib/host/common.sh` (`project_run_args`), `lib/host/setup.sh` (`cmd_list`), `bin/agentic` (`cmd_run` env file), `lib/host/schedule.sh` (`sched_fire`), `tests/bats/cli-core.bats`, `tests/bats/cli-setup.bats`, `tests/bats/cli-schedule.bats`, `tests/bats/cli-task-run.bats`

**Interfaces:**
- Produces: every container of the project (dev, shell, task) has `$(realpath -m "$AGENTIC_WORKSPACES")/<project>/cost` at `/cost`; a scheduled run's env file has `AGENTIC_SCHEDULE=<name>`.

- [ ] **Step 1: Write the failing tests**

In `tests/bats/cli-core.bats`, test "run arguments keep paths with spaces intact and mount the standard places", after the `repos` lines add:

```bash
  grep -qx "$AGENTIC_WORKSPACES/demo/cost:/cost" <<<"$output"
  [ -d "$AGENTIC_WORKSPACES/demo/cost" ]
```

and add a test:

```bash
@test "a symlinked cost folder is refused" {
  mkdir -p "$AGENTIC_WORKSPACES/demo" "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$AGENTIC_WORKSPACES/demo/cost"
  run in_project 'build_run_args agentic-demo:local'
  [ "$status" -ne 0 ]
  [[ "$output" == *"cost is a symlink"* ]]
}
```

In `tests/bats/cli-setup.bats`, in the `list` test, after the `repos` line add:

```bash
  [[ "$output" == *$'built-in\t'"$AGENTIC_WORKSPACES/demo/cost"' -> /cost (the cost ledger: agentic cost)'* ]]
```

In `tests/bats/cli-schedule.bats`, test "the task env of a firing has the scheduled settings, worktree and auto-clean", change the `for l in` list to `AGENTIC_SCHEDULED=1 AGENTIC_SCHEDULE=nightly AGENTIC_RUN_TIMEOUT=5400 AGENTIC_WORKTREE=1 AGENTIC_AUTO_CLEAN=1`.

In `tests/bats/cli-task-run.bats`, after the test "run --scheduled writes the scheduled settings into the host env file", add:

```bash
@test "only a scheduled run carries the schedule name into its env file" {
  AGENTIC_SCHEDULE=nightly ag run --id T-N --scheduled 60 "x"
  grep -qx AGENTIC_SCHEDULE=nightly "$H/T-N/env"
  AGENTIC_SCHEDULE=leaked ag run --id T-P "x"
  run grep -q '^AGENTIC_SCHEDULE=' "$H/T-P/env"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `bats tests/bats/cli-core.bats tests/bats/cli-setup.bats tests/bats/cli-schedule.bats tests/bats/cli-task-run.bats`
Expected: the new assertions FAIL.

- [ ] **Step 3: Implement**

`lib/host/common.sh`, `project_run_args`:

```bash
project_run_args() {
  local root cfg p repos cost
  root="$(project_root)"; cfg="$root/.agentic"; p="$(project_name)"
  # the workspace root is canonical; the rest is not resolved, so a symlink below it is seen
  repos="$(realpath -m -- "$AGENTIC_WORKSPACES")/$p/repos"
  cost="$(realpath -m -- "$AGENTIC_WORKSPACES")/$p/cost"
  mkdir -p "$repos" "$cost"
  bind_src_ok "$repos" || die "$repos is a symlink or goes through one; refused"
  bind_src_ok "$cost" || die "$cost is a symlink or goes through one; refused"
  RUN_ARGS=(--label "agentic.project=$p" -v "$root:/work" -v "$repos:/workspaces/repos" -v "$cost:/cost"
    -v "$cfg:/agentic-config:ro")
  shared_run_args "$1"
}
```

Note: when `cost` is a symlink to a directory, `mkdir -p` succeeds and `bind_src_ok` refuses it. Update the comment above `build_run_args` to: `# The workspace's tasks/ and events/ stay out of interactive containers; cost/ goes into all.`

`lib/host/setup.sh`, `cmd_list`, after the `repos` line:

```bash
  echo "built-in${t}$(realpath -m -- "$AGENTIC_WORKSPACES")/$p/cost -> /cost (the cost ledger: agentic cost)"
```

`bin/agentic`, `cmd_run`, in the env-file block replace the `sched` line with:

```bash
    if [ -n "$sched" ]; then
      printf 'AGENTIC_SCHEDULED=1\nAGENTIC_RUN_TIMEOUT=%s\n' "$sched"
      if [ -n "${AGENTIC_SCHEDULE:-}" ]; then printf 'AGENTIC_SCHEDULE=%s\n' "$AGENTIC_SCHEDULE"; fi
    fi
```

`lib/host/schedule.sh`, `sched_fire`: replace `if ! out="$( (cmd_run "${args[@]}") 2>&1 )"; then` with:

```bash
  # the name tags the run's cost records (docs/cost.md)
  if ! out="$( (export AGENTIC_SCHEDULE="$name"; cmd_run "${args[@]}") 2>&1 )"; then
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `bats tests/bats/cli-core.bats tests/bats/cli-setup.bats tests/bats/cli-schedule.bats tests/bats/cli-task-run.bats && shellcheck -x bin/agentic lib/host/*.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/host/common.sh lib/host/setup.sh lib/host/schedule.sh bin/agentic tests/bats/cli-core.bats \
  tests/bats/cli-setup.bats tests/bats/cli-schedule.bats tests/bats/cli-task-run.bats
git commit -m "feat: every container of a project mounts its cost ledger at /cost; scheduled runs carry their name"
```

---

### Task 6: `agentic cost`

**Files:**
- Create: `lib/host/cost.sh`, `tests/bats/cli-cost.bats`
- Modify: `bin/agentic` (source `cost.sh`, usage, dispatch)

**Interfaces:**
- Consumes: `image/cost/summary.jq` and `record.jq` (Task 1) from `$AGENTIC_ROOT/image/cost`; `bind_src_ok`, `read_agent_file`, `valid_task_id`, `valid_sched_name`, `optval`, `need_config`, `project_name`, `die`.
- Produces: `agentic cost [--since D] [--until D] [--task ID] [--schedule NAME] [--kind task|scheduled|dev] [--by context|task|schedule|session|model|day] [--json]`. `--json` prints `cost-summary/v1`, the contract a UI consumes.

- [ ] **Step 1: Write the failing tests**

`tests/bats/cli-cost.bats`:

```bash
#!/usr/bin/env bats
load helpers
load docker-stub

setup() {
  make_tmp_home
  install_docker_stub
  export AGENTIC_DATA="$BATS_TEST_TMPDIR/data" AGENTIC_WORKSPACES="$BATS_TEST_TMPDIR/ws"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/.agentic"; git init -q -b main "$PROJ"
  printf 'version: 2\nproject: demo\nlayout: single\n' > "$PROJ/.agentic/agentic.yaml"
  git -C "$PROJ" add -A; git -C "$PROJ" -c user.name=t -c user.email=t@example.com commit -qm init
  A="$REPO_ROOT/bin/agentic"
  D="$AGENTIC_WORKSPACES/demo/cost"; L="$D/ledger.jsonl"
  mkdir -p "$D"; cp "$REPO_ROOT/tests/fixtures/cost/ledger.jsonl" "$L"
}

ag() { (cd "$PROJ" && bash "$A" "$@" </dev/null); }

@test "cost --json is the project's cost-summary/v1" {
  run ag cost --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -c . > "$BATS_TEST_TMPDIR/s.json"
  [ "$(python3 "$REPO_ROOT/tests/fixtures/cost/validate.py" "$REPO_ROOT/schema/cost-summary.schema.json" "$BATS_TEST_TMPDIR/s.json")" = ok ]
  [ "$(jq -c '[.project, .sessions, .skipped_lines]' <<<"$output")" = '["demo",4,4]' ]
}

@test "filters and grouping reach the summary" {
  run ag cost --json --since 2026-10-03 --until 2026-10-04 --by schedule --kind scheduled --schedule nightly
  [ "$status" -eq 0 ]
  [ "$(jq -c .filter <<<"$output")" = '{"since":"2026-10-03","until":"2026-10-04","task":null,"schedule":"nightly","kind":"scheduled","by":"schedule"}' ]
  [ "$(jq -c '[.groups[] | [.key.schedule, .sessions]]' <<<"$output")" = '[["nightly",2]]' ]
  run ag cost --json --task t1
  [ "$(jq .sessions <<<"$output")" = 1 ]
}

@test "the table keeps estimates and credits apart, marks unpriced tokens and ends with the total" {
  run ag cost
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == GROUP*SESSIONS*"EST. USD"*"CREDITS USD" ]]
  [[ "$output" == *$'\n'"task t1 "*"0.50+?"* ]]
  [[ "$output" == *$'\n'"scheduled t2 nightly "*"-"*"0.03"* ]]
  grep -Eq '^total +4 +1\.2k +128 +2k +100 +2\.75\+\? +0\.03$' <<<"$output"
  [[ "$output" == *"4 ledger lines skipped"* ]]
  [[ "$output" == *"some tokens have no price"* ]]
}

@test "no ledger yet: an empty summary and a table with a zero total" {
  rm "$L"
  run ag cost --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.sessions, .groups]' <<<"$output")" = '[0,[]]' ]
  run ag cost
  grep -Eq '^total +0 +0 +0 +0 +0 +- +-$' <<<"$output"
}

@test "bad options are refused" {
  for a in "--since 2026-13-01" "--since yesterday" "--until 2026-02-30" "--by colour" "--kind other" \
           "--task a/b" "--schedule Nightly" "--bogus"; do
    # shellcheck disable=SC2086
    run ag cost $a
    [ "$status" -ne 0 ] || { echo "accepted: $a"; false; }
  done
}

@test "a symlinked ledger, a symlinked folder or a FIFO is refused, never read" {
  rm "$L"; ln -s /etc/passwd "$L"
  run ag cost --json
  [ "$status" -ne 0 ]; [[ "$output" != *root:* ]]; [[ "$output" == *refused* ]]
  rm "$L"; mkfifo "$L"
  run timeout 5 bash -c "cd '$PROJ' && bash '$A' cost --json </dev/null"
  [ "$status" -ne 0 ]; [ "$status" -ne 124 ]
  rm "$L"; rmdir "$D"; mkdir -p "$BATS_TEST_TMPDIR/other"
  cp "$REPO_ROOT/tests/fixtures/cost/ledger.jsonl" "$BATS_TEST_TMPDIR/other/ledger.jsonl"
  ln -s "$BATS_TEST_TMPDIR/other" "$D"
  run ag cost --json
  [ "$status" -ne 0 ]; [[ "$output" == *refused* ]]
}

@test "an oversized ledger is refused with a hint" {
  AGENTIC_COST_LEDGER_MAX=100 run ag cost
  [ "$status" -ne 0 ]
  [[ "$output" == *"rotate it"* ]]
}

@test "control characters in ledger strings never reach the terminal" {
  # the fixture's last line is cut off: a fresh ledger with one record, so nothing merges into it
  jq -c '.context.task = "t\u001b[2Jx"' <<<"$(sed -n 3p "$REPO_ROOT/tests/fixtures/cost/ledger.jsonl")" > "$L"
  run ag cost
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\e'* ]]
  [[ "$output" == *"task t [2Jx"* ]]
}

@test "help lists cost" {
  run bash "$A" help
  [[ "$output" == *"cost [--since D]"* ]]
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `bats tests/bats/cli-cost.bats`
Expected: FAIL (`agentic cost` is not a command).

- [ ] **Step 3: Write `lib/host/cost.sh`**

```bash
# agentic cost (docs/cost.md): the project's ledger, written by the cost plugin in the project's
# containers, read as untrusted (spec C9) and summed by the image's summary.jq (spec C8).

# cost_dir: the project's ledger folder, mounted at /cost in every container of the project.
cost_dir() { printf '%s/%s/cost\n' "$(realpath -m -- "$AGENTIC_WORKSPACES")" "$(project_name)"; }

# valid_day D: D is a calendar day, YYYY-MM-DD.
valid_day() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$1" +%F >/dev/null 2>&1; }

# cost_ledger: the ledger's content, or nothing when there is none. The agent writes it: a symlink
# on the way, anything but a regular file, or more than AGENTIC_COST_LEDGER_MAX bytes is refused.
cost_ledger() {
  local f max="${AGENTIC_COST_LEDGER_MAX:-67108864}"
  f="$(cost_dir)/ledger.jsonl"
  if [ ! -e "$f" ] && [ ! -L "$f" ] && bind_src_ok "$(cost_dir)"; then return 0; fi
  { bind_src_ok "$f" && [ -f "$f" ]; } || die "$f is not a regular file or goes through a symlink; refused"
  [ "$(stat -c %s -- "$f")" -le "$max" ] || die "$f is over $max bytes; rotate it (move it aside) and run again"
  read_agent_file "$f"
}

# cost_table: a cost-summary/v1 (stdin) as a table. Estimates and credits keep their own columns
# (spec C7); text from the ledger loses its control characters.
cost_table() {
  jq -r '
    def c: tostring | gsub("[[:cntrl:]]"; " ");
    def pad($n): c | if length < $n then . + (" " * ($n - length)) else . + " " end;
    def tok: if . >= 1000000 then "\(. / 100000 | floor / 10)M" elif . >= 1000 then "\(. / 100 | floor / 10)k" else tostring end;
    def usd: if . == null then "-" else (. * 100 | round) as $c
      | "\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)" end;
    def name: .key | [.kind, .task, .schedule, .harness, .session, .model, .day] | map(values)
      | if length == 0 then "-" else join(" ") end;
    def row($name): [($name | pad(36)), (.sessions | pad(9)),
        (.totals | (.input, .output, .cache_read, .cache_write) | tok | pad(9)),
        ((.totals.cost.estimate | usd) + (if .totals.cost | has("unknown") then "+?" else "" end) | pad(10)),
        (.totals.cost["billed-credits"] | usd)] | join("");
    ("GROUP" | pad(36)) + ("SESSIONS" | pad(9)) + ("INPUT" | pad(9)) + ("OUTPUT" | pad(9))
      + ("CACHE R" | pad(9)) + ("CACHE W" | pad(9)) + ("EST. USD" | pad(10)) + "CREDITS USD",
    (.groups[] | row(name)),
    ({sessions, totals} | row("total")),
    (if .skipped_lines > 0 then "\(.skipped_lines) ledger lines skipped: not a cost-record/v1" else empty end),
    (if .totals.cost | has("unknown") then "+? some tokens have no price: agentic cost --by model" else empty end)'
}

cmd_cost() {
  need_config
  local since="" until="" task="" schedule="" kind="" by=context json=0 out
  while [ $# -gt 0 ]; do
    case "$1" in
      --since|--until) optval "$@"; valid_day "$2" || die "$1 takes a day, YYYY-MM-DD"
        if [ "$1" = --since ]; then since="$2"; else until="$2"; fi; shift 2 ;;
      --task) optval "$@"; valid_task_id "$2" || die "--task takes a task id"; task="$2"; shift 2 ;;
      --schedule) optval "$@"; valid_sched_name "$2" || die "--schedule takes a schedule name"; schedule="$2"; shift 2 ;;
      --kind) optval "$@"; [[ "$2" =~ ^(task|scheduled|dev)$ ]] || die "--kind takes task, scheduled or dev"
        kind="$2"; shift 2 ;;
      --by) optval "$@"; [[ "$2" =~ ^(context|task|schedule|session|model|day)$ ]] \
          || die "--by takes context, task, schedule, session, model or day"
        by="$2"; shift 2 ;;
      --json) json=1; shift ;;
      *) die "usage: agentic cost [--since D] [--until D] [--task ID] [--schedule NAME] [--kind K] [--by G] [--json]" ;;
    esac
  done
  out="$(cost_ledger | jq -n -R -L "$AGENTIC_ROOT/image/cost" --arg project "$(project_name)" \
    --arg since "$since" --arg until "$until" --arg task "$task" --arg schedule "$schedule" \
    --arg kind "$kind" --arg by "$by" -f "$AGENTIC_ROOT/image/cost/summary.jq")" || exit 1
  if [ "$json" = 1 ]; then printf '%s\n' "$out"; else cost_table <<<"$out"; fi
}
```

`valid_task_id` accepts `[A-Za-z0-9._-]+`, so `a/b` is refused, as the test expects.

- [ ] **Step 4: Wire it into `bin/agentic`**

After `source "$AGENTIC_ROOT/lib/host/setup.sh"` add:

```bash
# shellcheck source=../lib/host/cost.sh
source "$AGENTIC_ROOT/lib/host/cost.sh"
```

In `usage`, after the `schedule follow` lines add:

```
  cost [--since D] [--until D] [--task ID] [--schedule NAME] [--kind task|scheduled|dev]
       [--by context|task|schedule|session|model|day] [--json]
                                     what the project's sessions spent (docs/cost.md); --json is cost-summary/v1
```

In `main`, add `cost` to the `init|remove|list|...|schedule` list.

- [ ] **Step 5: Run the tests to see them pass**

Run: `bats tests/bats/cli-cost.bats tests/bats/cli-core.bats && shellcheck -x bin/agentic lib/host/cost.sh`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/host/cost.sh tests/bats/cli-cost.bats bin/agentic
git commit -m "feat: agentic cost: the project's cost ledger, read as untrusted, as a table or cost-summary/v1"
```

---

### Task 7: Smoke, docs, and the check by hand

**Files:**
- Create: `tests/fixtures/cost/claude-home/projects/-work/11111111-1111-1111-1111-111111111111.jsonl`, `tests/fixtures/cost/claude-home/projects/-work/11111111-1111-1111-1111-111111111111/subagents/agent-a1.jsonl`, `tests/fixtures/cost/copilot-home/session-state/33333333-3333-3333-3333-333333333333/events.jsonl`, `docs/cost.md`
- Modify: `tests/image/smoke.sh`, `tests/fixtures/smoke-project/.agentic/agentic.yaml`, `README.md`, `docs/backlog.md`, `docs/architecture.md`, `docs/specs/2026-10-15-cost-tracking-design.md` (status line)

**Interfaces:**
- Consumes: everything above, in the built image.

- [ ] **Step 1: Write the synthetic transcripts**

`tests/fixtures/cost/claude-home/projects/-work/11111111-1111-1111-1111-111111111111.jsonl`:

```
{"type":"user","sessionId":"11111111-1111-1111-1111-111111111111","timestamp":"2026-10-15T10:00:00.000Z","uuid":"u0","cwd":"/work","message":{"role":"user","content":"hi"}}
{"type":"assistant","sessionId":"11111111-1111-1111-1111-111111111111","isSidechain":false,"requestId":"req_A","timestamp":"2026-10-15T10:00:01.000Z","uuid":"u1","cwd":"/work","version":"2.1.300","message":{"id":"m_A","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":3000,"output_tokens":100,"output_tokens_details":{"thinking_tokens":10},"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":2000},"service_tier":"standard","speed":"standard"}}}
{"type":"assistant","sessionId":"11111111-1111-1111-1111-111111111111","isSidechain":false,"requestId":"req_A","timestamp":"2026-10-15T10:00:01.500Z","uuid":"u2","cwd":"/work","version":"2.1.300","message":{"id":"m_A","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}],"usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":3000,"output_tokens":100,"output_tokens_details":{"thinking_tokens":10},"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":2000},"service_tier":"standard","speed":"standard"}}}
{"type":"assistant","sessionId":"11111111-1111-1111-1111-111111111111","isSidechain":false,"requestId":"req_B","timestamp":"2026-10-15T10:00:05.000Z","uuid":"u3","cwd":"/work","version":"2.1.300","message":{"id":"m_B","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"y"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":20,"service_tier":"standard","speed":"standard"}}}
```

`.../11111111-1111-1111-1111-111111111111/subagents/agent-a1.jsonl`:

```
{"type":"assistant","sessionId":"11111111-1111-1111-1111-111111111111","isSidechain":true,"agentId":"a1","requestId":"req_S","timestamp":"2026-10-15T10:00:03.000Z","uuid":"s1","cwd":"/work","version":"2.1.300","message":{"id":"m_S","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"z"}],"usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":7,"service_tier":"standard","speed":"standard"}}}
```

`tests/fixtures/cost/copilot-home/session-state/33333333-3333-3333-3333-333333333333/events.jsonl`:

```
{"type":"session.start","data":{"sessionId":"33333333-3333-3333-3333-333333333333","version":1,"producer":"copilot-agent","copilotVersion":"1.0.98","startTime":"2026-10-15T09:00:00.000Z","context":{"cwd":"/work"}},"id":"e1","timestamp":"2026-10-15T09:00:00.000Z","parentId":null}
{"type":"session.usage_checkpoint","data":{"totalNanoAiu":1000,"totalPremiumRequests":0,"modelCacheState":[]},"id":"e2","timestamp":"2026-10-15T09:01:00.000Z","parentId":"e1"}
{"type":"session.shutdown","data":{"shutdownType":"routine","totalPremiumRequests":1,"totalNanoAiu":4008501000,"tokenDetails":{"input":{"tokenCount":38812},"cache_read":{"tokenCount":90112},"cache_write":{"tokenCount":0},"output":{"tokenCount":1927}},"totalApiDurationMs":30410,"sessionStartTime":1789039080660,"modelMetrics":{"claude-sonnet-4.5":{"requests":{"count":4,"cost":1},"usage":{"inputTokens":128924,"outputTokens":1927,"cacheReadTokens":90112,"cacheWriteTokens":0,"reasoningTokens":1572},"totalNanoAiu":4008501000}},"currentModel":"claude-sonnet-4.5"},"id":"e3","timestamp":"2026-10-15T09:05:00.000Z","parentId":"e2"}
```

- [ ] **Step 2: Add the smoke checks**

In `tests/fixtures/smoke-project/.agentic/agentic.yaml`, append to `setup:`:

```yaml
  - add marketplace /opt/agentic/marketplace
  - add plugin cost@agentic
```

In `tests/image/smoke.sh`, after the `check "setup lines: ..."` block, add:

```bash
check "the cost plugin for both harnesses, and the cost ledger folder mounted" '
  claude plugin list 2>/dev/null | grep -q cost@agentic && copilot plugin list 2>/dev/null | grep -q cost \
  && mountpoint -q /cost && test -w /cost'
```

Before `step "a project with several repositories..."`, add:

```bash
step "cost: the pinned ccusage reads real transcript shapes; the snapshot and summary.jq agree"
out="$(docker run --rm --network none -v "$root/tests/fixtures/cost:/fx:ro" -e AGENTIC_COST_FOREGROUND=1 \
  -e CLAUDE_CONFIG_DIR=/fx/claude-home -e COPILOT_HOME=/fx/copilot-home -e AGENTIC_PROJECT=smoke \
  -e AGENTIC_TASK_ID=T1 -e AGENTIC_COST_LEDGER_DIR=/tmp/ledger --entrypoint bash "$IMG" -c '
    mkdir -p /tmp/ledger
    echo "{\"session_id\":\"11111111-1111-1111-1111-111111111111\"}" | /opt/agentic/cost/snapshot turn claude
    echo "{\"sessionId\":\"33333333-3333-3333-3333-333333333333\"}" | /opt/agentic/cost/snapshot end copilot
    jq -n -R -L /opt/agentic/cost --arg project smoke --arg since "" --arg until "" --arg task "" \
      --arg schedule "" --arg kind "" --arg by session -f /opt/agentic/cost/summary.jq < /tmp/ledger/ledger.jsonl')" \
  || fail "cost: the snapshot failed in the image"
[ "$(jq -c '[.sessions, .skipped_lines, .totals.input]' <<<"$out")" = "[2,0,$((1015 + 38812))]" ] \
  || fail "cost: ccusage counts changed (dedup, subagents or the Copilot shutdown): $out"
```

- [ ] **Step 3: Write the docs**

`docs/cost.md`:

````markdown
# Cost tracking

What the agents of a project spend: per task, scheduled run and interactive session, per model and
day. Design: `docs/specs/2026-10-15-cost-tracking-design.md`.

## Install

`agentic init` adds two recommended lines; an existing project adds them with
`agentic add marketplace /opt/agentic/marketplace` and `agentic add plugin cost@agentic`:

```yaml
setup:
  - add marketplace /opt/agentic/marketplace
  - add plugin cost@agentic
```

After `agentic build` and `agentic dev recreate`, every Claude and Copilot session of the project,
interactive, task or scheduled, writes a snapshot after every turn and at its end. Delete the two
lines to stop.

## Read

```
agentic cost [--since D] [--until D] [--task ID] [--schedule NAME] [--kind task|scheduled|dev]
             [--by context|task|schedule|session|model|day] [--json]
```

- **EST. USD** is the list price of the tokens (ccusage, the LiteLLM table, offline). A
  subscription or a negotiated price bills differently; it is an estimate.
- **CREDITS USD** is Copilot AI credits of a session that has not shut down yet (1 credit = $0.01).
- **+?** marks tokens of a model without a price; `--by model` shows which. Add a price in
  `.agentic/cost/ccusage.json` (below).
- A session counts once, with its latest snapshot, in the window of that snapshot's day.

The ledger is `$AGENTIC_WORKSPACES/<project>/cost/ledger.jsonl` on the host (`/cost` in every
container). It survives `clean` and recreation. It only grows: when `agentic cost` refuses it as
too large (64 MiB, `AGENTIC_COST_LEDGER_MAX`), move it aside and start a new one.

## Contracts

| Contract | Where | For |
|---|---|---|
| `cost-record/v1` | `schema/cost-record.schema.json` | one ledger line; what collectors produce |
| collector | `<dir>/collectors/<harness> EVENT`, payload on stdin, records on stdout | adding a harness |
| `cost-summary/v1` | `schema/cost-summary.schema.json`; `image/cost/summary.jq` | `agentic cost --json`, a UI |

A UI or another reader runs `summary.jq` on the ledger (`jq -n -R -L image/cost -f
image/cost/summary.jq --arg project P --arg since "" --arg until "" --arg task "" --arg schedule ""
--arg kind "" --arg by context < ledger.jsonl`) or calls `agentic cost --json`. Adding an optional
field keeps a version; anything else is v2.

## Extend

- **Another harness:** an executable `.agentic/cost/collectors/<harness>` prints `cost-record/v1`
  lines for the session in the hook payload, without `project` and `context`; it may source
  `/opt/agentic/cost/lib.sh` (`payload_session`, `ccusage_session_list`, `to_records`). The
  harness's own hook calls `/opt/agentic/cost/snapshot turn|end <harness>`.
- **Prices:** `.agentic/cost/ccusage.json` replaces the image's (empty) overrides:
  `{"defaults": {"pricingOverrides": {"<model>": {"inputCostPerToken": 0.000003, "outputCostPerToken": 0.000015}}}}`.
- **Diagnostics:** `~/.agentic/cost.log` in the container says why a snapshot was not written.
````

`README.md`: in the feature list near "**Setup lines**", add a bullet `- **Cost tracking**: per task, scheduled run and session, from the recommended cost plugin; \`agentic cost\` ([docs/cost.md](docs/cost.md)).`; in the usage steps, add `agentic cost` next to `agentic status`.

`docs/backlog.md`: add entries, each with `(source: docs/specs/2026-10-15-cost-tracking-design.md §7)`:
- **Live cost in the bridge**: map ACP `usage_update` (Claude: cumulative USD) and `PromptResponse.usage` to events and serve `GET /cost` with `cost-summary/v1`.
- **Cost budgets**: warn or stop a task at a spending limit; needs the live cost.
- **A cost UI**: consumes `cost-summary/v1`.
- **Remote cost ledger**: on a remote host the ledger stays there until a relay or shared store reads it.

`docs/architecture.md`: in the decisions table, add the row `| Cost | A recommended plugin writes cumulative per-session snapshots to one ledger per project; ccusage reads and prices; one summary program for every reader | No per-harness parsing here; versioned contracts let a UI come later |`.

Spec status line: `Status: implemented, <date>.`

- [ ] **Step 4: Run everything**

Run: `make test && make lint && make smoke`
Expected: all pass, ending with `smoke OK`. If `make smoke` fails at "the cost plugin for both harnesses", run `agentic shell` in the smoke project and `copilot plugin list`: Copilot may list it under another name; adjust the `grep` to what it prints, not the plugin.

- [ ] **Step 5: Check by hand what no test can (needs a logged-in harness)**

In a project with the two recommended lines, after `agentic build`:

1. `agentic dev`, start `claude`, ask "say hi", exit. On the host: `agentic cost --by session` shows one `claude` session under `dev`.
2. Same with `copilot`: one `copilot` session. If none: `~/.agentic/cost.log` in the container. If it says `claude` for a Copilot session, `COPILOT_PLUGIN_ROOT` is not set by this Copilot version: print the hook's environment (`env > /tmp/hookenv` as a temporary hook command) and switch the detection in `snapshot` to a variable Copilot does set.
3. `agentic run "say hi"`, wait for idle: `agentic cost --task ID`, with the id `run` printed, shows it as `task ID`.

Write what you saw at the end of `docs/plans/2026-10-15-cost-harness-facts.md` under "Checked by hand".

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/cost tests/image/smoke.sh tests/fixtures/smoke-project/.agentic/agentic.yaml docs README.md
git commit -m "docs: cost tracking: user guide and contracts; smoke covers the plugin and the pinned ccusage"
```
