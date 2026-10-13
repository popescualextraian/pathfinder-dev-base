#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  S="$REPO_ROOT/image/start.d/45-hooks.sh"
  export AGENTIC_GATE=1
}

@test "with the gate off the step does nothing" {
  AGENTIC_GATE=0 run bash "$S"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude/settings.json" ]
}

@test "claude gets the managed hooks with the harness named, other settings and hooks stay" {
  mkdir -p "$HOME/.claude"
  echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-own.sh"}]}]}}' > "$HOME/.claude/settings.json"
  run bash "$S"
  [ "$status" -eq 0 ]
  f="$HOME/.claude/settings.json"
  [ "$(jq -r .model "$f")" = opus ]
  [ "$(jq -r .skipDangerousModePermissionPrompt "$f")" = true ]
  [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$f")" = "bash $AGENTIC_DIR/task/hook.sh claude pretooluse" ]
  [ "$(jq -r '[.hooks.Stop[].hooks[].command] | join(",")' "$f")" = "my-own.sh,bash $AGENTIC_DIR/task/hook.sh claude stop" ]
  [ "$(jq -r '.hooks | keys | join(",")' "$f")" = PostToolUse,PreToolUse,SessionEnd,SessionStart,Stop,UserPromptSubmit ]
}

@test "running twice installs each hook once" {
  bash "$S"; bash "$S"
  [ "$(jq '[.hooks[][].hooks[]] | length' "$HOME/.claude/settings.json")" -eq 6 ]
}

@test "the step follows CLAUDE_CONFIG_DIR and COPILOT_HOME" {
  CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cc" COPILOT_HOME="$BATS_TEST_TMPDIR/cp" bash "$S"
  [ -f "$BATS_TEST_TMPDIR/cc/settings.json" ]
  [ -f "$BATS_TEST_TMPDIR/cp/hooks/agentic.json" ]
}

@test "copilot gets camelCase hooks and the task paragraph as a managed block" {
  mkdir -p "$HOME/.copilot"
  printf 'My own rule.\n' > "$HOME/.copilot/copilot-instructions.md"
  bash "$S"; bash "$S"
  f="$HOME/.copilot/hooks/agentic.json"
  [ "$(jq -r .version "$f")" = 1 ]
  [ "$(jq -r '.hooks.preToolUse[0].bash' "$f")" = "bash $AGENTIC_DIR/task/hook.sh copilot pretooluse" ]
  [ "$(jq -r '.hooks | keys | join(",")' "$f")" = agentStop,postToolUse,preToolUse,sessionStart,userPromptSubmitted ]
  i="$HOME/.copilot/copilot-instructions.md"
  grep -q 'My own rule.' "$i"
  [ "$(grep -c 'agentic-ask' "$i")" -ge 1 ]
  [ "$(grep -c '<!-- agentic:task -->' "$i")" -eq 2 ]
}

@test "check mode reports missing hooks and passes once installed" {
  run bash "$S" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"task hooks are not installed"* ]]
  bash "$S"
  run bash "$S" --check
  [ "$status" -eq 0 ]
}

@test "an unreadable settings.json stops the start: a task must not run unguarded" {
  mkdir -p "$HOME/.claude"; echo '{' > "$HOME/.claude/settings.json"
  run bash "$S"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not valid JSON"* ]]
}
