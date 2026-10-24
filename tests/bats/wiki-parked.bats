#!/usr/bin/env bats
load helpers

@test "the wiki skill is parked as a marketplace plugin, not a default skill" {
  [ ! -e "$REPO_ROOT/skills/wiki" ]
  [ -f "$REPO_ROOT/marketplace/plugins/wiki/skills/wiki/SKILL.md" ]
  jq -e '.name == "wiki"' "$REPO_ROOT/marketplace/plugins/wiki/.claude-plugin/plugin.json"
  jq -e '.plugins[] | select(.name == "wiki" and .source == "./plugins/wiki")' \
    "$REPO_ROOT/marketplace/.claude-plugin/marketplace.json"
}

@test "agentic-wiki stays in the image" {
  [ -f "$REPO_ROOT/image/bin/agentic-wiki" ]
  [ -f "$REPO_ROOT/image/lib/wiki.sh" ]
}
