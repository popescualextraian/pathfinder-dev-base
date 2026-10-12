#!/usr/bin/env bats
load helpers

setup() { S="$REPO_ROOT/skills/wiki"; }

@test "the wiki skill has a name, a description and all its parts" {
  [ "$(sed -n 1p "$S/SKILL.md")" = --- ]
  grep -qx 'name: wiki' "$S/SKILL.md"
  grep -q '^description: ' "$S/SKILL.md"
  for f in reference/routing.md reference/pages.md templates/component.md templates/decision.md \
           templates/concept.md templates/flow.md templates/overview.md templates/glossary.md \
           templates/rule.md templates/CLAUDE.template.md; do
    [ -f "$S/$f" ]
  done
}

@test "the skill names only agentic-wiki commands that exist" {
  run grep -ohE '`agentic-wiki [a-z]+' "$S/SKILL.md" "$S"/reference/*.md
  [ "$status" -eq 0 ]
  while read -r _ c; do
    [[ " build sync check affected " == *" $c "* ]]
  done <<<"$output"
}

@test "the skill body stays short" {
  [ "$(wc -l < "$S/SKILL.md")" -le 150 ]
}

@test "the CLAUDE.md template imports the index and fits the limit" {
  grep -qxF '@docs/wiki/index.md' "$S/templates/CLAUDE.template.md"
  [ "$(wc -l < "$S/templates/CLAUDE.template.md")" -le 130 ]
}

@test "the rule template is path-scoped" {
  [ "$(sed -n 1,2p "$S/templates/rule.md")" = $'---\npaths:' ]
}

@test "the component template has every body section of the page contract" {
  for h in 'Purpose and boundary' 'Where changes go' 'Contracts' 'Invariants' 'Why' 'Pitfalls' 'Outside the repo'; do
    grep -qxF "## $h" "$S/templates/component.md"
    grep -qF "**$h**" "$S/reference/pages.md"
  done
}
