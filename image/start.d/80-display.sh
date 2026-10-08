#!/usr/bin/env bash
# Headed Playwright needs a display: use the one given, or start Xvfb on :99.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
cfg_true .mcp.playwright.enabled || exit 0
[ "$(cfg .mcp.playwright.mode)" = headed ] || exit 0
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then exit 0; fi
if [ "$check" = 1 ]; then say "no display; Xvfb starts on :99 at container start"; exit 0; fi
if ! command -v Xvfb >/dev/null 2>&1; then say "headed Playwright needs a display, and Xvfb is missing"; exit 2; fi
if ! pgrep -x Xvfb >/dev/null 2>&1; then
  nohup Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp >/dev/null 2>&1 &
fi
env_export DISPLAY :99
