#!/usr/bin/env bats
load helpers

@test "the configuration reference lists every field with type, default and description" {
  run bash "$REPO_ROOT/tools/gen-config-docs.sh"
  [ "$status" -eq 0 ]
  grep -qF '| `project` | string |' <<<"$output"
  grep -qF '| `tools.maven` | false or string | `"3.9.9"` |' <<<"$output"
  grep -qF '| `targets` | array | `["claude","copilot"]` |' <<<"$output"
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

@test "docs/setup.md documents every setup command, and the skill reference lists the same commands" {
  f="$REPO_ROOT/docs/setup.md"
  for c in 'add marketplace' 'add plugin' 'add mcp' 'add skill' 'add agent' 'add command' 'add workspace' '`copy' '`mount' '`volume' 'agentic remove' 'agentic list' 'build --refresh'; do
    grep -q -- "$c" "$f" || { echo "missing: $c"; return 1; }
  done
  cmds() { grep -oE '^\| `(add [a-z]+|copy|mount|volume) ' "$1" | sort -u; }
  [ "$(cmds "$f" | wc -l)" -eq 10 ]
  diff <(cmds "$f") <(cmds "$REPO_ROOT/skills/agentic-setup/reference/setup-lines.md")
}

@test "no document describes a removed field, file or step" {
  run grep -rnE 'mcp\.atlassian|mcp\.graphify|mcp\.custom|plugins\.claude|plugins\.marketplaces|git\.user_name|git\.host|harness\.claude\.model|on_build|on-build|\.agentic/certs|agentic-install-plugins|--refresh-plugins|30-git|40-mcp|50-plugins|60-skills|70-graphify|80-display' \
    "$REPO_ROOT/README.md" "$REPO_ROOT/docs" "$REPO_ROOT/templates" "$REPO_ROOT/skills" --include='*.md' --exclude-dir=specs --exclude-dir=plans
  echo "$output"
  [ "$status" -eq 1 ]
}

@test "every local link in the README and docs points to a file that exists" {
  cd "$REPO_ROOT"
  for f in README.md docs/*.md; do
    while IFS= read -r l; do
      [ -e "$(dirname "$f")/$l" ] || { echo "$f: $l"; return 1; }
    done < <(grep -oE '\]\([^)#]+' "$f" | sed 's/^](//' | grep -vE '^(https?|mailto):' || true)
  done
}

@test "docs/remote.md covers the contract, the VM, a managed service and one user per container" {
  f="$REPO_ROOT/docs/remote.md"
  for w in '/work' '/workspaces' 'volume' 'DOCKER_HOST' 'docker push' 'one user'; do grep -q -- "$w" "$f" || { echo "missing: $w"; return 1; }; done
}

@test "the task threat model names path workspaces as live checkouts in every task" {
  grep -q 'add workspace PATH' "$REPO_ROOT/docs/tasks.md"
}
