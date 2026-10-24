#!/usr/bin/env bats
load helpers

setup() {
  S="$REPO_ROOT/skills/architect"
  source "$REPO_ROOT/image/lib/wiki.sh"
}

# validates FILE's front matter as KIND with the contract validator
validate_fm() {
  local fm
  fm="$(wiki_fm "$2")" || { echo "no front matter: $2"; return 1; }
  jq -c --arg k "$1" --arg f "$2" '{kind: $k, file: $f, data: .}' <<<"$fm" | jq -s . \
    | node "$REPO_ROOT/image/arch/validate.mjs"
}

@test "the architect skill has a name, a description and all its parts" {
  [ "$(sed -n 1p "$S/SKILL.md")" = --- ]
  grep -qx 'name: architect' "$S/SKILL.md"
  grep -q '^description: Use when ' "$S/SKILL.md"
  for f in reference/pages.md reference/seed.md reference/plan-review.md reference/full-review.md \
           templates/architecture.md templates/component.md templates/flow.md templates/decision.md \
           templates/CLAUDE-snippet.md; do
    [ -f "$S/$f" ] || { echo "missing: $f"; return 1; }
  done
}

@test "the description covers the five moments" {
  local d
  d="$(grep '^description: ' "$S/SKILL.md")"
  for w in seed plan review exception template; do
    [[ "$d" == *"$w"* ]] || { echo "description lacks: $w"; return 1; }
  done
}

@test "the skill names only agentic-arch commands that exist" {
  run grep -ohE '`agentic-arch [a-z]+' "$S/SKILL.md" "$S"/reference/*.md "$S"/templates/*.md
  [ "$status" -eq 0 ]
  while read -r _ c; do
    [[ " build check affected deps sync " == *" $c "* ]] || { echo "unknown command: $c"; return 1; }
  done <<<"$output"
}

@test "the skill never names agentic-wiki" {
  run grep -rn 'agentic-wiki' "$S"
  [ "$status" -eq 1 ]
}

@test "the skill body stays short" {
  [ "$(wc -l < "$S/SKILL.md")" -le 150 ]
}

@test "every mode has a heading" {
  for m in seed update plan review accept new audit; do
    grep -qE "^### $m( |$)" "$S/SKILL.md" || { echo "no heading for mode $m"; return 1; }
  done
  grep -qE '^### review \[--full\]' "$S/SKILL.md"
}

@test "plan mode is advisory and never asks in a detached task" {
  grep -qi 'advisory' "$S/SKILL.md"
  grep -qi 'never blocks' "$S/SKILL.md"
  grep -qi 'detached task' "$S/SKILL.md"
}

@test "the component template has every body section of the page contract" {
  for h in 'Purpose and boundary' 'Where changes go' 'Contracts' 'Invariants' 'Why' 'Pitfalls'; do
    grep -qxF "## $h" "$S/templates/component.md" || { echo "template lacks: $h"; return 1; }
    grep -qF "**$h**" "$S/reference/pages.md" || { echo "pages.md lacks: $h"; return 1; }
  done
}

@test "the decision template is minimal MADR" {
  for h in 'Context' 'Decision' 'Consequences'; do grep -qE "^## $h" "$S/templates/decision.md"; done
}

@test "the component template's front matter validates against component.schema.json" {
  [ -d "$REPO_ROOT/image/arch/node_modules" ] || skip "image/arch/node_modules is absent: run npm ci in image/arch"
  validate_fm component "$S/templates/component.md"
}

@test "the architecture template's front matter validates against architecture.schema.json" {
  [ -d "$REPO_ROOT/image/arch/node_modules" ] || skip "image/arch/node_modules is absent: run npm ci in image/arch"
  validate_fm architecture "$S/templates/architecture.md"
}

@test "the flow and decision templates carry a title for the index" {
  wiki_fm "$S/templates/flow.md" | jq -e '.title | type == "string"' >/dev/null
  wiki_fm "$S/templates/decision.md" | jq -e '.title | type == "string"' >/dev/null
}

@test "the CLAUDE.md snippet imports the index" {
  grep -qxF '@docs/architecture/index.md' "$S/templates/CLAUDE-snippet.md"
}

@test "the skill holds no real-looking token and no host but example.com" {
  run grep -rnE '(ghp_|gho_|ghs_|github_pat_|glpat-|xox[abprs]-|sk-[a-z]+-|AKIA)[A-Za-z0-9_-]{8,}|BEGIN [A-Z ]*PRIVATE KEY|[A-Za-z0-9+/]{40,}' \
    "$S/SKILL.md" "$S/reference" "$S/templates"
  [ "$status" -eq 1 ]
  run bash -c "grep -rhoiE '[a-z0-9.-]+\.(com|net|org|io|de|dev|cloud)\b' '$S/SKILL.md' '$S/reference' '$S/templates' | grep -viE '(^|\.)example\.com$'"
  [ "$status" -eq 1 ]
}

@test "plan mode keeps accepted findings with status accepted, as plan-review.md says" {
  ! grep -qi 'skip findings already accepted' "$S/SKILL.md"
  sed -n '/^### plan/,/^### review/p' "$S/SKILL.md" | tr '\n' ' ' | grep -qE 'status `accepted`'
  grep -qF 'keep the finding with status' "$S/reference/plan-review.md"
}

@test "update mode keeps the reviews in step with removed or renamed components" {
  sed -n '/^### update/,/^### plan/p' "$S/SKILL.md" | tr '\n' ' ' | grep -qE 'removed or renamed.*reviews/full\.json'
}
