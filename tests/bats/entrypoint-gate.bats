#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_STEPS_DIR="$BATS_TEST_TMPDIR/steps"
  mkdir -p "$AGENTIC_STEPS_DIR"
  printf '#!/usr/bin/env bash\necho "gate=${AGENTIC_GATE:-unset}" > "%s/gate"\n' "$BATS_TEST_TMPDIR" > "$AGENTIC_STEPS_DIR/01-show.sh"
  install_cmd_stub agentic-bridge
}

gate() { cat "$BATS_TEST_TMPDIR/gate"; }

@test "the gate is on by default for the bridge" {
  bash "$REPO_ROOT/image/entrypoint.sh" agentic-bridge </dev/null
  [ "$(gate)" = gate=1 ]
}

@test "the gate is on by default in worker mode" {
  mkdir -p "$AGENTIC_DIR/worker.d"; printf 'exit 0\n' > "$AGENTIC_DIR/worker.d/w.sh"
  AGENTIC_WORKER_MODE=w bash "$REPO_ROOT/image/entrypoint.sh"
  [ "$(gate)" = gate=1 ]
}

@test "the gate is off by default for anything else, and settable both ways" {
  bash "$REPO_ROOT/image/entrypoint.sh" true
  [ "$(gate)" = gate=0 ]
  AGENTIC_GATE=1 bash "$REPO_ROOT/image/entrypoint.sh" true
  [ "$(gate)" = gate=1 ]
  AGENTIC_GATE=0 bash "$REPO_ROOT/image/entrypoint.sh" agentic-bridge </dev/null
  [ "$(gate)" = gate=0 ]
}
