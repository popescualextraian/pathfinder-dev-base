#!/usr/bin/env bats
load helpers
bats_require_minimum_version 1.5.0

setup() {
  make_tmp_home
  export AGENTIC_DIR="$REPO_ROOT/image"
  ARCH="$REPO_ROOT/image/bin/agentic-arch"
  export ARCH_TOOLS="$REPO_ROOT/image/arch"
  arch_repo
  P="$BATS_TEST_TMPDIR/packages"
  cp -r "$REPO_ROOT/tests/fixtures/architect/packages" "$P"
  mv "$P/CLAUDE.fixture.md" "$P/CLAUDE.md"
  R="$P/docs/architecture/rules.depcruise.cjs"
}

# need_tools: skip unless dependency-cruiser is installed in ARCH_TOOLS.
need_tools() {
  [ -d "$ARCH_TOOLS/node_modules/dependency-cruiser" ] \
    || skip "$ARCH_TOOLS/node_modules/dependency-cruiser is absent: run npm ci in image/arch"
}

# deps DIR [ARGS]: build, then deps; the findings land in $output.
deps() {
  local d="$1"; shift
  "$ARCH" -C "$d" build
  run "$ARCH" -C "$d" deps "$@"
}

# ids: the finding ids of $output, comma separated.
ids() { jq -r '[.[].id] | join(",")' <<<"$output"; }

# rule NAME: the generated rule NAME as JSON.
rule() { node -e 'const r = require(process.argv[1]); console.log(JSON.stringify(r.forbidden.filter((x) => x.name === process.argv[2])))' "$R" "$1"; }

@test "the shop yields exactly the accepted layer break" {
  need_tools
  deps "$A"
  [ "$status" -eq 1 ]
  [ "$(ids)" = layers/orders-api/imports-order-store ]
  [ "$(jq -c '.[0] | del(.id)' <<<"$output")" = '{"rule":"layers:api>repository","component":"orders-api","severity":"error","source":"depcruise","text":"backend/src/api/orders/orders-api.ts imports backend/src/repository/orders/order-store.ts"}' ]
}

