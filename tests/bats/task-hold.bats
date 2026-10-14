#!/usr/bin/env bats
load helpers

setup() { make_tmp_home; export AGENTIC_STATE="$HOME/.agentic"; }

@test "agentic-task-hold records its pid, marks the start done and keeps running" {
  export AGENTIC_TASK_DIR="$BATS_TEST_TMPDIR/tasks/T-1"; mkdir -p "$AGENTIC_TASK_DIR"
  bash "$REPO_ROOT/image/bin/agentic-task-hold" & pid=$!
  for _ in $(seq 50); do [ -f "$AGENTIC_TASK_DIR/.ready" ] && break; sleep 0.1; done
  [ -f "$AGENTIC_TASK_DIR/.ready" ]
  [ "$(cat "$AGENTIC_STATE/hold.pid")" = "$pid" ]
  kill -0 "$pid"
  kill "$pid"
}

@test "agentic-task-start loads the start's environment and runs the bridge with its output in the task directory" {
  mkdir -p "$AGENTIC_STATE" "$BATS_TEST_TMPDIR/bin"
  printf 'export CLAUDE_CONFIG_DIR=/tasks/T-0/home/claude\nexport AGENTIC_TASK_DIR=/wrong\n' > "$AGENTIC_STATE/env"
  printf '#!/usr/bin/env bash\necho "cfg=$CLAUDE_CONFIG_DIR dir=$AGENTIC_TASK_DIR"\n' > "$BATS_TEST_TMPDIR/bin/agentic-bridge"
  chmod +x "$BATS_TEST_TMPDIR/bin/agentic-bridge"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" AGENTIC_TASK_DIR="$BATS_TEST_TMPDIR/tasks/T-2"
  bash "$REPO_ROOT/image/bin/agentic-task-start"
  [ "$(cat "$AGENTIC_TASK_DIR/bridge.out")" = "cfg=/tasks/T-0/home/claude dir=$AGENTIC_TASK_DIR" ]
}
