#!/usr/bin/env bats
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
