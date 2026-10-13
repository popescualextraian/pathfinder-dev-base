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

read_json() { if [ -s "$1" ] && jq -e . "$1" >/dev/null 2>&1; then cat "$1"; else echo '{}'; fi; }

cf="$(claude_json)"
claude_next="$(read_json "$cf" | jq '
  .hasCompletedOnboarding = true
  | reduce $ARGS.positional[] as $d (.;
      .projects[$d] = ((.projects[$d] // {}) + {hasTrustDialogAccepted: true, hasTrustDialogHooksAccepted: true}))' --args "${trust[@]}")"
pf="$(copilot_dir)/config.json"
copilot_next="$(read_json "$pf" | jq '.trusted_folders = (((.trusted_folders // []) + $ARGS.positional) | unique)' --args "${trust[@]}")"

if [ "$check" = 1 ]; then
  drift=0
  [ "$(read_json "$cf" | jq -S .)" = "$(jq -S . <<<"$claude_next")" ] || { say "Claude onboarding is not seeded"; drift=1; }
  [ "$(read_json "$pf" | jq -S .)" = "$(jq -S . <<<"$copilot_next")" ] || { say "Copilot trust is not seeded"; drift=1; }
  [ "$drift" = 0 ] || exit 2
  exit 0
fi
write_if_changed "$cf" "$claude_next"
chmod 600 "$cf"
write_if_changed "$pf" "$copilot_next"
