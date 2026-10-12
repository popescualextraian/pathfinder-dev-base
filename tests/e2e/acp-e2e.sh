#!/usr/bin/env bash
# Manual end-to-end check with the real agents (spec §14); spends tokens. Needs a built project
# image and the developer's tokens in the project's .agentic/.env. The push step creates a real
# branch agentic/<ID>-... on the project's origin; the script deletes it again on exit.
#   tests/e2e/acp-e2e.sh PROJECT_DIR [claude] [copilot]
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
A="$root/bin/agentic"
proj="${1:?usage: acp-e2e.sh PROJECT_DIR [claude] [copilot]}"; shift
agents=("$@"); [ "${#agents[@]}" -gt 0 ] || agents=(claude copilot)
ag() { (cd "$proj" && "$A" "$@"); }
fail() { echo "E2E FAILED: $*" >&2; exit 1; }

# On any exit, Ctrl-C included: stop and clean the current task and delete its remote branch.
cur="" branch=""
cleanup() {
  [ -n "$cur" ] || return 0
  [ -n "$branch" ] || branch="$(ag status "$cur" --json 2>/dev/null | jq -r '.branch // empty' 2>/dev/null)" || true
  ag stop "$cur" >/dev/null 2>&1 || true
  ag clean "$cur" --force >/dev/null 2>&1 || true
  if [ -n "$branch" ]; then (cd "$proj" && git push origin --delete "$branch" >/dev/null 2>&1) || true; fi
  cur=""; branch=""
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

wait_state() {
  local id="$1" s=""; shift
  for _ in $(seq 1 300); do
    s="$(ag status "$id" --json | jq -r .state)"
    if [[ " $* " == *" $s "* ]]; then return 0; fi
    case "$s" in failed|interrupted|stopped) fail "$id is $s, expected $*" ;; esac
    sleep 2
  done
  fail "$id stayed $s"
}

for agent in "${agents[@]}"; do
  echo "== $agent"
  id="$(ag run --agent "$agent" "Reply with exactly the word ONE and nothing else.")"
  cur="$id"; branch=""
  wait_state "$id" idle
  branch="$(ag status "$id" --json | jq -r '.branch // empty')"
  ans="$(ag status "$id" --json | jq -r .summary | sed -E 's/^[[:space:]]+//; s/[[:space:][:punct:]]+$//')"
  [ "$ans" = ONE ] || fail "$agent: first turn answered '$ans'"
  ag send "$id" "Run the shell command 'git push origin HEAD' exactly once. If it is refused, run agentic-ask to ask whether you may push, then end your turn." >/dev/null
  wait_state "$id" waiting
  # No question id: the oldest open question is answered.
  ag answer "$id" "Yes, you may push now; try again." --allow push >/dev/null
  wait_state "$id" idle
  ag logs "$id" | tail -n 30
  ag stop "$id" >/dev/null
  [ "$(ag status "$id" --json | jq -r .state)" = stopped ] || fail "$agent: stop"
  cleanup
  echo "$agent OK"
done
