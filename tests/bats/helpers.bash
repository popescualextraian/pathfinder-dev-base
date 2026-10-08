# Shared helpers for bats tests. Source with: load helpers
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# An isolated HOME under the test's temp dir.
make_tmp_home() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
}

# An /opt/agentic layout built from the repository, as the image has it. Call after make_tmp_home.
make_agentic_dir() {
  export AGENTIC_DIR="$BATS_TEST_TMPDIR/opt-agentic"
  export AGENTIC_STATE="$HOME/.agentic"
  mkdir -p "$AGENTIC_DIR/defaults" "$AGENTIC_DIR/worker.d"
  local pair src
  for pair in lib:image/lib start.d:image/start.d tools:image/tools bin:image/bin derive:derive \
              config:config schema:schema skills:skills profile.d:image/profile.d; do
    src="$REPO_ROOT/${pair#*:}"
    if [ -e "$src" ]; then ln -s "$src" "$AGENTIC_DIR/${pair%%:*}"; fi
  done
}
