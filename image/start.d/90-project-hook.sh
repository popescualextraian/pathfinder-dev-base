#!/usr/bin/env bash
# Runs the project's on-start hook in /work (the project root, also in a multi-repository task). A failure warns unless the hook is required.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
f="$(config_path "$(cfg .hooks.on_start)")" || exit 0
[ -f "$f" ] || exit 0
[ "$check" = 1 ] && exit 0
if (cd "$(work_root)" && bash "$f" </dev/null); then exit 0; fi
say "the on-start hook $f failed"
if cfg_true .hooks.on_start_required; then exit 1; fi
exit 2
