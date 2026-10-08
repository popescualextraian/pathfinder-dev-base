#!/usr/bin/env bash
# Node.js, latest release of the given major, into $AGENTIC_OPT/node/<major>.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/node/$1"; }
do_install() {
  local base="https://nodejs.org/dist/latest-v$1.x" sums file
  present "$(home "$1")" && return 0
  sums="$(mktemp)"
  fetch "$base/SHASUMS256.txt" "$sums"
  file="$(awk -v a="linux-$(arch_node).tar.xz" '$2 ~ a"$" {print $2}' "$sums")"
  rm -f "$sums"
  [ -n "$file" ] || { echo "node.sh: no linux build for major $1" >&2; return 1; }
  untar "$base/$file" "$(home "$1")"
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/node" --version; }
preset_main "$@"
