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

# untar URL DEST [STRIP]: unpack a tarball into DEST, dropping STRIP leading path parts.
untar() {
  local url="$1" dest="$2" strip="${3:-1}" tmp
  tmp="$(mktemp -d)"
  fetch "$url" "$tmp/archive"
  mkdir -p "$dest"
  tar -xf "$tmp/archive" -C "$dest" --strip-components="$strip"
  rm -rf "$tmp"
}

# unzip_to URL DEST [STRIP_TOP]: unpack a zip into DEST; with STRIP_TOP=1 its single top folder is dropped.
unzip_to() {
  local url="$1" dest="$2" strip="${3:-0}" tmp
  tmp="$(mktemp -d)"
  fetch "$url" "$tmp/archive.zip"
  mkdir -p "$tmp/x" "$dest"
  unzip -q "$tmp/archive.zip" -d "$tmp/x"
  if [ "$strip" = 1 ]; then cp -a "$tmp"/x/*/. "$dest/"; else cp -a "$tmp/x/." "$dest/"; fi
  rm -rf "$tmp"
}

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
