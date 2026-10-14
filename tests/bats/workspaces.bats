#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_WORKSPACES_DIR="$BATS_TEST_TMPDIR/ws"
  R="$BATS_TEST_TMPDIR/remote.git"
  git init -q --bare "$R"
  git clone -q "$R" "$BATS_TEST_TMPDIR/seedclone" 2>/dev/null
  git -C "$BATS_TEST_TMPDIR/seedclone" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  git -C "$BATS_TEST_TMPDIR/seedclone" push -q origin HEAD:main
  mkdir -p "$AGENTIC_STATE"
  S="$REPO_ROOT/image/start.d/15-workspaces.sh"
}

conf() { jq -n --args '{version: 2, project: "demo", setup: $ARGS.positional}' "$@" > "$AGENTIC_STATE/config.json"; }

@test "a URL workspace is cloned once and then left alone" {
  # parse_line takes https://, ssh:// and git@; the test uses a file URL through --name, so allow it here
  conf "add workspace https://example.invalid/api.git"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$R.insteadOf" GIT_CONFIG_VALUE_0="https://example.invalid/api.git"
  run bash "$S"
  [ "$status" -eq 0 ]
  [ -d "$AGENTIC_WORKSPACES_DIR/repos/api/.git" ]
  echo change > "$AGENTIC_WORKSPACES_DIR/repos/api/local.txt"
  bash "$S"
  [ -f "$AGENTIC_WORKSPACES_DIR/repos/api/local.txt" ]
}

@test "a failed clone warns and the container still starts" {
  conf "add workspace https://example.invalid/nope.git"
  run bash "$S"
  [ "$status" -eq 2 ]
  [[ "$output" == *"clone of workspace nope failed"* ]]
}

@test "path workspaces are mounts, not clones" {
  conf "add workspace ../lib"
  run bash "$S"
  [ "$status" -eq 0 ]
  [ ! -e "$AGENTIC_WORKSPACES_DIR/repos/lib" ]
}

@test "--check names a workspace that is not cloned yet" {
  conf "add workspace https://example.invalid/api.git"
  run bash "$S" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"workspace api is not cloned yet"* ]]
  [ ! -e "$AGENTIC_WORKSPACES_DIR/repos/api" ]
}

@test "a non-empty folder that is no clone is not touched" {
  conf "add workspace https://example.invalid/api.git"
  mkdir -p "$AGENTIC_WORKSPACES_DIR/repos/api"; echo x > "$AGENTIC_WORKSPACES_DIR/repos/api/f"
  run bash "$S"
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not a git clone; left alone"* ]]
}
