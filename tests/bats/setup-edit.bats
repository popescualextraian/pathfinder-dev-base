#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  D="$BATS_TEST_TMPDIR/dot-agentic"; mkdir -p "$D/files" "$D/agents"
  printf 'version: 2\nproject: demo\n# keep me\nsetup:\n  - add plugin a@m   # first\n' > "$D/agentic.yaml"
  E="$REPO_ROOT/image/bin/agentic-setup-edit"
}

lines() { yq -o=json '.setup' "$D/agentic.yaml" | jq -r '.[]'; }

@test "add appends a line and keeps comments" {
  run "$E" --dir "$D" add "add mcp x -- run-x"
  [ "$status" -eq 0 ]
  [ "$output" = "added: add mcp x -- run-x" ]
  [ "$(lines | tail -1)" = "add mcp x -- run-x" ]
  grep -q '# keep me' "$D/agentic.yaml"
}

@test "add creates setup: when the file has none" {
  printf 'version: 2\nproject: demo\n' > "$D/agentic.yaml"
  "$E" --dir "$D" add "volume m2 /home/dev/.m2"
  [ "$(lines)" = "volume m2 /home/dev/.m2" ]
}

@test "the same line twice is added once" {
  run "$E" --dir "$D" add "add plugin a@m"
  [ "$output" = "already there: add plugin a@m" ]
  [ "$(lines | wc -l)" -eq 1 ]
}

@test "same command, key and targets replaces the old line in place" {
  "$E" --dir "$D" add "add mcp x -- old"
  "$E" --dir "$D" add "volume v /v"
  run "$E" --dir "$D" add "add mcp x -- new"
  [ "$output" = "replaced: add mcp x -- old" ]
  [ "$(lines | sed -n 2p)" = "add mcp x -- new" ]
}

@test "a plugin for another target is a second line" {
  "$E" --dir "$D" add "add plugin a@m --target copilot"
  # a@m without --target means both; copilot only is a different ident
  [ "$(lines | wc -l)" -eq 2 ]
}

@test "an invalid line is refused and the file is unchanged" {
  before="$(cat "$D/agentic.yaml")"
  run "$E" --dir "$D" add "add plugin nope"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid line: usage: add plugin"* ]]
  [ "$(cat "$D/agentic.yaml")" = "$before" ]
}

@test "copy needs its source in .agentic/ and warns about secrets" {
  run "$E" --dir "$D" add "copy files/x /x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"files/x is not in .agentic/"* ]]
  touch "$D/files/id_rsa"
  run "$E" --dir "$D" add "copy files/id_rsa /home/dev/.ssh/id_rsa"
  [ "$status" -eq 0 ]
  [[ "$output" == *"looks like a secret"* ]]
}

@test "an asset for the default targets needs no line" {
  touch "$D/agents/db.md"
  run "$E" --dir "$D" add "add agent agents/db.md"
  [ "$output" = "agents/db.md installs to every target; no line needed" ]
  run "$E" --dir "$D" add "add agent agents/db.md --target claude"
  [ "$output" = "added: add agent agents/db.md --target claude" ]
}

@test "remove deletes every line with the key, or only the given target" {
  "$E" --dir "$D" add "add plugin a@m --target copilot"
  run "$E" --dir "$D" remove plugin a@m --target copilot
  [ "$output" = "removed: add plugin a@m --target copilot" ]
  [ "$(lines)" = "add plugin a@m   # first" ] || [ "$(lines)" = "add plugin a@m" ]
  run "$E" --dir "$D" remove plugin a@m
  [ "$status" -eq 0 ]
  [ -z "$(lines)" ]
  run "$E" --dir "$D" remove plugin a@m
  [ "$status" -eq 3 ]
}

@test "list prints the phase of each line" {
  "$E" --dir "$D" add "mount ~/.aws /home/dev/.aws --readonly"
  run "$E" --dir "$D" list
  [ "${lines[0]}" = $'build\tadd plugin a@m' ]
  [ "${lines[1]}" = $'run\tmount ~/.aws /home/dev/.aws --readonly' ]
}

@test "run-args lists mounts, volumes and path workspaces" {
  "$E" --dir "$D" add "mount ~/.aws /home/dev/.aws --readonly"
  "$E" --dir "$D" add "volume m2 /home/dev/.m2"
  "$E" --dir "$D" add "add workspace ../lib"
  "$E" --dir "$D" add "add workspace https://example.com/r.git"
  run "$E" --dir "$D" run-args
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = $'mount\t~/.aws\t/home/dev/.aws\tro\tmount ~/.aws /home/dev/.aws --readonly' ]
  [ "${lines[1]}" = $'volume\tm2\t/home/dev/.m2\t\tvolume m2 /home/dev/.m2' ]
  [ "${lines[2]}" = $'bind\t../lib\t/workspaces/repos/lib\t\tadd workspace ../lib' ]
}
