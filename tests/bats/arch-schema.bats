#!/usr/bin/env bats
load helpers

setup() {
  [ -d "$REPO_ROOT/image/arch/node_modules" ] || skip "run npm ci in image/arch first"
  V="$REPO_ROOT/image/arch/validate.mjs"
  C="$REPO_ROOT/tests/fixtures/architect/contract"
  S="$REPO_ROOT/skills/architect/schema"
}

# item KIND FILE -> one-element items array on stdout
item() { jq -c --arg k "$1" --arg f "$2" '[{kind:$k,file:$f,data:.}]' "$2"; }
val() { run bash -c "$1 | node '$V' --model '$C/model.json'"; }

@test "the model validates" {
  val "$(declare -f item); item model '$C/model.json'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "plans and the full review validate against the model" {
  for f in 2026-10-20-gift-cards 2026-10-22-move-catalog; do
    val "$(declare -f item); item plan '$C/$f.json'"
    [ "$status" -eq 0 ]
  done
  val "$(declare -f item); item full '$C/full.json'"
  [ "$status" -eq 0 ]
}

@test "model version 2 fails mentioning version" {
  val "$(declare -f item); item model '$C/invalid/model-version-2.json'"
  [ "$status" -eq 1 ]
  [[ "$output" == *version* ]]
}

@test "a plan naming an unknown component fails" {
  val "$(declare -f item); item plan '$C/invalid/plan-unknown-component.json'"
  [ "$status" -eq 1 ]
  [[ "$output" == *invoice-service* ]]
}

@test "a new change without proposed fails" {
  jq 'del(.changes[0].proposed)' "$C/2026-10-20-gift-cards.json" >"$BATS_TEST_TMPDIR/p.json"
  val "$(declare -f item); item plan '$BATS_TEST_TMPDIR/p.json'"
  [ "$status" -eq 1 ]
  [[ "$output" == *proposed* ]]
}

@test "a bad component id fails" {
  jq '.components[0].id = "Bad_Id"' "$C/model.json" >"$BATS_TEST_TMPDIR/m.json"
  run bash -c "$(declare -f item); item model '$BATS_TEST_TMPDIR/m.json' | node '$V'"
  [ "$status" -eq 1 ]
  [[ "$output" == *m.json* ]]
}

@test "a full review naming an unknown component fails" {
  jq '.findings[0].component = "ghost"' "$C/full.json" >"$BATS_TEST_TMPDIR/f.json"
  val "$(declare -f item); item full '$BATS_TEST_TMPDIR/f.json'"
  [ "$status" -eq 1 ]
  [[ "$output" == *ghost* ]]
}

@test "page front matter schemas accept good data and reject bad enums" {
  echo '[{"kind":"component","file":"a.md","data":{"id":"a","name":"A","summary":"s","layer":"api","sources":["src/"],"status":"draft","extra":1}}]' >"$BATS_TEST_TMPDIR/ok.json"
  run node "$V" <"$BATS_TEST_TMPDIR/ok.json"
  [ "$status" -eq 0 ]
  sed 's/"draft"/"done"/' "$BATS_TEST_TMPDIR/ok.json" >"$BATS_TEST_TMPDIR/bad.json"
  run node "$V" <"$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 1 ]
  echo '[{"kind":"architecture","file":"arch.md","data":{"style":"layered","parts":[{"id":"app","name":"App","layers":[{"id":"api","name":"API","mayUse":[]}]}],"principles":[],"patterns":[]}}]' >"$BATS_TEST_TMPDIR/arch.json"
  run node "$V" <"$BATS_TEST_TMPDIR/arch.json"
  [ "$status" -eq 0 ]
}

@test "usage errors exit 2" {
  run node "$V" --bogus </dev/null
  [ "$status" -eq 2 ]
}

@test "python jsonschema agrees on the valid files" {
  run python3 -c '
import json, sys, jsonschema
d, s = sys.argv[1], sys.argv[2]
for f, k in [("model","model"),("2026-10-20-gift-cards","plan-review"),("2026-10-22-move-catalog","plan-review"),("full","full-review")]:
    jsonschema.validate(json.load(open(f"{d}/{f}.json")), json.load(open(f"{s}/{k}.schema.json")))
' "$C" "$S"
  [ "$status" -eq 0 ]
}
