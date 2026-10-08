#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_OPT="$BATS_TEST_TMPDIR/opt" AGENTIC_PLUGINS_DIR="$BATS_TEST_TMPDIR/plugins"
  B="$BATS_TEST_TMPDIR/bin"; mkdir -p "$B" "$AGENTIC_OPT/java/17" "$AGENTIC_OPT/java/8" "$AGENTIC_OPT/terraform/1.9.8" "$AGENTIC_PLUGINS_DIR"
  printf '#!/bin/sh\necho "git version 2.43.0"\n' > "$B/git"
  printf '#!/bin/sh\necho "gh version 2.60.0 (2024-10-01)"\necho second line\n' > "$B/gh"
  printf '#!/bin/sh\necho "openjdk version \\"17.0.12\\"" >&2\n' > "$B/java"
  chmod +x "$B"/*
  echo '{"plugins":{"superpowers@claude-plugins-official":[{}]}}' > "$AGENTIC_PLUGINS_DIR/installed_plugins.json"
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

@test "lists baked plugins and skills" {
  PATH="$B:$PATH" run "$I"
  grep -qx -- '- superpowers@claude-plugins-official' <<<"$output"
  grep -qx -- '- agentic-setup' <<<"$output"
}
