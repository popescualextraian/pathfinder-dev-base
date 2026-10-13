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
              config:config schema:schema skills:skills profile.d:image/profile.d task:image/task; do
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

# FILE gets about 300 KB of filler lines appended: more than a pipe buffer, so a reader that stops
# early makes its writer die of SIGPIPE.
append_filler() {
  local i
  for i in $(seq 100); do printf 'filler %03d %s\n' "$i" "$(printf 'x%.0s' $(seq 3000))"; done >> "$1"
}

# install_cmd_stub NAME [EXIT]: a command that logs "args: ..." and its stdin to $BATS_TEST_TMPDIR/NAME.log.
install_cmd_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\n{ echo "args: $*"; [ -t 0 ] || cat; echo; } >> "%s/%s.log"\nexit %s\n' \
    "$BATS_TEST_TMPDIR" "$1" "${2:-0}" > "$BATS_TEST_TMPDIR/bin/$1"
  chmod +x "$BATS_TEST_TMPDIR/bin/$1"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# make_task_dir [ALLOWED...]: a /task stand-in at $AGENTIC_TASK_DIR with a state.json holding allowed_actions.
make_task_dir() {
  export AGENTIC_TASK_DIR="$BATS_TEST_TMPDIR/task"
  mkdir -p "$AGENTIC_TASK_DIR"
  jq -n '{version: 1, allowed_actions: $ARGS.positional}' --args "$@" > "$AGENTIC_TASK_DIR/state.json"
}

# install_curl_stub: a curl stand-in for bridge calls. Each call appends its arguments, the header
# file's content and the body (stdin) to $CURL_LOG, then prints $CURL_BODY and the HTTP code:
# $CURL_GET_CODE (default 200) for GET, $CURL_CODE (default 202) otherwise. CURL_RC=7 fails the call.
install_curl_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'EOF2'
#!/usr/bin/env bash
method=GET
{ echo "--- curl"; for a in "$@"; do echo "arg: $a"; case "$a" in @/*|@.*) sed 's/^/header: /' "${a#@}" ;; esac; done
  echo "body: $(cat)"; } >> "$CURL_LOG"
prev=""; for a in "$@"; do [ "$prev" = -X ] && method="$a"; prev="$a"; done
[ -z "${CURL_RC:-}" ] || exit "$CURL_RC"
code="${CURL_CODE:-202}"; [ "$method" = GET ] && code="${CURL_GET_CODE:-200}"
default='{"state":"idle","reason":""}'
printf '%s\n%s' "${CURL_BODY:-$default}" "$code"
EOF2
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
}
# curl_body N: the body of the Nth curl call.
curl_body() { grep '^body: ' "$CURL_LOG" | sed -n "${1}p" | sed 's/^body: //'; }
