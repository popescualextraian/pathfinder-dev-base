#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_OPT="$BATS_TEST_TMPDIR/opt" AGENTIC_CA_DIR="$BATS_TEST_TMPDIR/ca"
  mkdir -p "$AGENTIC_OPT" "$AGENTIC_CA_DIR" "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" LOG="$BATS_TEST_TMPDIR/calls.log"
  B="$REPO_ROOT/image/bin"
}

# fake_jdk MAJOR VERSION_STRING [jre]: a JDK dir with a release file and a logging keytool.
fake_jdk() {
  local d="$AGENTIC_OPT/java/$1"
  mkdir -p "$d/bin" "$d/lib/security"
  if [ "${3:-}" = jre ]; then rm -rf "$d/lib/security"; mkdir -p "$d/jre/lib/security"; fi
  printf 'JAVA_VERSION="%s"\n' "$2" > "$d/release"
  printf '#!/bin/sh\necho "keytool %s $*" >> "$LOG"\n' "$1" > "$d/bin/keytool"
  chmod +x "$d/bin/keytool"
}

@test "trust-java imports every cert into every JDK, Java 8 included" {
  fake_jdk 17 17.0.12; fake_jdk 8 1.8.0_422 jre
  touch "$AGENTIC_CA_DIR/corp.crt"
  run "$B/agentic-trust-java"
  [ "$status" -eq 0 ]
  grep -q "keytool 17 -importcert -noprompt -keystore $AGENTIC_OPT/java/17/lib/security/cacerts -storepass changeit -alias agentic-corp -file $AGENTIC_CA_DIR/corp.crt" "$LOG"
  grep -q "keytool 8 -importcert .*-keystore $AGENTIC_OPT/java/8/jre/lib/security/cacerts" "$LOG"
}

@test "trust-java does nothing without certs" {
  fake_jdk 17 17.0.12
  run "$B/agentic-trust-java"
  [ "$status" -eq 0 ]
  [ ! -f "$LOG" ]
}

@test "trust-nss adds every cert to the user's NSS database" {
  printf '#!/bin/sh\necho "certutil $*" >> "$LOG"\n' > "$BATS_TEST_TMPDIR/bin/certutil"; chmod +x "$BATS_TEST_TMPDIR/bin/certutil"
  touch "$AGENTIC_CA_DIR/corp.crt"
  run "$B/agentic-trust-nss"
  [ "$status" -eq 0 ]
  grep -q "certutil -d sql:$HOME/.pki/nssdb -A -t C,, -n agentic-corp -i $AGENTIC_CA_DIR/corp.crt" "$LOG"
}

@test "render-toolchains lists every JDK by major, sorted, in Maven and Gradle files" {
  fake_jdk 17 17.0.12; fake_jdk 8 1.8.0_422 jre; fake_jdk 21 21.0.4
  mkdir -p "$HOME/.gradle"; printf 'org.gradle.daemon=false\norg.gradle.java.installations.paths=/old\n' > "$HOME/.gradle/gradle.properties"
  run "$B/agentic-render-toolchains"
  [ "$status" -eq 0 ]
  [ "$(grep -o '<version>[0-9]*</version>' "$HOME/.m2/toolchains.xml" | tr -d '\n')" = "<version>8</version><version>17</version><version>21</version>" ]
  grep -q "<jdkHome>$AGENTIC_OPT/java/8</jdkHome>" "$HOME/.m2/toolchains.xml"
  grep -qx 'org.gradle.daemon=false' "$HOME/.gradle/gradle.properties"
  grep -qx "org.gradle.java.installations.paths=$AGENTIC_OPT/java/8,$AGENTIC_OPT/java/17,$AGENTIC_OPT/java/21" "$HOME/.gradle/gradle.properties"
  [ "$(grep -c installations.paths "$HOME/.gradle/gradle.properties")" -eq 1 ]
}

