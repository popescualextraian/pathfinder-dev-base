#!/usr/bin/env bats
load helpers
bats_require_minimum_version 1.5.0

setup() {
  make_tmp_home
  make_agentic_dir
  make_task_dir
  H="$AGENTIC_DIR/task/hook.sh"
  F="$REPO_ROOT/tests/fixtures/hooks"
}

@test "claude: a blocked push exits 2 with the reason on stderr" {
  run --separate-stderr bash "$H" claude pretooluse < "$F/claude/pretooluse-bash.json"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"agentic gate: git push is not in allowed_actions"* ]]
}

@test "copilot: a blocked merge is a deny decision on stdout with exit 0" {
  run --separate-stderr bash "$H" copilot pretooluse < "$F/copilot/pretooluse-bash.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .permissionDecision <<<"$output")" = deny ]
  [[ "$(jq -r .permissionDecisionReason <<<"$output")" == *"merging is never allowed"* ]]
}

@test "a grant in state.json lets the push through" {
  make_task_dir push
  run bash "$H" claude pretooluse < "$F/claude/pretooluse-bash.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a chooser is blocked by the ask-guard" {
  run --separate-stderr bash "$H" claude pretooluse < "$F/claude/pretooluse-ask.json"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Use agentic-ask"* ]]
}

@test "copilot: a chooser is a deny decision on stdout with exit 0" {
  run --separate-stderr bash "$H" copilot pretooluse < "$F/copilot/pretooluse-ask.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .permissionDecision <<<"$output")" = deny ]
  [[ "$(jq -r .permissionDecisionReason <<<"$output")" == *"Use agentic-ask"* ]]
}

@test "a guard that fails another way blocks: a task must not run unguarded" {
  mkdir -p "$BATS_TEST_TMPDIR/opt2"; cp -rL "$AGENTIC_DIR"/. "$BATS_TEST_TMPDIR/opt2/"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$BATS_TEST_TMPDIR/opt2/task/gate.sh"
  AGENTIC_DIR="$BATS_TEST_TMPDIR/opt2" run --separate-stderr bash "$BATS_TEST_TMPDIR/opt2/task/hook.sh" claude pretooluse < "$F/claude/pretooluse-bash.json"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"agentic gate failed (rc 7)"* ]]
}

@test "a block is reported to the bridge with the agent token" {
  install_cmd_stub curl
  AGENTIC_BRIDGE_URL=http://127.0.0.1:8765 AGENTIC_AGENT_TOKEN=agent-tok run bash "$H" claude pretooluse < "$F/claude/pretooluse-bash.json"
  [ "$status" -eq 2 ]
  grep -q -- 'http://127.0.0.1:8765/gate' "$BATS_TEST_TMPDIR/curl.log"
  grep -q -- 'Authorization: Bearer agent-tok' "$BATS_TEST_TMPDIR/curl.log"
  grep -q '"rule":"gate"' "$BATS_TEST_TMPDIR/curl.log"
  grep -q '"command":"git push origin HEAD"' "$BATS_TEST_TMPDIR/curl.log"
}

@test "without a bridge nothing is reported and the block still holds" {
  install_cmd_stub curl
  run bash "$H" claude pretooluse < "$F/claude/pretooluse-bash.json"
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/curl.log" ]
}

@test "a hooks.d pretooluse script can block, others only run" {
  mkdir -p "$BATS_TEST_TMPDIR/cfg/hooks.d/pretooluse" "$BATS_TEST_TMPDIR/cfg/hooks.d/stop"
  printf '#!/usr/bin/env bash\necho "no deploy wrapper" >&2\nexit 2\n' > "$BATS_TEST_TMPDIR/cfg/hooks.d/pretooluse/10-x.sh"
  printf '#!/usr/bin/env bash\ncat > "%s/stop-ran"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/cfg/hooks.d/stop/10-y.sh"
  jq -c '.tool_input.command = "ls"' "$F/claude/pretooluse-bash.json" > "$BATS_TEST_TMPDIR/ls.json"
  AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/cfg" run --separate-stderr bash "$H" claude pretooluse < "$BATS_TEST_TMPDIR/ls.json"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no deploy wrapper"* ]]
  AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/cfg" run bash "$H" claude stop < "$F/claude/stop.json"
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/stop-ran" ]
}

@test "other events never fail, even when an extension fails" {
  mkdir -p "$BATS_TEST_TMPDIR/cfg/hooks.d/stop"
  printf '#!/usr/bin/env bash\nexit 9\n' > "$BATS_TEST_TMPDIR/cfg/hooks.d/stop/10-bad.sh"
  AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/cfg" run bash "$H" claude stop < "$F/claude/stop.json"
  [ "$status" -eq 0 ]
}
