#!/usr/bin/env bash
# Config discovery, resolution and validation. Source after common.sh.
# shellcheck source=setup-line.sh
source "$AGENTIC_DIR/lib/setup-line.sh"

# config_find: the directory holding agentic.yaml; nothing when there is none. Fails, with a
# message, when AGENTIC_CONFIG_B64 is set but does not decode.
config_find() {
  local d
  for d in "${AGENTIC_CONFIG_MOUNT:-/agentic-config}" "${AGENTIC_WORK:-/work}/.agentic"; do
    if [ -f "$d/agentic.yaml" ]; then printf '%s\n' "$d"; return 0; fi
  done
  if [ -n "${AGENTIC_CONFIG_B64:-}" ]; then
    d="$AGENTIC_STATE/env-config"
    mkdir -p "$d"
    if ! printf '%s' "$AGENTIC_CONFIG_B64" | base64 -d > "$d/agentic.yaml" 2>/dev/null; then
      rm -f "$d/agentic.yaml"
      say "AGENTIC_CONFIG_B64 is not valid base64"
      return 1
    fi
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

# config_image_errs FILE: what only this image can decide, checked as the build checks it: every
# tool has a preset here, and build-time paths stay inside .agentic/ (the build context).
config_image_errs() {
  local f="$1" k p top=" version project base_image targets tools hooks harness docker setup "
  while IFS= read -r k; do
    [ -f "$AGENTIC_DIR/tools/$k.sh" ] && continue
    if [[ "$top" == *" $k "* ]]; then echo ".tools.$k: no preset $k in this image; $k is a top-level key, not a tool"
    else echo ".tools.$k: no preset $k in this image"; fi
  done < <(jq -r '.tools // {} | to_entries[]
    | select(.key != "apt" and .key != "extra_dockerfile" and .value != false and .value != null) | .key' "$f")
  p="$(jq -r '.tools.extra_dockerfile // empty' "$f")"
  if [ -n "$p" ]; then
    case "/$p/" in
      */../*) echo ".tools.extra_dockerfile: $p must be inside .agentic/" ;;
      *) case "$p" in .agentic/*) ;; *) echo ".tools.extra_dockerfile: $p must be inside .agentic/" ;; esac ;;
    esac
  fi
  if [ -f "$AGENTIC_DIR/defaults/agentic.yaml" ] && yq -e 'has("setup")' "$AGENTIC_DIR/defaults/agentic.yaml" >/dev/null 2>&1; then
    echo ".setup: overlay defaults cannot hold setup: lines; ship them in /opt/agentic/defaults/recommended"
  fi
}

# config_validate FILE: prints one error per line; exit 1 if there is any.
config_validate() {
  local errs
  if [ "$(jq -r '.version // empty' "$1")" = 1 ]; then
    echo ".version: version 1 is no longer supported; re-run agentic init (keep your .env)"; return 1
  fi
  errs="$(jq -r -L "$AGENTIC_DIR/lib" --slurpfile s "$AGENTIC_DIR/schema/agentic.schema.json" '
    include "schema-check"; include "config-rules";
    errs($s[0]; "") as $e
    | (if ($e | length) > 0 then $e else semantic_errs end) + secret_errs | .[]' "$1")" || return 1
  if [ -z "$errs" ]; then errs="$(config_image_errs "$1")"; fi
  if [ -z "$errs" ]; then errs="$(setup_errs "$1")"; fi
  if [ -n "$errs" ]; then printf '%s\n' "$errs"; return 1; fi
}
