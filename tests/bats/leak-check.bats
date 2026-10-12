#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  R="$BATS_TEST_TMPDIR/repo"
  git init -q "$R"
  export AGENTIC_LEAK_DENYLIST="$BATS_TEST_TMPDIR/deny.txt"
  printf '# comment\nacme-corp\n\n' > "$AGENTIC_LEAK_DENYLIST"
  echo 'hello' > "$R/ok.txt"
  LC="$REPO_ROOT/tools/leak-check.sh"
}

@test "clean repository passes" {
  run bash "$LC" "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "a denylisted term in a tracked file fails, case-insensitively" {
  echo 'see https://wiki.ACME-Corp.example' > "$R/doc.md"
  git -C "$R" add doc.md
  run bash "$LC" "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"doc.md"* ]]
}

@test "an untracked, not ignored file is checked too" {
  echo 'acme-corp' > "$R/new.txt"
  run bash "$LC" "$R"
  [ "$status" -eq 1 ]
}

@test "an ignored file is not checked" {
  echo 'secret.txt' > "$R/.gitignore"
  echo 'acme-corp' > "$R/secret.txt"
  run bash "$LC" "$R"
  [ "$status" -eq 0 ]
}

@test "certificates and keys outside tests/fixtures fail" {
  echo x > "$R/ca.crt"
  run bash "$LC" "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ca.crt"* ]]
}

@test "certificates under tests/fixtures are allowed" {
  mkdir -p "$R/tests/fixtures"
  echo x > "$R/tests/fixtures/test.pem"
  run bash "$LC" "$R"
  [ "$status" -eq 0 ]
}

@test "a real .env fails, .env.example passes" {
  echo 'A=1' > "$R/.env.example"
  run bash "$LC" "$R"
  [ "$status" -eq 0 ]
  echo 'A=1' > "$R/.env"
  run bash "$LC" "$R"
  [ "$status" -eq 1 ]
}

@test "a missing denylist fails with a hint" {
  rm "$AGENTIC_LEAK_DENYLIST"
  run bash "$LC" "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"configure your denylist"* ]]
}

@test "a non-ASCII filename containing a denylisted term is checked" {
  echo 'acme-corp' > "$R/dä.txt"
  run bash "$LC" "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"acme-corp"* ]]
}

@test "a comment-only denylist fails with the hint" {
  printf '# only a comment\n\n   \n' > "$AGENTIC_LEAK_DENYLIST"
  run bash "$LC" "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"configure your denylist"* ]]
}

@test "a grep error fails the check instead of reporting clean" {
  echo 'x' > "$R/locked.txt"
  chmod 000 "$R/locked.txt"
  run bash "$LC" "$R"
  chmod 644 "$R/locked.txt"
  [ "$status" -eq 1 ]
  [[ "$output" != *"clean"* ]]
  [[ "$output" == *"grep failed"* ]]
}

@test "a CRLF denylist still finds its terms" {
  printf '# comment\r\nacme-corp\r\n\r\n' > "$AGENTIC_LEAK_DENYLIST"
  echo 'see acme-corp here' > "$R/doc.md"
  git -C "$R" add doc.md
  run bash "$LC" "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"doc.md"* ]]
}

@test "a lockfile integrity hash that happens to contain a term is ignored, other lockfile text is not" {
  mkdir "$R/bridge"
  printf 'acmecorp\n' >> "$AGENTIC_LEAK_DENYLIST"
  printf '      "integrity": "sha512-xxAcMeCoRpxx==",\n' > "$R/bridge/package-lock.json"
  run bash "$LC" "$R"
  [ "$status" -eq 0 ]
  printf '      "resolved": "https://acmecorp.example/x.tgz",\n' >> "$R/bridge/package-lock.json"
  run bash "$LC" "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"resolved"* ]]
  [[ "$output" != *"integrity"* ]]
}
