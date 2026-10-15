#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  export AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/cfg"
  K="$REPO_ROOT/image/cost/ccusage-collector"
  F="$REPO_ROOT/tests/fixtures/cost"
  # a ccusage stand-in: logs its arguments, prints the recorded list of claude or copilot (or $STUB_OUT)
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/ccusage" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$BATS_TEST_TMPDIR/ccusage.args"
if [ "\$1" = --version ]; then echo "ccusage 20.0.32"; exit 0; fi
f="$F/ccusage-claude-session.json"; [ "\$1" != copilot ] || f="$F/ccusage-copilot-session.json"
cat "\${STUB_OUT:-\$f}"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/ccusage"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# valid OUTPUT: OUTPUT, completed as the snapshot does, is a valid record.
valid() {
  jq -e -L "$REPO_ROOT/image/cost" 'include "record"; . + {project: "p", context: {kind: "dev"}} | valid_record' <<<"$1" >/dev/null
}

@test "claude: the payload's session, per model, with ccusage's deduplicated totals" {
  run "$K" turn claude <<<'{"session_id":"11111111-1111-1111-1111-111111111111","transcript_path":"/x"}'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  valid "$output"
  [ "$(jq -c '[.harness, .session, .totals.input, .totals.output, .totals.cache_read, .totals.cache_write]' <<<"$output")" \
    = '["claude","11111111-1111-1111-1111-111111111111",1015,127,3000,2000]' ]
  [ "$(jq -c '[.models[] | [.model, .cost_source]]' <<<"$output")" = '[["claude-sonnet-4-5","estimate"],["claude-opus-5-5","estimate"]]' ]
  jq -e '(.totals.cost.estimate - 0.01346 | fabs) < 1e-9 and .producer == {collector: "ccusage", ccusage: "20.0.32"}' <<<"$output"
  grep -qx "claude session --json --offline" "$BATS_TEST_TMPDIR/ccusage.args"
}

@test "copilot: a camelCase payload; a shut-down session is a token estimate" {
  run "$K" end copilot <<<'{"sessionId":"33333333-3333-3333-3333-333333333333"}'
  [ "$status" -eq 0 ]
  valid "$output"
  [ "$(jq -c '[.harness, .totals.input, .totals.cost]' <<<"$output")" = '["copilot",38812,{"estimate":0.1723746}]' ]
}

@test "an open Copilot session (credits, no tokens yet) is billed-credits, not an estimate" {
  run "$K" turn copilot <<<'{"session_id":"44444444-4444-4444-4444-444444444444"}'
  valid "$output"
  [ "$(jq -c '[.models[0].cost_source, .totals.cost]' <<<"$output")" = '["billed-credits",{"billed-credits":0.03196233}]' ]
}

@test "any harness ccusage reads: the name is passed through" {
  run "$K" turn codex <<<'{"session_id":"11111111-1111-1111-1111-111111111111"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r .harness <<<"$output")" = codex ]
  grep -qx "codex session --json --offline" "$BATS_TEST_TMPDIR/ccusage.args"
}

@test "tokens without a price are unknown, beside the priced ones" {
  jq '.sessions[0].modelBreakdowns[1].cost = 0' "$F/ccusage-claude-session.json" > "$BATS_TEST_TMPDIR/out.json"
  STUB_OUT="$BATS_TEST_TMPDIR/out.json" run "$K" turn claude <<<'{"session_id":"11111111-1111-1111-1111-111111111111"}'
  valid "$output"
  [ "$(jq -c '[.models[1].cost_source, (.totals.cost | keys)]' <<<"$output")" = '["unknown",["estimate","unknown"]]' ]
}

@test "no session id, an unknown session, or a failing ccusage: no record, exit 0 for the first two" {
  run "$K" turn claude <<<'{}'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run "$K" turn claude <<<'not json'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run "$K" turn claude <<<'{"session_id":"nope"}'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  printf '#!/bin/sh\nexit 2\n' > "$BATS_TEST_TMPDIR/bin/ccusage"
  run "$K" turn claude <<<'{"session_id":"11111111-1111-1111-1111-111111111111"}'
  [ "$status" -ne 0 ]; [ -z "$output" ]
}

@test "the project's pricing overrides are passed when it has them" {
  mkdir -p "$AGENTIC_CONFIG_MOUNT/cost"; echo '{}' > "$AGENTIC_CONFIG_MOUNT/cost/ccusage.json"
  "$K" turn copilot <<<'{"sessionId":"33333333-3333-3333-3333-333333333333"}' >/dev/null
  grep -qx "copilot session --json --offline --config $AGENTIC_CONFIG_MOUNT/cost/ccusage.json" "$BATS_TEST_TMPDIR/ccusage.args"
}
