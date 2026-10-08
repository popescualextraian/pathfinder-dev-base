#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  export AGENTIC_STATE="$HOME/.agentic"
  mkdir -p "$AGENTIC_STATE" "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "tmux $* GREETING=$GREETING"\n' > "$BATS_TEST_TMPDIR/bin/tmux"
  chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "dev-shell applies the start environment and attaches the main session in /work" {
  echo 'export GREETING=hi' > "$AGENTIC_STATE/env"
  run bash "$REPO_ROOT/image/bin/dev-shell"
  [ "$status" -eq 0 ]
  [ "$output" = "tmux new-session -A -s main -c /work GREETING=hi" ]
}

@test "dev-shell takes the start directory as an argument and works without an env file" {
  run bash "$REPO_ROOT/image/bin/dev-shell" /workspaces/lib
  [ "$output" = "tmux new-session -A -s main -c /workspaces/lib GREETING=" ]
}
