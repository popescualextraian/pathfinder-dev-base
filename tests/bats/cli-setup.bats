#!/usr/bin/env bats
load helpers
load docker-stub

setup() {
  make_tmp_home
  install_docker_stub
  export AGENTIC_DATA="$BATS_TEST_TMPDIR/data" AGENTIC_WORKSPACES="$BATS_TEST_TMPDIR/ws"
  PROJ="$BATS_TEST_TMPDIR/proj"; mkdir -p "$PROJ/.agentic"; git init -q "$PROJ"
  printf 'version: 2\nproject: demo\n' > "$PROJ/.agentic/agentic.yaml"
  A="$REPO_ROOT/bin/agentic"
}
in_project() { (cd "$PROJ" && bash -c "source '$A'; $1"); }
edit_call() { docker_sub run | tail -n +2; }

@test "add plugin passes one line to the edit, in a throwaway container from the base image" {
  run in_project 'main add plugin r@m --target claude --no-build'
  [ "$status" -eq 0 ]
  run edit_call
  [[ "$output" == *"/opt/agentic/bin/agentic-setup-edit"* ]]
  [[ "$output" == *"$PROJ/.agentic:/agentic-config"* ]]
  [ "$(tail -1 <<<"$output")" = "add plugin r@m --target claude" ]
}

@test "a word with spaces is quoted in the line" {
  in_project 'main add mcp x --no-build -- run "a b"'
  [ "$(edit_call | tail -1)" = "add mcp x -- run 'a b'" ]
}

@test "--no-build and --yes after -- belong to the command" {
  in_project 'main add mcp x --no-build -- run --yes'
  [ "$(edit_call | tail -1)" = "add mcp x -- run --yes" ]
}

@test "copy brings an outside file into .agentic/files and records the local path" {
  echo s > "$BATS_TEST_TMPDIR/settings.xml"
  in_project "main copy '$BATS_TEST_TMPDIR/settings.xml' /home/dev/.m2/settings.xml --no-build"
  [ -f "$PROJ/.agentic/files/settings.xml" ]
  [ "$(edit_call | tail -1)" = "copy files/settings.xml /home/dev/.m2/settings.xml" ]
}

@test "copy refuses a different file under the same name" {
  mkdir -p "$PROJ/.agentic/files"; echo a > "$PROJ/.agentic/files/x"; echo b > "$BATS_TEST_TMPDIR/x"
  run in_project "main copy '$BATS_TEST_TMPDIR/x' /x --no-build"
  [ "$status" -eq 1 ]
  [[ "$output" == *"exists and differs"* ]]
}

@test "home path written as ~: a shell-expanded home in mount is stored as ~" {
  mkdir -p "$HOME/.aws"
  in_project "main mount '$HOME/.aws' /home/dev/.aws --readonly --no-build"
  [ "$(edit_call | tail -1)" = "mount ~/.aws /home/dev/.aws --readonly" ]
}

@test "a mount source inside the project is stored relative to the root" {
  mkdir -p "$PROJ/data"
  in_project "main mount '$PROJ/data' /data --no-build"
  [ "$(edit_call | tail -1)" = "mount data /data" ]
}

@test "add skill copies an outside folder into .agentic/skills" {
  mkdir -p "$BATS_TEST_TMPDIR/review"; echo x > "$BATS_TEST_TMPDIR/review/SKILL.md"
  in_project "main add skill '$BATS_TEST_TMPDIR/review' --no-build"
  [ -f "$PROJ/.agentic/skills/review/SKILL.md" ]
  [ "$(edit_call | tail -1)" = "add skill skills/review" ]
}

@test "remove workspace keeps clone and says where it is" {
  mkdir -p "$AGENTIC_WORKSPACES/demo/repos/api"
  DOCKER_RUN_OUT="removed: add workspace https://example.com/api.git" run in_project 'main remove workspace api --no-build'
  [ "$status" -eq 0 ]
  [ -d "$AGENTIC_WORKSPACES/demo/repos/api" ]
  [[ "$output" == *"the clone stays in $AGENTIC_WORKSPACES/demo/repos/api"* ]]
}

@test "remove skill deletes its folder in .agentic" {
  mkdir -p "$PROJ/.agentic/skills/review"
  DOCKER_RUN_RC=3 run in_project 'main remove skill skills/review --no-build'
  [ "$status" -eq 0 ]
  [ ! -e "$PROJ/.agentic/skills/review" ]
}

@test "after a change the build runs, and a running dev container is not recreated without --yes" {
  export DOCKER_RUNNING=true DOCKER_LABEL=current
  run in_project 'main add plugin r@m </dev/null'
  docker_sub build >/dev/null
  [[ "$output" == *"run agentic dev recreate to use it"* ]]
  if grep -q -- '--- rm' "$DOCKER_LOG"; then return 1; fi
}

@test "--yes recreates the running dev container without attaching" {
  export DOCKER_RUNNING=true DOCKER_LABEL=current
  run in_project 'main add plugin r@m --yes'
  grep -q -- '--- rm' "$DOCKER_LOG"
  if grep -q -- '--- exec' "$DOCKER_LOG"; then return 1; fi
}

