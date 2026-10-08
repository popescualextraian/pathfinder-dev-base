# Shared helpers for bats tests. Source with: load helpers
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# An isolated HOME under the test's temp dir.
make_tmp_home() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
}
