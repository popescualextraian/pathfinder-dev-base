#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  export AGENTIC_DIR="$REPO_ROOT/image"
  ARCH="$REPO_ROOT/image/bin/agentic-arch"
  arch_repo
  g() { git -C "$A" -c user.name=t -c user.email=t@example.com "$@"; }
  g init -q
  g add -A
  g commit -q -m base
}

@test "files map to components, omitted and unclaimed; docs and config are skipped" {
  echo "// x" >> "$A/backend/src/service/orders/order-service.ts"
  echo "// x" >> "$A/backend/src/service/orders/payments.ts"
  echo "// x" >> "$A/frontend/src/catalog/views/catalog-views.ts"
  echo "// x" >> "$A/backend/src/main.ts"
  echo "x" > "$A/scripts.sh"
  echo "// x" >> "$A/docs/architecture/components/order-store.md"
  echo "x" >> "$A/CLAUDE.md"
  mkdir -p "$A/.github" "$A/.claude"; echo x > "$A/.github/a.md"; echo x > "$A/.claude/b.md"
  g add -A; g commit -q -m change
  run "$ARCH" -C "$A" affected HEAD~1..HEAD
  [ "$status" -eq 0 ]
  expected="omitted backend/src/main.ts
component order-service backend/src/service/orders/order-service.ts
component order-service backend/src/service/orders/payments.ts
component catalog-views frontend/src/catalog/views/catalog-views.ts
unclaimed scripts.sh"
  [ "$output" = "$expected" ] || { echo "$output"; false; }
}

@test "a working-tree range works" {
  echo "// x" >> "$A/backend/src/api/orders/orders-api.ts"
  run "$ARCH" -C "$A" affected HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "component orders-api backend/src/api/orders/orders-api.ts" ]
}

@test "the longest source match owns a file" {
  sed -i 's#^sources:#sources:\n  - backend/src/service/#' "$A/docs/architecture/components/catalog-service.md"
  echo "// x" >> "$A/backend/src/service/orders/order-service.ts"
  echo "// x" >> "$A/backend/src/service/catalog/catalog-service.ts"
  run "$ARCH" -C "$A" affected HEAD
  [[ "$output" == *"component order-service backend/src/service/orders/order-service.ts"* ]]
  [[ "$output" == *"component catalog-service backend/src/service/catalog/catalog-service.ts"* ]]
  echo "// x" > "$A/backend/src/service/new.ts"
  git -C "$A" add -A
  run "$ARCH" -C "$A" affected HEAD
  [[ "$output" == *"component catalog-service backend/src/service/new.ts"* ]]
}

@test "a bad range exits 2" {
  run "$ARCH" -C "$A" affected nonesuch..nowhere
  [ "$status" -eq 2 ]
}

@test "affected without a range prints usage" {
  run "$ARCH" -C "$A" affected
  [ "$status" -eq 2 ]
  [[ "$output" == *usage* ]]
}

@test "-C on a project in a subfolder maps paths relative to the project" {
  r="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$r"
  cp -r "$REPO_ROOT/tests/fixtures/architect/good" "$r/shop"
  git -C "$r" init -q
  git -C "$r" add -A
  git -C "$r" -c user.name=t -c user.email=t@example.com commit -q -m base
  echo "// x" >> "$r/shop/backend/src/api/orders/orders-api.ts"
  echo "x" > "$r/outside.txt"
  git -C "$r" add -A
  run "$ARCH" -C "$r/shop" affected HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "component orders-api backend/src/api/orders/orders-api.ts" ]
}
