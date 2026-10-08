#!/usr/bin/env bash
# Temurin JDK, latest GA of the given major, into $AGENTIC_OPT/java/<major>.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/java/$1"; }
do_install() {
  local d; d="$(home "$1")"
  if ! present "$d"; then
    untar "https://api.adoptium.net/v3/binary/latest/$1/ga/linux/$(arch_temurin)/jdk/hotspot/normal/eclipse" "$d"
  fi
  if command -v agentic-trust-java >/dev/null 2>&1; then agentic-trust-java "$d"; fi
}
do_env() { echo "JAVA_HOME=$(home "$1")"; echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/java" -version 2>&1 | head -1; }
preset_main "$@"
