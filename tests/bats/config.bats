#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  P="$BATS_TEST_TMPDIR/project/.agentic"
  mkdir -p "$P"
  AC="$REPO_ROOT/image/bin/agentic-config"
}

write() { printf '%s\n' "$2" > "$1"; }

@test "resolve merges base defaults, overlay defaults and the project, project last" {
  write "$AGENTIC_DIR/defaults/agentic.yaml" $'docker:\n  socket: true\nharness:\n  default: copilot'
  write "$P/agentic.yaml" $'version: 2\nproject: demo\nharness:\n  default: claude'
  run "$AC" resolve "$P"
  [ "$status" -eq 0 ]
  [ "$(jq -r .project <<<"$output")" = demo ]
  [ "$(jq -r .docker.socket <<<"$output")" = true ]
  [ "$(jq -r .harness.default <<<"$output")" = claude ]
  [ "$(jq -c .targets <<<"$output")" = '["claude","copilot"]' ]
}

@test "lists from the project replace the defaults" {
  write "$P/agentic.yaml" $'version: 2\nproject: demo\ntools:\n  apt: [tree]\n  python: ["3.11"]'
  run "$AC" resolve "$P"
  [ "$(jq -c .tools.python <<<"$output")" = '["3.11"]' ]
  [ "$(jq -c .tools.apt <<<"$output")" = '["tree"]' ]
}

@test "the smallest valid file validates" {
  write "$P/agentic.yaml" $'version: 2\nproject: demo'
  run "$AC" validate "$P"
  [ "$status" -eq 0 ]
}

@test "a missing project is reported" {
  write "$P/agentic.yaml" 'version: 2'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *".project: is required"* ]]
}

@test "unknown keys and wrong types are reported with their path" {
  write "$P/agentic.yaml" $'version: 2\nproject: demo\ndocker:\n  socket: "yes"\nfoo: 1'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *".docker.socket: expected boolean, got string"* ]]
  [[ "$output" == *".foo: unknown key"* ]]
}

@test "project names are restricted to a safe pattern" {
  write "$P/agentic.yaml" $'version: 2\nproject: "My App"'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *".project: does not match"* ]]
}

@test "java accepts false or versions with a default inside them" {
  write "$P/agentic.yaml" $'version: 2\nproject: demo\ntools:\n  java: {versions: [17, 11], default: 11}'
  run "$AC" validate "$P"
  [ "$status" -eq 0 ]
  write "$P/agentic.yaml" $'version: 2\nproject: demo\ntools:\n  java: {versions: [17], default: 8}'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *".tools.java.default: 8 is not in versions"* ]]
}

@test "a version preset accepts false or a version string, not true" {
  write "$P/agentic.yaml" $'version: 2\nproject: demo\ntools:\n  terraform: true'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *".tools.terraform: matches none of the allowed forms"* ]]
}

@test "a preset this image lacks is reported by validate, as the build would" {
  write "$P/agentic.yaml" $'version: 2\nproject: demo\ntools:\n  hello: "1.0"'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *".tools.hello: no preset hello in this image"* ]]
}

@test "a preset an overlay adds to the image passes validate" {
  rm "$AGENTIC_DIR/tools"; cp -r "$REPO_ROOT/image/tools" "$AGENTIC_DIR/tools"
  printf '#!/usr/bin/env bash\n' > "$AGENTIC_DIR/tools/hello.sh"
  write "$P/agentic.yaml" $'version: 2\nproject: demo\ntools:\n  hello: "1.0"'
  run "$AC" validate "$P"
  [ "$status" -eq 0 ]
}

@test "a top-level key placed under tools gets a hint" {
  write "$P/agentic.yaml" $'version: 2\nproject: demo\ntools:\n  setup: x'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *".tools.setup: no preset setup in this image; setup is a top-level key, not a tool"* ]]
}

@test "build paths outside .agentic/ are reported by validate" {
  write "$P/agentic.yaml" $'version: 2\nproject: demo\ntools:\n  extra_dockerfile: .agentic/../x'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *".tools.extra_dockerfile: .agentic/../x must be inside .agentic/"* ]]
}

