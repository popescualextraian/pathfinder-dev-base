#!/usr/bin/env bash
# ask-guard.sh: PreToolUse check. The harnesses' choosers cannot be answered in a detached terminal,
# so they are refused with a pointer to agentic-ask. Exit 2 blocks.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
source "$AGENTIC_DIR/task/lib/harness.sh"
is_chooser_tool "$(payload_tool "$(cat)")" || exit 0
echo "Use agentic-ask; nobody can answer a chooser here." >&2
exit 2
