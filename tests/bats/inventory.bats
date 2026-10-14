#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_OPT="$BATS_TEST_TMPDIR/opt"
  B="$BATS_TEST_TMPDIR/bin"; mkdir -p "$B" "$AGENTIC_OPT/java/17" "$AGENTIC_OPT/java/8" "$AGENTIC_OPT/terraform/1.9.8"
  printf '#!/bin/sh\necho "git version 2.43.0"\n' > "$B/git"
  printf '#!/bin/sh\necho "gh version 2.60.0 (2024-10-01)"\necho second line\n' > "$B/gh"
  printf '#!/bin/sh\necho "openjdk version \\"17.0.12\\"" >&2\n' > "$B/java"
  chmod +x "$B"/*
  I="$REPO_ROOT/image/bin/agentic-inventory"
}

@test "lists installed commands with their first version line" {
  PATH="$B:$PATH" run "$I"
  [ "$status" -eq 0 ]
  grep -qx -- '- git: git version 2.43.0' <<<"$output"
  grep -qx -- '- gh: gh version 2.60.0 (2024-10-01)' <<<"$output"
  grep -qx -- '- java: openjdk version "17.0.12"' <<<"$output"
}

@test "lists the presets and the versions installed side by side" {
  PATH="$B:$PATH" run "$I"
  grep -qx -- '- terraform' <<<"$output"
  grep -qx -- '- java: 8 17' <<<"$output"
  grep -qx -- '- terraform: 1.9.8' <<<"$output"
  run grep -q -- '- _lib' <<<"$output"
  [ "$status" -ne 0 ]
}

@test "lists the plugins the setup lines installed, and the skills" {
  export AGENTIC_SEED="$BATS_TEST_TMPDIR/seed"; mkdir -p "$AGENTIC_SEED/.built"
  echo '["r@m"]' > "$AGENTIC_SEED/.built/claude-plugins.json"
  printf 'hello  1.0
' > "$AGENTIC_SEED/.built/copilot-plugins.txt"
  PATH="$B:$PATH" run "$I"
  [[ "$output" == *"## Plugins from setup lines"* ]]
  grep -qx -- '- claude: r@m' <<<"$output"
  grep -qx -- '- copilot: hello  1.0' <<<"$output"
  grep -qx -- '- agentic-setup' <<<"$output"
}

@test "lists agentic-wiki among the commands" {
  printf '#!/bin/sh\nexit 2\n' > "$B/agentic-wiki"; chmod +x "$B/agentic-wiki"
  PATH="$B:$PATH" run "$I"
  grep -qx -- '- agentic-wiki' <<<"$output"
}
