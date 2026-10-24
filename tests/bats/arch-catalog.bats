#!/usr/bin/env bats
load helpers

setup() {
  CAT="$REPO_ROOT/skills/architect/catalog"
  source "$REPO_ROOT/image/lib/wiki.sh"
  source "$REPO_ROOT/image/lib/arch.sh"
}

# each KIND: print "file" for every catalog entry of KIND
entries() { ls "$CAT/${1}s"/*.md; }

# need KIND JQ-EXPR: every entry of KIND satisfies the jq expression on its front matter
need() {
  local f
  for f in $(entries "$1"); do
    wiki_fm "$f" | jq -e --arg id "$(basename "$f" .md)" --arg kind "$1" \
      '.id == $id and .kind == $kind and (.name|type=="string") and (.summary|type=="string") and ('"$2"')' >/dev/null \
      || { echo "bad $1 entry: $f"; return 1; }
    [ "$(wc -l < "$f")" -le 40 ] || { echo "too long: $f"; return 1; }
  done
}

@test "the expected entries exist" {
  local i
  for i in layered modular-monolith hexagonal microservices; do [ -f "$CAT/styles/$i.md" ]; [ -f "$CAT/templates/$i.md" ]; done
  for i in make-it-work yagni least-surprise kiss consistent dry clean-code solid design-patterns boy-scout fast; do [ -f "$CAT/principles/$i.md" ]; done
  for i in ports-and-adapters repository adapter; do [ -f "$CAT/patterns/$i.md" ]; done
}

@test "styles carry detect, layers and rules" {
  need style '(.detect|length>0) and (.rules|length>0 and all(type=="string")) and (.layers|length>0 and all(has("id") and has("name") and has("mayUse")))'
}

@test "principles carry direction, breaks and a valid severity" {
  need principle '(.direction|type=="string") and (.plan_break|type=="string") and (.code_break|type=="string") and (.severity|IN("error","warn","info"))'
}

@test "patterns carry use_when, spot and layers_implied" {
  need pattern '(.use_when|type=="string") and (.spot|type=="string") and has("layers_implied")'
}

@test "templates name their style" {
  need template '.style == .id and (.parts|length>0)'
  [ "$(wiki_fm "$CAT/styles/modular-monolith.md" | jq -r .name)" = "Modular monolith, layered" ]
}

@test "templates validate against the architecture schema" {
  [ -d "$REPO_ROOT/image/arch/node_modules" ] || skip "run npm ci in image/arch first"
  local f
  for f in $(entries template); do
    wiki_fm "$f" | jq -c --arg f "$f" '{kind: "architecture", file: $f, data: del(.kind,.id,.name,.summary)}' | jq -s . \
      | node "$REPO_ROOT/image/arch/validate.mjs" || { echo "invalid: $f"; return 1; }
  done
}

@test "template principles and patterns resolve in the catalog" {
  export ARCH_CATALOG_OVERLAY="$BATS_TEST_TMPDIR/none" ROOT="$BATS_TEST_TMPDIR"
  local f k id
  for f in $(entries template); do
    for k in principle pattern; do
      for id in $(wiki_fm "$f" | jq -r ".${k}s[]?"); do
        arch_catalog_find "$k" "$id" >/dev/null || { echo "$f: $k $id"; return 1; }
      done
    done
    arch_catalog_find style "$(wiki_fm "$f" | jq -r .style)" >/dev/null
  done
}

@test "resolution order: project over overlay over built-in" {
  export ROOT="$BATS_TEST_TMPDIR/p" ARCH_DIR=docs/architecture ARCH_CATALOG_OVERLAY="$BATS_TEST_TMPDIR/o"
  mkdir -p "$ARCH_CATALOG_OVERLAY/principles" "$ROOT/docs/architecture/catalog/principles"
  [ "$(arch_catalog_find principle kiss)" = "$(cd "$CAT" && pwd)/principles/kiss.md" ] || [[ "$(arch_catalog_find principle kiss)" == */skills/architect/catalog/principles/kiss.md ]]
  touch "$ARCH_CATALOG_OVERLAY/principles/kiss.md"
  [ "$(arch_catalog_find principle kiss)" = "$ARCH_CATALOG_OVERLAY/principles/kiss.md" ]
  touch "$ROOT/docs/architecture/catalog/principles/kiss.md"
  [ "$(arch_catalog_find principle kiss)" = "$ROOT/docs/architecture/catalog/principles/kiss.md" ]
}

@test "build accepts an overlay-only style id" {
  [ -d "$REPO_ROOT/image/arch/node_modules" ] || skip "run npm ci in image/arch first"
  make_tmp_home
  export AGENTIC_DIR="$REPO_ROOT/image"
  arch_repo
  export ARCH_CATALOG_OVERLAY="$BATS_TEST_TMPDIR/o"
  mkdir -p "$ARCH_CATALOG_OVERLAY/styles"
  printf -- '---\nid: house-style\nname: House style\n---\n' > "$ARCH_CATALOG_OVERLAY/styles/house-style.md"
  sed -i 's/^style: modular-monolith/style: house-style/' "$A/docs/architecture/architecture.md"
  run "$REPO_ROOT/image/bin/agentic-arch" -C "$A" build
  [ "$status" -eq 0 ]
  [ "$(jq -r '.style.name' "$A/docs/architecture/model.json")" = "House style" ]
}

@test "both architect fixtures pass check with the built-in catalog only" {
  [ -d "$REPO_ROOT/image/arch/node_modules" ] || skip "run npm ci in image/arch first"
  make_tmp_home
  export AGENTIC_DIR="$REPO_ROOT/image" ARCH_CATALOG_OVERLAY="$BATS_TEST_TMPDIR/none"
  arch_repo
  run "$REPO_ROOT/image/bin/agentic-arch" -C "$A" check
  [ "$output" = "architect: ok" ]
  P="$BATS_TEST_TMPDIR/pk"; cp -r "$REPO_ROOT/tests/fixtures/architect/packages" "$P"
  mv "$P/CLAUDE.fixture.md" "$P/CLAUDE.md"
  run "$REPO_ROOT/image/bin/agentic-arch" -C "$P" check
  echo "$output"; [ "$output" = "architect: ok" ]
}

@test "with ports-and-adapters, integration and repository may use service in the catalog defaults" {
  local f
  for f in "$CAT/styles/modular-monolith.md" "$CAT/templates/modular-monolith.md"; do
    wiki_fm "$f" | jq -e '[(.layers // .parts[0].layers)[] | select(.id == "integration" or .id == "repository") | .mayUse | index("service") != null] | length == 2 and all' >/dev/null \
      || { echo "integration and repository must list service: $f"; false; }
  done
  for f in layered microservices; do
    wiki_fm "$CAT/styles/$f.md" | jq -e '.rules | any(test("ports-and-adapters") and test("may use service"))' >/dev/null \
      || { echo "rule missing in $f"; false; }
  done
  wiki_fm "$CAT/patterns/ports-and-adapters.md" | jq -e '.implies | test("integration and repository may use service")' >/dev/null
}
