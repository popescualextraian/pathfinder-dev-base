#!/usr/bin/env bats
load helpers

setup() {
  WK="$REPO_ROOT/image/bin/agentic-wiki"
  wiki_repo
  D="$W/docs/wiki"
}

chk() { run "$WK" -C "$W" check; }
has() { grep -qxF -- "$1" <<<"$output"; }

@test "the fixture passes" {
  chk
  [ "$status" -eq 0 ]
  [ "$output" = "wiki: ok" ]
}

@test "a repository without docs/wiki has nothing to check" {
  mkdir "$BATS_TEST_TMPDIR/empty"
  run "$WK" -C "$BATS_TEST_TMPDIR/empty" check
  [ "$status" -eq 0 ]
  [ "$output" = "agentic-wiki: no docs/wiki; nothing to check" ]
}

@test "a wiki with only an overview builds and passes" {
  rm -rf "$D/components" "$D/decisions" "$D/concepts" "$D/flows" "$D/glossary.md" "$D/reuse.md" "$D/index.md" "$W/.claude" "$W/.github"
  run "$WK" -C "$W" build
  run "$WK" -C "$W" sync
  chk
  [ "$status" -eq 0 ]
}

@test "missing or invalid front matter" {
  printf '# Loose\n' > "$D/components/loose.md"
  printf -- '---\nid: [\n---\n' > "$D/concepts/bad.md"
  chk
  [ "$status" -eq 1 ]
  has 'docs/wiki/components/loose.md: missing or invalid front matter'
  has 'docs/wiki/concepts/bad.md: missing or invalid front matter'
}

@test "a page outside the known locations" {
  printf -- '---\nid: notes\nkind: concept\n---\n' > "$D/notes.md"
  chk
  has 'docs/wiki/notes.md: not a page location of the wiki'
}

@test "kind and id must match the path" {
  sed -i 's/^kind: concept$/kind: flow/; s#^id: concepts/money$#id: concepts/cash#' "$D/concepts/money.md"
  chk
  has 'docs/wiki/concepts/money.md: kind must be concept'
  has 'docs/wiki/concepts/money.md: id must be concepts/money'
}

@test "required fields, lists and allowed values" {
  sed -i '/^summary:/d; s/^depends_on: \[\]$/depends_on: components\/api/; s/^lifecycle: active$/lifecycle: done/; s/^status: reviewed$/status: final/' "$D/components/common.md"
  sed -i 's/^status: accepted$/status: maybe/' "$D/decisions/adr-1.md"
  chk
  has 'docs/wiki/components/common.md: missing summary'
  has 'docs/wiki/components/common.md: depends_on must be a list'
  has 'docs/wiki/components/common.md: lifecycle must be active, migrating or retiring'
  has 'docs/wiki/components/common.md: status must be draft or reviewed'
  has 'docs/wiki/decisions/adr-1.md: status must be proposed, accepted or superseded'
}

@test "an offer needs name, location and use" {
  sed -i '/^    use: Format/d' "$D/components/common.md"
  chk
  has 'docs/wiki/components/common.md: every offer needs name, location and use'
}

@test "references to unknown pages" {
  sed -i 's#^  - concepts/money$#  - concepts/cash#' "$D/components/api.md"
  sed -i 's#^parent: components/api$#parent: components/apx#' "$D/components/api/routes.md"
  chk
  has 'docs/wiki/components/api.md: depends_on names unknown page concepts/cash'
  has 'docs/wiki/components/api/routes.md: parent names unknown page components/apx'
}

@test "broken links fail; links to code and external links pass" {
  echo 'See [money](../../../src/common/money.py) and [docs](https://example.com/x).' >> "$D/concepts/money.md"
  chk
  [ "$status" -eq 0 ]
  echo 'See [gone](gone.md).' >> "$D/concepts/money.md"
  chk
  has 'docs/wiki/concepts/money.md: broken link gone.md'
}

@test "sources must exist and belong to one component" {
  sed -i 's#^  - infra/api.tf$#  - infra/gone.tf#' "$D/components/api.md"
  sed -i 's#^  - src/api/routes.py$#  - src/common/#' "$D/components/api/routes.md"
  chk
  has 'docs/wiki/components/api.md: source infra/gone.tf does not exist'
  has 'docs/wiki/components/common.md: source src/common/ is also claimed by docs/wiki/components/api/routes.md'
}

@test "an offer must point at an existing file" {
  sed -i 's#src/common/money.py::#src/common/cash.py::#' "$D/components/common.md"
  chk
  has 'docs/wiki/components/common.md: offer format_money points at missing src/common/cash.py'
}

@test "page size, tables and path lists are limited" {
  for i in $(seq 61); do echo "Line $i."; done >> "$D/concepts/money.md"
  { echo; echo '| a | b |'; echo '|---|---|'; for i in $(seq 12); do echo "| $i | x |"; done; } >> "$D/components/api.md"
  for i in $(seq 11); do echo "- \`src/x$i/y.py\`"; done >> "$D/components/api.md"
  chk
  has 'docs/wiki/concepts/money.md: 63 lines, limit 60'
  has 'docs/wiki/components/api.md: table with 12 rows, limit 10; leave inventories to the code'
  has 'docs/wiki/components/api.md: 12 lines name paths, limit 10; leave inventories to the code'
}

@test "the index is limited to 70 lines" {
  for i in $(seq 70); do
    printf -- '---\nid: concepts/c%s\nkind: concept\nname: C%s\nsummary: s\n---\n' "$i" "$i" > "$D/concepts/c$i.md"
  done
  run "$WK" -C "$W" build
  chk
  grep -qE '^docs/wiki/index.md: [0-9]+ lines, limit 70; group components under parents$' <<<"$output"
}

@test "CLAUDE.md must import the index and stay under 130 lines" {
  sed -i '\#^@docs/wiki/index.md$#d' "$W/CLAUDE.md"
  for i in $(seq 130); do echo "line $i"; done >> "$W/CLAUDE.md"
  chk
  has 'CLAUDE.md: no @docs/wiki/index.md line'
  grep -qE '^CLAUDE.md: [0-9]+ lines, limit 130$' <<<"$output"
  rm "$W/CLAUDE.md"
  chk
  has 'CLAUDE.md: missing; it must import the wiki index'
}

@test "a rule without paths belongs in CLAUDE.md" {
  printf '# Everywhere\n' > "$W/.claude/rules/general.md"
  chk
  has '.claude/rules/general.md: a rule without paths belongs in CLAUDE.md'
}

@test "stale generated files and orphaned mirrors are reported" {
  echo extra >> "$D/reuse.md"
  rm "$W/.claude/rules/api.md"
  chk
  has 'docs/wiki/reuse.md: generated content is stale; run agentic-wiki build and agentic-wiki sync'
  has '.github/instructions/api.instructions.md: generated content is stale; run agentic-wiki build and agentic-wiki sync'
}

@test "all problems are reported at once and counted" {
  printf '# Loose\n' > "$D/components/loose.md"
  printf '# Everywhere\n' > "$W/.claude/rules/general.md"
  chk
  [ "$status" -eq 1 ]
  [[ "$output" == *"agentic-wiki: 2 problem(s)"* ]]
}
