#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_SEED="$BATS_TEST_TMPDIR/seed" LOG="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for h in claude copilot; do
    printf '#!/bin/sh\necho "%s home=${CLAUDE_CONFIG_DIR:-}${COPILOT_HOME:-} $*" >> "$LOG"\n' "$h" > "$BATS_TEST_TMPDIR/bin/$h"
    chmod +x "$BATS_TEST_TMPDIR/bin/$h"
  done
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  P="$REPO_ROOT/image/bin/agentic-apply"
}

@test "add plugin for both targets: each harness on its own seed home" {
  run "$P" --default-targets claude,copilot "add plugin r@m"
  [ "$status" -eq 0 ]
  grep -qx "claude home=$AGENTIC_SEED/claude plugin install -s user r@m" "$LOG"
  grep -qx "copilot home=$AGENTIC_SEED/copilot plugin install r@m" "$LOG"
}

@test "claude-plugins-official is added first when the seed does not know it" {
  "$P" --default-targets claude "add plugin superpowers@claude-plugins-official"
  [ "$(sed -n 1p "$LOG")" = "claude home=$AGENTIC_SEED/claude plugin marketplace add anthropics/claude-plugins-official" ]
  mkdir -p "$AGENTIC_SEED/claude/plugins"; echo '{"claude-plugins-official":{}}' > "$AGENTIC_SEED/claude/plugins/known_marketplaces.json"
  : > "$LOG"
  "$P" --default-targets claude "add plugin superpowers@claude-plugins-official"
  if grep -q "marketplace add" "$LOG"; then return 1; fi
}

@test "the line's own target wins over the default" {
  "$P" --default-targets claude,copilot "add marketplace o/r --target copilot"
  [ "$(cat "$LOG")" = "copilot home=$AGENTIC_SEED/copilot plugin marketplace add o/r" ]
}

@test "add mcp stdio writes env names as references, never values" {
  JIRA_PERSONAL_TOKEN=secret "$P" --default-targets claude,copilot "add mcp jira --env JIRA_PERSONAL_TOKEN --env U=https://x.example.com -- mcp-atlassian -v"
  grep -qxF 'claude home='"$AGENTIC_SEED"'/claude mcp add -s user jira -e JIRA_PERSONAL_TOKEN=${JIRA_PERSONAL_TOKEN} -e U=https://x.example.com -- mcp-atlassian -v' "$LOG"
  grep -qxF 'copilot home='"$AGENTIC_SEED"'/copilot mcp add jira --env JIRA_PERSONAL_TOKEN=${JIRA_PERSONAL_TOKEN} --env U=https://x.example.com -- mcp-atlassian -v' "$LOG"
  if grep -q secret "$LOG"; then return 1; fi
}

@test "add mcp http" {
  "$P" --default-targets claude,copilot "add mcp docs --transport http https://mcp.example.com/mcp"
  grep -qx "claude home=$AGENTIC_SEED/claude mcp add -s user --transport http docs https://mcp.example.com/mcp" "$LOG"
  grep -qx "copilot home=$AGENTIC_SEED/copilot mcp add --transport http docs https://mcp.example.com/mcp" "$LOG"
}

@test "a failing harness call fails with the line" {
  printf '#!/bin/sh\nexit 4\n' > "$BATS_TEST_TMPDIR/bin/copilot"
  run "$P" --default-targets claude,copilot "add plugin r@m"
  [ "$status" -eq 1 ]
  [[ "$output" == *"setup line failed for copilot: add plugin r@m"* ]]
}

@test "start- and run-phase lines are refused" {
  run "$P" --default-targets claude "volume m2 /m2"
  [ "$status" -eq 1 ]
}

@test "baseline snapshots the seed JSON files listed in seed-map.tsv" {
  mkdir -p "$AGENTIC_SEED/claude"; echo '{"a":1}' > "$AGENTIC_SEED/claude/settings.json"
  "$P" --baseline
  [ "$(jq -c . "$AGENTIC_SEED/.baseline/claude/settings.json")" = '{"a":1}' ]
  [ "$(jq -c . "$AGENTIC_SEED/.baseline/copilot/mcp-config.json")" = '{}' ]
}

@test "finish records the plugins the build installed" {
  mkdir -p "$AGENTIC_SEED/claude/plugins"
  echo '{"plugins":{"r@m":[{}]}}' > "$AGENTIC_SEED/claude/plugins/installed_plugins.json"
  "$P" --finish
  [ "$(jq -c . "$AGENTIC_SEED/.built/claude-plugins.json")" = '["r@m"]' ]
}
