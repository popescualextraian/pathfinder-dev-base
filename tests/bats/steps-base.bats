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

@test "10 without any config warns and uses the defaults" {
  run bash "$S/10-validate.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no agentic.yaml found; using defaults"* ]]
  [ "$(jq -r .project "$AGENTIC_STATE/config.json")" = default ]
  [ "$(cat "$AGENTIC_STATE/config-dir")" = "" ]
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

@test "30 without a token sets no helper" {
  config $'version: 1\nproject: demo'; bash "$S/10-validate.sh"
  run bash "$S/30-git.sh"
  [ "$status" -eq 0 ]
  ! grep -q GIT_CONFIG_COUNT "$AGENTIC_STATE/env"
}
