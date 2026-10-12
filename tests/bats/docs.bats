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
  # copy the repo without the bridge's node_modules (hundreds of MB)
  mkdir "$BATS_TEST_TMPDIR/copy"
  tar -C "$REPO_ROOT" --exclude=./bridge/node_modules -cf - . | tar -C "$BATS_TEST_TMPDIR/copy" -xf -
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
  grep -q 'agentic-env' "$f"
  grep -q 'config-errors.txt' "$f"
  grep -q 'never read' "$f"
  grep -q '/opt/agentic/inventory.txt' "$f"
  grep -q 'command -v' "$f"
}

@test "the README names the CA file rules and how private repos authenticate" {
  f="$REPO_ROOT/README.md"
  grep -qF '`*.crt`' "$f"
  grep -qF 'AGENTIC_BUILD_CA_DIR' "$f"
  grep -qF 'Never put a token in the URL' "$f"
}

@test "the setup hand-over suggests /wiki seed when the project has no wiki" {
  grep -qF '/wiki seed' "$REPO_ROOT/skills/agentic-setup/SKILL.md"
}
