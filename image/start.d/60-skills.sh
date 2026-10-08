#!/usr/bin/env bash
# Copies base, overlay and project skills into both harnesses. Project skills win on a name clash.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
dirs=("$AGENTIC_DIR/skills")
if p="$(config_path "$(cfg .skills)")"; then dirs+=("$p"); fi
targets=("$(claude_dir)/skills" "$(copilot_dir)/skills")
rc=0
declare -A pick=()
for d in "${dirs[@]}"; do
  for s in "$d"/*/; do
    [ -f "$s/SKILL.md" ] && pick["$(basename "$s")"]="${s%/}"
  done
done
for name in "${!pick[@]}"; do
  for t in "${targets[@]}"; do
    if [ "$check" = 1 ]; then
      diff -rq "${pick[$name]}" "$t/$name" >/dev/null 2>&1 || { say "skill $name is not current in $t"; rc=2; }
      continue
    fi
    mkdir -p "$t"
    rm -rf "${t:?}/$name"
    cp -R "${pick[$name]}" "$t/$name"
  done
done
exit "$rc"
