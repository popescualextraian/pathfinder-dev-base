#!/usr/bin/env bash
# Finds, resolves and validates agentic.yaml into ~/.agentic/config.json.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
source "$AGENTIC_DIR/lib/config.sh"
mkdir -p "$AGENTIC_STATE"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
rc=0
dir="$(config_find)"
if [ -z "$dir" ]; then
  say "no agentic.yaml found; using defaults"
  config_resolve | jq -c '.project = "default"' > "$tmp"
  rc=2
else
  config_resolve "$dir" > "$tmp" || { say "could not read $dir/agentic.yaml"; exit 1; }
fi
if ! errs="$(config_validate "$tmp")"; then
  printf '%s\n' "$errs"
  say "agentic.yaml is invalid"
  exit 1
fi
cp "$tmp" "$RESOLVED"
printf '%s\n' "$dir" > "$AGENTIC_STATE/config-dir"
exit "$rc"
