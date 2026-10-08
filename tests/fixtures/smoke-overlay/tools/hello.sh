#!/usr/bin/env bash
# A preset only the overlay provides.
# shellcheck source=/dev/null
source /opt/agentic/tools/_lib.sh
home() { echo "$AGENTIC_OPT/hello/$1"; }
do_install() {
  mkdir -p "$(home "$1")/bin"
  printf '#!/bin/sh\necho "hello %s"\n' "$1" > "$(home "$1")/bin/hello"
  chmod 755 "$(home "$1")/bin/hello"
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/hello"; }
preset_main "$@"
