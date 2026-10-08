#!/usr/bin/env bash
# Shared helpers for image scripts. Source, do not execute.
AGENTIC_DIR="${AGENTIC_DIR:-/opt/agentic}"
AGENTIC_STATE="${AGENTIC_STATE:-$HOME/.agentic}"
RESOLVED="$AGENTIC_STATE/config.json"
ENV_FILE="$AGENTIC_STATE/env"
export AGENTIC_DIR AGENTIC_STATE

say() { echo "agentic: $*" >&2; }

claude_dir() { printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }
claude_json() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then printf '%s\n' "$CLAUDE_CONFIG_DIR/.claude.json"
  else printf '%s\n' "$HOME/.claude.json"; fi
}
copilot_dir() { printf '%s\n' "${COPILOT_HOME:-$HOME/.copilot}"; }

# cfg EXPR: a string from the resolved config, empty when missing or null.
cfg() { jq -r "($1) // empty" "$RESOLVED"; }
cfg_true() { jq -e "($1) == true" "$RESOLVED" >/dev/null 2>&1; }
cfg_json() { jq -c "$1" "$RESOLVED"; }

config_dir() { cat "$AGENTIC_STATE/config-dir" 2>/dev/null || true; }

# config_path REL: a config path (".agentic/x") as a path inside the config directory.
config_path() {
  local p="$1" d
  d="$(config_dir)"
  [ -n "$p" ] && [ -n "$d" ] || return 1
  case "$p" in
    .agentic/*) printf '%s\n' "$d/${p#.agentic/}" ;;
    /*) printf '%s\n' "$p" ;;
    *) printf '%s\n' "$d/$p" ;;
  esac
}

# env_export NAME VALUE: exported to the entrypoint's command and to dev-shell.
env_export() {
  mkdir -p "$AGENTIC_STATE"
  printf 'export %s=%q\n' "$1" "$2" >> "$ENV_FILE"
}

# write_if_changed FILE CONTENT: writes only on change, private to the user.
write_if_changed() {
  local f="$1" new="$2"
  if [ -f "$f" ] && [ "$(cat "$f")" = "$new" ]; then return 0; fi
  mkdir -p "$(dirname "$f")"
  (umask 077; printf '%s\n' "$new" > "$f")
}
