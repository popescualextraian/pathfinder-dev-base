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
  mkdir -p "$O/.agentic"; printf 'version: 1\nproject: cloned\n' > "$O/.agentic/agentic.yaml"
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

@test "05 and 15 clone with prompts off and ssh in batch mode" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "$GIT_TERMINAL_PROMPT|$GIT_SSH_COMMAND" >> "%s"\nexit 1\n' "$BATS_TEST_TMPDIR/seen" > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  config $'version: 1\nproject: demo\nrepos:\n  - {name: main}\n  - {name: lib, url: "git@git.example.com:team/lib.git"}'
  bash "$S/10-validate.sh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" AGENTIC_REPO_URL="git@git.example.com:team/x.git" run bash "$S/05-workspace.sh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$S/15-repos.sh"
  [ "$(sort -u "$BATS_TEST_TMPDIR/seen")" = "0|ssh -o BatchMode=yes" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/seen")" -eq 2 ]
}

@test "redact_url hides userinfo in every URL" {
  run bash -c "source '$AGENTIC_DIR/lib/common.sh'; source '$AGENTIC_DIR/lib/gitenv.sh'; redact_url 'a https://u:p@h/x and ssh://git@h2/y git@h3:z'"
  [ "$output" = 'a https://***@h/x and ssh://***@h2/y git@h3:z' ]
  run bash -c "source '$AGENTIC_DIR/lib/common.sh'; source '$AGENTIC_DIR/lib/gitenv.sh'; echo 'https://u:p@h/x' | redact_url"
  [ "$output" = 'https://***@h/x' ]
}

# --- 10-validate
@test "10 resolves the mounted config and records its directory" {
  config $'version: 1\nproject: demo'
  run bash "$S/10-validate.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r .project "$AGENTIC_STATE/config.json")" = demo ]
  [ "$(cat "$AGENTIC_STATE/config-dir")" = "$AGENTIC_CONFIG_MOUNT" ]
}

@test "10 fails on an invalid config and keeps the previous resolved config" {
  echo '{"project":"old"}' > "$AGENTIC_STATE/config.json"
  config $'version: 1\nproject: demo\nfoo: 1'
  run bash "$S/10-validate.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *".foo: unknown key"* ]]
  [ "$(jq -r .project "$AGENTIC_STATE/config.json")" = old ]
}

@test "10 under agentic setup warns on an invalid config, records the errors and starts with defaults" {
  config $'version: 1\nproject: demo\nfoo: 1'
  AGENTIC_SETUP=1 run bash "$S/10-validate.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *".foo: unknown key"* ]]
  grep -q '.foo: unknown key' "$AGENTIC_STATE/config-errors.txt"
  [ "$(cat "$AGENTIC_STATE/config-dir")" = "$AGENTIC_CONFIG_MOUNT" ]
  config $'version: 1\nproject: demo'
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

# --- 15-repos
@test "15 clones other repos into /workspaces and skips existing ones" {
  config "$(printf 'version: 1\nproject: demo\nrepos:\n  - {name: main}\n  - {name: lib, url: "file://%s"}' "$O")"
  bash "$S/10-validate.sh"
  run bash "$S/15-repos.sh"
  [ "$status" -eq 0 ]
  [ -d "$AGENTIC_WORKSPACES_DIR/lib/.git" ]
  [ ! -d "$AGENTIC_WORKSPACES_DIR/main" ]
  run bash "$S/15-repos.sh"
  [ "$status" -eq 0 ]
}

@test "15 warns, and continues, when a clone fails" {
  config $'version: 1\nproject: demo\nrepos:\n  - {name: main}\n  - {name: gone, url: "file:///nonexistent/repo"}'
  bash "$S/10-validate.sh"
  run bash "$S/15-repos.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not clone gone"* ]]
}

@test "15 never prints the userinfo of a failing repo URL" {
  export GIT_ALLOW_PROTOCOL=file   # offline: https and ssh fail at once
  config $'version: 1\nproject: demo\nrepos:\n  - {name: main}\n  - {name: priv, url: "https://user:tok@127.0.0.1:1/x"}'
  bash "$S/10-validate.sh"
  run bash "$S/15-repos.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not clone priv from https://***@127.0.0.1:1/x"* ]]
  [[ "$output" != *tok* ]]
}

@test "15 clones a git@ URL over https, without prompting" {
  export GIT_ALLOW_PROTOCOL=file   # offline: https and ssh fail at once
  config $'version: 1\nproject: demo\nrepos:\n  - {name: main}\n  - {name: ssh, url: "git@127.0.0.1:team/x.git"}'
  bash "$S/10-validate.sh"
  run bash "$S/15-repos.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"transport 'https' not allowed"* ]]
  [[ "$output" != *"transport 'ssh'"* ]]
}

