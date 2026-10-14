#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/mount" AGENTIC_WORK="$BATS_TEST_TMPDIR/work"
  export AGENTIC_PLUGINS_DIR="$BATS_TEST_TMPDIR/claude-plugins"
  mkdir -p "$AGENTIC_CONFIG_MOUNT" "$AGENTIC_WORK" "$AGENTIC_PLUGINS_DIR" "$BATS_TEST_TMPDIR/bin"
  echo '{"plugins":{"superpowers@claude-plugins-official":[{}]}}' > "$AGENTIC_PLUGINS_DIR/installed_plugins.json"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" LOG="$BATS_TEST_TMPDIR/calls.log"
  S="$REPO_ROOT/image/start.d"
  unset DISPLAY WAYLAND_DISPLAY
  export AGENTIC_X11_DIR="$BATS_TEST_TMPDIR/x11" AGENTIC_X_TMP="$BATS_TEST_TMPDIR/xtmp" AGENTIC_X11_WAIT=1
  mkdir -p "$AGENTIC_X11_DIR" "$AGENTIC_X_TMP"
}

stub() { printf '#!/bin/sh\necho "%s $*" >> "$LOG"\n%s\n' "$1" "${2:-exit 0}" > "$BATS_TEST_TMPDIR/bin/$1"; chmod +x "$BATS_TEST_TMPDIR/bin/$1"; }
config() { printf '%s\n' "$1" > "$AGENTIC_CONFIG_MOUNT/agentic.yaml"; bash "$S/10-validate.sh" >/dev/null; }

# --- 25-harness: Claude credentials
@test "25 moves an OAuth token found in ANTHROPIC_API_KEY to CLAUDE_CODE_OAUTH_TOKEN, without writing it" {
  config $'version: 2\nproject: demo'
  ANTHROPIC_API_KEY=sk-ant-oat01-supersecret run bash "$S/25-harness.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"rename ANTHROPIC_API_KEY to CLAUDE_CODE_OAUTH_TOKEN"* ]]
  run grep -q supersecret "$AGENTIC_STATE/env"
  [ "$status" -ne 0 ]
  run env -u CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY=sk-ant-oat01-supersecret bash -c 'source "$AGENTIC_STATE/env"; echo "oauth=$CLAUDE_CODE_OAUTH_TOKEN api=${ANTHROPIC_API_KEY-unset}"'
  [ "$output" = "oauth=sk-ant-oat01-supersecret api=unset" ]
}

@test "25's env lines survive being sourced again under set -u, as the entrypoint does after every step" {
  config $'version: 2\nproject: demo'
  ANTHROPIC_API_KEY=sk-ant-oat01-supersecret bash "$S/25-harness.sh" || true
  run env -u CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY=sk-ant-oat01-supersecret bash -c 'set -u; source "$AGENTIC_STATE/env"; source "$AGENTIC_STATE/env"; echo "oauth=$CLAUDE_CODE_OAUTH_TOKEN api=${ANTHROPIC_API_KEY-unset}"'
  [ "$status" -eq 0 ]
  [ "$output" = "oauth=sk-ant-oat01-supersecret api=unset" ]
}

@test "25 drops ANTHROPIC_API_KEY when CLAUDE_CODE_OAUTH_TOKEN is set too" {
  config $'version: 2\nproject: demo'
  ANTHROPIC_API_KEY=sk-ant-api03-key CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-tok run bash "$S/25-harness.sh"
  [ "$status" -eq 0 ]
  run env ANTHROPIC_API_KEY=sk-ant-api03-key CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-tok bash -c 'source "$AGENTIC_STATE/env"; echo "oauth=$CLAUDE_CODE_OAUTH_TOKEN api=${ANTHROPIC_API_KEY-unset}"'
  [ "$output" = "oauth=sk-ant-oat01-tok api=unset" ]
}

@test "25 leaves a real API key alone" {
  config $'version: 2\nproject: demo'
  ANTHROPIC_API_KEY=sk-ant-api03-key run bash "$S/25-harness.sh"
  [ "$status" -eq 0 ]
  run grep -q ANTHROPIC_API_KEY "$AGENTIC_STATE/env"
  [ "$status" -ne 0 ]
}

@test "25 --check warns about an OAuth token in ANTHROPIC_API_KEY and writes nothing" {
  config $'version: 2\nproject: demo'
  ANTHROPIC_API_KEY=sk-ant-oat01-supersecret run bash "$S/25-harness.sh" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"rename ANTHROPIC_API_KEY to CLAUDE_CODE_OAUTH_TOKEN"* ]]
  run grep -q CLAUDE_CODE_OAUTH_TOKEN "$AGENTIC_STATE/env"
  [ "$status" -ne 0 ]
}

# --- 25-harness
@test "25 with empty models sets nothing" {
  config $'version: 2\nproject: demo'
  run bash "$S/25-harness.sh"
  [ "$status" -eq 0 ]
  run grep -q ANTHROPIC_MODEL "$AGENTIC_STATE/env"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/.copilot/config.json" ]
}

# --- 90-project-hook
@test "90 runs the on-start hook in /work with the environment" {
  mkdir -p "$AGENTIC_CONFIG_MOUNT/hooks"
  printf 'pwd > "$HOME/hook-pwd"; echo "$MY_VAR" > "$HOME/hook-var"\n' > "$AGENTIC_CONFIG_MOUNT/hooks/on-start.sh"
  config $'version: 2\nproject: demo'
  MY_VAR=hello run bash "$S/90-project-hook.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/hook-pwd")" = "$AGENTIC_WORK" ]
  [ "$(cat "$HOME/hook-var")" = hello ]
}

@test "90 failure warns, or stops the start when the hook is required" {
  mkdir -p "$AGENTIC_CONFIG_MOUNT/hooks"; echo 'exit 3' > "$AGENTIC_CONFIG_MOUNT/hooks/on-start.sh"
  config $'version: 2\nproject: demo'
  run bash "$S/90-project-hook.sh"
  [ "$status" -eq 2 ]
  config $'version: 2\nproject: demo\nhooks:\n  on_start_required: true'
  run bash "$S/90-project-hook.sh"
  [ "$status" -eq 1 ]
}

@test "90 without a hook does nothing" {
  config $'version: 2\nproject: demo'
  run bash "$S/90-project-hook.sh"
  [ "$status" -eq 0 ]
}
