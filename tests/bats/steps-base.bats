#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_WORK="$BATS_TEST_TMPDIR/work" AGENTIC_WORKSPACES_DIR="$BATS_TEST_TMPDIR/workspaces"
  export AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/mount"
  mkdir -p "$AGENTIC_WORK" "$AGENTIC_WORKSPACES_DIR" "$AGENTIC_STATE"
  S="$REPO_ROOT/image/start.d"
  # an origin repository containing .agentic/agentic.yaml
  O="$BATS_TEST_TMPDIR/origin"
  git init -q -b main "$O"
  mkdir -p "$O/.agentic"; printf 'version: 2\nproject: cloned\n' > "$O/.agentic/agentic.yaml"
  git -C "$O" add . && git -C "$O" -c user.name=t -c user.email=t@t commit -q -m init
}

config() { mkdir -p "$AGENTIC_CONFIG_MOUNT"; printf '%s\n' "$1" > "$AGENTIC_CONFIG_MOUNT/agentic.yaml"; }

# --- 05-workspace
@test "05 leaves a non-empty /work alone" {
  touch "$AGENTIC_WORK/file"
  AGENTIC_REPO_URL="file://$O" run bash "$S/05-workspace.sh"
  [ "$status" -eq 0 ]
  [ ! -d "$AGENTIC_WORK/.git" ]
}

@test "05 clones AGENTIC_REPO_URL into an empty /work, at AGENTIC_REPO_REF" {
  git -C "$O" branch feature
  AGENTIC_REPO_URL="file://$O" AGENTIC_REPO_REF=feature run bash "$S/05-workspace.sh"
  [ "$status" -eq 0 ]
  [ "$(git -C "$AGENTIC_WORK" branch --show-current)" = feature ]
}

@test "05 warns when /work is empty and there is no URL" {
  run bash "$S/05-workspace.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"mount a repository or set AGENTIC_REPO_URL"* ]]
}

@test "05 --check reports without cloning" {
  AGENTIC_REPO_URL="file://$O" run bash "$S/05-workspace.sh" --check
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$AGENTIC_WORK")" ]
}

@test "05 never prints the userinfo of a failing repo URL" {
  export GIT_ALLOW_PROTOCOL=file   # offline: https and ssh fail at once
  AGENTIC_REPO_URL="https://user:tok@127.0.0.1:1/x" run bash "$S/05-workspace.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"https://***@127.0.0.1:1/x"* ]]
  [[ "$output" != *tok* ]]
  AGENTIC_REPO_URL="https://user:tok@127.0.0.1:1/x" run bash "$S/05-workspace.sh" --check
  [[ "$output" != *tok* ]]
}

@test "05 keeps the token out of the start log" {
  export GIT_ALLOW_PROTOCOL=file   # offline: https and ssh fail at once
  export AGENTIC_STEPS_DIR="$BATS_TEST_TMPDIR/steps"; mkdir -p "$AGENTIC_STEPS_DIR"
  ln -s "$S/05-workspace.sh" "$AGENTIC_STEPS_DIR/05-workspace.sh"
  AGENTIC_REPO_URL="https://user:tok@127.0.0.1:1/x" run bash "$REPO_ROOT/image/entrypoint.sh" true
  [ "$status" -eq 1 ]
  [[ "$output" != *tok* ]]
  grep -q '127.0.0.1:1/x' "$AGENTIC_STATE/start.log"
  run grep -q tok "$AGENTIC_STATE/start.log"
  [ "$status" -ne 0 ]
}

@test "05 clones with prompts off and ssh in batch mode" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "$GIT_TERMINAL_PROMPT|$GIT_SSH_COMMAND" >> "%s"\nexit 1\n' "$BATS_TEST_TMPDIR/seen" > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" AGENTIC_REPO_URL="git@git.example.com:team/x.git" run bash "$S/05-workspace.sh"
  [ "$(sort -u "$BATS_TEST_TMPDIR/seen")" = "0|ssh -o BatchMode=yes" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/seen")" -eq 1 ]
}

@test "redact_url hides userinfo in every URL" {
  run bash -c "source '$AGENTIC_DIR/lib/common.sh'; source '$AGENTIC_DIR/lib/gitenv.sh'; redact_url 'a https://u:p@h/x and ssh://git@h2/y git@h3:z'"
  [ "$output" = 'a https://***@h/x and ssh://***@h2/y git@h3:z' ]
  run bash -c "source '$AGENTIC_DIR/lib/common.sh'; source '$AGENTIC_DIR/lib/gitenv.sh'; echo 'https://u:p@h/x' | redact_url"
  [ "$output" = 'https://***@h/x' ]
}

