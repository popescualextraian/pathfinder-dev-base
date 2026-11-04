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

# check_one DIR PATH [EXCLUDE...]: nothing uncommitted in worktree PATH of repository DIR, and no
# commit that only the task branch has (not on a remote, not on DIR's HEAD).
check_one() {
  local dir="$1" path="$2" st; shift 2
  # a worktree folder that is gone leaves its branch: that still counts
  if [ -d "$path" ]; then
    if [ $# -gt 0 ]; then set -- -- . "$@"; fi
    st="$(git -C "$path" status --porcelain "$@")" || die "$path is no worktree; cannot check it"
    [ -z "$st" ] || die "$path has uncommitted changes; commit and push them, or clean with --force"
  else
    git -C "$dir" rev-parse -q --verify "refs/heads/$branch" >/dev/null || return 0
  fi
  [ -z "$(git -C "$dir" log --oneline --not --remotes HEAD --not --end-of-options "$branch" 2>/dev/null)" ] \
    || die "$path has commits on no remote branch ($branch); push them, or clean with --force"
}
check() { check_one "$work" "$wt"; }

# drop DIR PATH: remove worktree PATH of repository DIR and the task branch there.
drop() {
  if [ -d "$2" ]; then git -C "$1" worktree remove --force -- "$2"; fi
  git -C "$1" worktree prune
  if git -C "$1" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then git -C "$1" branch -D -- "$branch" >/dev/null; fi
}

# Multi mode: WORK is ROOT/<target>; ROOT holds several repositories (spec multi-repo-tasks §3).
# The task is ROOT/.worktrees/ID: a worktree of ROOT (a plain folder if ROOT is no repository)
# holding a worktree of each repository, all on BRANCH.
if [ "${AGENTIC_LAYOUT:-}" = multi ]; then
  root="$(dirname "$work")" target="$(basename "$work")" wt="$root/.worktrees/$id"
  # candidates: folders that are no symlink and have a .git (directory, or file: skipped on add)
  cands=()
  for d in "$root"/*/; do
    d="${d%/}"
    if [ ! -L "$d" ] && [ -e "$d/.git" ]; then cands+=("${d##*/}"); fi
  done
  # rootgit: the task root is a worktree of a repository; live: repositories that have a worktree in it
  # (skipped ones have none and are left alone, branch included)
  rootgit=0
  if [ -f "$wt/.git" ] || { [ ! -e "$wt" ] && [ -e "$root/.git" ]; }; then rootgit=1; fi
  live_repos() {
    live=() excl=()
    for n in ${cands[@]+"${cands[@]}"}; do
      if [ -d "$root/$n/.git" ] && [ -f "$wt/$n/.git" ]; then live+=("$n"); excl+=(":(exclude,literal)$n"); fi
    done
  }
  # add_one NAME: worktree of repository NAME; sets reason and fails when it must be skipped
  add_one() {
    local d="$root/$1" g
    [ -d "$d/.git" ] || { reason=".git is a file"; return 1; }
    git -C "$d" rev-parse -q --verify HEAD >/dev/null 2>&1 || { reason="no commit"; return 1; }
    for g in rebase-merge rebase-apply; do [ ! -d "$d/.git/$g" ] || { reason="mid-rebase"; return 1; }; done
    git -C "$d" worktree add -q -b "$branch" -- "$wt/$1" HEAD >/dev/null 2>&1 || { reason="worktree add failed"; return 1; }
  }
  check_all() {
    live_repos
    for n in ${live[@]+"${live[@]}"}; do check_one "$root/$n" "$wt/$n"; done
    if [ "$rootgit" = 1 ]; then check_one "$root" "$wt" ${excl[@]+"${excl[@]}"}; fi
  }
  drop_all() {
    live_repos
    for n in ${live[@]+"${live[@]}"}; do drop "$root/$n" "$wt/$n"; done
    if [ "$rootgit" = 1 ]; then drop "$root" "$wt"
    elif [ -d "$wt" ]; then rmdir "$wt" 2>/dev/null || die "$wt is not empty; remove what is left in it"; fi
  }
  case "$cmd" in
    add)
      if [ -L "$work" ] || [ ! -d "$work/.git" ]; then die "$work is no git repository"; fi
      [ ! -e "$wt" ] || die "$wt exists"
      mkdir -p "$root/.worktrees"
      if [ "$rootgit" = 1 ]; then
        git -C "$root" rev-parse -q --verify HEAD >/dev/null || die "$root has no commit to start a worktree from"
        ex="$(git -C "$root" rev-parse --git-path info/exclude)"; [[ "$ex" == /* ]] || ex="$root/$ex"
        mkdir -p "$(dirname "$ex")"
        grep -qx '.worktrees/' "$ex" 2>/dev/null || echo '.worktrees/' >> "$ex"
        git -C "$root" worktree add -q -b "$branch" -- "$wt" HEAD >&2
      else
        mkdir "$wt"
      fi
      made=() reason=""
      # the target first: it is never skipped
      for n in "$target" ${cands[@]+"${cands[@]}"}; do
        if [ "$n" = "$target" ] && [ ${#made[@]} -gt 0 ]; then continue; fi
        if add_one "$n"; then made+=("$n")
        elif [ "$n" = "$target" ]; then
          for m in ${made[@]+"${made[@]}"}; do drop "$root/$m" "$wt/$m"; done
          if [ "$rootgit" = 1 ]; then drop "$root" "$wt"; else rmdir "$wt"; fi
          die "$work cannot get a worktree: $reason"
        else echo "agentic-worktree: skipped $n: $reason" >&2; fi
      done
      printf '%s\n' "$wt/$target" ;;
    check) check_all ;;
    remove)
      [ "$force" = --force ] || check_all
      drop_all ;;
    *) die "unknown command $cmd" ;;
  esac
  exit 0
fi

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
