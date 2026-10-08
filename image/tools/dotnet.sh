#!/usr/bin/env bash
# .NET SDK, latest of the given channel (e.g. 8.0), into $AGENTIC_OPT/dotnet/<channel>.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/dotnet/$1"; }
do_install() {
  local s
  present "$(home "$1")" && return 0
  s="$(mktemp)"
  fetch https://dot.net/v1/dotnet-install.sh "$s"
  bash "$s" --channel "$1" --install-dir "$(home "$1")" --no-path
  rm -f "$s"
}
do_env() {
  echo "DOTNET_ROOT=$(home "$1")"
  echo "DOTNET_CLI_TELEMETRY_OPTOUT=1"
  echo "PATH=$(home "$1")"
}
do_check() { "$(home "$1")/dotnet" --version 2>/dev/null; }
preset_main "$@"
