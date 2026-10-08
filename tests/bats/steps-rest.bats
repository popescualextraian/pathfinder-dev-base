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

# --- 50-plugins
# --- 25-harness: Claude credentials
@test "25 moves an OAuth token found in ANTHROPIC_API_KEY to CLAUDE_CODE_OAUTH_TOKEN, without writing it" {
  config $'version: 1\nproject: demo'
  ANTHROPIC_API_KEY=sk-ant-oat01-supersecret run bash "$S/25-harness.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"rename ANTHROPIC_API_KEY to CLAUDE_CODE_OAUTH_TOKEN"* ]]
  run grep -q supersecret "$AGENTIC_STATE/env"
  [ "$status" -ne 0 ]
  run env -u CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY=sk-ant-oat01-supersecret bash -c 'source "$AGENTIC_STATE/env"; echo "oauth=$CLAUDE_CODE_OAUTH_TOKEN api=${ANTHROPIC_API_KEY-unset}"'
  [ "$output" = "oauth=sk-ant-oat01-supersecret api=unset" ]
}

@test "25's env lines survive being sourced again under set -u, as the entrypoint does after every step" {
  config $'version: 1\nproject: demo'
  ANTHROPIC_API_KEY=sk-ant-oat01-supersecret bash "$S/25-harness.sh" || true
  run env -u CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY=sk-ant-oat01-supersecret bash -c 'set -u; source "$AGENTIC_STATE/env"; source "$AGENTIC_STATE/env"; echo "oauth=$CLAUDE_CODE_OAUTH_TOKEN api=${ANTHROPIC_API_KEY-unset}"'
  [ "$status" -eq 0 ]
  [ "$output" = "oauth=sk-ant-oat01-supersecret api=unset" ]
}

@test "25 drops ANTHROPIC_API_KEY when CLAUDE_CODE_OAUTH_TOKEN is set too" {
  config $'version: 1\nproject: demo'
  ANTHROPIC_API_KEY=sk-ant-api03-key CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-tok run bash "$S/25-harness.sh"
  [ "$status" -eq 0 ]
  run env ANTHROPIC_API_KEY=sk-ant-api03-key CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-tok bash -c 'source "$AGENTIC_STATE/env"; echo "oauth=$CLAUDE_CODE_OAUTH_TOKEN api=${ANTHROPIC_API_KEY-unset}"'
  [ "$output" = "oauth=sk-ant-oat01-tok api=unset" ]
}

@test "25 leaves a real API key alone" {
  config $'version: 1\nproject: demo'
  ANTHROPIC_API_KEY=sk-ant-api03-key run bash "$S/25-harness.sh"
  [ "$status" -eq 0 ]
  run grep -q ANTHROPIC_API_KEY "$AGENTIC_STATE/env"
  [ "$status" -ne 0 ]
}

@test "25 --check warns about an OAuth token in ANTHROPIC_API_KEY and writes nothing" {
  config $'version: 1\nproject: demo'
  ANTHROPIC_API_KEY=sk-ant-oat01-supersecret run bash "$S/25-harness.sh" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"rename ANTHROPIC_API_KEY to CLAUDE_CODE_OAUTH_TOKEN"* ]]
  run grep -q CLAUDE_CODE_OAUTH_TOKEN "$AGENTIC_STATE/env"
  [ "$status" -ne 0 ]
}

# --- 25-harness
@test "25 sets the Claude model as ANTHROPIC_MODEL and the Copilot model in its config" {
  echo '{"trusted_folders":["/work"]}' > "$BATS_TEST_TMPDIR/cp.json"; mkdir -p "$HOME/.copilot"
  cp "$BATS_TEST_TMPDIR/cp.json" "$HOME/.copilot/config.json"
  config $'version: 1\nproject: demo\nharness:\n  claude: {model: claude-opus-x}\n  copilot: {model: gpt-x}'
  run bash "$S/25-harness.sh"
  [ "$status" -eq 0 ]
  grep -qx 'export ANTHROPIC_MODEL=claude-opus-x' "$AGENTIC_STATE/env"
  [ "$(jq -r .model "$HOME/.copilot/config.json")" = gpt-x ]
  [ "$(jq -r '.trusted_folders[0]' "$HOME/.copilot/config.json")" = /work ]
}

