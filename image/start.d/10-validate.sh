#!/usr/bin/env bash
# Finds, resolves and validates agentic.yaml into ~/.agentic/config.json.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
source "$AGENTIC_DIR/lib/config.sh"
mkdir -p "$AGENTIC_STATE"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
rc=0
dir="$(config_find)" || exit 1
if [ -z "$dir" ]; then
  say "no agentic.yaml found; using defaults"
  config_resolve | jq -c '.project = "default"' > "$tmp"
  rc=2
else
  config_resolve "$dir" > "$tmp" || { say "could not read $dir/agentic.yaml"; exit 1; }
fi
errfile="$AGENTIC_STATE/config-errors.txt"
if ! errs="$(config_validate "$tmp")"; then
  printf '%s\n' "$errs"
  if [ "${AGENTIC_SETUP:-}" != 1 ]; then say "agentic.yaml is invalid"; exit 1; fi
  # agentic setup exists to fix the config: start on the defaults and hand the errors to the skill.
  printf '%s\n' "$errs" > "$errfile"
  config_resolve | jq -c '.project = "default"' > "$tmp"
  say "agentic.yaml is invalid; starting on the defaults so /agentic-setup can fix it ($errfile)"
  rc=2
else
  rm -f "$errfile"
fi
cp "$tmp" "$RESOLVED"
printf '%s\n' "$dir" > "$AGENTIC_STATE/config-dir"
exit "$rc"
