#!/usr/bin/env bash
# GitLab CLI (exact version) into $AGENTIC_OPT/glab/<version>.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/glab/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  untar "https://gitlab.com/gitlab-org/cli/-/releases/v$1/downloads/glab_$1_linux_$(arch_go).tar.gz" "$(home "$1")" 0
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/glab" --version 2>/dev/null | head -1; }
preset_main "$@"
