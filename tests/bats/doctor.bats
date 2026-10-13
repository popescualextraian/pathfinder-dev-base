#!/usr/bin/env bats
load helpers
load docker-stub

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_STEPS_DIR="$BATS_TEST_TMPDIR/steps" AGENTIC_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$AGENTIC_STEPS_DIR" "$AGENTIC_STATE" "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  for c in claude copilot gh aws az; do
    printf '#!/bin/sh\necho "%s 1.0"\n' "$c" > "$BATS_TEST_TMPDIR/bin/$c"; chmod +x "$BATS_TEST_TMPDIR/bin/$c"
  done
  printf '#!/bin/sh\nexit "${CURL_RC:-0}"\n' > "$BATS_TEST_TMPDIR/bin/curl"; chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  # a JDK 21 that answers `java -version`
  mkdir -p "$AGENTIC_OPT/java/21/bin"
  printf '#!/bin/sh\necho "openjdk version 21" >&2\n' > "$AGENTIC_OPT/java/21/bin/java"; chmod +x "$AGENTIC_OPT/java/21/bin/java"
  resolved '{"project":"demo","git":{"host":"github.com"},"tools":{"java":{"versions":[21],"default":21},"apt":[]},"mcp":{"atlassian":{"enabled":false},"playwright":{"enabled":false},"graphify":{"enabled":false},"custom":[]},"docker":{"socket":false}}'
  echo '{}' > "$HOME/.claude.json"
  export ANTHROPIC_API_KEY=k COPILOT_GITHUB_TOKEN=t
  D="$REPO_ROOT/image/bin/agentic-doctor"
}

resolved() { printf '%s\n' "$1" > "$AGENTIC_STATE/config.json"; }
step() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$AGENTIC_STEPS_DIR/$1.sh"; }

@test "a healthy container passes" {
  step 10-ok 'exit 0'
  run bash "$D"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok    10-ok"* ]]
  [[ "$output" == *"ok    java 21"* ]]
  [[ "$output" == *"doctor: 0 errors, 0 warnings"* ]]
}

@test "a failing start step is an error, a warning step a warning" {
  step 10-bad 'echo "agentic: config broken"; exit 1'
  step 20-meh 'echo "agentic: not ideal"; exit 2'
  run bash "$D"
  [ "$status" -eq 1 ]
  [[ "$output" == *"error 10-bad: config broken"* ]]
  [[ "$output" == *"warn  20-meh: not ideal"* ]]
}

@test "a configured tool that is not installed is an error" {
  resolved '{"project":"demo","tools":{"terraform":"1.9.8","apt":[]},"mcp":{"custom":[]},"docker":{"socket":false}}'
  run bash "$D"
  [ "$status" -eq 1 ]
  [[ "$output" == *"error terraform 1.9.8 is not installed"* ]]
}

@test "a missing login is only a warning" {
  unset ANTHROPIC_API_KEY COPILOT_GITHUB_TOKEN
  run bash "$D"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn  claude: not authenticated"* ]]
  [[ "$output" == *"warn  copilot: not authenticated"* ]]
}

@test "a placeholder token does not count as a login" {
  export COPILOT_GITHUB_TOKEN=TBD
  run bash "$D"
  [[ "$output" == *"warn  copilot: not authenticated"* ]]
}

@test "an HTTP MCP server with an untrusted certificate is an error with the fix" {
  echo '{"mcpServers":{"docs":{"type":"http","url":"https://mcp.example.com/mcp"}}}' > "$HOME/.claude.json"
  CURL_RC=60 run bash "$D"
  [ "$status" -eq 1 ]
  [[ "$output" == *"error mcp docs: TLS certificate not trusted"* ]]
  [[ "$output" == *".agentic/certs"* ]]
}

@test "an unreachable HTTP MCP server is a warning" {
  echo '{"mcpServers":{"docs":{"type":"http","url":"https://mcp.example.com/mcp"}}}' > "$HOME/.claude.json"
  CURL_RC=6 run bash "$D"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn  mcp docs unreachable"* ]]
}

@test "a stdio MCP server whose command is missing is an error" {
  echo '{"mcpServers":{"tool":{"type":"stdio","command":"does-not-exist"}}}' > "$HOME/.claude.json"
  run bash "$D"
  [ "$status" -eq 1 ]
  [[ "$output" == *"error mcp tool: command does-not-exist not found"* ]]
}

@test "a config that changed since the build is reported" {
  AGENTIC_IMAGE_CONFIG_HASH=0000000000000000 run bash "$D"
  [[ "$output" == *"warn  agentic.yaml changed since the last agentic build"* ]]
}

@test "the host command runs agentic-doctor through the entrypoint with the image's config hash" {
  install_docker_stub
  P="$BATS_TEST_TMPDIR/proj"; mkdir -p "$P/.agentic"; git init -q "$P"
  printf 'version: 1\nproject: demo\n' > "$P/.agentic/agentic.yaml"
  DOCKER_LABEL=abc123 run bash -c "cd '$P' && bash '$REPO_ROOT/bin/agentic' doctor"
  [ "$status" -eq 0 ]
  call="$(docker_sub run)"
  grep -qx 'AGENTIC_IMAGE_CONFIG_HASH=abc123' <<<"$call"
  [ "$(tail -n 1 <<<"$call")" = agentic-doctor ]
  run grep -qx -- '--entrypoint' <<<"$call"
  [ "$status" -ne 0 ]
}
