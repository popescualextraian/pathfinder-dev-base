#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
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

@test "remove of a worktree whose folder is gone still refuses commits only on the task branch" {
  bash "$S" add "$W" T-1 agentic/T-1-x >/dev/null
  echo x > "$W/.worktrees/T-1/f"
  git -C "$W/.worktrees/T-1" add f; git -C "$W/.worktrees/T-1" commit -qm f
  rm -rf "$W/.worktrees/T-1"; git -C "$W" worktree prune
  run bash "$S" remove "$W" T-1 agentic/T-1-x
  [ "$status" -eq 1 ]; [[ "$output" == *"has commits on no remote branch"* ]]
  git -C "$W" rev-parse -q --verify refs/heads/agentic/T-1-x
  bash "$S" remove "$W" T-1 agentic/T-1-x --force
  run git -C "$W" rev-parse -q --verify refs/heads/agentic/T-1-x; [ "$status" -ne 0 ]
}

# multi mode: a root holding several repositories (spec multi-repo-tasks §3)
setup_multi() {
  R="$BATS_TEST_TMPDIR/root"; export AGENTIC_LAYOUT=multi
  git init -q -b main "$R"; : > "$R/.gitignore"
  git -C "$R" add .gitignore; git -C "$R" commit -qm init
  local r; for r in webapp api; do
    git init -q -b main "$R/$r"; git -C "$R/$r" commit -q --allow-empty -m init
  done
  MW="$R/.worktrees/T-1"
}

@test "multi add makes the root and every repository a worktree on the branch and prints the target's" {
  setup_multi
  run --separate-stderr bash "$S" add "$R/webapp" T-1 agentic/T-1-x
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$MW/webapp" ]
  [ "$(git -C "$MW" rev-parse --abbrev-ref HEAD)" = agentic/T-1-x ]
  [ "$(git -C "$MW/webapp" rev-parse --abbrev-ref HEAD)" = agentic/T-1-x ]
  [ "$(git -C "$MW/api" rev-parse --abbrev-ref HEAD)" = agentic/T-1-x ]
  # the repository folders themselves are untracked here (the .gitignore lists nothing)
  [ -z "$(git -C "$R" status --porcelain -- . ':(exclude)webapp' ':(exclude)api')" ]
}

@test "multi add with a root that is no git repository makes a plain folder" {
  setup_multi; rm -rf "$R/.git"
  bash "$S" add "$R/webapp" T-1 agentic/T-1-x >/dev/null
  [ -d "$MW" ]; [ ! -e "$MW/.git" ]
  [ "$(git -C "$MW/webapp" rev-parse --abbrev-ref HEAD)" = agentic/T-1-x ]
  [ "$(git -C "$MW/api" rev-parse --abbrev-ref HEAD)" = agentic/T-1-x ]
  bash "$S" remove "$R/webapp" T-1 agentic/T-1-x
  [ ! -e "$MW" ]
}

@test "add skips a symlinked repository and a .git file" {
  setup_multi
  ln -s "$R/api" "$R/link"; mkdir "$R/sub"; echo "gitdir: /nowhere" > "$R/sub/.git"
  run --separate-stderr bash "$S" add "$R/webapp" T-1 agentic/T-1-x
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"agentic-worktree: skipped sub: .git is a file"* ]]
  [ ! -e "$MW/link" ]; [ ! -e "$MW/sub/.git" ]
}

@test "add skips a repository without a commit or mid-rebase" {
  setup_multi
  git init -q "$R/empty"; mkdir "$R/api/.git/rebase-merge"
  run --separate-stderr bash "$S" add "$R/webapp" T-1 agentic/T-1-x
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"skipped empty: no commit"* ]]
  [[ "$stderr" == *"skipped api: mid-rebase"* ]]
}

@test "add rolls back when the target cannot get a worktree" {
  setup_multi; git init -q "$R/empty"
  run bash "$S" add "$R/empty" T-1 agentic/T-1-x
  [ "$status" -eq 1 ]
  [ ! -e "$MW" ]
  [ -z "$(git -C "$R/webapp" branch --list agentic/T-1-x)" ]
  [ -z "$(git -C "$R" branch --list agentic/T-1-x)" ]
}

@test "check ignores the repository folders in the root worktree" {
  setup_multi
  bash "$S" add "$R/webapp" T-1 agentic/T-1-x >/dev/null
  bash "$S" check "$R/webapp" T-1 agentic/T-1-x
}

@test "multi check refuses when any one repository has uncommitted changes, and remove removes nothing then" {
  setup_multi
  bash "$S" add "$R/webapp" T-1 agentic/T-1-x >/dev/null
  echo x > "$MW/api/f"
  run bash "$S" check "$R/webapp" T-1 agentic/T-1-x
  [ "$status" -eq 1 ]; [[ "$output" == *"has uncommitted changes"* ]]
  run bash "$S" remove "$R/webapp" T-1 agentic/T-1-x
  [ "$status" -eq 1 ]; [ -d "$MW/webapp" ]
}

@test "multi remove deletes every worktree and branch" {
  setup_multi
  bash "$S" add "$R/webapp" T-1 agentic/T-1-x >/dev/null
  bash "$S" remove "$R/webapp" T-1 agentic/T-1-x
  [ ! -e "$MW" ]
  local r; for r in "$R" "$R/webapp" "$R/api"; do
    [ -z "$(git -C "$r" branch --list agentic/T-1-x)" ]
  done
}
