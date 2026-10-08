#!/usr/bin/env bash
# Clones the other repos: entries (all but the first) into /workspaces/<name>.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
source "$AGENTIC_DIR/lib/gitenv.sh"
check=0; [ "${1:-}" = --check ] && check=1
ws="${AGENTIC_WORKSPACES_DIR:-/workspaces}"
rc=0
while IFS=$'\t' read -r name url ref; do
  [ -n "$url" ] || continue
  dest="$ws/$name"
  [ -d "$dest/.git" ] && continue
  if [ "$check" = 1 ]; then say "$name is not cloned yet"; rc=2; continue; fi
  args=()
  if [ -n "$ref" ]; then args+=(--branch "$ref"); fi
  if ! (eval "$(git_cred_env "$(url_host "$url")")"; git_clone "$url" "$dest" "${args[@]}"); then
    say "could not clone $name from $(redact_url "$url")"
    rc=2
  fi
done < <(jq -r '.repos[1:][]? | [.name, (.url // ""), (.ref // "")] | @tsv' "$RESOLVED")
exit "$rc"
