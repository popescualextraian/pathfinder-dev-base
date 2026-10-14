#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

setup() {
  make_tmp_home
  A="$REPO_ROOT/bin/agentic"
  # a folder holding two repositories, with the project config at the top
  M="$BATS_TEST_TMPDIR/multi"
  mkdir -p "$M/.agentic"
  git init -q "$M/api"; git init -q "$M/web"
  printf 'version: 2\nproject: demo\nlayout: multi\n' > "$M/.agentic/agentic.yaml"
}

# shellcheck source=../../lib/host/common.sh
lib() { bash -c "source '$REPO_ROOT/lib/host/common.sh'; $1"; }

@test "project_root is the nearest folder with .agentic/agentic.yaml, not the repository git names" {
  [ "$(cd "$M/api" && lib project_root)" = "$M" ]
  [ "$(cd "$M" && lib project_root)" = "$M" ]
  mkdir -p "$BATS_TEST_TMPDIR/plain/sub"
  [ "$(cd "$BATS_TEST_TMPDIR/plain/sub" && lib project_root)" = "$BATS_TEST_TMPDIR/plain/sub" ]
  [ "$(AGENTIC_PROJECT="$M/web" lib project_root)" = "$M" ]
}

@test "project_root works from a working directory that was deleted and recreated" {
  run bash -c "cd '$M' && cp -a '$M' '$M.new' && rm -rf '$M' && mv '$M.new' '$M' && source '$REPO_ROOT/lib/host/common.sh' && project_root"
  [ "$status" -eq 0 ]
  [ "$output" = "$M" ]
}

@test "yaml_set_top replaces a top-level key or appends it, and leaves nested keys alone" {
  f="$BATS_TEST_TMPDIR/y.yaml"
  printf 'version: 2\nharness:\n  target: nested\n' > "$f"
  lib "yaml_set_top '$f' target api"
  [ "$(cat "$f")" = "$(printf 'version: 2\nharness:\n  target: nested\ntarget: api')" ]
  lib "yaml_set_top '$f' target web"
  [ "$(grep -c '^target:' "$f")" = 1 ]
  grep -qx 'target: web' "$f"
}

@test "yaml_set_top keeps the file mode and leaves no temp file" {
  f="$BATS_TEST_TMPDIR/y.yaml"
  printf 'version: 2\n' > "$f"; chmod 644 "$f"
  lib "yaml_set_top '$f' target api"
  [ "$(stat -c %a "$f")" = 644 ]
  [ -z "$(ls "$BATS_TEST_TMPDIR" | grep '^y\.yaml\.' || true)" ]
}

@test "yaml_set_top writes through a symlinked agentic.yaml and keeps the symlink" {
  real="$BATS_TEST_TMPDIR/real.yaml"; f="$BATS_TEST_TMPDIR/link.yaml"
  printf 'version: 2\n' > "$real"; ln -s "$real" "$f"
  lib "yaml_set_top '$f' target api"
  [ -L "$f" ]
  grep -qx 'target: api' "$real"
}

# shellcheck source=../../lib/host/layout.sh
lay() { bash -c "source '$REPO_ROOT/lib/host/common.sh'; source '$REPO_ROOT/lib/host/layout.sh'; $1"; }

@test "repo_dirs lists the direct subfolders with .git, sorted, and skips symlinks and files" {
  ln -s "$M/api" "$M/link"
  mkdir -p "$M/docs"; : > "$M/README"
  [ "$(lay "repo_dirs '$M'" | tr '\n' ' ')" = "api web " ]
}

@test "valid_target refuses a symlink, dot names, a slash and a folder without .git" {
  ln -s "$M/api" "$M/link"; mkdir -p "$M/docs"
  lay "valid_target '$M' api"
  for t in link . .. 'api/x' docs nope ''; do
    run lay "valid_target '$M' '$t'"; [ "$status" -ne 0 ]
  done
}

@test "detect_layout says single, multi or nothing" {
  [ "$(lay "detect_layout '$M'")" = multi ]
  [ "$(lay "detect_layout '$M/api'")" = single ]
  mkdir -p "$BATS_TEST_TMPDIR/none"
  [ -z "$(lay "detect_layout '$BATS_TEST_TMPDIR/none'")" ]
}

@test "yaml_set_top removes its temp file and fails when the write fails" {
  [ "$(id -u)" != 0 ] || skip "root reads a mode 000 file"
  f="$BATS_TEST_TMPDIR/y.yaml"
  printf 'version: 2\n' > "$f"; chmod 000 "$f"
  run lib "yaml_set_top '$f' target api"
  [ "$status" -ne 0 ]
  [ -z "$(ls "$BATS_TEST_TMPDIR" | grep '^y\.yaml\.' || true)" ]
}

ag() { (cd "$M" && bash "$A" "$@" </dev/null); }

@test "target NAME writes the default; target prints it and the candidates" {
  run ag target
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'target: (none)\nrepositories: api web')" ]
  run ag target web
  [ "$status" -eq 0 ]; [ "$output" = "target: web" ]
  grep -qx 'target: web' "$M/.agentic/agentic.yaml"
  run ag target api
  [ "$(grep -c '^target:' "$M/.agentic/agentic.yaml")" = 1 ]
  [ "$(ag target | head -n 1)" = "target: api" ]
}

@test "help lists target after dev's description, not between dev and it" {
  run bash "$A" help
  [[ "$(grep -A1 'dev \[stop|recreate|status\]' <<<"$output" | tail -n 1)" == *"persistent dev container"* ]]
  grep -q 'target \[NAME\].*default repository' <<<"$output"
}

@test "target refuses an unknown name, a single-repository project and a missing layout" {
  run ag target nope
  [ "$status" -eq 1 ]; [[ "$output" == *"nope is not a repository of the project; choose one of: api web"* ]]
  run ! grep -q '^target:' "$M/.agentic/agentic.yaml"
  S="$M/api"; mkdir -p "$S/.agentic"; printf 'version: 2\nproject: one\nlayout: single\n' > "$S/.agentic/agentic.yaml"
  run bash -c "cd '$S' && bash '$A' target x"
  [ "$status" -eq 1 ]; [[ "$output" == *"a single-repository project has no target to set"* ]]
  printf 'version: 2\nproject: demo\n' > "$M/.agentic/agentic.yaml"
  run ag target api
  [ "$status" -eq 1 ]; [[ "$output" == *"no layout in .agentic/agentic.yaml; re-run agentic init"* ]]
}