# --- 10-validate
@test "10 resolves the mounted config and records its directory" {
  config $'version: 2\nproject: demo'
  run bash "$S/10-validate.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r .project "$AGENTIC_STATE/config.json")" = demo ]
  [ "$(cat "$AGENTIC_STATE/config-dir")" = "$AGENTIC_CONFIG_MOUNT" ]
}

@test "10 fails on an invalid config and keeps the previous resolved config" {
  echo '{"project":"old"}' > "$AGENTIC_STATE/config.json"
  config $'version: 2\nproject: demo\nfoo: 1'
  run bash "$S/10-validate.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *".foo: unknown key"* ]]
  [ "$(jq -r .project "$AGENTIC_STATE/config.json")" = old ]
}

@test "10 under agentic setup warns on an invalid config, records the errors and starts with defaults" {
  config $'version: 2\nproject: demo\nfoo: 1'
  AGENTIC_SETUP=1 run bash "$S/10-validate.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *".foo: unknown key"* ]]
  grep -q '.foo: unknown key' "$AGENTIC_STATE/config-errors.txt"
  [ "$(cat "$AGENTIC_STATE/config-dir")" = "$AGENTIC_CONFIG_MOUNT" ]
  config $'version: 2\nproject: demo'
  AGENTIC_SETUP=1 run bash "$S/10-validate.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$AGENTIC_STATE/config-errors.txt" ]
}

@test "10 without any config warns and uses the defaults" {
  run bash "$S/10-validate.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no agentic.yaml found; using defaults"* ]]
  [ "$(jq -r .project "$AGENTIC_STATE/config.json")" = default ]
  [ "$(cat "$AGENTIC_STATE/config-dir")" = "" ]
}

@test "10 fails when AGENTIC_CONFIG_B64 is not valid base64, instead of using the defaults" {
  AGENTIC_CONFIG_B64='%%%not-base64' run bash "$S/10-validate.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"AGENTIC_CONFIG_B64 is not valid base64"* ]]
  [ ! -f "$AGENTIC_STATE/config.json" ]
}

@test "10 finds the config inside a cloned /work" {
  git clone -q "$O" "$AGENTIC_WORK/x" && mv "$AGENTIC_WORK/x/.agentic" "$AGENTIC_WORK/.agentic"
  run bash "$S/10-validate.sh"
  [ "$(jq -r .project "$AGENTIC_STATE/config.json")" = cloned ]
}

# --- 20-onboarding
@test "20 seeds Claude onboarding and trusts /work, /workspaces and each clone" {
  mkdir -p "$AGENTIC_WORKSPACES_DIR/lib/.git" "$AGENTIC_WORKSPACES_DIR/repos/app/.git"
  config $'version: 2\nproject: demo'; bash "$S/10-validate.sh"
  run bash "$S/20-onboarding.sh"
  [ "$status" -eq 0 ]
  f="$HOME/.claude.json"
  [ "$(jq -r .hasCompletedOnboarding "$f")" = true ]
  # a task mounts clones as /workspaces/<name>, a dev container as /workspaces/repos/<name>
  for d in "$AGENTIC_WORK" "$AGENTIC_WORKSPACES_DIR" "$AGENTIC_WORKSPACES_DIR/lib" "$AGENTIC_WORKSPACES_DIR/repos/app"; do
    [ "$(jq -r --arg d "$d" '.projects[$d].hasTrustDialogAccepted' "$f")" = true ]
  done
  [ "$(stat -c %a "$f")" = 600 ]
  jq -e --arg d "$AGENTIC_WORK" '.trusted_folders | index($d)' "$HOME/.copilot/config.json"
}

@test "20 keeps existing keys and follows CLAUDE_CONFIG_DIR" {
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cc"; mkdir -p "$CLAUDE_CONFIG_DIR"
  echo '{"theme":"dark"}' > "$CLAUDE_CONFIG_DIR/.claude.json"
  config $'version: 2\nproject: demo'; bash "$S/10-validate.sh"
  bash "$S/20-onboarding.sh"
  [ "$(jq -r .theme "$CLAUDE_CONFIG_DIR/.claude.json")" = dark ]
  [ "$(jq -r .hasCompletedOnboarding "$CLAUDE_CONFIG_DIR/.claude.json")" = true ]
}

@test "20 --check warns about missing onboarding and changes nothing" {
  config $'version: 2\nproject: demo'; bash "$S/10-validate.sh"
  run bash "$S/20-onboarding.sh" --check
  [ "$status" -eq 2 ]
  [ ! -f "$HOME/.claude.json" ]
}

