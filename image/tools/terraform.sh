#!/usr/bin/env bash
# Terraform (exact version) into $AGENTIC_OPT/terraform/<version>/bin.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/terraform/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  unzip_to "https://releases.hashicorp.com/terraform/$1/terraform_$1_linux_$(arch_go).zip" "$(home "$1")/bin"
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/terraform" version 2>/dev/null | head -1; }
preset_main "$@"
