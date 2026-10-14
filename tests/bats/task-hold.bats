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

# hold_stubs: pkill and pgrep stand-ins that log to $BATS_TEST_TMPDIR/hold.log; pgrep finds a bridge
# for its first $PGREP_BUSY calls.
hold_stubs() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\necho "pkill $*" >> "%s/hold.log"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/pkill"
  printf '#!/usr/bin/env bash\necho pgrep >> "%s/hold.log"\nn=$(grep -c pgrep "%s/hold.log")\n[ "$n" -le "${PGREP_BUSY:-0}" ]\n' \
    "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/pgrep"
  chmod +x "$BATS_TEST_TMPDIR/bin/pkill" "$BATS_TEST_TMPDIR/bin/pgrep"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "agentic-task-hold passes SIGTERM to the bridge, waits for it to end, then exits" {
  hold_stubs
  export AGENTIC_TASK_DIR="$BATS_TEST_TMPDIR/tasks/T-3" PGREP_BUSY=3; mkdir -p "$AGENTIC_TASK_DIR"
  bash "$REPO_ROOT/image/bin/agentic-task-hold" & pid=$!
  for _ in $(seq 50); do [ -f "$AGENTIC_TASK_DIR/.ready" ] && break; sleep 0.1; done
  sleeper="$(/usr/bin/pgrep -P "$pid" sleep || true)"
  kill -TERM "$pid"
  for _ in $(seq 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  run kill -0 "$pid"; [ "$status" -ne 0 ]
  grep -qxF 'pkill -TERM -f bridge/dist/main\.js$' "$BATS_TEST_TMPDIR/hold.log"
  [ "$(grep -c '^pgrep' "$BATS_TEST_TMPDIR/hold.log")" -ge 4 ]
  [ -z "$sleeper" ] || { run kill -0 "$sleeper"; [ "$status" -ne 0 ]; }
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
