#!/usr/bin/env bash
# Helm (exact version) into $AGENTIC_OPT/helm/<version>/bin.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/helm/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  untar "https://get.helm.sh/helm-v$1-linux-$(arch_go).tar.gz" "$(home "$1")/bin" 1
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/helm" version --short 2>/dev/null; }
preset_main "$@"
