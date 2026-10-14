#!/usr/bin/env bash
# Clones every `add workspace URL` line that has no clone yet into /workspaces/repos/<name>. A clone
# is never pulled, reset or deleted: it may hold the user's work. Credentials come from the
# environment as for any git use (.env). Path workspaces are bind mounts made by the host CLI.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
source "$AGENTIC_DIR/lib/setup-line.sh"
source "$AGENTIC_DIR/lib/gitenv.sh"
check=0; [ "${1:-}" = --check ] && check=1
ws="${AGENTIC_WORKSPACES_DIR:-/workspaces}/repos"
rc=0
while IFS= read -r l; do
  parse_line "$l" || continue
  if [ "$L_KIND" != workspace ] || [ "$L_OPT" != url ]; then continue; fi
  d="$ws/$L_KEY"
  [ -e "$d/.git" ] && continue
  if [ -n "$(ls -A "$d" 2>/dev/null)" ]; then say "$d is not a git clone; left alone"; rc=2; continue; fi
  if [ "$check" = 1 ]; then say "workspace $L_KEY is not cloned yet"; rc=2; continue; fi
  mkdir -p "$ws"
  args=(); [ -z "$L_REF" ] || args+=(--branch "$L_REF")
  git_clone "$L_SRC" "$d" "${args[@]}" || { say "clone of workspace $L_KEY failed"; rc=2; }
done < <(jq -r '.setup // [] | .[]' "$RESOLVED")
exit "$rc"
