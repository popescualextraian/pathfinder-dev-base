#!/usr/bin/env bash
# Clones AGENTIC_REPO_URL into an empty /work. A mounted /work is left alone.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
source "$AGENTIC_DIR/lib/gitenv.sh"
check=0; [ "${1:-}" = --check ] && check=1
work="${AGENTIC_WORK:-/work}"

if [ -n "$(ls -A "$work" 2>/dev/null)" ]; then exit 0; fi
if [ -z "${AGENTIC_REPO_URL:-}" ]; then
  # A worker may clone on its own; a bare `docker run` may need no code. Warn, never stop.
  say "$work is empty: mount a repository or set AGENTIC_REPO_URL"
  exit 2
fi
if [ "$check" = 1 ]; then say "would clone $AGENTIC_REPO_URL into $work"; exit 0; fi
eval "$(git_cred_env "$(url_host "$AGENTIC_REPO_URL")")"
args=(clone --quiet)
if [ -n "${AGENTIC_REPO_REF:-}" ]; then args+=(--branch "$AGENTIC_REPO_REF"); fi
if ! git "${args[@]}" "$AGENTIC_REPO_URL" "$work"; then
  say "clone of $AGENTIC_REPO_URL failed"
  exit 1
fi
