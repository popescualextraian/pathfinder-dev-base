#!/usr/bin/env bash
# Copies the skills of the base and the overlay, and the project's skills, agents, commands and
# instructions, into each target harness (spec 6.2). What it installed before and the project no
# longer has is removed; what the user put in the homes by hand is left alone.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
source "$AGENTIC_DIR/lib/setup-line.sh"
source "$AGENTIC_DIR/task/lib/harness.sh"
check=0; [ "${1:-}" = --check ] && check=1
proj="${AGENTIC_PROJECT_ASSETS:-$AGENTIC_DIR/project}"
dt="$(jq -r '(.targets // ["claude","copilot"]) | join(",")' "$RESOLVED")"
mark='<!-- agentic:instructions -->'
rc=0
declare -A pick=() narrow=() want=()

for s in "$AGENTIC_DIR/skills"/*/ "$proj/skills"/*/; do [ -f "$s/SKILL.md" ] && pick["skills/$(basename "$s")"]="${s%/}"; done
for a in "$proj/agents"/*.md; do [ -f "$a" ] && pick["agents/$(basename "$a")"]="$a"; done
for a in "$proj/commands"/*.md; do [ -f "$a" ] && pick["commands/$(basename "$a")"]="$a"; done
while IFS= read -r l; do
  parse_line "$l" || continue
  case "$L_KIND" in skill|agent|command) [ -z "$L_TARGETS" ] || narrow["$L_KEY"]="$L_TARGETS" ;; esac
done < <(jq -r '.setup // [] | .[]' "$RESOLVED")

home_of() { case "$1" in claude) claude_dir ;; copilot) copilot_dir ;; esac; }
# dest HARNESS REL: where an asset goes in the home; nothing when the harness has no place for it.
dest() {
  case "$1:$2" in
    claude:*) printf '%s/%s\n' "$(claude_dir)" "$2" ;;
    copilot:skills/*) printf '%s/%s\n' "$(copilot_dir)" "$2" ;;
    copilot:agents/*) printf '%s/agents/%s.agent.md\n' "$(copilot_dir)" "$(basename "$2" .md)" ;;
  esac
}

for rel in "${!pick[@]}"; do
  IFS=, read -ra ts <<<"$(norm_targets "${narrow[$rel]:-$dt}")"
  for h in "${ts[@]}"; do
    d="$(dest "$h" "$rel")"
    if [ -z "$d" ]; then say "$rel: Copilot has no user-level commands; installed for Claude only"; rc=2; continue; fi
    want["$h:$d"]=1
    if [ "$check" = 1 ]; then diff -rq "${pick[$rel]}" "$d" >/dev/null 2>&1 || { say "$rel is not current in $(home_of "$h")"; rc=2; }; continue; fi
    mkdir -p "$(dirname "$d")"; rm -rf -- "$d"; cp -R -- "${pick[$rel]}" "$d"
  done
done

text="$(cat "$proj/instructions.md" 2>/dev/null || true)"
for h in claude copilot; do
  home="$(home_of "$h")"; list="$home/.agentic-assets"
  if [ "$check" = 0 ]; then
    # remove what this step installed before and no longer wants, only inside the home
    while IFS= read -r d; do
      if [ -z "$d" ] || [ -n "${want[$h:$d]:-}" ]; then continue; fi
      case "$(realpath -m -- "$d")/" in "$(realpath -m -- "$home")/"?*) rm -rf -- "$d" ;; esac
    done < <(cat "$list" 2>/dev/null)
    mkdir -p "$home"
    for k in "${!want[@]}"; do [[ "$k" == "$h:"* ]] && printf '%s\n' "${k#*:}"; done | sort > "$list"
    if [[ ",$(norm_targets "$dt")," == *",$h,"* ]]; then t="$text"; else t=""; fi
    if [ "$h" = claude ]; then marked_block "$home/CLAUDE.md" "$mark" "$t"
    else marked_block "$(copilot_instructions_file)" "$mark" "$t"; fi
  fi
done
exit "$rc"
