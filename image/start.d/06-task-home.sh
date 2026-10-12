#!/usr/bin/env bash
# With a task volume (/task mounted, or AGENTIC_TASK_DIR set): the harness homes live on it, so a
# suspended task's sessions survive the container. Runs before every step that writes a home.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
if [ -z "${AGENTIC_TASK_DIR:-}" ] && ! mountpoint -q /task 2>/dev/null; then exit 0; fi
task="${AGENTIC_TASK_DIR:-/task}"
if [ ! -w "$task" ]; then say "$task is not writable by $(id -un); fix the owner of the task volume"; exit 1; fi
[ "${1:-}" = --check ] && exit 0
mkdir -p "$task/home/claude" "$task/home/copilot"
printf 'export CLAUDE_CONFIG_DIR=%s\nexport COPILOT_HOME=%s\n' "$task/home/claude" "$task/home/copilot" >> "$AGENTIC_STATE/env"
