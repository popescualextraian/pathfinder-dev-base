#!/usr/bin/env bash
# Python via uv into $AGENTIC_OPT/python, visible to every user's uv.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
export UV_PYTHON_INSTALL_DIR="$AGENTIC_OPT/python"
# Only uv-managed builds count; `uv python find` would also match a system interpreter.
managed() { compgen -G "$UV_PYTHON_INSTALL_DIR/cpython-$1.*" | head -1; }
do_install() {
  [ -n "$(managed "$1")" ] && return 0
  mkdir -p "$UV_PYTHON_INSTALL_DIR"
  uv python install "$1"
  chmod -R a+rX "$UV_PYTHON_INSTALL_DIR"
}
do_env() { echo "UV_PYTHON_INSTALL_DIR=$UV_PYTHON_INSTALL_DIR"; }
do_check() { local m; m="$(managed "$1")"; [ -n "$m" ] && echo "$m"; }
preset_main "$@"