@test "25 with empty models sets nothing" {
  config $'version: 1\nproject: demo'
  run bash "$S/25-harness.sh"
  [ "$status" -eq 0 ]
  run grep -q ANTHROPIC_MODEL "$AGENTIC_STATE/env"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/.copilot/config.json" ]
}

@test "25 --check reports model drift and changes nothing" {
  config $'version: 1\nproject: demo\nharness:\n  claude: {model: claude-opus-x}\n  copilot: {model: gpt-x}'
  ANTHROPIC_MODEL=other run bash "$S/25-harness.sh" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"ANTHROPIC_MODEL"* ]]
  [[ "$output" == *"Copilot model"* ]]
  [ ! -e "$HOME/.copilot/config.json" ]
  bash "$S/25-harness.sh"
  ANTHROPIC_MODEL=claude-opus-x run bash "$S/25-harness.sh" --check
  [ "$status" -eq 0 ]
}

@test "50 links the baked plugins and enables the configured ones" {
  stub copilot
  config $'version: 1\nproject: demo'
  run bash "$S/50-plugins.sh"
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.claude/plugins")" = "$AGENTIC_PLUGINS_DIR" ]
  [ "$(jq -r '.enabledPlugins["superpowers@claude-plugins-official"]' "$HOME/.claude/settings.json")" = true ]
}

@test "50 warns about a configured plugin the image does not have" {
  stub copilot
  config $'version: 1\nproject: demo\nplugins:\n  claude: [missing@m]'
  run bash "$S/50-plugins.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"plugin missing@m is not in the image"* ]]
}

@test "50 leaves a real plugins directory alone" {
  stub copilot
  mkdir -p "$HOME/.claude/plugins"
  config $'version: 1\nproject: demo'
  run bash "$S/50-plugins.sh"
  [ "$status" -eq 2 ]
  [ -d "$HOME/.claude/plugins" ] && [ ! -L "$HOME/.claude/plugins" ]
}

@test "50 installs missing Copilot plugins and survives a failure" {
  stub copilot 'case "$2" in list) echo "have@m";; install) [ "$3" = "bad@m" ] && exit 1;; esac; exit 0'
  config $'version: 1\nproject: demo\nplugins:\n  copilot: [have@m, new@m, bad@m]'
  run bash "$S/50-plugins.sh"
  [ "$status" -eq 2 ]
  grep -q "copilot plugin install new@m" "$LOG"
  run grep -q "copilot plugin install have@m" "$LOG"
  [ "$status" -ne 0 ]
}

# --- 60-skills
@test "60 copies base and project skills into both harnesses, project wins" {
  config $'version: 1\nproject: demo'
  mkdir -p "$AGENTIC_CONFIG_MOUNT/skills/agentic-setup" "$AGENTIC_CONFIG_MOUNT/skills/mine"
  echo project > "$AGENTIC_CONFIG_MOUNT/skills/agentic-setup/SKILL.md"
  echo mine > "$AGENTIC_CONFIG_MOUNT/skills/mine/SKILL.md"
  run bash "$S/60-skills.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.claude/skills/agentic-setup/SKILL.md")" = project ]
  [ -f "$HOME/.copilot/skills/mine/SKILL.md" ]
}

@test "60 copies a base skill when the project has none" {
  config $'version: 1\nproject: demo'
  run bash "$S/60-skills.sh"
  [ "$status" -eq 0 ]
  diff -q "$REPO_ROOT/skills/agentic-setup/SKILL.md" "$HOME/.claude/skills/agentic-setup/SKILL.md"
}

