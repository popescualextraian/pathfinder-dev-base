#!/usr/bin/env bash
# Claude credentials: a subscription token under ANTHROPIC_API_KEY is moved to CLAUDE_CODE_OAUTH_TOKEN
# (by reference, never by value); an API key outranks the token when both are set, so it is dropped.
# Models come from .env (ANTHROPIC_MODEL, COPILOT_MODEL).
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
rc=0
mkdir -p "$AGENTIC_STATE"
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    [ "$check" = 1 ] || printf 'unset ANTHROPIC_API_KEY\n' >> "$ENV_FILE"
  elif [[ "$ANTHROPIC_API_KEY" == sk-ant-oat* ]]; then
    say "ANTHROPIC_API_KEY holds a subscription token (sk-ant-oat...); rename ANTHROPIC_API_KEY to CLAUDE_CODE_OAUTH_TOKEN in .agentic/.env"
    rc=2
    # shellcheck disable=SC2016 # references, expanded when the env file is sourced; sourced again
    # after every later step, when ANTHROPIC_API_KEY is already gone, hence the fallback
    [ "$check" = 1 ] || printf 'export CLAUDE_CODE_OAUTH_TOKEN="${ANTHROPIC_API_KEY:-${CLAUDE_CODE_OAUTH_TOKEN:-}}"\nunset ANTHROPIC_API_KEY\n' >> "$ENV_FILE"
  fi
fi

exit "$rc"
