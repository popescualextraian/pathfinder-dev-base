#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/mount" AGENTIC_WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$AGENTIC_CONFIG_MOUNT" "$AGENTIC_WORK"
  S="$REPO_ROOT/image/start.d"
  CJ="$HOME/.claude.json"
}

apply() {
  printf '%s\n' "$1" > "$AGENTIC_CONFIG_MOUNT/agentic.yaml"
  bash "$S/10-validate.sh" >/dev/null
  run bash "$S/40-mcp.sh" "${@:2}"
}

@test "defaults register headless Playwright and Graphify, not Atlassian" {
  apply $'version: 1\nproject: demo'
  [ "$status" -eq 0 ]
  jq -e '.mcpServers.playwright.args | index("--headless")' "$CJ"
  [ "$(jq -r .mcpServers.playwright.command "$CJ")" = mcp-server-playwright ]
  [ "$(jq -r '.mcpServers.graphify.args | join(" ")' "$CJ")" = "-m graphify.serve graphify-out/graph.json" ]
  [ "$(jq -r '.mcpServers.atlassian // "none"' "$CJ")" = none ]
}

@test "atlassian gets the configured URLs as arguments, and warns without a token" {
  apply $'version: 1\nproject: demo\nmcp:\n  atlassian: {enabled: true, jira_url: "https://jira.example.com"}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"JIRA_PERSONAL_TOKEN"* ]]
  [ "$(jq -c .mcpServers.atlassian.args "$CJ")" = '["--jira-url","https://jira.example.com"]' ]
  JIRA_PERSONAL_TOKEN=x apply $'version: 1\nproject: demo\nmcp:\n  atlassian: {enabled: true, jira_url: "https://jira.example.com"}'
  [ "$status" -eq 0 ]
}

@test "headed Playwright drops --headless" {
  apply $'version: 1\nproject: demo\nmcp:\n  playwright: {enabled: true, mode: headed}'
  [ "$(jq '.mcpServers.playwright.args | index("--headless")' "$CJ")" = null ]
}

@test "custom servers keep \${VAR} literal and warn when the variable is unset" {
  apply $'version: 1\nproject: demo\nmcp:\n  custom:\n    - {name: docs, type: http, url: "https://mcp.example.com/mcp", headers: {Authorization: "Bearer ${DOCS_TOKEN}"}}\n    - {name: tool, type: stdio, command: my-mcp, args: [--fast]}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"docs uses \${DOCS_TOKEN}, which is not set"* ]]
  [ "$(jq -r .mcpServers.docs.headers.Authorization "$CJ")" = 'Bearer ${DOCS_TOKEN}' ]
  [ "$(jq -r .mcpServers.tool.command "$CJ")" = my-mcp ]
}

@test "servers added by hand survive; a disabled managed server is removed" {
  echo '{"mcpServers":{"mine":{"type":"stdio","command":"x"}}}' > "$CJ"
  apply $'version: 1\nproject: demo'
  jq -e '.mcpServers.mine' "$CJ"
  apply $'version: 1\nproject: demo\nmcp:\n  graphify: {enabled: false}'
  [ "$(jq -r '.mcpServers.graphify // "gone"' "$CJ")" = gone ]
  jq -e '.mcpServers.mine' "$CJ"
}

@test "a second run with the same config changes nothing" {
  apply $'version: 1\nproject: demo'
  before="$(cat "$CJ" "$HOME/.copilot/mcp-config.json")"
  apply $'version: 1\nproject: demo'
  [ "$status" -eq 0 ]
  [ "$before" = "$(cat "$CJ" "$HOME/.copilot/mcp-config.json")" ]
}

@test "Copilot gets the same servers in its own format" {
  apply $'version: 1\nproject: demo\nmcp:\n  custom:\n    - {name: docs, type: http, url: "https://mcp.example.com/mcp"}'
  f="$HOME/.copilot/mcp-config.json"
  [ "$(jq -r .mcpServers.playwright.type "$f")" = local ]
  [ "$(jq -c .mcpServers.playwright.tools "$f")" = '["*"]' ]
  [ "$(jq -r .mcpServers.docs.type "$f")" = http ]
  [ "$(jq -r .mcpServers.docs.url "$f")" = https://mcp.example.com/mcp ]
}

@test "--check reports drift without writing" {
  printf 'version: 1\nproject: demo\n' > "$AGENTIC_CONFIG_MOUNT/agentic.yaml"
  bash "$S/10-validate.sh" >/dev/null
  run bash "$S/40-mcp.sh" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"MCP servers differ from agentic.yaml"* ]]
  [ ! -f "$CJ" ]
}

@test "a failing jq computation is fatal and leaves .claude.json untouched" {
  printf 'version: 1\nproject: demo\n' > "$AGENTIC_CONFIG_MOUNT/agentic.yaml"
  bash "$S/10-validate.sh" >/dev/null
  printf '{"hasCompletedOnboarding":true}\n' > "$CJ"
  before="$(cat "$CJ")"
  # a private copy of lib with a broken jq module
  rm "$AGENTIC_DIR/lib"
  cp -r "$REPO_ROOT/image/lib" "$AGENTIC_DIR/lib"
  echo 'def desired($g): ;' > "$AGENTIC_DIR/lib/mcp.jq"
  run bash "$S/40-mcp.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not compute MCP servers"* ]]
  [ "$before" = "$(cat "$CJ")" ]
}