# --- 20-onboarding
@test "20 seeds Claude onboarding and trusts /work, /workspaces and each clone" {
  mkdir -p "$AGENTIC_WORKSPACES_DIR/lib/.git"
  config $'version: 1\nproject: demo'; bash "$S/10-validate.sh"
  run bash "$S/20-onboarding.sh"
  [ "$status" -eq 0 ]
  f="$HOME/.claude.json"
  [ "$(jq -r .hasCompletedOnboarding "$f")" = true ]
  for d in "$AGENTIC_WORK" "$AGENTIC_WORKSPACES_DIR" "$AGENTIC_WORKSPACES_DIR/lib"; do
    [ "$(jq -r --arg d "$d" '.projects[$d].hasTrustDialogAccepted' "$f")" = true ]
  done
  [ "$(stat -c %a "$f")" = 600 ]
  jq -e --arg d "$AGENTIC_WORK" '.trusted_folders | index($d)' "$HOME/.copilot/config.json"
}

@test "20 keeps existing keys and follows CLAUDE_CONFIG_DIR" {
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cc"; mkdir -p "$CLAUDE_CONFIG_DIR"
  echo '{"theme":"dark"}' > "$CLAUDE_CONFIG_DIR/.claude.json"
  config $'version: 1\nproject: demo'; bash "$S/10-validate.sh"
  bash "$S/20-onboarding.sh"
  [ "$(jq -r .theme "$CLAUDE_CONFIG_DIR/.claude.json")" = dark ]
  [ "$(jq -r .hasCompletedOnboarding "$CLAUDE_CONFIG_DIR/.claude.json")" = true ]
}

@test "20 --check warns about missing onboarding and changes nothing" {
  config $'version: 1\nproject: demo'; bash "$S/10-validate.sh"
  run bash "$S/20-onboarding.sh" --check
  [ "$status" -eq 2 ]
  [ ! -f "$HOME/.claude.json" ]
}

# --- 30-git
@test "30 sets the identity from config, else from GIT_AUTHOR_*, and exports it" {
  config $'version: 1\nproject: demo\ngit:\n  user_name: Cfg Name'; bash "$S/10-validate.sh"
  GIT_AUTHOR_EMAIL=env@example.com run bash "$S/30-git.sh"
  [ "$status" -eq 0 ]
  [ "$(git config --global user.name)" = "Cfg Name" ]
  [ "$(git config --global user.email)" = env@example.com ]
  grep -q '^export GIT_COMMITTER_NAME=Cfg\\ Name$' "$AGENTIC_STATE/env"
}

@test "30 wires the credential helper for git.host without writing the token" {
  config $'version: 1\nproject: demo\ngit:\n  host: git.example.com'; bash "$S/10-validate.sh"
  GH_TOKEN=supersecret run bash "$S/30-git.sh"
  [ "$status" -eq 0 ]
  run grep -q supersecret "$AGENTIC_STATE/env"
  [ "$status" -ne 0 ]
  grep -q 'credential.https://git.example.com.helper' "$AGENTIC_STATE/env"
  grep -q '^export GH_HOST=git.example.com$' "$AGENTIC_STATE/env"
  out="$(GH_TOKEN=supersecret bash -c "source '$AGENTIC_STATE/env'; printf 'protocol=https\nhost=git.example.com\n\n' | git credential fill")"
  [[ "$out" == *"password=supersecret"* ]]
}

@test "30 with a token rewrites git@ and ssh:// URLs for git.host to https" {
  config $'version: 1\nproject: demo\ngit:\n  host: git.example.com'; bash "$S/10-validate.sh"
  GH_TOKEN=supersecret bash "$S/30-git.sh"
  run bash -c "source '$AGENTIC_STATE/env'; git ls-remote --get-url git@git.example.com:team/x.git; git ls-remote --get-url ssh://git@git.example.com/team/y.git"
  [ "${lines[0]}" = https://git.example.com/team/x.git ]
  [ "${lines[1]}" = https://git.example.com/team/y.git ]
}

@test "30 without a token sets no helper" {
  config $'version: 1\nproject: demo'; bash "$S/10-validate.sh"
  run bash "$S/30-git.sh"
  [ "$status" -eq 0 ]
  ! grep -q GIT_CONFIG_COUNT "$AGENTIC_STATE/env"
}
