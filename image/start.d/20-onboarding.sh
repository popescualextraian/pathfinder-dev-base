#!/usr/bin/env bash
# Marks harness first-run dialogs as done and trusts /work, /workspaces and every clone in it: a
# task mounts clones as /workspaces/<name>, a dev container as /workspaces/repos/<name>.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
work="${AGENTIC_WORK:-/work}"; ws="${AGENTIC_WORKSPACES_DIR:-/workspaces}"
trust=("$work")
if [ -d "$ws" ]; then
  trust+=("$ws")
  for d in "$ws"/*/ "$ws"/repos/*/; do [ -e "$d.git" ] && trust+=("${d%/}"); done
fi

cf="$(claude_json)"
pf="$(copilot_dir)/config.json"
rc=0
# a file that is not JSON is left alone: rewriting it from {} would lose the user's login
if claude_cur="$(read_json "$cf")"; then
  claude_next="$(jq '
    .hasCompletedOnboarding = true
    | reduce $ARGS.positional[] as $d (.;
        .projects[$d] = ((.projects[$d] // {}) + {hasTrustDialogAccepted: true, hasTrustDialogHooksAccepted: true}))' --args "${trust[@]}" <<<"$claude_cur")"
else say "$cf is not valid JSON; left alone"; rc=2; cf=""; fi
if copilot_cur="$(read_json "$pf")"; then
  copilot_next="$(jq '.trusted_folders = (((.trusted_folders // []) + $ARGS.positional) | unique)' --args "${trust[@]}" <<<"$copilot_cur")"
else say "$pf is not valid JSON; left alone"; rc=2; pf=""; fi

if [ "$check" = 1 ]; then
  if [ -n "$cf" ] && [ "$(jq -S . <<<"$claude_cur")" != "$(jq -S . <<<"$claude_next")" ]; then say "Claude onboarding is not seeded"; rc=2; fi
  if [ -n "$pf" ] && [ "$(jq -S . <<<"$copilot_cur")" != "$(jq -S . <<<"$copilot_next")" ]; then say "Copilot trust is not seeded"; rc=2; fi
  exit "$rc"
fi
if [ -n "$cf" ]; then write_if_changed "$cf" "$claude_next"; chmod 600 "$cf"; fi
if [ -n "$pf" ]; then write_if_changed "$pf" "$copilot_next"; fi
exit "$rc"
