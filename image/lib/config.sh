#!/usr/bin/env bash
# Config discovery, resolution and validation. Source after common.sh.

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
  local f="$1" k key p top=" version project base_image git certs plugins mcp skills hooks harness docker "
  while IFS= read -r k; do
    [ -f "$AGENTIC_DIR/tools/$k.sh" ] && continue
    if [[ "$top" == *" $k "* ]]; then echo ".tools.$k: no preset $k in this image; $k is a top-level key, not a tool"
    else echo ".tools.$k: no preset $k in this image"; fi
  done < <(jq -r '.tools // {} | to_entries[]
    | select(.key != "apt" and .key != "extra_dockerfile" and .value != false and .value != null) | .key' "$f")
  for key in .certs .tools.extra_dockerfile .hooks.on_build; do
    p="$(jq -r "$key // empty" "$f")"
    [ -n "$p" ] || continue
    case "/$p/" in */../*) echo "$key: $p must be inside .agentic/"; continue ;; esac
    case "$p" in .agentic/*) ;; *) echo "$key: $p must be inside .agentic/" ;; esac
  done
}

# config_validate FILE: prints one error per line; exit 1 if there is any.
config_validate() {
  local errs
  errs="$(jq -r -L "$AGENTIC_DIR/lib" --slurpfile s "$AGENTIC_DIR/schema/agentic.schema.json" '
    include "schema-check"; include "config-rules";
    errs($s[0]; "") as $e
    | (if ($e | length) > 0 then $e else semantic_errs end) + secret_errs | .[]' "$1")" || return 1
  if [ -z "$errs" ]; then errs="$(config_image_errs "$1")"; fi
  # repos: was removed in sub-project 2; say what to do instead of "unknown key".
  # shellcheck disable=SC2001  # anchored match, not expressible as ${var//}
  errs="$(sed 's#^\.repos: unknown key$#.repos: no longer supported; delete it (tasks use the clones in the project'"'"'s workspace, see docs/tasks.md)#' <<<"$errs")"
  if [ -n "$errs" ]; then printf '%s\n' "$errs"; return 1; fi
}
