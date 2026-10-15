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
  resolved '{"version":2,"project":"demo","targets":["claude","copilot"],"tools":{"java":{"versions":[21],"default":21},"apt":[]},"docker":{"socket":false},"setup":[]}'
  echo '{}' > "$HOME/.claude.json"
  export ANTHROPIC_API_KEY=k COPILOT_GITHUB_TOKEN=t
  D="$REPO_ROOT/image/bin/agentic-doctor"
}

resolved() { printf '%s\n' "$1" > "$AGENTIC_STATE/config.json"; }
conf_with_setup() { jq --argjson s "$1" '.setup = $s' "$AGENTIC_STATE/config.json" > "$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$AGENTIC_STATE/config.json"; }
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
  [[ "$output" == *"agentic copy"* ]]
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
  printf 'version: 2\nproject: demo\n' > "$P/.agentic/agentic.yaml"
  DOCKER_LABEL=abc123 run bash -c "cd '$P' && bash '$REPO_ROOT/bin/agentic' doctor"
  [ "$status" -eq 0 ]
  call="$(docker_sub run)"
  grep -qx 'AGENTIC_IMAGE_CONFIG_HASH=abc123' <<<"$call"
  [ "$(tail -n 1 <<<"$call")" = agentic-doctor ]
  run grep -qx -- '--entrypoint' <<<"$call"
  [ "$status" -ne 0 ]
}

@test "a mount line that is not mounted is listed as skipped" {
  conf_with_setup '["mount ~/.aws /home/dev/.aws --readonly", "volume m2 /home/dev/.m2"]'
  export AGENTIC_MOUNTINFO="$BATS_TEST_TMPDIR/mountinfo"
  echo '36 25 0:31 / /home/dev/.m2 rw,relatime - ext4 /dev/x rw' > "$AGENTIC_MOUNTINFO"
  run bash "$D"
  [[ "$output" == *"warn  mount ~/.aws /home/dev/.aws --readonly: not mounted (started without the agentic CLI?)"* ]]
  [[ "$output" == *"ok    volume m2 /home/dev/.m2"* ]]
}

@test "an unset \${VAR} of an MCP server is a warning" {
  mkdir -p "$HOME/.copilot"
  echo '{"mcpServers":{"j":{"command":"true","env":{"T":"${JIRA_T}"}}}}' > "$HOME/.copilot/mcp-config.json"
  run env -u JIRA_T bash "$D"
  [[ "$output" == *'warn  mcp j uses ${JIRA_T}, which is not set (add it to .agentic/.env)'* ]]
}

@test "a plugin installed by hand is named with the line that keeps it" {
  export AGENTIC_SEED="$BATS_TEST_TMPDIR/seed"; mkdir -p "$AGENTIC_SEED/.built" "$HOME/.claude/plugins"
  echo '["a@m"]' > "$AGENTIC_SEED/.built/claude-plugins.json"
  echo '{"plugins":{"a@m":[{}],"b@m":[{}]}}' > "$HOME/.claude/plugins/installed_plugins.json"
  run bash "$D"
  [[ "$output" == *"warn  plugin b@m was installed by hand and is gone after a recreate; keep it with: agentic add plugin b@m --target claude"* ]]
  if [[ "$output" == *"plugin a@m was installed by hand"* ]]; then return 1; fi
}

@test "git: an origin without credentials for its host warns with agentic login git" {
  export AGENTIC_WORK="$BATS_TEST_TMPDIR/work"; git init -q "$AGENTIC_WORK"
  git -C "$AGENTIC_WORK" remote add origin https://github.com/example/api.git
  GIT_AUTHOR_NAME=J GIT_AUTHOR_EMAIL=j@example.com run bash "$D"
  [[ "$output" == *"warn  git: no credentials for github.com (agentic login git)"* ]]
}

@test "git: credentials and an identity for the origin's host pass" {
  export AGENTIC_WORK="$BATS_TEST_TMPDIR/work"; git init -q "$AGENTIC_WORK"
  git -C "$AGENTIC_WORK" remote add origin git@github.com:example/api.git
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.https://github.com.helper GIT_CONFIG_VALUE_0='!true'
  GIT_AUTHOR_NAME=J GIT_AUTHOR_EMAIL=j@example.com run bash "$D"
  [[ "$output" == *"ok    git (github.com)"* ]]
  [[ "$output" != *"identity"* ]]
}

@test "git: no commit identity warns" {
  export AGENTIC_WORK="$BATS_TEST_TMPDIR/work"; git init -q "$AGENTIC_WORK"
  git -C "$AGENTIC_WORK" remote add origin https://github.com/example/api.git
  run env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL bash "$D"
  [[ "$output" == *"warn  git: no commit identity"* ]]
}

@test "git: a project without an origin is not checked" {
  run bash "$D"
  [[ "$output" != *"git:"* ]]
}

@test "git: a workspace folder lists its repositories and checks each origin's host once" {
  export AGENTIC_WORK="$BATS_TEST_TMPDIR/work"; mkdir -p "$AGENTIC_WORK/notes"
  for r in api ui web; do git init -q "$AGENTIC_WORK/$r"; done
  git -C "$AGENTIC_WORK/api" remote add origin git@github.com:example/api.git
  git -C "$AGENTIC_WORK/web" remote add origin https://github.com/example/web.git
  git -C "$AGENTIC_WORK/ui" remote add origin https://gitlab.example.com/example/ui.git
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.https://github.com.helper GIT_CONFIG_VALUE_0='!true'
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  run bash "$D"
  [[ "$output" == *"ok    workspace folder: api, ui, web"* ]]
  [ "$(grep -c 'ok    git (github.com)' <<<"$output")" -eq 1 ]
  [[ "$output" == *"warn  git: no credentials for gitlab.example.com (agentic login git)"* ]]
  [[ "$output" != *"notes"* ]]
}

@test "git: an empty workspace folder warns how to fill it" {
  export AGENTIC_WORK="$BATS_TEST_TMPDIR/work"; mkdir -p "$AGENTIC_WORK"
  run bash "$D"
  [[ "$output" == *"warn  no git repository in $AGENTIC_WORK (agentic login git URL, then clone into it)"* ]]
}
