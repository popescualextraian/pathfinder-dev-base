#!/usr/bin/env bash
# Go (exact version) into $AGENTIC_OPT/go/<version>.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/go/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  untar "https://go.dev/dl/go$1.linux-$(arch_go).tar.gz" "$(home "$1")" 1
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/go" version 2>/dev/null; }
preset_main "$@"
