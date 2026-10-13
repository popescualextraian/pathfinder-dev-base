#!/usr/bin/env bash
# With a task volume (/task mounted, or AGENTIC_TASK_DIR set): the harness homes live on it, so a
# suspended task's sessions survive the container. Runs before every step that writes a home.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
if [ -z "${AGENTIC_TASK_DIR:-}" ] && ! mountpoint -q /task 2>/dev/null; then exit 0; fi
task="${AGENTIC_TASK_DIR:-/task}"
if [ ! -w "$task" ]; then say "$task is not writable by $(id -un); fix the owner of the task volume"; exit 1; fi
[ "${1:-}" = --check ] && exit 0
if ! mkdir -p "$task/home/claude" "$task/home/copilot"; then say "cannot create the harness homes under $task/home"; exit 1; fi
printf 'export CLAUDE_CONFIG_DIR=%q\nexport COPILOT_HOME=%q\n' "$task/home/claude" "$task/home/copilot" >> "$AGENTIC_STATE/env"
