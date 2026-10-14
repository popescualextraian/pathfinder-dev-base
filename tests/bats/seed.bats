#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_SEED="$BATS_TEST_TMPDIR/seed"
  mkdir -p "$AGENTIC_SEED/claude/plugins" "$AGENTIC_SEED/copilot/installed-plugins" "$AGENTIC_SEED/.baseline/claude" "$AGENTIC_SEED/.baseline/copilot"
  S="$REPO_ROOT/image/start.d/40-seed.sh"
}

m() { jq -c -L "$REPO_ROOT/image/lib" --argjson o "$2" --argjson n "$3" 'include "seed"; seedmerge($o; $n)' <<<"$1"; }

@test "merge: a new seed value is set" {
  [ "$(m '{}' '{}' '{"a":{"x":1}}')" = '{"a":{"x":1}}' ]
}
@test "merge: a value only the old seed had, unchanged by the user, is removed" {
  [ "$(m '{"a":{"x":1,"y":2}}' '{"a":{"x":1,"y":2}}' '{"a":{"x":1}}')" = '{"a":{"x":1}}' ]
}
@test "merge: a value the user changed is kept even when the seed dropped it" {
  [ "$(m '{"a":{"y":9}}' '{"a":{"y":2}}' '{"a":{}}')" = '{"a":{"y":9}}' ]
}
@test "merge: keys only the home has are never touched" {
  [ "$(m '{"theme":"dark","a":1}' '{"a":1}' '{"a":2}')" = '{"theme":"dark","a":2}' ]
}
@test "merge: arrays are single values" {
  [ "$(m '{"l":[1,2]}' '{"l":[1]}' '{"l":[3]}')" = '{"l":[3]}' ]
}
@test "delta keeps only what differs from the baseline" {
  run jq -c -L "$REPO_ROOT/image/lib" --argjson b '{"id":"u","m":{"a":1}}' 'include "seed"; delta($b)' <<<'{"id":"u","m":{"a":1,"b":2},"n":3}'
  [ "$output" = '{"m":{"b":2},"n":3}' ]
}

@test "the step links plugin folders and merges JSON into the home" {
  echo '{"mcpServers":{"pw":{"command":"x"}},"userID":"seed"}' > "$AGENTIC_SEED/claude/.claude.json"
  echo '{"userID":"seed"}' > "$AGENTIC_SEED/.baseline/claude/.claude.json"
  echo '{"theme":"dark","userID":"mine"}' > "$HOME/.claude.json"
  run bash "$S"
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.claude/plugins")" = "$AGENTIC_SEED/claude/plugins" ]
  [ "$(readlink "$HOME/.copilot/installed-plugins")" = "$AGENTIC_SEED/copilot/installed-plugins" ]
  [ "$(jq -c -S . "$HOME/.claude.json")" = '{"mcpServers":{"pw":{"command":"x"}},"theme":"dark","userID":"mine"}' ]
}

@test "removed line: what the old seed added disappears, a user key is kept" {
  echo '{"mcpServers":{"pw":{"command":"x"}}}' > "$AGENTIC_SEED/claude/.claude.json"
  echo '{}' > "$AGENTIC_SEED/.baseline/claude/.claude.json"
  bash "$S"
  jq '.mcpServers.mine = {"command":"y"}' "$HOME/.claude.json" > "$HOME/t" && mv "$HOME/t" "$HOME/.claude.json"
  echo '{}' > "$AGENTIC_SEED/claude/.claude.json"
  bash "$S"
  [ "$(jq -c .mcpServers "$HOME/.claude.json")" = '{"mine":{"command":"y"}}' ]
}

@test "real folder moved aside, not deleted, then linked" {
  mkdir -p "$HOME/.copilot/installed-plugins/old"
  run bash "$S"
  [ "$status" -eq 2 ]
  [ -L "$HOME/.copilot/installed-plugins" ]
  compgen -G "$HOME/.copilot/installed-plugins.pre-seed.*/old" >/dev/null
}

@test "unreadable JSON in the home is left alone with a warning" {
  echo '{"a":1}' > "$AGENTIC_SEED/copilot/mcp-config.json"
  mkdir -p "$HOME/.copilot"; echo 'not json' > "$HOME/.copilot/mcp-config.json"
  run bash "$S"
  [ "$status" -eq 2 ]
  [ "$(cat "$HOME/.copilot/mcp-config.json")" = 'not json' ]
}

