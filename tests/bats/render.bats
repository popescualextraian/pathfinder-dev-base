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

apps_label() { sed -nE 's/.*agentic\.apps="([^"]*)".*/\1/p' <<<"$1"; }

@test "no apps gives an empty apps label" {
  run bash "$R" "$C"
  [ "$(apps_label "$output")" = "e30=" ]
}

@test "the apps label holds only ports, url and autostart" {
  cp -r "$C" "$BATS_TEST_TMPDIR/ac"
  cat >> "$BATS_TEST_TMPDIR/ac/agentic.yaml" <<'YAML'
apps:
  web:
    run: npm start
    ports: [3000]
    env: {NODE_ENV: development}
    prepare: npm ci
    autostart: true
  api:
    run: ./serve
    url: /health
YAML
  run bash "$R" "$BATS_TEST_TMPDIR/ac"
  [ "$status" -eq 0 ]
  run bash -c "base64 -d <<<'$(apps_label "$output")'"
  [ "$(jq -cS . <<<"$output")" = '{"api":{"autostart":false,"ports":[],"url":"/health"},"web":{"autostart":true,"ports":[3000],"url":"/"}}' ]
}

# fake_compose JSON: a docker on PATH whose `compose ... config` prints JSON and logs its arguments.
fake_compose() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '%s' "$1" > "$BATS_TEST_TMPDIR/model.json"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/compose.args"\ncat "%s/model.json"\n' \
    "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/docker"
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}
stack_cfg() { printf 'version: 2\nproject: demo\nstack: [%s]\n' "$1" > "$C/agentic.yaml"; }

@test "a stack writes its files, in order, as the label agentic.stack and is checked without .env" {
  fake_compose '{"services":{"db":{"image":"postgres:17"}}}'
  printf 'services:\n  db:\n    image: postgres:17\n' > "$C/a.yaml"; printf 'services: {}\n' > "$C/b.yaml"
  stack_cfg '.agentic/a.yaml, .agentic/b.yaml'
  run bash "$R" "$C"
  [ "$status" -eq 0 ]
  b64="$(grep -o 'agentic.stack="[^"]*"' <<<"$output" | sed 's/^agentic.stack="//; s/"$//')"
  [ "$(base64 -d <<<"$b64" | jq -c '[.[].file]')" = '[".agentic/a.yaml",".agentic/b.yaml"]' ]
  [ "$(base64 -d <<<"$b64" | jq -r '.[0].content')" = "$(cat "$C/a.yaml")" ]
  grep -qx -- '--env-file' "$BATS_TEST_TMPDIR/compose.args"
  grep -qx /dev/null "$BATS_TEST_TMPDIR/compose.args"
  [ "$(grep -A1 -x -- '-f' "$BATS_TEST_TMPDIR/compose.args" | grep -v -- '^-' | tr '\n' ' ')" = "$C/a.yaml $C/b.yaml " ]
}

@test "without a stack there is no agentic.stack label" {
  run bash "$R" "$C"
  [ "$status" -eq 0 ]
  [[ "$output" != *"agentic.stack="* ]]
}

@test "a stack file outside .agentic/ or missing fails the build" {
  fake_compose '{"services":{}}'
  stack_cfg 'compose.yaml'
  run bash "$R" "$C"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stack: compose.yaml must be inside .agentic/"* ]]
  stack_cfg '.agentic/missing.yaml'
  run bash "$R" "$C"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stack: .agentic/missing.yaml does not exist"* ]]
}

@test "a stack that breaks the rules fails the build, naming the service and the rule" {
  fake_compose '{"services":{"db":{"image":"x","privileged":true}}}'
  printf 'services: {}\n' > "$C/a.yaml"
  stack_cfg '.agentic/a.yaml'
  run bash "$R" "$C"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stack: service db: privileged"* ]]
}
