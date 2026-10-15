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
  run ag cost --json --since 2026-10-03 --until 2026-10-04 --schedule nightly
  [ "$status" -eq 0 ]
  [ "$(jq -c .filter <<<"$output")" = '{"since":"2026-10-03","until":"2026-10-04","task":null,"schedule":"nightly","by":"context"}' ]
  [ "$(jq -c '[.groups[].key.task]' <<<"$output")" = '["t3","t2"]' ]
  run ag cost --json --by day
  [ "$(jq '.groups | length' <<<"$output")" = 4 ]
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
  for a in "--since 2026-13-01" "--since yesterday" "--until 2026-02-30" "--by colour" "--by session" \
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

@test "the read is capped even when the ledger grows after the size check" {
  # a stat that reports a small file: the cap must hold in the read itself
  printf '#!/bin/sh\necho 1\n' > "$BATS_TEST_TMPDIR/bin/stat"; chmod +x "$BATS_TEST_TMPDIR/bin/stat"
  AGENTIC_COST_LEDGER_MAX=934 run ag cost --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.sessions, .skipped_lines]' <<<"$output")" = '[1,1]' ]
}

@test "a ledger that cannot be read safely is refused, not summarised as empty" {
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/dd"; chmod +x "$BATS_TEST_TMPDIR/bin/dd"
  run ag cost --json
  [ "$status" -ne 0 ]
  [[ "$output" == *refused* ]]
  [[ "$output" != *'"schema"'* ]]
}

@test "help lists cost" {
  run bash "$A" help
  [[ "$output" == *"cost [--since D]"* ]]
}