@test "a literal secret in a setup line is rejected, a reference is accepted" {
  write "$P/agentic.yaml" $'version: 2
project: demo
setup:
  - add mcp docs --env API_TOKEN=abc123 -- run'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"API_TOKEN: literal secret"* ]]
  write "$P/agentic.yaml" $'version: 2
project: demo
setup:
  - add mcp docs --env API_TOKEN -- run'
  run "$AC" validate "$P"
  [ "$status" -eq 0 ]
}

@test "config_find prefers the mount, then /work/.agentic, then AGENTIC_CONFIG_B64" {
  source "$AGENTIC_DIR/lib/common.sh"; source "$AGENTIC_DIR/lib/config.sh"
  export AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/mount" AGENTIC_WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$AGENTIC_CONFIG_MOUNT" "$AGENTIC_WORK/.agentic"
  export AGENTIC_CONFIG_B64; AGENTIC_CONFIG_B64="$(printf 'version: 2\nproject: fromenv\n' | base64 -w0)"
  [ "$(config_find)" = "$AGENTIC_STATE/env-config" ]
  [ "$(yq .project "$AGENTIC_STATE/env-config/agentic.yaml")" = fromenv ]
  touch "$AGENTIC_WORK/.agentic/agentic.yaml"
  [ "$(config_find)" = "$AGENTIC_WORK/.agentic" ]
  touch "$AGENTIC_CONFIG_MOUNT/agentic.yaml"
  [ "$(config_find)" = "$AGENTIC_CONFIG_MOUNT" ]
}

@test "agentic-config says so when AGENTIC_CONFIG_B64 is not valid base64" {
  export AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/none" AGENTIC_WORK="$BATS_TEST_TMPDIR/none"
  AGENTIC_CONFIG_B64='%%%not-base64' run "$AC" validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"AGENTIC_CONFIG_B64 is not valid base64"* ]]
}

@test "config_path maps .agentic/ paths into the config directory" {
  source "$AGENTIC_DIR/lib/common.sh"
  mkdir -p "$AGENTIC_STATE"; echo /agentic-config > "$AGENTIC_STATE/config-dir"
  [ "$(config_path .agentic/certs)" = /agentic-config/certs ]
  [ "$(config_path /abs/x)" = /abs/x ]
}

@test "get reads the resolved config" {
  mkdir -p "$AGENTIC_STATE"; echo '{"project":"demo","docker":{"socket":false}}' > "$AGENTIC_STATE/config.json"
  run "$AC" get .project
  [ "$output" = demo ]
  run "$AC" get .docker.socket
  [ "$output" = false ]
}

@test "apt pins may not carry shell metacharacters" {
  write "$P/agentic.yaml" $'version: 2\nproject: demo\ntools:\n  apt: ["tree=1;id"]'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  write "$P/agentic.yaml" $'version: 2\nproject: demo\ntools:\n  apt: ["tree=2.1.1-2"]'
  run "$AC" validate "$P"
  [ "$status" -eq 0 ]
}

@test "version 1 is refused with re-run agentic init" {
  write "$P/agentic.yaml" $'version: 1\nproject: demo'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"re-run agentic init"* ]]
}

@test "version 2 with setup lines and targets is valid" {
  write "$P/agentic.yaml" $'version: 2\nproject: demo\ntargets: [claude]\nsetup:\n  - add plugin a@b\n  - volume m2 /home/dev/.m2'
  run "$AC" validate "$P"
  [ "$status" -eq 0 ]
}

@test "a bad setup line is reported with its index" {
  write "$P/agentic.yaml" $'version: 2\nproject: demo\nsetup:\n  - add plugin nope'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *".setup[0]: usage: add plugin NAME@MARKETPLACE"* ]]
}

@test "removed version 1 keys are unknown" {
  for k in 'git: {host: x}' 'certs: .agentic/certs' 'plugins: {claude: []}' 'mcp: {}' 'skills: .agentic/skills'; do
    write "$P/agentic.yaml" "$(printf 'version: 2\nproject: demo\n%s' "$k")"
    run "$AC" validate "$P"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown key"* ]]
  done
}

@test "an overlay default with setup: is refused" {
  write "$AGENTIC_DIR/defaults/agentic.yaml" 'setup: [add plugin a@b]'
  write "$P/agentic.yaml" $'version: 2\nproject: demo'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"overlay defaults cannot hold setup:"* ]]
}
