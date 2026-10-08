#!/usr/bin/env bash
# Config discovery, resolution and validation. Source after common.sh.

# config_find: the directory holding agentic.yaml; nothing when there is none.
config_find() {
  local d
  for d in "${AGENTIC_CONFIG_MOUNT:-/agentic-config}" "${AGENTIC_WORK:-/work}/.agentic"; do
    if [ -f "$d/agentic.yaml" ]; then printf '%s\n' "$d"; return 0; fi
  done
  if [ -n "${AGENTIC_CONFIG_B64:-}" ]; then
    d="$AGENTIC_STATE/env-config"
    mkdir -p "$d"
    printf '%s' "$AGENTIC_CONFIG_B64" | base64 -d > "$d/agentic.yaml" || return 1
    printf '%s\n' "$d"
  fi
}

# config_resolve [DIR]: base defaults < overlay defaults < DIR/agentic.yaml, as compact JSON.
config_resolve() {
  local dir="${1:-}" files=("$AGENTIC_DIR/config/defaults.yaml")
  if [ -f "$AGENTIC_DIR/defaults/agentic.yaml" ]; then files+=("$AGENTIC_DIR/defaults/agentic.yaml"); fi
  if [ -n "$dir" ] && [ -f "$dir/agentic.yaml" ]; then files+=("$dir/agentic.yaml"); fi
  # shellcheck disable=SC2016 # the $ names are yq variables, not shell
  yq eval-all -o=json -I=0 '. as $item ireduce ({}; . * ($item // {}))' "${files[@]}"
}

# config_validate FILE: prints one error per line; exit 1 if there is any.
config_validate() {
  local errs
  errs="$(jq -r -L "$AGENTIC_DIR/lib" --slurpfile s "$AGENTIC_DIR/schema/agentic.schema.json" '
    include "schema-check"; include "config-rules";
    errs($s[0]; "") as $e
    | (if ($e | length) > 0 then $e else semantic_errs end) + secret_errs | .[]' "$1")" || return 1
  if [ -n "$errs" ]; then printf '%s\n' "$errs"; return 1; fi
}
