#!/usr/bin/env bash
# Harness models: harness.claude.model as ANTHROPIC_MODEL, harness.copilot.model in Copilot's config.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
claude_model="$(cfg .harness.claude.model)"
copilot_model="$(cfg .harness.copilot.model)"
pf="$(copilot_dir)/config.json"

read_json() { if [ -s "$1" ] && jq -e . "$1" >/dev/null 2>&1; then cat "$1"; else echo '{}'; fi; }

if [ "$check" = 1 ]; then
  rc=0
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
exit 0
