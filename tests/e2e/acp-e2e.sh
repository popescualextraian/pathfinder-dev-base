#!/usr/bin/env bash
# Manual end-to-end check with the real agents (spec §14); spends tokens. Needs a built project
# image and the developer's tokens in the project's .agentic/.env.
#   tests/e2e/acp-e2e.sh PROJECT_DIR [claude] [copilot]
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
A="$root/bin/agentic"
proj="${1:?usage: acp-e2e.sh PROJECT_DIR [claude] [copilot]}"; shift
agents=("$@"); [ "${#agents[@]}" -gt 0 ] || agents=(claude copilot)
ag() { (cd "$proj" && "$A" "$@"); }
fail() { echo "E2E FAILED: $*" >&2; exit 1; }
wait_state() {
  local id="$1" s=""; shift
  for _ in $(seq 1 300); do
    s="$(ag status "$id" --json | jq -r .state)"
    if [[ " $* " == *" $s "* ]]; then return 0; fi
    sleep 2
  done
  fail "$id stayed $s"
}

for agent in "${agents[@]}"; do
  echo "== $agent"
  id="$(ag run --agent "$agent" "Reply with exactly the word ONE and nothing else.")"
  wait_state "$id" idle
  [ "$(ag status "$id" --json | jq -r .summary)" = ONE ] || fail "$agent: first turn"
  ag send "$id" "Run the shell command 'git push origin HEAD' exactly once. If it is refused, run agentic-ask to ask whether you may push, then end your turn." >/dev/null
  wait_state "$id" waiting
  # No question id: the oldest open question is answered.
  ag answer "$id" "Yes, you may push now; try again." --allow push >/dev/null
  wait_state "$id" idle
  ag logs "$id" | tail -n 30
  ag stop "$id" >/dev/null
  [ "$(ag status "$id" --json | jq -r .state)" = stopped ] || fail "$agent: stop"
  ag clean "$id" --force >/dev/null
  echo "$agent OK"
done
