#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  S="$REPO_ROOT/image/cost/snapshot"
  # an image cost dir with stub collectors
  export AGENTIC_COST_DIR="$BATS_TEST_TMPDIR/cost"
  mkdir -p "$AGENTIC_COST_DIR/collectors"
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

@test "the collector gets the event and the harness as arguments and the payload on stdin" {
  collector "$AGENTIC_COST_DIR/collectors" claude "echo \"\$1 \$2\" > '$BATS_TEST_TMPDIR/event'; cat > '$BATS_TEST_TMPDIR/payload'"
  "$S" end <<<'{"session_id":"abc"}'
  [ "$(cat "$BATS_TEST_TMPDIR/event")" = "end claude" ]
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

@test "a harness with no collector of its own gets the generic ccusage collector" {
  collector "$AGENTIC_COST_DIR" ccusage-collector "jq -c --arg h \"\$2\" '.harness = \$h' <<<'$REC'"
  "$S" turn codex </dev/null
  [ "$(jq -r .harness "$LEDGER")" = codex ]
}

@test "output that is not JSON is not written, and is logged" {
  collector "$AGENTIC_COST_DIR/collectors" claude "echo 'not json'"
  run "$S" turn </dev/null
  [ "$status" -eq 0 ]
  [ ! -s "$LEDGER" ]
  grep -q 'not JSON' "$AGENTIC_STATE/cost.log"
}

@test "no ledger folder, no collector at all, a failing or a slow collector: nothing written, exit 0" {
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