@test "the clean packages fixture yields [] with no false positive from nested ownership" {
  need_tools
  deps "$P"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "a layer break inside a package is a layers finding" {
  need_tools
  echo "import { loadItems } from '../repository/backlog-store';" >> "$P/backend/src/backlog/api/backlog-api.ts"
  deps "$P"
  [ "$status" -eq 1 ]
  [ "$(ids)" = layers/backlog-api/imports-backlog-store ]
  [ "$(jq -r '.[0].rule' <<<"$output")" = 'layers:api>repository' ]
}

@test "importing past another package's entry is a boundaries finding" {
  need_tools
  echo "import { listItems } from '../../backlog/service/backlog-service';" >> "$P/backend/src/schedule/api/schedule-api.ts"
  deps "$P"
  [ "$(ids)" = boundaries/schedule-api/imports-backlog-service ]
  [ "$(jq -r '.[0].rule' <<<"$output")" = 'boundaries:backlog-package:entry' ]
}

@test "a package using a layer outside its uses is a boundaries finding" {
  need_tools
  echo "import { start } from '../../main';" >> "$P/backend/src/backlog/repository/backlog-store.ts"
  deps "$P"
  [ "$(ids)" = boundaries/backlog-store/imports-main,layers/backlog-store/imports-main ]
  [ "$(jq -r '.[0].rule' <<<"$output")" = 'boundaries:backlog-package:uses' ]
}

@test "a cross-part import is a parts finding unless the part may use the other" {
  need_tools
  echo "import { log } from '../../backend/src/commons/log';" >> "$P/frontend/src/app.ts"
  deps "$P"
  [ "$(ids)" = parts/web/imports-commons ]
  [ "$(jq -r '.[0].rule' <<<"$output")" = 'parts:frontend>backend' ]
  sed -i 's/^      - { id: ui, name: UI, mayUse: \[\] }$/&\n    mayUse: [backend]/' "$P/docs/architecture/architecture.md"
  deps "$P"
  [ "$output" = '[]' ]
}

@test "a nested component is checked in its own layer, not the outer one" {
  need_tools
  echo "import { listItems } from '../backlog/service/backlog-service';" >> "$P/backend/src/commons/log.ts"
  deps "$P"
  [ "$(jq -r '.[] | select(.id == "layers/commons/imports-backlog-service") | .rule' <<<"$output")" = 'layers:commons>service' ]
  ! jq -e '.[] | select(.rule | startswith("layers:boot"))' <<<"$output"
}

@test "layer folders own paths in the rules" {
  need_tools
  "$ARCH" -C "$P" build
  rule 'layers:commons>service' | jq -e '.[0].to.path | index("^backend/src/schedule/service/")'
  # the outer component's rules leave the nested owners out
  rule 'layers:boot>service' | jq -e '.[0].from.path == ["^backend/src/"] and (.[0].from.pathNot | index("^backend/src/commons/"))'
}

@test "a break from a file owned only by a layer folder carries the layer id, not an outer component" {
  need_tools
  f="$P/backend/src/schedule/service/planner.ts"
  echo "import { schedule } from '../api/schedule-api';" >> "$f"
  echo "import { listItems } from '../../backlog/service/backlog-service';" >> "$f"
  deps "$P"
  [ "$status" -eq 1 ]
  [ "$(ids)" = boundaries/service/imports-backlog-service,layers/service/imports-schedule-api ]
  [ "$(jq -r '[.[].component] | unique | join(",")' <<<"$output")" = service ]
  # the outer component no longer reaches the folder: the folder is scanned on its own
  sed -i 's#^  - backend/src/$#  - backend/src/main.ts#' "$P/docs/architecture/components/main.md"
  deps "$P"
  [ "$status" -eq 1 ]
  [ "$(ids)" = boundaries/service/imports-backlog-service,layers/service/imports-schedule-api ]
}

@test "a break from an omitted file is reported on stderr, never dropped" {
  need_tools
  mkdir -p "$P/backend/src/tools"
  echo "import { listItems } from '../backlog/service/backlog-service';" > "$P/backend/src/tools/seed.ts"
  printf 'paths:\n  - { path: backend/src/tools/, reason: one-off scripts }\n' > "$P/docs/architecture/omitted.yaml"
  "$ARCH" -C "$P" build
  run --separate-stderr "$ARCH" -C "$P" deps
  [ "$status" -eq 1 ]
  [ "$output" = '[]' ]
  [ "$stderr" = 'agentic-arch: backend/src/tools/seed.ts imports backend/src/backlog/service/backlog-service.ts (boundaries:backlog-package:entry), but no component or layer owns backend/src/tools/seed.ts' ]
}

# node_stub: ARCH_NODE becomes a node that logs its arguments to $NODE_LOG, then runs node.
node_stub() {
  NODE_LOG="$BATS_TEST_TMPDIR/node.log"
  printf '#!/bin/sh\necho "$@" >> "%s"\nexec node "$@"\n' "$NODE_LOG" > "$BATS_TEST_TMPDIR/node-stub"
  chmod +x "$BATS_TEST_TMPDIR/node-stub"
  export ARCH_NODE="$BATS_TEST_TMPDIR/node-stub"
}

@test "deps runs dependency-cruiser on ARCH_NODE" {
  need_tools
  node_stub
  deps "$P"
  [ "$status" -eq 0 ]
  grep -q 'dependency-cruiser/bin/dependency-cruiser.mjs --config docs/architecture/rules.depcruise.cjs' "$NODE_LOG"
}

@test "node is the image's pinned Node when present, else node from PATH" {
  source "$REPO_ROOT/image/lib/wiki.sh"; source "$REPO_ROOT/image/lib/arch.sh"
  unset ARCH_NODE
  NODE_HARNESS=no-such-major
  [ "$(arch_node)" = node ]
  NODE_HARNESS=22
  if [ -x /opt/node/22/bin/node ]; then [ "$(arch_node)" = /opt/node/22/bin/node ]; fi
  unset NODE_HARNESS
  if [ -x /opt/node/22/bin/node ]; then [ "$(arch_node)" = /opt/node/22/bin/node ]; fi
  ARCH_NODE=/x/node
  [ "$(arch_node)" = /x/node ]
}

@test "the rules file is generated, valid JS and stable" {
  need_tools
  "$ARCH" -C "$P" build
  [ "$(head -n 1 "$R")" = '// Generated by agentic-arch build from docs/architecture/. Do not edit.' ]
  node -e 'const r = require(process.argv[1]); if (!r.forbidden.length || !r.options.tsPreCompilationDeps) process.exit(1)' "$R"
  [ "$(node -e 'console.log(require(process.argv[1]).options.exclude.path)' "$R")" = '(^|/)(node_modules|dist|build|coverage)/|\.(test|spec)\.[jt]sx?$' ]
  before="$(sha256sum < "$R")"
  "$ARCH" -C "$P" build
  [ "$(sha256sum < "$R")" = "$before" ]
}

@test "the committed rules files are what build writes" {
  "$ARCH" -C "$A" build
  cmp "$A/docs/architecture/rules.depcruise.cjs" "$REPO_ROOT/tests/fixtures/architect/good/docs/architecture/rules.depcruise.cjs"
  "$ARCH" -C "$P" build
  cmp "$R" "$REPO_ROOT/tests/fixtures/architect/packages/docs/architecture/rules.depcruise.cjs"
}

@test "deps without dependency-cruiser exits 2 with a message" {
  ARCH_TOOLS="$BATS_TEST_TMPDIR/empty"; mkdir -p "$ARCH_TOOLS"
  run "$ARCH" -C "$P" deps
  [ "$status" -eq 2 ]
  [ "$output" = 'agentic-arch: dependency-cruiser is not installed (npm ci in image/arch)' ]
}

@test "deps without a rules file asks for a build" {
  need_tools
  rm -f "$R"
  run "$ARCH" -C "$P" deps
  [ "$status" -eq 2 ]
  [[ "$output" == *"run agentic-arch build"* ]]
}

@test "deps with no modules to cruise exits 2 with a message" {
  need_tools
  find "$P/backend" "$P/frontend" -name '*.ts' -delete
  deps "$P"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no JavaScript or TypeScript"* ]]
}

@test "deps with a bad option prints usage" {
  run "$ARCH" -C "$P" deps --frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *usage* ]]
}

