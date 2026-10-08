#!/usr/bin/env bash
# Reconciles the managed MCP servers for Claude and Copilot with agentic.yaml.
# Servers added by hand are left alone. ${VAR} references stay literal; the harness expands them.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
graphify="${AGENTIC_GRAPHIFY_PYTHON:-/opt/agentic/uv-tools/graphifyy/bin/python}"
lib="$AGENTIC_DIR/lib"
rc=0

desired="$(jq -c -L "$lib" --arg g "$graphify" 'include "mcp"; desired($g)' "$RESOLVED")" || { say "could not compute MCP servers"; exit 1; }
mf="$(claude_dir)/agentic-managed-mcp.json"
managed="$(jq -c . "$mf" 2>/dev/null || echo '[]')"
read_json() { if [ -s "$1" ] && jq -e . "$1" >/dev/null 2>&1; then cat "$1"; else echo '{}'; fi; }

cf="$(claude_json)"
pf="$(copilot_dir)/mcp-config.json"
claude_next="$(read_json "$cf" | jq -L "$lib" --argjson m "$managed" --argjson d "$desired" 'include "mcp"; merge_managed($m; $d)')" || { say "could not compute MCP servers"; exit 1; }
copilot_next="$(read_json "$pf" | jq -L "$lib" --argjson m "$managed" --argjson d "$desired" 'include "mcp"; merge_managed($m; $d | to_copilot)')" || { say "could not compute MCP servers"; exit 1; }

# Variables the servers need at connect time.
refs="$(jq -r -L "$lib" 'include "mcp"; to_entries[] | .key as $k | (.value | env_refs[]) | [$k, .] | @tsv' <<<"$desired")" || { say "could not compute MCP servers"; exit 1; }
while IFS=$'\t' read -r server var; do
  [ -n "$server" ] || continue
  if [ -z "${!var:-}" ]; then say "MCP server $server uses \${$var}, which is not set (add it to .agentic/.env)"; rc=2; fi
done <<<"$refs"
if jq -e 'has("atlassian")' <<<"$desired" >/dev/null && [ -z "${JIRA_PERSONAL_TOKEN:-}${CONFLUENCE_PERSONAL_TOKEN:-}" ]; then
  say "MCP server atlassian has no token: set JIRA_PERSONAL_TOKEN or CONFLUENCE_PERSONAL_TOKEN in .agentic/.env"
  rc=2
fi

if [ "$check" = 1 ]; then
  if [ "$(read_json "$cf" | jq -S .mcpServers)" != "$(jq -S .mcpServers <<<"$claude_next")" ] \
     || [ "$(read_json "$pf" | jq -S .mcpServers)" != "$(jq -S .mcpServers <<<"$copilot_next")" ]; then
    say "MCP servers differ from agentic.yaml"
    rc=2
  fi
  exit "$rc"
fi

write_if_changed "$cf" "$claude_next"
chmod 600 "$cf"
write_if_changed "$pf" "$copilot_next"
write_if_changed "$mf" "$(jq -c 'keys' <<<"$desired")"
exit "$rc"
