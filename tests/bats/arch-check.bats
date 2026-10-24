#!/usr/bin/env bats
load helpers

setup() {
  [ -d "$REPO_ROOT/image/arch/node_modules" ] || skip "run npm ci in image/arch first (validate.mjs needs ajv)"
  make_tmp_home
  export AGENTIC_DIR="$REPO_ROOT/image"
  ARCH="$REPO_ROOT/image/bin/agentic-arch"
  arch_repo
  D="$A/docs/architecture"
  # principles and patterns of the fixture resolve through a stub overlay catalog
  export ARCH_CATALOG_OVERLAY="$BATS_TEST_TMPDIR/overlay"
  mkdir -p "$ARCH_CATALOG_OVERLAY"/{principles,patterns,styles}
  local i
  for i in make-it-work yagni least-surprise kiss consistent dry clean-code solid; do touch "$ARCH_CATALOG_OVERLAY/principles/$i.md"; done
  for i in ports-and-adapters repository; do touch "$ARCH_CATALOG_OVERLAY/patterns/$i.md"; done
}

# chk SUBSTRING: check fails with one line containing SUBSTRING
chk() {
  run "$ARCH" -C "$A" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"$1"* ]] || { echo "$output"; false; }
  [[ "$output" == *"problem(s)"* ]]
}

@test "the good fixture passes check" {
  run "$ARCH" -C "$A" check
  [ "$status" -eq 0 ]
  [ "$output" = "architect: ok" ]
}

@test "check runs validate.mjs on ARCH_NODE" {
  log="$BATS_TEST_TMPDIR/node.log"
  printf '#!/bin/sh\necho "$@" >> "%s"\nexec node "$@"\n' "$log" > "$BATS_TEST_TMPDIR/node-stub"
  chmod +x "$BATS_TEST_TMPDIR/node-stub"
  ARCH_NODE="$BATS_TEST_TMPDIR/node-stub" run "$ARCH" -C "$A" check
  [ "$status" -eq 0 ]
  grep -q 'arch/validate.mjs --model ' "$log"
}

@test "no docs/architecture prints a message and exits 0" {
  rm -r "$D"
  run "$ARCH" -C "$A" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to check"* ]]
}

@test "a component page without a summary fails the shape check" {
  sed -i '/^summary:/d' "$D/components/order-store.md"
  chk "components/order-store.md: "
  [[ "$output" == *summary* ]]
}

@test "a duplicate component id is reported" {
  cp "$D/components/order-store.md" "$D/components/order-store-copy.md"
  chk "duplicate component id order-store"
}

@test "an id that differs from the file name is reported" {
  sed -i 's/^id: order-store$/id: order-stor/' "$D/components/order-store.md"
  chk "id order-stor differs from the file name order-store"
}

@test "a part, layer or module not in architecture.md is reported" {
  sed -i 's/^part: backend$/part: nowhere/' "$D/components/order-store.md"
  chk "part nowhere is not in architecture.md"
}

@test "an unknown layer is reported" {
  sed -i 's/^layer: repository$/layer: storage/' "$D/components/order-store.md"
  chk "layer storage is not in part backend"
}

@test "an unknown module is reported" {
  sed -i 's/^module: orders$/module: billing/' "$D/components/order-store.md"
  chk "module billing is not in part backend"
}

@test "mayUse naming an unknown layer is reported" {
  sed -i 's/mayUse: \[state\]/mayUse: [statee]/' "$D/architecture.md"
  chk "may use unknown layer statee"
}

@test "a boundary using an unknown layer is reported" {
  sed -i '/^principles:/i boundaries:\n  - { id: b1, folder: backend/src/api, uses: [nolayer], entry: index.ts }' "$D/architecture.md"
  chk "boundary b1 uses unknown layer nolayer"
}

@test "talks_to naming an unknown component is reported" {
  sed -i 's/to: order-store, via: call/to: ghost, via: call/' "$D/components/order-service.md"
  chk "talks_to names unknown component ghost"
}

@test "an unknown parent is reported" {
  sed -i 's/^layer: repository$/layer: repository\nparent: ghost/' "$D/components/order-store.md"
  chk "parent names unknown component ghost"
}

@test "a principle, pattern or style not in the catalog is reported" {
  sed -i 's/make-it-work, yagni/make-it-work, nonesuch, yagni/' "$D/architecture.md"
  chk "principle nonesuch is not in the catalog"
}

@test "an unknown pattern is reported" {
  sed -i 's/patterns: \[ports-and-adapters, repository\]/patterns: [ports-and-adapters, nopattern]/' "$D/architecture.md"
  chk "pattern nopattern is not in the catalog"
}

@test "an unknown style is reported" {
  sed -i 's/^style: modular-monolith$/style: nostyle/' "$D/architecture.md"
  chk "style nostyle is not in the catalog"
}

@test "a source missing on disk is reported" {
  sed -i 's#backend/src/repository/orders/order-store.ts#backend/src/repository/orders/gone.ts#' "$D/components/order-store.md"
  chk "components/order-store.md: source backend/src/repository/orders/gone.ts does not exist"
}

@test "a source claimed twice is reported" {
  sed -i 's#^sources:#sources:\n  - backend/src/repository/catalog/catalog-store.ts#' "$D/components/order-store.md"
  chk "source backend/src/repository/catalog/catalog-store.ts is also claimed by"
}

