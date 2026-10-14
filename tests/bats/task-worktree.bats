#!/usr/bin/env bats
load helpers

setup() {
  W="$BATS_TEST_TMPDIR/work"
  git init -q -b main "$W"
  git -C "$W" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  S="$REPO_ROOT/image/task/worktree.sh"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
}

@test "add makes the worktree on a new branch from HEAD, excluded from the checkout, and prints its path" {
  run --separate-stderr bash "$S" add "$W" T-1 agentic/T-1-x
  [ "$status" -eq 0 ]
  [ "$output" = "$W/.worktrees/T-1" ]
  [ "$(git -C "$W/.worktrees/T-1" rev-parse --abbrev-ref HEAD)" = agentic/T-1-x ]
  grep -qx '.worktrees/' "$W/.git/info/exclude"
  [ -z "$(git -C "$W" status --porcelain)" ]
}

@test "add refuses a repository without a commit, an existing branch, a bad id and a bad branch" {
  E="$BATS_TEST_TMPDIR/empty"; git init -q "$E"
  run bash "$S" add "$E" T-1 b; [ "$status" -eq 1 ]; [[ "$output" == *"has no commit"* ]]
  git -C "$W" branch taken
  run bash "$S" add "$W" T-2 taken; [ "$status" -ne 0 ]
  run bash "$S" add "$W" ../x b; [ "$status" -eq 1 ]; [[ "$output" == *"bad task id"* ]]
  run bash "$S" add "$W" T-3 -b; [ "$status" -eq 1 ]; [[ "$output" == *"bad branch name"* ]]
}

@test "check refuses uncommitted changes and commits that are only on the task branch" {
  bash "$S" add "$W" T-1 agentic/T-1-x >/dev/null
  bash "$S" check "$W" T-1 agentic/T-1-x
  echo x > "$W/.worktrees/T-1/f"
  run bash "$S" check "$W" T-1 agentic/T-1-x
  [ "$status" -eq 1 ]; [[ "$output" == *"has uncommitted changes"* ]]
  git -C "$W/.worktrees/T-1" add f; git -C "$W/.worktrees/T-1" commit -qm f
  run bash "$S" check "$W" T-1 agentic/T-1-x
  [ "$status" -eq 1 ]; [[ "$output" == *"has commits on no remote branch (agentic/T-1-x)"* ]]
}

@test "remove checks first, --force skips the check; both remove the worktree and the branch" {
  bash "$S" add "$W" T-1 agentic/T-1-x >/dev/null
  echo x > "$W/.worktrees/T-1/f"
  run bash "$S" remove "$W" T-1 agentic/T-1-x
  [ "$status" -eq 1 ]; [ -d "$W/.worktrees/T-1" ]
  bash "$S" remove "$W" T-1 agentic/T-1-x --force
  [ ! -e "$W/.worktrees/T-1" ]
  run git -C "$W" rev-parse -q --verify refs/heads/agentic/T-1-x; [ "$status" -ne 0 ]
  bash "$S" remove "$W" T-1 agentic/T-1-x   # nothing left: still succeeds
}
