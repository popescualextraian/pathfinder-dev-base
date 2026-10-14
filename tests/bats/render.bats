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

@test "a CA copy comes before the tools and refreshes the trust store" {
  run bash "$R" "$C"
  [ "$status" -eq 0 ]
  ca="$(grep -n 'ca-certificates/corp.crt' <<<"$output" | cut -d: -f1)"
  upd="$(grep -n '^RUN update-ca-certificates' <<<"$output" | cut -d: -f1)"
  java="$(grep -n 'java.sh install' <<<"$output" | cut -d: -f1)"
  [ "$ca" -lt "$upd" ]
  [ "$upd" -lt "$java" ]
}

@test "build lines become one RUN each, in order, after the baseline" {
  run bash "$R" "$C"
  base="$(grep -n 'agentic-apply","--baseline' <<<"$output" | cut -d: -f1)"
  plug="$(grep -nF '"add plugin r@m"' <<<"$output" | cut -d: -f1)"
  copy="$(grep -nF '"files/settings.xml","/home/dev/.m2/settings.xml"' <<<"$output" | cut -d: -f1)"
  mcp="$(grep -nF '"add mcp x --env TOKEN -- run-x '"'"'a b'"'"'"' <<<"$output" | cut -d: -f1)"
  [ "$base" -lt "$plug" ]
  [ "$plug" -lt "$copy" ]
  [ "$copy" -lt "$mcp" ]
  grep -qF 'RUN ["agentic-apply","--finish"]' <<<"$output"
}

@test "run-phase lines are not in the Dockerfile but in the run label" {
  run bash "$R" "$C"
  if grep -q 'mount ~/.aws' <<<"$(grep -v '^LABEL' <<<"$output")"; then return 1; fi
  label="$(sed -nE 's/.*agentic\.run="([^"]*)".*/\1/p' <<<"$output")"
  run bash -c "base64 -d <<<'$label'"
  [ "${lines[0]}" = $'mount\t~/.aws\t/home/dev/.aws\tro\tmount ~/.aws /home/dev/.aws --readonly' ]
  [ "${lines[1]}" = $'volume\tm2\t/home/dev/.m2\t\tvolume m2 /home/dev/.m2' ]
}

@test "project assets are copied when present" {
  run bash "$R" "$C"
  grep -qF 'COPY --chown=dev ["skills","/opt/agentic/project/skills"]' <<<"$output"
  if grep -q '/opt/agentic/project/agents' <<<"$output"; then return 1; fi
}

@test "a copy whose source is missing fails the render" {
  printf '  - copy files/missing /x\n' >> "$C/agentic.yaml"
  run bash "$R" "$C"
  [ "$status" -eq 1 ]
  [[ "$output" == *"files/missing is not in .agentic/"* ]]
}

@test "without setup lines there is no baseline and no finish" {
  yq -i 'del(.setup)' "$C/agentic.yaml"
  run bash "$R" "$C"
  if grep -q agentic-apply <<<"$output"; then return 1; fi
}
