#!/usr/bin/env bash
# The task's apps: a container restart ends every prepare, so the markers of prepares that were
# running (agentic-app's NAME.preparing) are stale; they go before anything can read them.
set -euo pipefail
[ "${1:-}" = --check ] && exit 0
rm -f "${AGENTIC_STATE:-$HOME/.agentic}"/apps/*.preparing
