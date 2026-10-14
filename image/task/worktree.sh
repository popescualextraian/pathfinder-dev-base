#!/usr/bin/env bash
# A task's own worktree, made and removed inside the task container, never by the host
# (spec run-thin-relay §5.2, §6.2).
#   add WORK ID BRANCH               WORK/.worktrees/ID on a new BRANCH from WORK's HEAD; prints the path
#   check WORK ID BRANCH             refuses uncommitted changes or commits on BRANCH only
#   remove WORK ID BRANCH [--force]  check (unless --force), then remove the worktree and BRANCH
set -euo pipefail
die() { echo "agentic-worktree: $*" >&2; exit 1; }
[ $# -ge 4 ] || die "usage: worktree.sh add|check|remove WORK ID BRANCH [--force]"
cmd="$1" work="$2" id="$3" branch="$4" force="${5:-}"
[[ "$id" =~ ^[A-Za-z0-9._-]+$ && "$id" != . && "$id" != .. ]] || die "bad task id $id"
{ [[ "$branch" != -* ]] && git check-ref-format --branch "$branch" >/dev/null 2>&1; } || die "bad branch name $branch"
wt="$work/.worktrees/$id"

# check: nothing uncommitted, and no commit that only the task branch has (not on a remote, not
# on the checkout's HEAD).
check() {
  [ -d "$wt" ] || return 0
  [ -z "$(git -C "$wt" status --porcelain)" ] || die "$wt has uncommitted changes; commit and push them, or clean with --force"
  [ -z "$(git -C "$work" log --oneline --not --remotes HEAD --not --end-of-options "$branch" 2>/dev/null)" ] \
    || die "$wt has commits on no remote branch ($branch); push them, or clean with --force"
}

case "$cmd" in
  add)
    git -C "$work" rev-parse -q --verify HEAD >/dev/null || die "$work has no commit to start a worktree from"
    ex="$(git -C "$work" rev-parse --git-path info/exclude)"; [[ "$ex" == /* ]] || ex="$work/$ex"
    mkdir -p "$(dirname "$ex")" "$work/.worktrees"
    grep -qx '.worktrees/' "$ex" 2>/dev/null || echo '.worktrees/' >> "$ex"
    git -C "$work" worktree add -q -b "$branch" -- "$wt" HEAD >&2
    printf '%s\n' "$wt" ;;
  check) check ;;
  remove)
    [ "$force" = --force ] || check
    if [ -d "$wt" ]; then git -C "$work" worktree remove --force -- "$wt"; fi
    git -C "$work" worktree prune
    if git -C "$work" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then git -C "$work" branch -D -- "$branch" >/dev/null; fi ;;
  *) die "unknown command $cmd" ;;
esac
