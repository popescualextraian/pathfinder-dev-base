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
xdir="${AGENTIC_X11_DIR:-/tmp/.X11-unix}"
if ! pgrep -x Xvfb >/dev/null 2>&1; then
  # A restart leaves the lock and socket behind; Xvfb refuses to start over them.
  rm -f "${AGENTIC_X_TMP:-/tmp}/.X99-lock" "$xdir/X99"
  nohup Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp >/dev/null 2>&1 &
  tries=$(( ${AGENTIC_X11_WAIT:-5} * 5 ))
  while [ "$tries" -gt 0 ] && [ ! -S "$xdir/X99" ] && [ ! -e "$xdir/X99" ]; do
    sleep 0.2; tries=$((tries - 1))
  done
  if [ ! -e "$xdir/X99" ]; then say "Xvfb did not come up on :99; headed Playwright will not work"; exit 2; fi
fi
env_export DISPLAY :99
