#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$AGENTIC_WORK/.agentic"
  E="$AGENTIC_WORK/.agentic/.env"
  X="$AGENTIC_WORK/.agentic/.env.example"
  AE="$REPO_ROOT/image/bin/agentic-env"
}

@test "names lists key names only, never values or comments" {
  printf '# a comment\nGH_TOKEN=ghp_secretvalue\nEMPTY=\n' > "$E"
  run "$AE" names
  [ "$status" -eq 0 ]
  [ "$output" = $'GH_TOKEN\nEMPTY' ]
}

@test "add appends a missing key with its value and says so without echoing the value" {
  printf 'GH_TOKEN=ghp_secretvalue' > "$E"
  run "$AE" add DB_PASSWORD localpw --comment "local database started by hooks/on-start.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "added DB_PASSWORD to .agentic/.env" ]
  [ "$(tail -n 2 "$E")" = $'# local database started by hooks/on-start.sh\nDB_PASSWORD=localpw' ]
  grep -qx 'GH_TOKEN=ghp_secretvalue' "$E"
}

@test "add never changes an existing key and never shows its value" {
  printf 'GH_TOKEN=ghp_secretvalue\n' > "$E"
  run "$AE" add GH_TOKEN other
  [ "$status" -eq 0 ]
  [ "$output" = "GH_TOKEN is already set in .agentic/.env; left unchanged" ]
  [ "$(cat "$E")" = 'GH_TOKEN=ghp_secretvalue' ]
}

@test "add without a value writes an empty placeholder for the user" {
  run "$AE" add JIRA_PERSONAL_TOKEN --comment "Jira profile > Personal Access Tokens"
  [ "$status" -eq 0 ]
  grep -qx 'JIRA_PERSONAL_TOKEN=' "$E"
}

@test "a new .env is private to the user" {
  run "$AE" add A 1
  [ "$(stat -c %a "$E")" = 600 ]
}

@test "--example writes names to .env.example, never a value" {
  run "$AE" add --example DB_USER ecr --comment "local database user"
  [ "$status" -eq 0 ]
  grep -qx 'DB_USER=' "$X"
  run grep -q ecr "$X"
  [ "$status" -ne 0 ]
  [ ! -e "$E" ]
}

@test "invalid keys and values that docker --env-file would mangle are refused" {
  run "$AE" add 'bad key' x
  [ "$status" -eq 2 ]
  run "$AE" add GOOD $'two\nlines'
  [ "$status" -eq 2 ]
  run "$AE" add GOOD '"quoted"'
  [ "$status" -eq 2 ]
  [ ! -e "$E" ]
}
