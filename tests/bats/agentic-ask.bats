#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  ASK="$REPO_ROOT/image/bin/agentic-ask"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # curl stand-in: logs the arguments and the body, answers with $ASK_BODY and $ASK_CODE
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/curl.args"
for a in "$@"; do case "$a" in @-) ;; @*) cat "${a#@}" > "$BATS_TEST_TMPDIR/curl.header" ;; esac; done
cat > "$BATS_TEST_TMPDIR/curl.body"
default='{"id":"Q3"}'
printf '%s\n%s' "${ASK_BODY:-$default}" "${ASK_CODE:-201}"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" AGENTIC_BRIDGE_URL=http://127.0.0.1:8765 AGENTIC_AGENT_TOKEN=agent-token-0123456789
}

@test "asks with options and a recommendation, and tells the agent what to do next" {
  run bash "$ASK" "Which DB?" --option pg --option sqlite --recommend pg
  [ "$status" -eq 0 ]
  [ "$output" = "Recorded Q3. Continue with work that does not depend on it; when nothing else can move, end your turn." ]
  [ "$(jq -c . "$BATS_TEST_TMPDIR/curl.body")" = '{"text":"Which DB?","options":["pg","sqlite"],"recommend":"pg"}' ]
  grep -qx 'http://127.0.0.1:8765/ask' "$BATS_TEST_TMPDIR/curl.args"
  grep -q 'Authorization: Bearer agent-token-0123456789' "$BATS_TEST_TMPDIR/curl.header"
  run grep -q agent-token-0123456789 "$BATS_TEST_TMPDIR/curl.args"
  [ "$status" -ne 0 ]
}

@test "the question text keeps quotes, newlines and dollars" {
  bash "$ASK" $'Use "pg"\nor $DB?'
  [ "$(jq -r .text "$BATS_TEST_TMPDIR/curl.body")" = $'Use "pg"\nor $DB?' ]
  [ "$(jq -c .options "$BATS_TEST_TMPDIR/curl.body")" = '[]' ]
  [ "$(jq -c .recommend "$BATS_TEST_TMPDIR/curl.body")" = null ]
}

@test "outside a task it says so" {
  unset AGENTIC_BRIDGE_URL
  run bash "$ASK" "x"
  [ "$status" -eq 1 ]
  [ "$output" = "agentic-ask: agentic-ask works only inside a task" ]
}

@test "usage errors and refusals are clear" {
  run bash "$ASK"
  [ "$status" -eq 1 ]; [[ "$output" == *usage* ]]
  run bash "$ASK" a b
  [ "$status" -eq 1 ]; [[ "$output" == *"one question at a time"* ]]
  ASK_BODY='{"error":{"code":"conflict","message":"task is stopped"}}' ASK_CODE=409 run bash "$ASK" "x"
  [ "$status" -eq 1 ]; [ "$output" = "agentic-ask: task is stopped" ]
}
