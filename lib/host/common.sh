#!/usr/bin/env bash
# Host-side helpers for bin/agentic. Source, do not execute.
AGENTIC_DATA="${AGENTIC_DATA:-$HOME/.agentic}"
AGENTIC_WORKSPACES="${AGENTIC_WORKSPACES:-$HOME/agentic-workspaces}"
BASE_IMAGE=agentic-dev-base:local
PROXY_VARS=(HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy)

die() { echo "agentic: $*" >&2; exit 1; }
say() { echo "agentic: $*" >&2; }

# pgit ARG...: host git in the project's checkout, which a dev container can write: no fsmonitor,
# no hooks.
pgit() { git -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"; }
# project_root: the git top level of $AGENTIC_PROJECT (default: the current directory).
project_root() {
  local d="${AGENTIC_PROJECT:-$PWD}"
  pgit -C "$d" rev-parse --show-toplevel 2>/dev/null || (cd "$d" && pwd)
}
cfg_dir() { printf '%s\n' "$(project_root)/.agentic"; }
need_config() {
  [ -f "$(cfg_dir)/agentic.yaml" ] || die "no .agentic/agentic.yaml in $(project_root); run agentic init"
}

# yaml_top FILE KEY: a top-level scalar, without quotes or a trailing comment.
yaml_top() {
  awk -v key="$2" 'index($0, key ":") == 1 {
      v = substr($0, length(key) + 2)
      sub(/[[:space:]]+#.*$/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v); gsub(/^\047|\047$/, "", v)
      print v; exit }' "$1"
}
project_name() {
  local p; p="$(yaml_top "$(cfg_dir)/agentic.yaml" project)"
  [ -n "$p" ] || die "agentic.yaml has no project name"
  printf '%s\n' "$p"
}
project_image() { printf 'agentic-%s:local\n' "$(project_name)"; }
base_image_of() { local b; b="$(yaml_top "$(cfg_dir)/agentic.yaml" base_image)"; printf '%s\n' "${b:-$BASE_IMAGE}"; }
image_exists() { docker image inspect "$1" >/dev/null 2>&1; }
image_label() { docker image inspect -f "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null || true; }

dotenv_value() {
  if [ -f "$1" ]; then grep -E "^$2=" "$1" | tail -1 | cut -d= -f2- || true; fi
}

# is_placeholder VALUE: a stand-in such as TBD, changeme or <token>, not a credential.
is_placeholder() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    tbd|todo|changeme|change-me|none|null|n/a|xxx*|'<'*'>') return 0 ;;
    *) return 1 ;;
  esac
}
# token_value FILE KEY: KEY's value in .env, empty when unset or a placeholder.
token_value() {
  local v; v="$(dotenv_value "$1" "$2")"
  if is_placeholder "$v"; then v=""; fi
  printf '%s' "$v"
}

# check_env_file FILE: refuse what docker --env-file would silently mangle.
check_env_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  if grep -q $'\r' "$f"; then die "$f has Windows line endings (CRLF); fix it with: sed -i 's/\r\$//' '$f'"; fi
  if grep -Eq "^[A-Za-z_][A-Za-z0-9_]*=([\"'].*[\"'])[[:space:]]*\$" "$f"; then
    die "$f has quoted values; docker keeps the quotes as part of the value. Remove them."
  fi
}

proxy_build_args() {
  PROXY_BUILD_ARGS=()
  local v
  for v in "${PROXY_VARS[@]}"; do
    if [ -n "${!v:-}" ]; then PROXY_BUILD_ARGS+=(--build-arg "$v"); fi
  done
}

