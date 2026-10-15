#!/usr/bin/env bats
load helpers

M="$REPO_ROOT/marketplace"

@test "the agentic marketplace lists the cost plugin" {
  jq -e '.name == "agentic" and (.plugins | map(select(.name == "cost" and .source == "./plugins/cost")) | length == 1)' \
    "$M/.claude-plugin/marketplace.json"
  jq -e '.name == "cost" and (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$M/plugins/cost/.claude-plugin/plugin.json"
}

@test "the plugin's hooks snapshot after every turn and at session end, through the image's snapshot" {
  h="$M/plugins/cost/hooks/hooks.json"
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$h")" = "/opt/agentic/cost/snapshot turn" ]
  [ "$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$h")" = "/opt/agentic/cost/snapshot end" ]
  [ "$(jq -r '[.hooks[][].hooks[].type] | unique | join(",")' "$h")" = command ]
  # /opt/agentic/cost is image/cost in the repository: the commands exist and are executable
  for c in snapshot ccusage-collector; do [ -x "$REPO_ROOT/image/cost/$c" ]; done
}

@test "the recommended lines install the cost plugin for both harnesses" {
  grep -qx 'add marketplace /opt/agentic/marketplace' "$REPO_ROOT/config/recommended"
  grep -qx 'add plugin cost@agentic' "$REPO_ROOT/config/recommended"
}
