#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  unset AGENTIC_OPT
  C="$BATS_TEST_TMPDIR/dot-agentic"
  cp -r "$REPO_ROOT/tests/fixtures/render" "$C"
  rm -f "$C/Dockerfile.expected"
  mkdir -p "$C/certs"; touch "$C/certs/test.crt"
  R="$REPO_ROOT/derive/render-dockerfile.sh"
}

normalise() { sed -E 's/agentic\.config\.hash="[0-9a-f]+"/agentic.config.hash="HASH"/'; }

@test "renders the golden Dockerfile" {
  run bash -c "bash '$R' '$C' | sed -E 's/agentic\\.config\\.hash=\"[0-9a-f]+\"/agentic.config.hash=\"HASH\"/'"
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "$REPO_ROOT/tests/fixtures/render/Dockerfile.expected"
}

@test "without certs, extra Dockerfile, on-build hook or plugins those parts are left out" {
  rm -rf "$C/certs" "$C/Dockerfile.extra" "$C/hooks"
  printf 'plugins:\n  claude: []\n' >> "$C/agentic.yaml"
  run bash "$R" "$C"
  [ "$status" -eq 0 ]
  [[ "$output" != *"update-ca-certificates"* ]]
  [[ "$output" != *"Dockerfile.extra"* ]]
  [[ "$output" != *"on-build"* ]]
  [[ "$output" != *"agentic-install-plugins"* ]]
}

@test "an invalid config fails with the validation errors" {
  printf 'version: 1\nproject: demo\nfoo: 1\n' > "$C/agentic.yaml"
  run bash "$R" "$C"
  [ "$status" -eq 1 ]
  [[ "$output" == *".foo: unknown key"* ]]
}

@test "a tool without a preset in the image fails" {
  printf 'version: 1\nproject: demo\ntools:\n  hello: "1.0"\n' > "$C/agentic.yaml"
  run bash "$R" "$C"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tools.hello: no preset hello in this image"* ]]
}

@test "paths outside .agentic/ are refused" {
  printf 'version: 1\nproject: demo\ncerts: ../certs\n' > "$C/agentic.yaml"
  mkdir -p "$BATS_TEST_TMPDIR/certs"; touch "$BATS_TEST_TMPDIR/certs/x.crt"
  run bash "$R" "$C"
  [ "$status" -eq 1 ]
  [[ "$output" == *"certs: ../certs must be inside .agentic/"* ]]
}

@test "the config hash changes with the config" {
  a="$(bash "$R" "$C" | grep -o 'config.hash="[0-9a-f]*"')"
  sed -i 's/1.9.8/1.9.7/' "$C/agentic.yaml"
  b="$(bash "$R" "$C" | grep -o 'config.hash="[0-9a-f]*"')"
  [ "$a" != "$b" ]
}
