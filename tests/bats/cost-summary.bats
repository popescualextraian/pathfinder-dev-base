#!/usr/bin/env bats
load helpers

setup() {
  C="$REPO_ROOT/image/cost"
  L="$REPO_ROOT/tests/fixtures/cost/ledger.jsonl"
  V="$REPO_ROOT/tests/fixtures/cost/validate.py"
}

# summary [FILE]: the summary of FILE (default: the fixture ledger), filters from SINCE UNTIL TASK SCHED BY.
summary() {
  jq -n -R -L "$C" --arg project demo --arg since "${SINCE:-}" --arg until "${UNTIL:-}" --arg task "${TASK:-}" \
    --arg schedule "${SCHED:-}" --arg by "${BY:-}" -f "$C/summary.jq" < "${1:-$L}"
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
  for by in context model day; do
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

@test "by model and day" {
  BY=model run summary
  [ "$(jq '.groups | length' <<<"$output")" = 5 ]
  [ "$(jq -c '.groups[] | select(.key.model == "unknown") | [.key.harness, .totals.cost]' <<<"$output")" = '["copilot",{"billed-credits":0.03}]' ]
  BY=day run summary
  [ "$(jq -c '[.groups[].key.day]' <<<"$output")" = '["2026-10-04","2026-10-03","2026-10-02","2026-10-01"]' ]
}

@test "filters: days inclusive, task, schedule; the filter is echoed" {
  SINCE=2026-10-03 run summary
  [ "$(jq .sessions <<<"$output")" = 2 ]
  [ "$(jq -c .filter <<<"$output")" = '{"since":"2026-10-03","until":null,"task":null,"schedule":null,"by":"context"}' ]
  SINCE=2026-10-02 UNTIL=2026-10-02 run summary
  [ "$(jq -c '[.groups[].key.task]' <<<"$output")" = '["t1"]' ]
  TASK=t1 run summary;       [ "$(jq .sessions <<<"$output")" = 1 ]
  SCHED=nightly run summary; [ "$(jq -c '[.sessions, [.groups[].key.task]]' <<<"$output")" = '[2,["t3","t2"]]' ]
}

@test "an empty or missing ledger gives an empty summary" {
  : > "$BATS_TEST_TMPDIR/empty"
  run summary "$BATS_TEST_TMPDIR/empty"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.sessions, .groups, .totals.cost, .skipped_lines]' <<<"$output")" = '[0,[],{},0]' ]
}
