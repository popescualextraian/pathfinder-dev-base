#!/usr/bin/env bats
load helpers

setup() {
  WK="$REPO_ROOT/image/bin/agentic-wiki"
  wiki_repo
  git -C "$W" init -q
  commit base
}

commit() {
  git -C "$W" add -A
  git -C "$W" -c user.name=t -c user.email=t@example.com commit -qm "$1"
}

@test "changed files map to components by the longest matching source" {
  for f in infra/api.tf src/api/app.py src/api/routes.py src/common/money.py; do echo x >> "$W/$f"; done
  commit change
  run "$WK" -C "$W" affected HEAD~1..HEAD
  [ "$status" -eq 0 ]
  [ "$output" = $'component components/api infra/api.tf\ncomponent components/api src/api/app.py\ncomponent components/api/routes src/api/routes.py\ncomponent components/common src/common/money.py' ]
}

@test "omitted and unclaimed files; a source is a path boundary, not a string prefix" {
  echo x >> "$W/scripts/dev.sh"
  mkdir -p "$W/src/apiv2"; echo y > "$W/src/apiv2/x.py"
  commit change
  run "$WK" -C "$W" affected HEAD~1..HEAD
  [ "$output" = $'omitted scripts/dev.sh\nunclaimed src/apiv2/x.py' ]
}

@test "the wiki, CLAUDE.md and rules are not reported" {
  echo x >> "$W/docs/wiki/glossary.md"; echo x >> "$W/CLAUDE.md"; echo x >> "$W/.claude/rules/api.md"
  commit change
  run "$WK" -C "$W" affected HEAD~1..HEAD
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a base alone includes uncommitted changes" {
  echo x >> "$W/src/common/money.py"
  run "$WK" -C "$W" affected HEAD
  [ "$output" = 'component components/common src/common/money.py' ]
}

@test "a bad range fails" {
  run "$WK" -C "$W" affected nope..HEAD
  [ "$status" -eq 2 ]
  [[ "$output" != *usage:* ]]
}
