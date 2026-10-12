#!/usr/bin/env bash
# hook.sh HARNESS EVENT: the one hook entry point for both harnesses; payload on stdin. On PreToolUse
# the gate, the ask-guard and hooks.d/pretooluse scripts may refuse the call; nothing else fails a turn.
set -uo pipefail
AGENTIC_DIR="${AGENTIC_DIR:-/opt/agentic}"
# shellcheck disable=SC1091
source "$AGENTIC_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$AGENTIC_DIR/task/lib/harness.sh"

harness="${1:-claude}"; ev="${2:-}"
payload="$(cat 2>/dev/null || true)"

# run_extensions EVENT: hooks.d scripts of the image, then of the project, payload on stdin. On
# pretooluse a script exiting 2 refuses the call: its stderr is printed and 2 returned.
run_extensions() {
  local d s out rc
  for d in "$AGENTIC_DIR/hooks.d/$1" "${AGENTIC_CONFIG_MOUNT:-/agentic-config}/hooks.d/$1"; do
    for s in "$d"/*.sh; do
      [ -f "$s" ] || continue
      out="$(printf '%s' "$payload" | timeout 15 bash "$s" 2>&1 >/dev/null)"
      rc=$?
      if [ "$rc" = 2 ] && [ "$1" = pretooluse ]; then printf '%s\n' "${out:-refused by $(basename "$s")}"; return 2; fi
    done
  done
  return 0
}

# report RULE: tells the bridge about a refusal, best effort. The token goes in a 0600 header file
# (never argv) and the call bypasses any proxy: the bridge is on the container's loopback.
report() {
  [ -n "${AGENTIC_BRIDGE_URL:-}" ] || return 0
  local hdr
  hdr="$(mktemp)" || return 0
  [ -z "${AGENTIC_AGENT_TOKEN:-}" ] || printf 'Authorization: Bearer %s\n' "$AGENTIC_AGENT_TOKEN" > "$hdr"
  jq -cn --arg r "$1" --arg c "$(payload_command "$payload")" '{rule: $r, command: $c}' \
    | curl -fsS -m 1 --noproxy '*' -X POST -H "@$hdr" -H 'Content-Type: application/json' \
        --data-binary @- "$AGENTIC_BRIDGE_URL/gate" >/dev/null 2>&1 || true
  rm -f "$hdr"
}

# refuse RULE REASON: reports, then refuses the call in the harness's format.
refuse() { report "$1"; harness_block "$harness" "$2"; exit $?; }

if [ "$ev" != pretooluse ]; then run_extensions "$ev" >/dev/null 2>&1; exit 0; fi

for g in gate ask-guard; do
  reason="$(printf '%s' "$payload" | bash "$AGENTIC_DIR/task/$g.sh" 2>&1 >/dev/null)"
  grc=$?
  [ "$grc" -ne 2 ] || refuse "$g" "$reason"
  [ "$grc" -eq 0 ] || refuse gate "agentic gate failed (rc $grc); refusing to run unguarded"
done
reason="$(run_extensions pretooluse)"
[ $? -ne 2 ] || refuse hooks.d "$reason"
exit 0
