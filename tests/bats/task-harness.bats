#!/usr/bin/env bats
load helpers
bats_require_minimum_version 1.5.0

setup() {
  make_tmp_home
  make_agentic_dir
  source "$REPO_ROOT/image/lib/common.sh"
  source "$REPO_ROOT/image/task/lib/harness.sh"
  F="$REPO_ROOT/tests/fixtures/hooks"
}

@test "payload_command reads a toolArgs JSON string; camelCase ids and tool names work" {
  p='{"sessionId":"S9","toolName":"bash","toolArgs":"{\"command\":\"ls -l\"}"}'
  [ "$(payload_command "$p")" = "ls -l" ]
  [ "$(payload_session "$p")" = S9 ]
  [ "$(payload_tool "$p")" = bash ]
}

@test "payload fields from both harnesses" {
  p="$(cat "$F/claude/pretooluse-bash.json")"
  [ "$(payload_session "$p")" = 00000000-0000-0000-0000-000000000001 ]
  [ "$(payload_tool "$p")" = Bash ]
  [ "$(payload_command "$p")" = "git push origin HEAD" ]
  p="$(cat "$F/copilot/pretooluse-bash.json")"
  [ "$(payload_tool "$p")" = bash ]
  [ "$(payload_command "$p")" = "gh pr merge 12" ]
  [ -z "$(payload_command 'not json')" ]
}

@test "tool classes" {
  is_shell_tool Bash; is_shell_tool bash
  run is_shell_tool Edit; [ "$status" -ne 0 ]
  is_chooser_tool AskUserQuestion; is_chooser_tool ExitPlanMode; is_chooser_tool ask_user; is_chooser_tool exit_plan_mode
  run is_chooser_tool Bash; [ "$status" -ne 0 ]
}

@test "copilot paths follow COPILOT_HOME" {
  COPILOT_HOME=/x/cp
  [ "$(copilot_hooks_file)" = /x/cp/hooks/agentic.json ]
  [ "$(copilot_instructions_file)" = /x/cp/copilot-instructions.md ]
}


@test "hook events: claude PascalCase, copilot camelCase as confirmed under --acp" {
  run harness_hook_events claude
  [ "$output" = $'SessionStart sessionstart\nUserPromptSubmit userpromptsubmit\nPreToolUse pretooluse\nPostToolUse posttooluse\nStop stop\nSessionEnd sessionend' ]
  run harness_hook_events copilot
  [ "$output" = $'sessionStart sessionstart\nuserPromptSubmitted userpromptsubmit\npreToolUse pretooluse\npostToolUse posttooluse\nagentStop stop' ]
}

@test "claude refusals go to stderr with exit code 2" {
  run --separate-stderr bash -c 'source "$1"; source "$2"; harness_block claude "no push"; echo "rc=$?"' _ \
    "$AGENTIC_DIR/lib/common.sh" "$AGENTIC_DIR/task/lib/harness.sh"
  [ "$output" = "rc=2" ]
  [ "$stderr" = "no push" ]
}

@test "copilot refusals are a JSON deny decision on stdout with exit code 0" {
  run --separate-stderr bash -c 'source "$1"; source "$2"; harness_block copilot "no \"push\""; echo "rc=$?"' _ \
    "$AGENTIC_DIR/lib/common.sh" "$AGENTIC_DIR/task/lib/harness.sh"
  [ "$(head -1 <<<"$output" | jq -r .permissionDecision)" = deny ]
  [ "$(head -1 <<<"$output" | jq -r .permissionDecisionReason)" = 'no "push"' ]
  [ "$(tail -1 <<<"$output")" = "rc=0" ]
}

@test "takeover resumes the session interactively" {
  harness_resume_argv claude 1234; [ "${ARGV[*]}" = "claude --dangerously-skip-permissions --resume 1234" ]
  harness_resume_argv copilot 1234; [ "${ARGV[*]}" = "copilot --allow-all --resume=1234" ]
}
