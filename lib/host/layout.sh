#!/usr/bin/env bash
# The project's layout (spec run-thin-relay §3): one repository at the root (single) or several in
# its direct subfolders (multi), and the target the agent starts in. File tests only, never git.
# Source after lib/host/common.sh.

# repo_dirs ROOT: the direct subfolders of ROOT that hold .git, sorted; a symlinked folder is skipped.
repo_dirs() {
  local d
  for d in "$1"/*/; do
    d="${d%/}"
    if [ ! -L "$d" ] && [ -e "$d/.git" ]; then basename "$d"; fi
  done | LC_ALL=C sort
}

# detect_layout ROOT: single when ROOT holds .git, multi when a direct subfolder does, else nothing.
detect_layout() {
  if [ -e "$1/.git" ]; then echo single
  elif [ -n "$(repo_dirs "$1")" ]; then echo multi
  fi
}

# valid_target ROOT NAME: NAME is a plain folder name under ROOT, no symlink, with .git.
valid_target() {
  [[ "$2" =~ ^[A-Za-z0-9._-]+$ && "$2" != . && "$2" != .. ]] && [ ! -L "$1/$2" ] && [ -e "$1/$2/.git" ]
}

# target_hint ROOT: what to do when a multi-repository project has no target.
target_hint() {
  local names first
  names="$(repo_dirs "$1" | paste -sd, - | sed 's/,/, /g')"; first="$(repo_dirs "$1" | head -n 1)"
  printf 'the project holds several repositories (%s) and no target is set.\n  Run with --target NAME, or set the default: agentic target %s' "$names" "$first"
}

# task_work TARGET: the agent's directory in the container: /work for a single repository, else
# /work/<TARGET or the configured target>. Dies with the reason otherwise.
task_work() {
  local cfgf root layout t
  cfgf="$(cfg_dir)/agentic.yaml"; root="$(project_root)"
  layout="$(yaml_top "$cfgf" layout)"
  case "$layout" in
    single)
      [ -z "$1" ] || die "--target is for a project with several repositories; this one is a single repository"
      [ -z "$(yaml_top "$cfgf" target)" ] || die "agentic.yaml sets target: but the layout is single; remove the target line"
      echo /work ;;
    multi)
      t="${1:-$(yaml_top "$cfgf" target)}"
      [ -n "$t" ] || die "$(target_hint "$root")"
      valid_target "$root" "$t" || die "$t is not a repository of the project; choose one of: $(repo_dirs "$root" | paste -sd' ' -)"
      echo "/work/$t" ;;
    "") die "no layout in .agentic/agentic.yaml; re-run agentic init" ;;
    *) die "layout must be single or multi, not $layout" ;;
  esac
}