@test "remove of an asset deletes only a path under its own folder" {
  mkdir -p "$PROJ/src" "$PROJ/.agentic/skills/a" "$PROJ/.agentic/files"
  echo keep > "$PROJ/src/f"
  for k in "skill ../src" "skill skills" "command files" "agent instructions.md" "skill skills/../files"; do
    DOCKER_RUN_RC=3 run in_project "main remove $k --no-build"
    [ "$status" -ne 0 ]
  done
  [ -f "$PROJ/src/f" ]
  [ -d "$PROJ/.agentic/skills/a" ]
  [ -d "$PROJ/.agentic/files" ]
}

@test "remove of an asset with --target narrows and keeps the folder" {
  mkdir -p "$PROJ/.agentic/skills/x"
  DOCKER_RUN_RC=3 run in_project 'main remove skill skills/x --target copilot --no-build'
  [ -d "$PROJ/.agentic/skills/x" ]
}

@test "a symlinked dotfile in mount is written as the path typed, under ~" {
  mkdir -p "$HOME/dot"; echo x > "$HOME/dot/gitconfig"; ln -s "$HOME/dot/gitconfig" "$HOME/.gitconfig"
  in_project "main mount '$HOME/.gitconfig' /home/dev/.gitconfig --no-build"
  [ "$(edit_call | tail -1)" = "mount ~/.gitconfig /home/dev/.gitconfig" ]
}

@test "a quoted ~ in mount stays ~ from a subdirectory" {
  mkdir -p "$PROJ/sub"
  (cd "$PROJ/sub" && bash -c "source '$A'; main mount '~/.aws' /home/dev/.aws --no-build")
  [ "$(edit_call | tail -1)" = "mount ~/.aws /home/dev/.aws" ]
}

@test "remove refuses an argument it does not know, such as --target=T, and keeps the folder" {
  mkdir -p "$PROJ/.agentic/skills/x"
  for extra in "--target=claude" "extra" "--target claude more"; do
    DOCKER_RUN_RC=3 run in_project "main remove skill skills/x $extra --no-build"
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage: agentic remove KIND KEY [--target T]"* ]]
  done
  [ -d "$PROJ/.agentic/skills/x" ]
  [ -z "$(edit_call)" ]
}

@test "a refused copy takes back the file it brought into .agentic/files" {
  echo s > "$BATS_TEST_TMPDIR/key.txt"
  DOCKER_RUN_RC=1 run in_project "main copy '$BATS_TEST_TMPDIR/key.txt' relative/dest --no-build"
  [ "$status" -ne 0 ]
  [ ! -e "$PROJ/.agentic/files/key.txt" ]
}

@test "a refused copy keeps a file that was already in .agentic/files" {
  mkdir -p "$PROJ/.agentic/files"; echo s > "$PROJ/.agentic/files/key.txt"; echo s > "$BATS_TEST_TMPDIR/key.txt"
  DOCKER_RUN_RC=1 run in_project "main copy '$BATS_TEST_TMPDIR/key.txt' relative/dest --no-build"
  [ "$status" -ne 0 ]
  [ -f "$PROJ/.agentic/files/key.txt" ]
}

@test "a refused add skill takes back the folder it brought into .agentic/skills" {
  mkdir -p "$BATS_TEST_TMPDIR/review"; echo x > "$BATS_TEST_TMPDIR/review/SKILL.md"
  DOCKER_RUN_RC=1 run in_project "main add skill '$BATS_TEST_TMPDIR/review' --bogus --no-build"
  [ "$status" -ne 0 ]
  [ ! -e "$PROJ/.agentic/skills/review" ]
}

@test "a missing argument prints the agentic usage, not a bash error" {
  for c in "copy" "copy a" "mount" "mount a" "add skill" "remove" "remove skill"; do
    run in_project "main $c --no-build"
    [ "$status" -ne 0 ]
    [[ "$output" == "agentic: usage: agentic "* ]]
  done
}

@test "list shows the built-in mounts first, then the setup lines" {
  DOCKER_RUN_OUT=$'build\tadd plugin a@m' run in_project 'main list'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'built-in\t'"$PROJ"' -> /work (a task: its own worktree)' ]
  [[ "$output" == *$'built-in\t'"$PROJ/.agentic"' -> /agentic-config (read-only)'* ]]
  [[ "$output" == *$'built-in\t'"$AGENTIC_DATA/projects/demo/harness/claude"' -> /home/dev/.claude'* ]]
  [[ "$output" == *$'built-in\t'"$AGENTIC_DATA/projects/demo/harness/copilot"' -> /home/dev/.copilot'* ]]
  [[ "$output" == *$'built-in\t'"$AGENTIC_WORKSPACES/demo/repos"' -> /workspaces/repos'* ]]
  [ "${lines[-1]}" = $'build\tadd plugin a@m' ]
}
