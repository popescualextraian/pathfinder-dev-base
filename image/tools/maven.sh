#!/usr/bin/env bash
# Apache Maven (exact version) into $AGENTIC_OPT/maven/<version>.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/maven/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  untar "https://archive.apache.org/dist/maven/maven-${1%%.*}/$1/binaries/apache-maven-$1-bin.tar.gz" "$(home "$1")"
}
do_env() { echo "MAVEN_HOME=$(home "$1")"; echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/mvn" -v 2>/dev/null | head -1; }
preset_main "$@"
