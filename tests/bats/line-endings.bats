#!/usr/bin/env bats
load helpers

@test "text files are checked out with LF on every platform" {
  for f in bin/agentic tests/bats/helpers.bash README.md bridge/src/task.ts image/Dockerfile; do
    run git -C "$REPO_ROOT" check-attr eol -- "$f"
    [ "$output" = "$f: eol: lf" ]
  done
}

@test "no tracked file holds CRLF in the index" {
  run bash -c "git -C '$REPO_ROOT' ls-files --eol | grep -E '^i/(crlf|mixed)'"
  [ "$status" -eq 1 ]
}
