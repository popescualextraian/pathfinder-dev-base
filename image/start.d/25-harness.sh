#!/usr/bin/env bash
# Harness credentials and models. A subscription token (claude setup-token) under ANTHROPIC_API_KEY
# is sent as an API key and rejected, and an API key outranks the token when both are set: both are
# fixed by reference in the env file, never by value. Models: harness.claude.model as ANTHROPIC_MODEL,
# harness.copilot.model in Copilot's config.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
claude_model="$(cfg .harness.claude.model)"
copilot_model="$(cfg .harness.copilot.model)"
pf="$(copilot_dir)/config.json"

read_json() { if [ -s "$1" ] && jq -e . "$1" >/dev/null 2>&1; then cat "$1"; else echo '{}'; fi; }

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

if [ "$check" = 1 ]; then
  if [ -n "$claude_model" ] && [ "${ANTHROPIC_MODEL:-}" != "$claude_model" ]; then
    say "ANTHROPIC_MODEL is not $claude_model"; rc=2
  fi
  if [ -n "$copilot_model" ] && [ "$(read_json "$pf" | jq -r '.model // empty')" != "$copilot_model" ]; then
    say "Copilot model is not $copilot_model"; rc=2
  fi
  exit "$rc"
fi

if [ -n "$claude_model" ]; then env_export ANTHROPIC_MODEL "$claude_model"; fi
if [ -n "$copilot_model" ]; then
  write_if_changed "$pf" "$(read_json "$pf" | jq --arg m "$copilot_model" '.model = $m')"
fi
exit "$rc"
