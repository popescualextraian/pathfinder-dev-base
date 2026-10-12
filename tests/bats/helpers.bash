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

# A copy of the wiki fixture repository at $W, with CLAUDE.md, .claude and .github under their
# real names (the fixture avoids them so no harness loads them from this repository).
wiki_repo() {
  W="$BATS_TEST_TMPDIR/repo"
  cp -r "$REPO_ROOT/tests/fixtures/wiki/good" "$W"
  mv "$W/CLAUDE.fixture.md" "$W/CLAUDE.md"
  mv "$W/dot-claude" "$W/.claude"
  if [ -d "$W/dot-github" ]; then mv "$W/dot-github" "$W/.github"; fi
  export W
}
