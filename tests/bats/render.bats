#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  unset AGENTIC_OPT
  C="$BATS_TEST_TMPDIR/dot-agentic"
  cp -r "$REPO_ROOT/tests/fixtures/render" "$C"
  rm -f "$C/Dockerfile.expected"
  R="$REPO_ROOT/derive/render-dockerfile.sh"
}

normalise() { sed -E 's/agentic\.config\.hash="[0-9a-f]+"/agentic.config.hash="HASH"/'; }

@test "renders the golden Dockerfile" {
  run bash -c "bash '$R' '$C' | sed -E 's/agentic\\.config\\.hash=\"[0-9a-f]+\"/agentic.config.hash=\"HASH\"/'"
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "$REPO_ROOT/tests/fixtures/render/Dockerfile.expected"
}

@test "without an extra Dockerfile that part is left out" {
  rm -f "$C/Dockerfile.extra"
  run bash "$R" "$C"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Dockerfile.extra"* ]]
}

@test "an invalid config fails with the validation errors" {
  printf 'version: 2\nproject: demo\nfoo: 1\n' > "$C/agentic.yaml"
  run bash "$R" "$C"
  [ "$status" -eq 1 ]
  [[ "$output" == *".foo: unknown key"* ]]
}

@test "a tool without a preset in the image fails" {
  printf 'version: 2\nproject: demo\ntools:\n  hello: "1.0"\n' > "$C/agentic.yaml"
  run bash "$R" "$C"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tools.hello: no preset hello in this image"* ]]
}

@test "paths outside .agentic/ are refused" {
  printf 'version: 2\nproject: demo\ntools:\n  extra_dockerfile: ../Dockerfile.x\n' > "$C/agentic.yaml"
  run bash "$R" "$C"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tools.extra_dockerfile: ../Dockerfile.x must be inside .agentic/"* ]]
}

@test "the config hash changes with the config" {
  a="$(bash "$R" "$C" | grep -o 'config.hash="[0-9a-f]*"')"
  sed -i 's/1.9.8/1.9.7/' "$C/agentic.yaml"
  b="$(bash "$R" "$C" | grep -o 'config.hash="[0-9a-f]*"')"
  [ "$a" != "$b" ]
}

@test "a .. segment cannot escape .agentic/" {
  printf 'RUN echo outside\n' > "$BATS_TEST_TMPDIR/outside"
  printf 'version: 2\nproject: demo\ntools:\n  extra_dockerfile: .agentic/../../outside\n' > "$C/agentic.yaml"
  run bash "$R" "$C"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tools.extra_dockerfile: .agentic/../../outside must be inside .agentic/"* ]]
}