# --- 70-graphify
@test "70 wires Graphify into both harnesses when enabled" {
  stub graphify
  config $'version: 1\nproject: demo'
  run bash "$S/70-graphify.sh"
  [ "$status" -eq 0 ]
  grep -q "graphify install --platform claude" "$LOG"
  grep -q "graphify install --platform copilot" "$LOG"
}

@test "70 does nothing when Graphify is disabled" {
  stub graphify
  config $'version: 1\nproject: demo\nmcp:\n  graphify: {enabled: false}'
  run bash "$S/70-graphify.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$LOG" ]
}

# --- 80-display
@test "80 starts Xvfb for headed Playwright without a display and exports DISPLAY" {
  stub Xvfb ': > "$AGENTIC_X11_DIR/X99"'; stub pgrep 'exit 1'
  config $'version: 1\nproject: demo\nmcp:\n  playwright: {enabled: true, mode: headed}'
  run bash "$S/80-display.sh"
  [ "$status" -eq 0 ]
  grep -q "Xvfb :99" "$LOG"
  grep -q '^export DISPLAY=:99$' "$AGENTIC_STATE/env"
}

@test "80 removes a stale lock and socket before starting Xvfb" {
  stub Xvfb '[ ! -e "$AGENTIC_X_TMP/.X99-lock" ] && : > "$AGENTIC_X11_DIR/X99"'; stub pgrep 'exit 1'
  : > "$AGENTIC_X_TMP/.X99-lock"; : > "$AGENTIC_X11_DIR/X99"
  config $'version: 1\nproject: demo\nmcp:\n  playwright: {enabled: true, mode: headed}'
  run bash "$S/80-display.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$AGENTIC_X_TMP/.X99-lock" ]
  grep -q '^export DISPLAY=:99$' "$AGENTIC_STATE/env"
}

@test "80 warns and exports nothing when Xvfb never comes up" {
  stub Xvfb; stub pgrep 'exit 1'
  config $'version: 1\nproject: demo\nmcp:\n  playwright: {enabled: true, mode: headed}'
  run bash "$S/80-display.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Xvfb did not come up"* ]]
  run grep -s DISPLAY "$AGENTIC_STATE/env"
  [ "$status" -ne 0 ]
}

@test "80 uses an existing display" {
  stub Xvfb
  config $'version: 1\nproject: demo\nmcp:\n  playwright: {enabled: true, mode: headed}'
  DISPLAY=:0 run bash "$S/80-display.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$LOG" ]
}

@test "80 does nothing in headless mode" {
  stub Xvfb
  config $'version: 1\nproject: demo'
  run bash "$S/80-display.sh"
  [ ! -f "$LOG" ]
}

# --- 90-project-hook
@test "90 runs the on-start hook in /work with the environment" {
  mkdir -p "$AGENTIC_CONFIG_MOUNT/hooks"
  printf 'pwd > "$HOME/hook-pwd"; echo "$MY_VAR" > "$HOME/hook-var"\n' > "$AGENTIC_CONFIG_MOUNT/hooks/on-start.sh"
  config $'version: 1\nproject: demo'
  MY_VAR=hello run bash "$S/90-project-hook.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/hook-pwd")" = "$AGENTIC_WORK" ]
  [ "$(cat "$HOME/hook-var")" = hello ]
}

@test "90 failure warns, or stops the start when the hook is required" {
  mkdir -p "$AGENTIC_CONFIG_MOUNT/hooks"; echo 'exit 3' > "$AGENTIC_CONFIG_MOUNT/hooks/on-start.sh"
  config $'version: 1\nproject: demo'
  run bash "$S/90-project-hook.sh"
  [ "$status" -eq 2 ]
  config $'version: 1\nproject: demo\nhooks:\n  on_start_required: true'
  run bash "$S/90-project-hook.sh"
  [ "$status" -eq 1 ]
}

@test "90 without a hook does nothing" {
  config $'version: 1\nproject: demo'
  run bash "$S/90-project-hook.sh"
  [ "$status" -eq 0 ]
}
