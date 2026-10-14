#!/usr/bin/env bash
# The setup-line commands of the host CLI: add, copy, mount, volume, remove, list. The file is edited
# by agentic-setup-edit in a throwaway container (the host has no yq). Source, do not execute.

# setup_edit ARG...: agentic-setup-edit on this project's .agentic/.
setup_edit() {
  local img; img="$(base_image_of)"
  image_exists "$img" || die "$img not found; run agentic build-base (or pull your overlay) first"
  docker run --rm --user "$(id -u):$(id -g)" -v "$(cfg_dir):/agentic-config" \
    --entrypoint /opt/agentic/bin/agentic-setup-edit "$img" "$@"
}

# localise KIND PATH: PATH as a path inside .agentic/, copied to .agentic/KIND/ when it is outside.
localise() {
  local kind="$1" src="$2" cfg base
  cfg="$(cfg_dir)"
  [ -e "$src" ] || die "$src does not exist"
  src="$(realpath -- "$src")"
  case "$src/" in "$cfg/"?*) printf '%s\n' "${src#"$cfg"/}"; return 0 ;; esac
  base="$(basename "$src")"
  if [ -e "$cfg/$kind/$base" ]; then
    diff -rq -- "$src" "$cfg/$kind/$base" >/dev/null 2>&1 || die ".agentic/$kind/$base exists and differs; rename one of them"
  else
    mkdir -p "$cfg/$kind"; cp -R -- "$src" "$cfg/$kind/$base"
  fi
  printf '%s/%s\n' "$kind" "$base"
}

# host_path PATH: a mount source as it is written in the file: ~/... under the home, relative under
# the project root, otherwise absolute. The shell has usually expanded ~ already.
host_path() {
  local p="$1" root; root="$(project_root)"
  # a ~ the shell did not expand (quoted) is the home; symlinks stay as typed (-s)
  # shellcheck disable=SC2088  # a literal ~ from the user, expanded here by hand
  case "$p" in "~") p="$HOME" ;; "~/"*) p="$HOME/${p#\~/}" ;; esac
  p="$(realpath -ms -- "$p")"
  case "$p" in "$(realpath -ms -- "$HOME")"/*) p="$HOME/${p#"$(realpath -ms -- "$HOME")"/}" ;; esac
  # shellcheck disable=SC2088  # the file keeps a literal ~
  case "$p/" in
    "$root/"?*) printf '%s\n' "${p#"$root"/}" ;;
    "$HOME/"?*) printf '~/%s\n' "${p#"$HOME"/}" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

# line_of WORD...: the words as one setup line, single-quoting a word only when it needs it.
line_of() {
  local w out=""
  for w in "$@"; do
    if [[ "$w" =~ ^[A-Za-z0-9_@%+=:,./~-]+$ ]]; then out+="${out:+ }$w"
    else out+="${out:+ }'${w//\'/\'\\\'\'}'"; fi
  done
  printf '%s\n' "$out"
}

# split_flags ARG...: WORDS without --no-build and --yes (before --), BUILD and YES set from them.
split_flags() {
  local a after=0
  WORDS=(); BUILD=1; YES=0
  for a in "$@"; do
    if [ "$after" = 0 ]; then
      case "$a" in --no-build) BUILD=0; continue ;; --yes) YES=1; continue ;; --) after=1 ;; esac
    fi
    WORDS+=("$a")
  done
}

# after_change BUILD YES: build, then offer to recreate a running dev container (without attaching).
after_change() {
  local name ans=n
  if [ "$1" = 0 ]; then echo "not built (--no-build); run agentic build"; return 0; fi
  cmd_build
  name="agentic-$(project_name)-dev"
  [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" = true ] || return 0
  if [ "$2" = 1 ]; then ans=y
  elif [ -t 0 ]; then read -rp "recreate the running dev container $name now? It ends its tmux sessions. [y/N] " ans || ans=n; fi
  case "$ans" in
    y|Y) docker rm -f "$name" >/dev/null 2>&1 || true; dev_start "$name" "$(project_image)" 0; echo "recreated $name; attach with agentic dev" ;;
    *) echo "run agentic dev recreate to use it" ;;
  esac
}

# cmd_setup_line add ...|copy ...|mount ...|volume ...
cmd_setup_line() {
  need_config
  split_flags "$@"
  case "${WORDS[0]:-} ${WORDS[1]:-}" in
    "copy "*) WORDS[1]="$(localise files "${WORDS[1]:?usage: agentic copy SRC DEST}")" ;;
    "mount "*) WORDS[1]="$(host_path "${WORDS[1]:?usage: agentic mount SRC DEST}")" ;;
    "add skill"|"add agent"|"add command") WORDS[2]="$(localise "${WORDS[1]}s" "${WORDS[2]:?usage: agentic add ${WORDS[1]} PATH}")" ;;
    "add workspace") case "${WORDS[2]:-}" in https://*|ssh://*|git@*:*|"") ;; *) WORDS[2]="$(host_path "${WORDS[2]}")" ;; esac ;;
  esac
  setup_edit add "$(line_of "${WORDS[@]}")"
  after_change "$BUILD" "$YES"
}

# cmd_remove KIND KEY [--target T]: deletes the lines, then the asset or copied file they owned.
cmd_remove() {
  need_config
  split_flags "$@"
  local kind="${WORDS[0]:?usage: agentic remove KIND KEY [--target T]}" key="${WORDS[1]:?usage: agentic remove KIND KEY}" out rc=0 cfg
  cfg="$(cfg_dir)"
  case "$kind" in
    skill|agent|command)
      # the key names one asset under its own folder, nothing else in .agentic/ or outside it
      key="${key%/}"
      [[ "$key" == "${kind}s/"?* && "/$key/" != */../* && "$key" != */./* ]] \
        || die "agentic remove $kind takes a path under ${kind}s/, for example ${kind}s/NAME" ;;
  esac
  out="$(setup_edit remove "${WORDS[@]}")" || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  case "$kind" in
    skill|agent|command)
      [ "$rc" = 0 ] || [ "$rc" = 3 ] || exit "$rc"
      # --target only narrows: the asset stays for the other harness
      if [[ " ${WORDS[*]} " != *" --target "* ]] && [ -e "$cfg/$key" ]; then
        rm -rf -- "${cfg:?}/$key" && echo "deleted .agentic/$key"
      fi ;;
    *) [ "$rc" = 0 ] || exit "$rc" ;;
  esac
  case "$kind" in
    workspace) echo "the clone stays in $(realpath -m -- "$AGENTIC_WORKSPACES")/$(project_name)/repos/$key; delete it yourself when you are done" ;;
    volume) echo "the Docker volume agentic-$(project_name)-$key stays; docker volume rm agentic-$(project_name)-$key deletes it" ;;
    copy) echo "files under .agentic/files/ stay; delete the one you no longer need" ;;
  esac
  after_change "$BUILD" "$YES"
}

cmd_list() { need_config; setup_edit list; }