@test "--affected reports only findings from the changed files" {
  need_tools
  echo "import { log } from '../../backend/src/commons/log';" >> "$P/frontend/src/app.ts"
  git -C "$P" init -q
  git -C "$P" add -A
  git -C "$P" -c user.email=a@example.com -c user.name=a commit -qm base
  echo "import { loadItems } from '../repository/backlog-store';" >> "$P/backend/src/backlog/api/backlog-api.ts"
  deps "$P" --affected HEAD
  [ "$(ids)" = layers/backlog-api/imports-backlog-store ]
  deps "$P"
  [ "$(ids)" = layers/backlog-api/imports-backlog-store,parts/web/imports-commons ]
}

@test "--affected with an unknown revision exits 2" {
  need_tools
  git -C "$P" init -q
  deps "$P" --affected nope
  [ "$status" -eq 2 ]
}

@test "--affected works on a project in a subfolder of the repository" {
  need_tools
  git -C "$BATS_TEST_TMPDIR" init -q
  git -C "$BATS_TEST_TMPDIR" add -A
  git -C "$BATS_TEST_TMPDIR" -c user.email=a@example.com -c user.name=a commit -qm base
  echo "import { loadItems } from '../repository/backlog-store';" >> "$P/backend/src/backlog/api/backlog-api.ts"
  deps "$P" --affected HEAD
  [ "$(ids)" = layers/backlog-api/imports-backlog-store ]
}

@test "type-only imports are not layer, part or boundary breaks" {
  need_tools
  grep -q loadItems "$P/backend/src/backlog/repository/backlog-store.ts"
  echo "import type { Item } from '../repository/backlog-store';" >> "$P/backend/src/backlog/api/backlog-api.ts"
  echo "import type { Item as Other } from '../../backlog/service/backlog-service';" >> "$P/backend/src/schedule/api/schedule-api.ts"
  echo "import type { start } from '../../main';" >> "$P/backend/src/backlog/repository/backlog-store.ts"
  deps "$P"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "every generated layers, parts and boundaries rule skips type-only dependencies" {
  need_tools
  "$ARCH" -C "$P" build
  run node -e 'const r = require(process.argv[1]); const bad = r.forbidden.filter((x) => !(x.to.dependencyTypesNot || []).includes("type-only")); if (r.forbidden.length === 0 || bad.length) { console.log(bad.map((x) => x.name).join(",") || "no rules"); process.exit(1); }' "$R"
  [ "$status" -eq 0 ]
}

@test "a value import next to a type-only one is still a break" {
  need_tools
  printf '%s\n' "import type { Item } from '../repository/backlog-store';" "import { loadItems } from '../repository/backlog-store';" >> "$P/backend/src/backlog/api/backlog-api.ts"
  deps "$P"
  [ "$(ids)" = layers/backlog-api/imports-backlog-store ]
}
