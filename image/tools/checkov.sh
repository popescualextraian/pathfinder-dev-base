#!/usr/bin/env bash
# Checkov (exact version) as a uv tool into $AGENTIC_OPT/checkov/<version>.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/checkov/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  UV_TOOL_DIR="$(home "$1")/tools" UV_TOOL_BIN_DIR="$(home "$1")/bin" uv tool install "checkov==$1"
  chmod -R a+rX "$(home "$1")"
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/checkov" --version 2>/dev/null; }
preset_main "$@"
