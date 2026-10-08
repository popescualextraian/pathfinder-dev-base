#!/usr/bin/env bash
# kubectl (exact version) into $AGENTIC_OPT/kubectl/<version>/bin.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/kubectl/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  mkdir -p "$(home "$1")/bin"
  fetch "https://dl.k8s.io/release/v$1/bin/linux/$(arch_go)/kubectl" "$(home "$1")/bin/kubectl"
  chmod 755 "$(home "$1")/bin/kubectl"
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/kubectl" version --client 2>/dev/null | head -1; }
preset_main "$@"
