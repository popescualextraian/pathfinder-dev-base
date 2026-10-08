#!/usr/bin/env bash
# Shared helpers for tool presets. Source, do not execute.
# Every preset: <name>.sh install VERSION | env VERSION | check VERSION
#   install  idempotent, into $AGENTIC_OPT/<name>/<VERSION>; runs as root at build time
#   env      KEY=VALUE lines; PATH=<dir> lines go first on PATH
#   check    prints the installed version; non-zero when missing
set -euo pipefail
AGENTIC_OPT="${AGENTIC_OPT:-/opt}"

arch_go() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;;
    *) echo "unsupported architecture $(uname -m)" >&2; return 1 ;;
  esac
}
# Temurin and Node name x86_64 "x64"; Temurin names arm64 "aarch64", Node "arm64".
arch_temurin() { case "$(arch_go)" in amd64) echo x64 ;; arm64) echo aarch64 ;; esac; }
arch_node() { case "$(arch_go)" in amd64) echo x64 ;; arm64) echo arm64 ;; esac; }

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

# first_missing PATH: the topmost ancestor of PATH (or PATH itself) that does not exist yet.
first_missing() {
  local p="$1" top=""
  while [ ! -e "$p" ] && [ "$p" != / ] && [ "$p" != . ]; do top="$p"; p="$(dirname "$p")"; done
  echo "$top"
}

# stage_extract DEST FILL...: run FILL (given the staging dir) next to DEST, then move
# the result into place. On failure nothing is left behind, so `present` stays false.
stage_extract() {
  local dest="$1" created tmp
  shift
  created="$(first_missing "$dest")"
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp -d "$(dirname "$dest")/.tmp.XXXXXX")"
  if "$@" "$tmp/x" && rm -rf "$dest" && mv "$tmp/x" "$dest"; then
    rm -rf "$tmp"
  else
    rm -rf "$tmp"
    if [ -n "$created" ]; then rm -rf "$created"; else rm -rf "$dest"; fi
    return 1
  fi
}

_untar_into() {
  local url="$1" strip="$2" out="$3" a
  a="$(mktemp)"
  fetch "$url" "$a" && mkdir -p "$out" && tar -xf "$a" -C "$out" --strip-components="$strip"
  local rc=$?
  rm -f "$a"
  return "$rc"
}

_unzip_into() {
  local url="$1" strip="$2" out="$3" a
  a="$(mktemp)"
  { fetch "$url" "$a" && mkdir -p "$out" && unzip -q "$a" -d "$out"; } || { rm -f "$a"; return 1; }
  rm -f "$a"
  if [ "$strip" = 1 ]; then
    # drop the single top folder
    local top; top="$(ls -A "$out")"
    [ "$(printf '%s\n' "$top" | wc -l)" -eq 1 ] && [ -d "$out/$top" ] || return 1
    mv "$out/$top" "$out.top" && rm -rf "$out" && mv "$out.top" "$out"
  fi
}

# untar URL DEST [STRIP]: unpack a tarball into DEST (atomically), dropping STRIP leading path parts.
untar() { stage_extract "$2" _untar_into "$1" "${3:-1}"; }

# unzip_to URL DEST [STRIP_TOP]: unpack a zip into DEST (atomically); with STRIP_TOP=1 its single top folder is dropped.
unzip_to() { stage_extract "$2" _unzip_into "$1" "${3:-0}"; }

present() { [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]; }

# preset_main "$@": dispatch to do_install, do_env, do_check, which each preset defines.
preset_main() {
  local cmd="${1:-}" v="${2:-}"
  if [ -z "$v" ]; then echo "usage: $(basename "$0") install|env|check VERSION" >&2; exit 2; fi
  case "$cmd" in
    install) do_install "$v" ;;
    env) do_env "$v" ;;
    check) do_check "$v" ;;
    *) echo "usage: $(basename "$0") install|env|check VERSION" >&2; exit 2 ;;
  esac
}
