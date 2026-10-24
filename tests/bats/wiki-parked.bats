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

@test "the README tells how to add the parked wiki, marketplace first when missing" {
  sed -n '/^## Project wiki (parked)/,/^## /p' "$REPO_ROOT/README.md" | tr '\n' ' ' > "$BATS_TEST_TMPDIR/w"
  grep -qF 'agentic add marketplace /opt/agentic/marketplace' "$BATS_TEST_TMPDIR/w"
  grep -qF 'agentic add plugin wiki@agentic' "$BATS_TEST_TMPDIR/w"
}

@test "the README intro names the architect skill next to /agentic-setup" {
  awk 'NR > 2 && /^$/ { exit } NR > 2' "$REPO_ROOT/README.md" | tr '\n' ' ' | grep -qE '/agentic-setup`.*`/architect`|`/architect`.*/agentic-setup`'
}
