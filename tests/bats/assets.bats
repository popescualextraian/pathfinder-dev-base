#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_PROJECT_ASSETS="$BATS_TEST_TMPDIR/project"
  P="$AGENTIC_PROJECT_ASSETS"; mkdir -p "$P/skills/hello" "$P/agents" "$P/commands" "$AGENTIC_STATE"
  echo '# hello' > "$P/skills/hello/SKILL.md"
  echo $'---\nname: db\n---\nDB expert' > "$P/agents/db.md"
  echo 'Run the tests' > "$P/commands/t.md"
  echo 'Always use make' > "$P/instructions.md"
  conf '{}'
  S="$REPO_ROOT/image/start.d/60-assets.sh"
}

conf() { jq -n --argjson x "$1" '{version: 2, project: "demo", targets: ["claude","copilot"]} + $x' > "$AGENTIC_STATE/config.json"; }

@test "base and project assets go to both harnesses in their layout" {
  run bash "$S"
  [ "$status" -eq 2 ]   # the command has no Copilot place: a warning
  [ -f "$HOME/.claude/skills/hello/SKILL.md" ]
  [ -f "$HOME/.copilot/skills/hello/SKILL.md" ]
  [ -f "$HOME/.claude/skills/agentic-setup/SKILL.md" ]
  [ -f "$HOME/.copilot/skills/wiki/SKILL.md" ]
  [ -f "$HOME/.claude/agents/db.md" ]
  [ -f "$HOME/.copilot/agents/db.agent.md" ]
  [ -f "$HOME/.claude/commands/t.md" ]
  [ ! -e "$HOME/.copilot/commands" ]
  [[ "$output" == *"commands/t.md: Copilot has no user-level commands"* ]]
  grep -q 'Always use make' "$HOME/.claude/CLAUDE.md"
  grep -q 'Always use make' "$HOME/.copilot/copilot-instructions.md"
}

@test "an asset narrowed by a setup line goes only to its target" {
  conf '{"setup": ["add agent agents/db.md --target claude"]}'
  rm "$P/commands/t.md"
  bash "$S"
  [ -f "$HOME/.claude/agents/db.md" ]
  [ ! -e "$HOME/.copilot/agents/db.agent.md" ]
}

@test "the user's own text in CLAUDE.md is kept and the block is replaced" {
  mkdir -p "$HOME/.claude"; echo 'my notes' > "$HOME/.claude/CLAUDE.md"
  bash "$S" || true
  echo 'Use pnpm' > "$P/instructions.md"
  bash "$S" || true
  grep -q 'my notes' "$HOME/.claude/CLAUDE.md"
  grep -q 'Use pnpm' "$HOME/.claude/CLAUDE.md"
  if grep -q 'Always use make' "$HOME/.claude/CLAUDE.md"; then return 1; fi
}

@test "an asset the project dropped is removed; a hand-made one stays" {
  rm "$P/commands/t.md"
  bash "$S"
  mkdir -p "$HOME/.claude/skills/mine"; echo x > "$HOME/.claude/skills/mine/SKILL.md"
  rm -r "$P/skills/hello"
  bash "$S"
  [ ! -e "$HOME/.claude/skills/hello" ]
  [ -f "$HOME/.claude/skills/mine/SKILL.md" ]
}

@test "only removes inside the home" {
  rm "$P/commands/t.md"
  bash "$S"
  mkdir -p "$BATS_TEST_TMPDIR/outside"; echo keep > "$BATS_TEST_TMPDIR/outside/f"
  echo "$BATS_TEST_TMPDIR/outside" >> "$HOME/.claude/.agentic-assets"
  echo "$HOME/.claude/../../outside" >> "$HOME/.claude/.agentic-assets"
  run bash "$S"
  [ -f "$BATS_TEST_TMPDIR/outside/f" ]
}

@test "--check reports a stale asset and writes nothing" {
  rm "$P/commands/t.md"
  run bash "$S" --check
  [ "$status" -eq 2 ]
  [ ! -e "$HOME/.claude/skills/hello" ]
}
