#!/usr/bin/env bats
load helpers

@test "the setup skill teaches setup lines and no removed field" {
  s="$REPO_ROOT/skills/agentic-setup"
  grep -q 'agentic-setup-edit --dir /work/.agentic add' "$s/SKILL.md"
  grep -q 'reference/setup-lines.md' "$s/SKILL.md"
  if grep -qE 'mcp\.atlassian|mcp\.custom|plugins\.claude|`plugins`|certs/\*\.crt|on-build|git\.user_' "$s/SKILL.md"; then return 1; fi
  for c in 'add marketplace' 'add plugin' 'add mcp' 'add skill' 'add agent' 'add command' 'add workspace' 'copy' 'mount' 'volume'; do
    grep -q "$c" "$s/reference/setup-lines.md" || { echo "missing: $c"; return 1; }
  done
}

@test "the setup skill prefers copy and .env over mount and says tasks get mounts" {
  s="$REPO_ROOT/skills/agentic-setup/SKILL.md"
  grep -q 'Prefer `copy` for plain files' "$s"
  grep -q 'tasks receive mounts too' "$s"
}

@test "the setup skill sets git up with agentic-git login, never the GIT_CONFIG keys by hand" {
  s="$REPO_ROOT/skills/agentic-setup/SKILL.md"
  grep -q 'agentic-git login' "$s"
  if grep -q 'agentic-env add GIT_CONFIG' "$s"; then return 1; fi
  grep -q 'identity from the host' "$s"
}