@test "remap-user changes ids only when they differ" {
  for c in groupmod usermod chown; do
    printf '#!/bin/sh\necho "%s $*" >> "$LOG"\n' "$c" > "$BATS_TEST_TMPDIR/bin/$c"; chmod +x "$BATS_TEST_TMPDIR/bin/$c"
  done
  printf '#!/bin/sh\ncase "$1" in -u) echo 1000;; -g) echo 1000;; esac\n' > "$BATS_TEST_TMPDIR/bin/id"; chmod +x "$BATS_TEST_TMPDIR/bin/id"
  run "$B/agentic-remap-user" 1000 1000
  [ "$status" -eq 0 ]
  [ ! -f "$LOG" ]
  run "$B/agentic-remap-user" 1001 1002
  [ "$status" -eq 0 ]
  grep -q "groupmod -o -g 1002 dev" "$LOG"
  grep -q "usermod -o -u 1001 -g 1002 dev" "$LOG"
  grep -q "chown -R 1001:1002" "$LOG"
}

@test "remap-user chowns only the directories that exist" {
  for c in groupmod usermod chown; do
    printf '#!/bin/sh\necho "%s $*" >> "$LOG"\n' "$c" > "$BATS_TEST_TMPDIR/bin/$c"; chmod +x "$BATS_TEST_TMPDIR/bin/$c"
  done
  printf '#!/bin/sh\necho 1000\n' > "$BATS_TEST_TMPDIR/bin/id"; chmod +x "$BATS_TEST_TMPDIR/bin/id"
  printf '#!/bin/sh\nfor a; do case "$a" in /*) [ -e "$a" ] || { echo "chown: $a missing" >&2; exit 1; };; esac; done\necho "chown $*" >> "$LOG"\n' > "$BATS_TEST_TMPDIR/bin/chown"
  chmod +x "$BATS_TEST_TMPDIR/bin/chown"
  run "$B/agentic-remap-user" 1001 1002
  [ "$status" -eq 0 ]
  grep -q "chown -R 1001:1002 /home/dev" "$LOG"
  ! grep -q "/opt/agentic/claude-plugins" "$LOG" || [ -e /opt/agentic/claude-plugins ]
}

@test "install-plugins installs only missing plugins and reports failures after trying all" {
  mkdir -p "$HOME/.claude/plugins"
  echo '{"plugins":{"have@m":[{}]}}' > "$HOME/.claude/plugins/installed_plugins.json"
  printf '#!/bin/sh\necho "claude $*" >> "$LOG"\n[ "$3" = "bad@m" ] && exit 1\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/claude"; chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  run "$B/agentic-install-plugins" '{"claude":["have@m","bad@m","new@m"],"marketplaces":["o/m"]}'
  [ "$status" -eq 1 ]
  grep -q "claude plugin marketplace add o/m" "$LOG"
  grep -q "claude plugin install new@m" "$LOG"
  ! grep -q "install have@m" "$LOG"
}

@test "install-plugins warns about a failed marketplace add and still installs" {
  mkdir -p "$HOME/.claude/plugins"
  printf '#!/bin/sh\necho "claude $*" >> "$LOG"\ncase "$3" in add) echo "boom" >&2; exit 1;; esac\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/claude"; chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  run "$B/agentic-install-plugins" '{"claude":["new@m"],"marketplaces":["o/badmarket"]}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"o/badmarket"* ]]
  [[ "$output" == *"boom"* ]]
  grep -q "claude plugin install new@m" "$LOG"
}

@test "use-java switches JAVA_HOME and PATH in the current shell" {
  fake_jdk 11 11.0.24
  printf '#!/bin/sh\necho "openjdk version 11"\n' > "$AGENTIC_OPT/java/11/bin/java"; chmod +x "$AGENTIC_OPT/java/11/bin/java"
  run bash -c "source '$REPO_ROOT/image/profile.d/agentic.sh'; use-java 11 && echo \"\$JAVA_HOME|\$(command -v java)\""
  [ "$status" -eq 0 ]
  [ "$output" = "$AGENTIC_OPT/java/11|$AGENTIC_OPT/java/11/bin/java" ]
}

@test "use-tool refuses a version that is not installed" {
  run bash -c "source '$REPO_ROOT/image/profile.d/agentic.sh'; use-java 99"
  [ "$status" -eq 1 ]
  [[ "$output" == *"java 99 is not installed"* ]]
}
