#!/usr/bin/env bash
# System Gradle (exact version) into $AGENTIC_OPT/gradle/<version>. Projects usually use ./gradlew.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/gradle/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  unzip_to "https://services.gradle.org/distributions/gradle-$1-bin.zip" "$(home "$1")" 1
}
do_env() { echo "GRADLE_HOME=$(home "$1")"; echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/gradle" --version 2>/dev/null | grep -m1 '^Gradle'; }
preset_main "$@"