@test "a component page over its limit is reported" {
  for i in $(seq 1 85); do echo "Line number $i of filler text."; echo; done >> "$D/components/order-store.md"
  chk "components/order-store.md: "
  [[ "$output" == *"limit 80"* ]]
}

@test "an index over 70 lines is reported" {
  for i in $(seq 1 70); do echo "- filler $i"; done >> "$D/index.md"
  chk "docs/architecture/index.md: "
  [[ "$output" == *"limit 70"* ]]
}

@test "a table over 10 rows is reported" {
  { echo; echo "| a | b |"; echo "|---|---|"; for i in $(seq 1 11); do echo "| $i | x |"; done; } >> "$D/components/order-store.md"
  chk "table with 11 rows"
}

@test "a broken relative link in authored text is reported" {
  echo "See [more](missing-page.md)." >> "$D/components/order-store.md"
  chk "components/order-store.md: broken link missing-page.md"
}

@test "a working relative link passes" {
  echo "See [the service](order-service.md)." >> "$D/components/order-store.md"
  run "$ARCH" -C "$A" check
  [ "$status" -eq 0 ]
}

@test "CLAUDE.md without the index import is reported" {
  echo "# Shop" > "$A/CLAUDE.md"
  chk "CLAUDE.md: no @docs/architecture/index.md line"
}

@test "a stale index is reported" {
  echo "- an edit by hand" >> "$D/index.md"
  chk "docs/architecture/index.md: generated content is stale; run agentic-arch build"
}

@test "a stale model.json is reported" {
  jq '.style.name = "Other"' "$D/model.json" > "$D/model.tmp" && mv "$D/model.tmp" "$D/model.json"
  chk "docs/architecture/model.json: generated content is stale; run agentic-arch build"
}

@test "a stale rules file is reported" {
  echo "// an edit by hand" >> "$D/rules.depcruise.cjs"
  chk "docs/architecture/rules.depcruise.cjs: generated content is stale; run agentic-arch build"
}

@test "a missing generated file is stale" {
  rm "$D/index.md"
  chk "docs/architecture/index.md: generated content is stale"
}

@test "generated files with CRLF line endings are not stale" {
  sed -i 's/$/\r/' "$D/index.md" "$D/model.json" "$D/rules.depcruise.cjs"
  run "$ARCH" -C "$A" check
  [ "$status" -eq 0 ]
  [ "$output" = "architect: ok" ]
}

@test "an accepted finding without an exception is reported" {
  sed -i '/^exceptions:/,/^    reason:/d' "$D/architecture.md"
  "$ARCH" -C "$A" build
  chk "reviews/full.json: accepted finding layers/orders-api/imports-order-store is not in exceptions"
}

@test "an invalid review file is reported" {
  jq '.version = 2' "$D/reviews/full.json" > "$D/reviews/f.tmp" && mv "$D/reviews/f.tmp" "$D/reviews/full.json"
  chk "docs/architecture/reviews/full.json: "
}

@test "a plan review with an unknown component is reported" {
  jq '.changes[0].component = "invoice-service" | .changes[0].change = "changed"' "$D/reviews/plans/2026-10-20-gift-cards.json" > "$D/reviews/p.tmp"
  mv "$D/reviews/p.tmp" "$D/reviews/plans/2026-10-20-gift-cards.json"
  chk "invoice-service"
}

@test "a stale exception warns and still passes" {
  sed -i 's/^exceptions:/exceptions:\n  - { id: dry\/nowhere\/never-found, rule: dry, component: order-service, reason: old }/' "$D/architecture.md"
  "$ARCH" -C "$A" build
  run "$ARCH" -C "$A" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn: dry/nowhere/never-found: exception matches no finding"* ]]
  [[ "$output" == *"architect: ok"* ]]
}

@test "a plan-scoped exception is not stale while its plan review exists" {
  sed -i 's/^exceptions:/exceptions:\n  - { id: dry\/nowhere\/never-found, rule: dry, component: order-service, reason: old, plan: 2026-10-20-gift-cards }/' "$D/architecture.md"
  "$ARCH" -C "$A" build
  run "$ARCH" -C "$A" check
  [ "$status" -eq 0 ]
  [[ "$output" != *"never-found"* ]]
  rm "$D/reviews/plans/2026-10-20-gift-cards.json"
  run "$ARCH" -C "$A" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn: dry/nowhere/never-found: exception matches no finding"* ]]
}

@test "a project with one part and no modules passes check" {
  touch "$ARCH_CATALOG_OVERLAY/styles/layered.md"
  P="$BATS_TEST_TMPDIR/plain"
  mkdir -p "$P/docs/architecture/components" "$P/src"
  echo "export const x = 1;" > "$P/src/app.ts"
  echo "@docs/architecture/index.md" > "$P/CLAUDE.md"
  cat > "$P/docs/architecture/architecture.md" <<'MD'
---
style: layered
parts:
  - id: app
    name: App
    layers:
      - { id: core, name: Core, mayUse: [] }
principles: [kiss]
patterns: []
---

# Architecture
MD
  cat > "$P/docs/architecture/components/app.md" <<'MD'
---
id: app
name: App
summary: "The app."
layer: core
sources:
  - src/app.ts
---

# App
MD
  "$ARCH" -C "$P" build
  run "$ARCH" -C "$P" check
  [ "$status" -eq 0 ]
  [ "$output" = "architect: ok" ]
}
