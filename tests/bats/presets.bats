#!/usr/bin/env bats
load helpers

DIR_PRESETS="java:21 maven:3.9.9 gradle:8.10 node:22 terraform:1.9.8 checkov:3.2.0 tflint:0.53.0 kubectl:1.31.0 helm:3.16.1 dotnet:8.0 go:1.22.5 glab:1.46.1"

setup() {
  make_tmp_home
  export AGENTIC_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$AGENTIC_OPT" "$BATS_TEST_TMPDIR/bin"
  # any download attempt fails the test
  printf '#!/bin/sh\necho "unexpected download: $*" >&2\nexit 99\n' > "$BATS_TEST_TMPDIR/bin/curl"
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  T="$REPO_ROOT/image/tools"
}

@test "every preset prints usage and exits 2 without a version or with an unknown command" {
  for f in "$T"/*.sh; do
    [ "$(basename "$f")" = _lib.sh ] && continue
    run bash "$f" install
    [ "$status" -eq 2 ] || { echo "$f: $status"; false; }
    run bash "$f" frobnicate 1.0
    [ "$status" -eq 2 ] || { echo "$f: $status"; false; }
  done
}

@test "env prints only KEY=VALUE lines" {
  for f in "$T"/*.sh; do
    [ "$(basename "$f")" = _lib.sh ] && continue
    run bash "$f" env 1.2.3
    [ "$status" -eq 0 ] || { echo "$f: $status $output"; false; }
    while IFS= read -r line; do
      [ -z "$line" ] || [[ "$line" =~ ^[A-Z_][A-Z0-9_]*=.+$ ]] || { echo "$f: bad line '$line'"; false; }
    done <<<"$output"
  done
}

@test "install is a no-op when the version is already present" {
  for pv in $DIR_PRESETS; do
    p="${pv%%:*}"; v="${pv#*:}"
    mkdir -p "$AGENTIC_OPT/$p/$v/bin"; touch "$AGENTIC_OPT/$p/$v/bin/marker"
    run bash "$T/$p.sh" install "$v"
    [ "$status" -eq 0 ] || { echo "$p: $status $output"; false; }
  done
}

@test "check fails when the version is missing" {
  for pv in $DIR_PRESETS; do
    p="${pv%%:*}"; v="${pv#*:}"
    run bash "$T/$p.sh" check "$v"
    [ "$status" -ne 0 ] || { echo "$p: check passed without an install"; false; }
  done
}

@test "java env points JAVA_HOME and PATH at the major" {
  run bash "$T/java.sh" env 17
  [ "${lines[0]}" = "JAVA_HOME=$AGENTIC_OPT/java/17" ]
  [ "${lines[1]}" = "PATH=$AGENTIC_OPT/java/17/bin" ]
}

@test "java install hands the new JDK to agentic-trust-java when it exists" {
  printf '#!/bin/sh\necho "$1" > "%s/trusted"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/agentic-trust-java"
  chmod +x "$BATS_TEST_TMPDIR/bin/agentic-trust-java"
  mkdir -p "$AGENTIC_OPT/java/17/bin"; touch "$AGENTIC_OPT/java/17/bin/java"
  run bash "$T/java.sh" install 17
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/trusted")" = "$AGENTIC_OPT/java/17" ]
}

@test "python uses uv's install dir and skips an installed version" {
  printf '#!/bin/sh\n[ "$1 $2" = "python find" ] && exit 0\necho "uv $*" >> "%s/uv.log"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/uv"
  chmod +x "$BATS_TEST_TMPDIR/bin/uv"
  run bash "$T/python.sh" install 3.12
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/uv.log" ]
  run bash "$T/python.sh" env 3.12
  [ "$output" = "UV_PYTHON_INSTALL_DIR=$AGENTIC_OPT/python" ]
}
