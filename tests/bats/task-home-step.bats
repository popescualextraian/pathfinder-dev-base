#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  S="$REPO_ROOT/image/start.d/06-task-home.sh"
  mkdir -p "$AGENTIC_STATE"; : > "$AGENTIC_STATE/env"
}

@test "without a task volume the step does nothing" {
  run bash "$S"
  [ "$status" -eq 0 ]
  [ ! -s "$AGENTIC_STATE/env" ]
}

@test "with a task directory the harness homes move onto it" {
  export AGENTIC_TASK_DIR="$BATS_TEST_TMPDIR/task"; mkdir -p "$AGENTIC_TASK_DIR"
  run bash "$S"
  [ "$status" -eq 0 ]
  [ -d "$AGENTIC_TASK_DIR/home/claude" ] && [ -d "$AGENTIC_TASK_DIR/home/copilot" ]
  grep -qx "export CLAUDE_CONFIG_DIR=$AGENTIC_TASK_DIR/home/claude" "$AGENTIC_STATE/env"
  grep -qx "export COPILOT_HOME=$AGENTIC_TASK_DIR/home/copilot" "$AGENTIC_STATE/env"
}

@test "an unwritable task directory stops the start with a clear message" {
  [ "$(id -u)" != 0 ] || skip "root can write anywhere"
  export AGENTIC_TASK_DIR="$BATS_TEST_TMPDIR/task"; mkdir -p "$AGENTIC_TASK_DIR"; chmod 500 "$AGENTIC_TASK_DIR"
  run bash "$S"
  chmod 700 "$AGENTIC_TASK_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not writable"* ]]
}

@test "a task directory with spaces is written quoted and a failing mkdir stops the start" {
  [ "$(id -u)" != 0 ] || skip "root can write anywhere"
  export AGENTIC_TASK_DIR="$BATS_TEST_TMPDIR/my task"; mkdir -p "$AGENTIC_TASK_DIR/home"
  run bash "$S"
  [ "$status" -eq 0 ]
  ( source "$AGENTIC_STATE/env"; [ "$CLAUDE_CONFIG_DIR" = "$AGENTIC_TASK_DIR/home/claude" ] )
  rmdir "$AGENTIC_TASK_DIR/home/claude" "$AGENTIC_TASK_DIR/home/copilot"; chmod 500 "$AGENTIC_TASK_DIR/home"
  : > "$AGENTIC_STATE/env"
  run bash "$S"
  chmod 700 "$AGENTIC_TASK_DIR/home"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot create"* ]]
  [ ! -s "$AGENTIC_STATE/env" ]
}
