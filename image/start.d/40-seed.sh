#!/usr/bin/env bash
# Brings what the build set up (the seed homes under /opt/agentic/seed) into the harness homes:
# plugin folders are linked, JSON files get a 3-way merge, so the user's own keys survive.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
seed="${AGENTIC_SEED:-$AGENTIC_DIR/seed}"
lib="$AGENTIC_DIR/lib"
[ -d "$seed" ] || exit 0
rc=0

home_of() { case "$1" in claude) claude_dir ;; copilot) copilot_dir ;; esac; }
# home_file HARNESS PATH: where a seed path lives in the home (Claude's .claude.json is special).
home_file() {
  if [ "$1/$2" = claude/.claude.json ]; then claude_json; else printf '%s/%s\n' "$(home_of "$1")" "$2"; fi
}

while IFS=$'\t' read -r h kind p; do
  case "$h" in ''|'#'*) continue ;; esac
  src="$seed/$h/$p"; dst="$(home_file "$h" "$p")"
  case "$kind" in
    link)
      [ -e "$src" ] || continue
      if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        if [ "$check" = 1 ]; then say "$dst is a real folder; the image's $p is not linked"; rc=2; continue; fi
        mv "$dst" "$dst.pre-seed.$(date +%s)"
        say "moved $dst aside to link the image's $p"; rc=2
      fi
      if [ "$(readlink "$dst" 2>/dev/null)" != "$src" ]; then
        if [ "$check" = 1 ]; then say "$dst is not linked to the image's $p"; rc=2
        else mkdir -p "$(dirname "$dst")"; ln -sfn "$src" "$dst"; fi
      fi ;;
    json)
      cur="$(read_json "$dst")" || { say "$dst is not valid JSON; left alone"; rc=2; continue; }
      snap="$(home_of "$h")/.agentic-seed/$p"
      new="$(read_json "$src" | jq -c -L "$lib" --argjson base "$(read_json "$seed/.baseline/$h/$p" || echo '{}')" \
               --argjson ign "$(read_json "$lib/seed-ignore.json")" --arg k "$h/$p" \
               'include "seed"; delta($base) | drop($ign[$k] // [])')" || { say "could not read the seed's $p"; rc=2; continue; }
      next="$(jq -L "$lib" --argjson o "$(read_json "$snap" || echo '{}')" --argjson n "$new" 'include "seed"; seedmerge($o; $n)' <<<"$cur")"
      if [ "$check" = 1 ]; then
        [ "$(jq -S . <<<"$cur")" = "$(jq -S . <<<"$next")" ] || { say "$dst lacks what the setup lines set up"; rc=2; }
        continue
      fi
      write_if_changed "$dst" "$next"
      write_if_changed "$snap" "$new" ;;
  esac
done < "$lib/seed-map.tsv"
exit "$rc"
