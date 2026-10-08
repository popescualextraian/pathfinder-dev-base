#!/usr/bin/env bash
# Python via uv into $AGENTIC_OPT/python, visible to every user's uv.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
export UV_PYTHON_INSTALL_DIR="$AGENTIC_OPT/python"
do_install() {
  uv python find "$1" >/dev/null 2>&1 && return 0
  uv python install "$1"
  chmod -R a+rX "$UV_PYTHON_INSTALL_DIR"
}
do_env() { echo "UV_PYTHON_INSTALL_DIR=$UV_PYTHON_INSTALL_DIR"; }
do_check() { uv python find "$1"; }
preset_main "$@"
