#!/usr/bin/env bash
# Wires Graphify's hooks and skill into both harnesses. Building a graph is not done here.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
cfg_true .mcp.graphify.enabled || exit 0
if ! command -v graphify >/dev/null 2>&1; then say "graphify is not installed in this image"; exit 2; fi
[ "$check" = 1 ] && exit 0
rc=0
for p in claude copilot; do
  graphify install --platform "$p" </dev/null >/dev/null 2>&1 || { say "graphify install --platform $p failed"; rc=2; }
done
exit "$rc"
