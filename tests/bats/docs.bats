#!/usr/bin/env bats
load helpers

@test "the configuration reference lists every field with type, default and description" {
  run bash "$REPO_ROOT/tools/gen-config-docs.sh"
  [ "$status" -eq 0 ]
  grep -qF '| `project` | string |' <<<"$output"
  grep -qF '| `tools.maven` | false or string | `"3.9.9"` |' <<<"$output"
  grep -qF '| `mcp.playwright.mode` | "headless" / "headed" | `"headless"` |' <<<"$output"
  grep -qF '| `docker.socket` | boolean | `false` |' <<<"$output"
}

@test "--check fails when docs/configuration.md is stale" {
  cp -r "$REPO_ROOT" "$BATS_TEST_TMPDIR/copy"
  echo stale >> "$BATS_TEST_TMPDIR/copy/docs/configuration.md"
  run bash "$BATS_TEST_TMPDIR/copy/tools/gen-config-docs.sh" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale"* ]]
}

@test "the committed reference is current" {
  run bash "$REPO_ROOT/tools/gen-config-docs.sh" --check
  [ "$status" -eq 0 ]
}

@test "the setup skill has a name, a description and its rules" {
  f="$REPO_ROOT/skills/agentic-setup/SKILL.md"
  [ "$(sed -n 1p "$f")" = --- ]
  grep -qx 'name: agentic-setup' "$f"
  grep -q '^description: ' "$f"
  grep -q 'agentic-config validate' "$f"
  grep -q 'Never read .agentic/.env' "$f"
}
