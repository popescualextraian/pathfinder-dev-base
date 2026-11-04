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

@test "the setup skill asks for a default target when a multi-repository project has none" {
  grep -q 'layout: multi' "$REPO_ROOT/skills/agentic-setup/SKILL.md"
  grep -q 'agentic target NAME' "$REPO_ROOT/skills/agentic-setup/SKILL.md"
}

@test "the setup skill sets git up with agentic-git login, never the GIT_CONFIG keys by hand" {
  s="$REPO_ROOT/skills/agentic-setup/SKILL.md"
  grep -q 'agentic-git login' "$s"
  if grep -q 'agentic-env add GIT_CONFIG' "$s"; then return 1; fi
  grep -q 'identity from the host' "$s"
}

@test "the setup skill joins services through the project network, not the image or the socket" {
  s="$REPO_ROOT/skills/agentic-setup/SKILL.md"
  grep -q 'agentic-<project>' "$s"
  grep -q '.agentic/compose.yaml' "$s"
  grep -q 'external: true' "$s"
  grep -q 'parallel tasks share the database' "$s"
}

@test "the setup skill adds apps from what each repository's own instructions say" {
  s="$REPO_ROOT/skills/agentic-setup/SKILL.md"
  grep -q '## Apps' "$s"
  grep -q '`AGENTS.md` of every repository' "$s"
  grep -q 'subfolders with their own build file' "$s"
  grep -q '0.0.0.0' "$s"
  grep -q 'agentic-app start NAME' "$s"
  grep -q 'NAME.prepared' "$s"
}

@test "the setup skill opens with a catalog when started without a request" {
  s="$REPO_ROOT/skills/agentic-setup/SKILL.md"
  grep -q '## Start: the catalog' "$s"
  for e in 'First-time setup' 'Tell me what you want' 'Configure an app' 'Show what is installed' 'Review the current setup'; do
    grep -qF "$e" "$s" || { echo "missing: $e"; return 1; }
  done
  # the catalog comes before the rules, so it is the first thing done
  [ "$(grep -n '## Start: the catalog' "$s" | cut -d: -f1)" -lt "$(grep -n '^## Rules' "$s" | cut -d: -f1)" ]
}