# build_run_args IMAGE: docker run arguments for this project, in the global array RUN_ARGS. Of the
# workspace only repos/ (the clones) is mounted, canonical: its tasks/ and events/ hold what the
# host trusts or writes, and stay out of interactive containers.
build_run_args() {
  local root cfg p data repos
  root="$(project_root)"; cfg="$root/.agentic"; p="$(project_name)"
  data="$AGENTIC_DATA/projects/$p"; repos="$(realpath -m -- "$AGENTIC_WORKSPACES")/$p/repos"
  mkdir -p "$data/harness/claude" "$data/harness/copilot" "$repos"
  RUN_ARGS=(--label "agentic.project=$p"
    -v "$root:/work" -v "$repos:/workspaces/repos" -v "$cfg:/agentic-config:ro"
    -v "$data/harness/claude:/home/dev/.claude" -v "$data/harness/copilot:/home/dev/.copilot")
  shared_run_args "$1"
}

# shared_run_args IMAGE: appends what every container of the project gets to RUN_ARGS: the .env
# file, git identity, proxy, the opt-in Docker socket and the setup lines' mounts and volumes.
shared_run_args() {
  local img="$1" root cfg v name email sock
  root="$(project_root)"; cfg="$root/.agentic"
  check_env_file "$cfg/.env"
  if [ -f "$cfg/.env" ]; then RUN_ARGS+=(--env-file "$cfg/.env"); fi
  # the host's git identity, for what .env leaves unset (-e would win over --env-file)
  name="$(pgit -C "$root" config user.name || true)"; email="$(pgit -C "$root" config user.email || true)"
  if [ -n "$name" ] && [ -z "$(dotenv_value "$cfg/.env" GIT_AUTHOR_NAME)" ]; then RUN_ARGS+=(-e "GIT_AUTHOR_NAME=$name" -e "GIT_COMMITTER_NAME=$name"); fi
  if [ -n "$email" ] && [ -z "$(dotenv_value "$cfg/.env" GIT_AUTHOR_EMAIL)" ]; then RUN_ARGS+=(-e "GIT_AUTHOR_EMAIL=$email" -e "GIT_COMMITTER_EMAIL=$email"); fi
  for v in "${PROXY_VARS[@]}"; do
    if [ -n "${!v:-}" ]; then RUN_ARGS+=(-e "$v"); fi
  done
  sock="${AGENTIC_DOCKER_SOCK:-/var/run/docker.sock}"
  if [ "$(image_label "$img" agentic.docker_socket)" = true ] && [ -S "$sock" ]; then
    RUN_ARGS+=(-v "$sock:/var/run/docker.sock" --group-add "$(stat -c %g "$sock")")
  fi
  setup_run_args "$img"
}

# setup_run_args IMAGE: -v arguments for the image's mount, volume and path-workspace lines (the
# agentic.run label written by agentic build), appended to RUN_ARGS. ~ is the host home; a relative
# source is relative to the project root.
setup_run_args() {
  local data row kind src dest opt line root p t=$'\t'
  data="$(image_label "$1" agentic.run)"
  [ -n "$data" ] || return 0
  root="$(project_root)"; p="$(project_name)"
  # fields are split by hand: read with IFS=tab would merge an empty field into the next
  while IFS= read -r row; do
    kind="${row%%"$t"*}"; row="${row#*"$t"}"
    src="${row%%"$t"*}"; row="${row#*"$t"}"
    dest="${row%%"$t"*}"; row="${row#*"$t"}"
    opt="${row%%"$t"*}"; line="${row#*"$t"}"
    case "$kind" in
      mount|bind)
        # shellcheck disable=SC2088  # a literal ~ in the line, expanded here by hand
        case "$src" in "~") src="$HOME" ;; "~/"*) src="$HOME/${src#\~/}" ;; /*) ;; *) src="$root/$src" ;; esac
        src="$(realpath -m -- "$src")"
        [ -e "$src" ] || die "setup line '$line': $src does not exist on this host"
        RUN_ARGS+=(-v "$src:$dest${opt:+:$opt}") ;;
      volume) RUN_ARGS+=(-v "agentic-$p-$src:$dest") ;;
    esac
  done < <(base64 -d <<<"$data")
}
