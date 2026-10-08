#!/usr/bin/env bash
# TFLint (exact version) into $AGENTIC_OPT/tflint/<version>/bin.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/tflint/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  unzip_to "https://github.com/terraform-linters/tflint/releases/download/v$1/tflint_linux_$(arch_go).zip" "$(home "$1")/bin"
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/tflint" --version 2>/dev/null | head -1; }
preset_main "$@"
