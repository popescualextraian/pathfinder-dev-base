#!/usr/bin/env bash
# Generates docs/configuration.md from the schema and the defaults. --check fails when it is stale.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

render() {
  local defaults
  defaults="$(yq -o=json -I=0 . "$root/config/defaults.yaml")"
  echo "# agentic.yaml reference"
  echo
  echo "Generated from \`schema/agentic.schema.json\` and \`config/defaults.yaml\` by"
  echo "\`tools/gen-config-docs.sh\`. Do not edit by hand."
  echo
  echo "| Field | Type | Default | Description |"
  echo "|---|---|---|---|"
  jq -r --argjson d "$defaults" '
    def tdesc:
      if has("type") then (.type | if type == "array" then join(" or ") else . end)
      elif has("enum") then (.enum | map(tojson) | join(" / "))
      elif has("anyOf") then ([.anyOf[] | if has("enum") and .enum == [false] then "false" else tdesc end] | join(" or "))
      else "any" end;
    def rows($p):
      (.properties // {}) | to_entries[] | .key as $k | .value as $v | ($p + [$k]) as $path
      | ("| `" + ($path | join(".")) + "` | " + ($v | tdesc) + " | "
         + (($d | getpath($path)) as $x | if $x == null then "" else "`" + ($x | tojson) + "`" end)
         + " | " + ($v.description // "") + " |"),
        ($v | rows($path));
    rows([])' "$root/schema/agentic.schema.json"
}

if [ "${1:-}" = --check ]; then
  if ! diff -q "$root/docs/configuration.md" <(render) >/dev/null 2>&1; then
    echo "docs/configuration.md is stale; run: tools/gen-config-docs.sh > docs/configuration.md" >&2
    exit 1
  fi
else
  render
fi
