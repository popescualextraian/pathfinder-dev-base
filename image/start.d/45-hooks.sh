#!/usr/bin/env bash
# Installs the hooks for both harnesses when the gate is on (AGENTIC_GATE=1): a managed block in
# Claude's settings.json, Copilot's own hook file, and the task paragraph for Copilot. A task must
# not run unguarded, so an unreadable settings.json is fatal.
set -uo pipefail
[ "${AGENTIC_GATE:-0}" = 1 ] || exit 0
AGENTIC_DIR="${AGENTIC_DIR:-/opt/agentic}"
# shellcheck disable=SC1091
source "$AGENTIC_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$AGENTIC_DIR/task/lib/harness.sh"
check=0; [ "${1:-}" = --check ] && check=1
hook="$AGENTIC_DIR/task/hook.sh"
mark='<!-- agentic:task -->'
rc=0

claude_block() {
  harness_hook_events claude | jq -Rn --arg h "$hook" '[inputs | split(" ")
    | {key: .[0], value: [{hooks: [{type: "command", command: "bash \($h) claude \(.[1])", timeout: 30}]}]}] | from_entries'
}

f="$(claude_dir)/settings.json"
cur='{}'
if [ -s "$f" ]; then cur="$(cat "$f")"; fi
if ! new="$(jq --argjson ours "$(claude_block)" --arg h "$hook" '
      .skipDangerousModePermissionPrompt = true
      | .hooks = ((.hooks // {})
          | map_values(map(select(any(.hooks[]?; (.command // "") | contains($h)) | not)))
          | with_entries(select(.value | length > 0)))
      | .hooks = reduce ($ours | to_entries[]) as $e (.hooks; .[$e.key] = ((.[$e.key] // []) + $e.value))' \
      <<<"$cur" 2>/dev/null)"; then
  say "$f is not valid JSON; task hooks not installed"
  exit 1
fi

copilot_new="$(harness_hook_events copilot | jq -Rn --arg h "$hook" '{version: 1, hooks: ([inputs | split(" ")
  | {key: .[0], value: [{type: "command", bash: "bash \($h) copilot \(.[1])", timeoutSec: 30}]}] | from_entries)}')"
cf="$(copilot_hooks_file)"
inf="$(copilot_instructions_file)"

if [ "$check" = 1 ]; then
  [ "$(jq -S . <<<"$new")" = "$(jq -S . <<<"$cur")" ] || { say "task hooks are not installed for claude"; rc=2; }
  [ "$(cat "$cf" 2>/dev/null)" = "$copilot_new" ] || { say "task hooks are not installed for copilot"; rc=2; }
  exit "$rc"
fi
write_if_changed "$f" "$new"
write_if_changed "$cf" "$copilot_new"
# the instructions keep the user's text; the task paragraph sits between two markers
marked_block "$inf" "$mark" "$(cat "$AGENTIC_DIR/task/task-prompt.md")"
exit 0