@test "--check reports a home that lacks the seed and writes nothing" {
  echo '{"a":1}' > "$AGENTIC_SEED/claude/settings.json"
  run bash "$S" --check
  [ "$status" -eq 2 ]
  [ ! -e "$HOME/.claude/settings.json" ]
}

@test "ignored volatile keys are never merged" {
  key="$(jq -r '."claude/.claude.json"[0] // empty' "$REPO_ROOT/image/lib/seed-ignore.json")"
  [ -n "$key" ] || skip "Task 1 recorded no volatile key for .claude.json"
  jq -n --arg k "$key" '{($k): 5}' > "$AGENTIC_SEED/claude/.claude.json"
  echo '{}' > "$AGENTIC_SEED/.baseline/claude/.claude.json"
  bash "$S"
  [ "$(jq --arg k "$key" 'has($k)' "$HOME/.claude.json")" = false ]
}

@test "Copilot's commented config.json is merged and keeps the login" {
  printf '// managed automatically\n{"installedPlugins":[{"name":"p"}]}\n' > "$AGENTIC_SEED/copilot/config.json"
  mkdir -p "$HOME/.copilot"
  printf '// managed automatically\n{"logged_in_users":[{"login":"me"}]}\n' > "$HOME/.copilot/config.json"
  bash "$S"
  [ "$(jq -r '.logged_in_users[0].login' "$HOME/.copilot/config.json")" = me ]
  [ "$(jq -r '.installedPlugins[0].name' "$HOME/.copilot/config.json")" = p ]
}

@test "merge: removing a seed object keeps only the user's keys inside it" {
  [ "$(m '{"s":{"pw":1,"mine":2}}' '{"s":{"pw":1}}' '{}')" = '{"s":{"mine":2}}' ]
  [ "$(m '{"s":{"pw":9}}' '{"s":{"pw":1}}' '{}')" = '{"s":{"pw":9}}' ]
}

@test "an MCP server whose \${VAR} is unset is a start warning" {
  echo '{"mcpServers":{"jira":{"command":"x","env":{"T":"${JIRA_T}"}}}}' > "$AGENTIC_SEED/claude/.claude.json"
  run env -u JIRA_T bash "$S"
  [ "$status" -eq 2 ]
  [[ "$output" == *'MCP server jira uses ${JIRA_T}, which is not set (add it to .agentic/.env)'* ]]
  JIRA_T=x run bash "$S"
  [ "$status" -eq 0 ]
}

@test "a link to a plugin folder the seed no longer has is removed; a user's own folder stays" {
  bash "$S"
  [ -L "$HOME/.claude/plugins" ]
  rm -rf "$AGENTIC_SEED/claude/plugins" "$AGENTIC_SEED/copilot/installed-plugins"
  mkdir -p "$HOME/.copilot"; rm -f "$HOME/.copilot/installed-plugins"; mkdir "$HOME/.copilot/installed-plugins"
  run bash "$S"
  [ ! -e "$HOME/.claude/plugins" ]
  if [ -L "$HOME/.claude/plugins" ]; then return 1; fi
  [ -d "$HOME/.copilot/installed-plugins" ]
}

@test "a home JSON the merge cannot handle is left alone, not emptied" {
  echo '{"mcpServers":{"pw":{"command":"x"}}}' > "$AGENTIC_SEED/claude/.claude.json"
  echo '{}' > "$AGENTIC_SEED/.baseline/claude/.claude.json"
  echo '[1]' > "$HOME/.claude.json"
  run bash "$S"
  [ "$status" -eq 2 ]
  [ "$(cat "$HOME/.claude.json")" = '[1]' ]
}

@test "a real folder that cannot be moved aside is left alone, with no link inside it" {
  mkdir -p "$HOME/.copilot/installed-plugins/old"
  chmod 555 "$HOME/.copilot"
  run bash "$S"
  chmod 755 "$HOME/.copilot"
  [ "$status" -eq 2 ]
  [ ! -L "$HOME/.copilot/installed-plugins" ]
  [ ! -e "$HOME/.copilot/installed-plugins/installed-plugins" ]
  [[ "$output" == *"could not move"* ]]
}
