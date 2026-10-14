#!/usr/bin/env bash
# setup: lines (docs/specs/2026-10-14-revamp-design.md section 4): splitting, parsing, validation.
# Source after common.sh. Nothing here runs a line; it only reads it.
# shellcheck disable=SC2034  # the L_* globals are read by the scripts that source this file

SECRET_LIKE='(^|/)(\.env(\..*)?|id_[A-Za-z0-9]+|credentials|[^/]*\.pem|[^/]*\.key)$'

# line_words LINE: LINE split as a shell would, without expanding anything, into the array WORDS.
line_words() {
  local enc
  # python prints the words NUL-joined and base64-encoded, so no pipe can hide its failure
  enc="$(python3 -I -c '
import base64, shlex, sys
try:
    words = shlex.split(sys.argv[1])
except ValueError as e:
    sys.exit(str(e))
print(base64.b64encode(b"".join(w.encode() + b"\0" for w in words)).decode())' "$1")" || return 1
  mapfile -d '' -t WORDS < <(base64 -d <<<"$enc")
}

_rel_ok() { [ -n "$1" ] && [[ "$1" != /* ]] && [[ "/$1/" != */../* ]]; }
_abs_ok() { [[ "$1" == /* ]] && [[ "$1/" != */../* ]] && [[ "$1" != *[:,]* ]]; }
_fail() { L_ERR="$1"; return 1; }
# _secret_name NAME: NAME has a part (split at _) that names a credential, such as API_KEY or JIRA_PAT.
_secret_name() {
  local part
  for part in ${1//_/ }; do
    case "$(tr '[:lower:]' '[:upper:]' <<<"$part")" in
      TOKEN|TOKENS|PASSWORD|PASSWD|PASS|SECRET|SECRETS|KEY|APIKEY|PAT|AUTH|CREDENTIAL|CREDENTIALS) return 0 ;;
    esac
  done
  return 1
}
# _url_secret WORD: WORD holds a URL with user:password@ or a token-like query parameter.
_url_secret() {
  [[ "$1" =~ [a-z+]+://[^/@[:space:]]*:[^/@[:space:]]*@ ]] && return 0
  [[ "$1" =~ [a-z+]+://[^[:space:]]*[?\&]([A-Za-z_]*([Tt]oken|[Kk]ey|[Ss]ecret|[Pp]assword|[Aa]uth|[Ss]ig)[A-Za-z_]*)= ]]
}

# norm_targets T: the targets in a fixed order, comma-joined; fails on an unknown one.
norm_targets() {
  local t x out=() c=0 p=0
  IFS=, read -ra t <<<"$1"
  for x in "${t[@]}"; do
    case "$x" in claude) c=1 ;; copilot) p=1 ;; *) return 1 ;; esac
  done
  [ "$c" = 1 ] && out+=(claude)
  [ "$p" = 1 ] && out+=(copilot)
  [ "${#out[@]}" -gt 0 ] || return 1
  (IFS=,; echo "${out[*]}")
}

# parse_line LINE: see the Interfaces of Task 2 in docs/plans/2026-10-14-revamp.md.
parse_line() {
  L_KIND=""; L_PHASE=""; L_KEY=""; L_TARGETS=""; L_SRC=""; L_DEST=""; L_OPT=""; L_REF=""
  L_TRANSPORT=""; L_URL=""; L_ENV=(); L_CMD=(); L_ERR=""; L_WARN=""
  [[ "$1" != *$'\n'* ]] || _fail "a line cannot span lines" || return 1
  line_words "$1" || _fail "unbalanced quotes" || return 1
  local w=("${WORDS[@]}") pos=() i=0 a name="" readonly=0 dashdash=0
  for a in "${w[@]}"; do
    if _url_secret "$a"; then _fail "credentials in a URL end up in the image or the repository; put them in .agentic/.env"; return 1; fi
  done
  while [ "$i" -lt "${#w[@]}" ]; do
    a="${w[i]}"
    case "$a" in
      --) L_CMD=("${w[@]:i+1}"); dashdash=1; break ;;
      --target) i=$((i + 1)); L_TARGETS="${w[i]:-}"
                norm_targets "$L_TARGETS" >/dev/null || _fail "--target takes claude, copilot or claude,copilot" || return 1 ;;
      --env) i=$((i + 1)); L_ENV+=("${w[i]:-}") ;;
      --transport) i=$((i + 1)); L_TRANSPORT="${w[i]:-}" ;;
      --name) i=$((i + 1)); name="${w[i]:-}" ;;
      --ref) i=$((i + 1)); L_REF="${w[i]:-}" ;;
      --readonly) readonly=1 ;;
      --*) _fail "unknown option $a"; return 1 ;;
      *) pos+=("$a") ;;
    esac
    i=$((i + 1))
  done
  local cmd="${pos[0]:-}"
  if [ "$cmd" = add ]; then cmd="add ${pos[1]:-}"; pos=("${pos[@]:2}"); else pos=("${pos[@]:1}"); fi
  # which options each command takes
  local allowed
  case "$cmd" in
    "add marketplace"|"add plugin"|"add skill"|"add agent"|"add command") allowed=target ;;
    "add mcp") allowed="target env transport dashdash" ;;
    "add workspace") allowed="name ref" ;;
    mount) allowed="readonly" ;;
    copy|volume) allowed="" ;;
    *) _fail "unknown command: ${w[*]:0:2}"; return 1 ;;
  esac
  [ -z "$L_TARGETS" ] || [[ " $allowed " == *" target "* ]] || _fail "--target is not an option of $cmd" || return 1
  [ "${#L_ENV[@]}" -eq 0 ] || [[ " $allowed " == *" env "* ]] || _fail "--env is not an option of $cmd" || return 1
  [ -z "$L_TRANSPORT" ] || [[ " $allowed " == *" transport "* ]] || _fail "--transport is not an option of $cmd" || return 1
  [ "$dashdash" = 0 ] || [[ " $allowed " == *" dashdash "* ]] || _fail "-- is not used by $cmd" || return 1
  [ -z "$name" ] || [[ " $allowed " == *" name "* ]] || _fail "--name is not an option of $cmd" || return 1
  [ -z "$L_REF" ] || [[ " $allowed " == *" ref "* ]] || _fail "--ref is not an option of $cmd" || return 1
  [ "$readonly" = 0 ] || [[ " $allowed " == *" readonly "* ]] || _fail "--readonly is not an option of $cmd" || return 1

  case "$cmd" in
    "add marketplace")
      [ "${#pos[@]}" -eq 1 ] || _fail "usage: add marketplace SOURCE [--target T]" || return 1
      L_KIND=marketplace; L_PHASE=build; L_KEY="${pos[0]}"; L_SRC="${pos[0]}" ;;
    "add plugin")
      [ "${#pos[@]}" -eq 1 ] && [[ "${pos[0]}" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] \
        || _fail "usage: add plugin NAME@MARKETPLACE [--target T]" || return 1
      L_KIND=plugin; L_PHASE=build; L_KEY="${pos[0]}" ;;
    "add mcp")
      [ "${#pos[@]}" -ge 1 ] && [[ "${pos[0]}" =~ ^[A-Za-z0-9_-]+$ ]] || _fail "add mcp needs a NAME of letters, digits, _ and -" || return 1
      L_KIND=mcp; L_PHASE=build; L_KEY="${pos[0]}"
      for a in "${L_ENV[@]}"; do
        [[ "$a" =~ ^[A-Za-z_][A-Za-z0-9_]*(=.*)?$ ]] || _fail "--env takes KEY or KEY=VALUE, not '$a'" || return 1
        if [[ "$a" == *=* ]] && _secret_name "${a%%=*}"; then
          _fail "--env ${a%%=*}: literal secret; write --env ${a%%=*} and put the value in .agentic/.env"; return 1
        fi
      done
      if [ -n "$L_TRANSPORT" ]; then
        case "$L_TRANSPORT" in http|sse) ;; *) _fail "--transport takes http or sse" || return 1 ;; esac
        [ "${#pos[@]}" -eq 2 ] && [ "$dashdash" = 0 ] || _fail "usage: add mcp NAME --transport http|sse URL" || return 1
        [ "${#L_ENV[@]}" -eq 0 ] || _fail "--env applies to a stdio server; a remote server gets no environment" || return 1
        L_URL="${pos[1]}"
      else
        [ "${#pos[@]}" -eq 1 ] && [ "${#L_CMD[@]}" -gt 0 ] || _fail "usage: add mcp NAME [--env K]... -- COMMAND [ARGS...]" || return 1
      fi ;;
    "add skill"|"add agent"|"add command")
      L_KIND="${cmd#add }"; L_PHASE=build
      [ "${#pos[@]}" -eq 1 ] || _fail "usage: add $L_KIND PATH [--target T]" || return 1
      L_KEY="${pos[0]%/}"
      _rel_ok "$L_KEY" && [[ "$L_KEY" == "${L_KIND}s/"?* ]] || _fail "$L_KIND path must be under ${L_KIND}s/ in .agentic/" || return 1 ;;
    "add workspace")
      [ "${#pos[@]}" -eq 1 ] || _fail "usage: add workspace URL|PATH [--name N] [--ref R]" || return 1
      L_KIND=workspace; L_PHASE=start; L_SRC="${pos[0]}"
      case "$L_SRC" in https://*|ssh://*|git@*:*) L_OPT=url ;; *) L_OPT=path ;; esac
      [ -z "$L_REF" ] || [ "$L_OPT" = url ] || _fail "--ref needs a URL workspace" || return 1
      if [ -z "$name" ]; then name="${L_SRC%/}"; name="${name##*[/:]}"; name="${name%.git}"; fi
      [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$name" != . ] && [ "$name" != .. ] || _fail "workspace name '$name' is not valid; use --name" || return 1
      L_KEY="$name"; L_DEST="/workspaces/repos/$name" ;;
    copy)
      [ "${#pos[@]}" -eq 2 ] || _fail "usage: copy SRC DEST" || return 1
      L_KIND=copy; L_PHASE=build; L_SRC="${pos[0]%/}"; L_DEST="${pos[1]}"; L_KEY="$L_DEST"
      _rel_ok "$L_SRC" || _fail "copy SRC must be a path inside .agentic/" || return 1
      _abs_ok "$L_DEST" || _fail "copy DEST must be an absolute path without : or ," || return 1
      if [[ "$L_SRC" =~ $SECRET_LIKE ]]; then
        L_WARN="$L_SRC looks like a secret: it ends up in the image, readable by anyone who has it, and stays in pushed layers; use .env or mount instead"
      fi ;;
    mount)
      [ "${#pos[@]}" -eq 2 ] || _fail "usage: mount SRC DEST [--readonly]" || return 1
      L_KIND=mount; L_PHASE=run; L_SRC="${pos[0]}"; L_DEST="${pos[1]}"; L_KEY="$L_DEST"
      [ "$readonly" = 0 ] || L_OPT=ro
      [[ "$L_SRC" != *[:,]* ]] || _fail "mount SRC cannot contain : or ," || return 1
      _abs_ok "$L_DEST" || _fail "mount DEST must be an absolute path without : or ," || return 1 ;;
    volume)
      [ "${#pos[@]}" -eq 2 ] || _fail "usage: volume NAME DEST" || return 1
      L_KIND=volume; L_PHASE=run; L_KEY="${pos[0]}"; L_DEST="${pos[1]}"
      [[ "$L_KEY" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || _fail "volume NAME takes lowercase letters, digits, _ . -" || return 1
      _abs_ok "$L_DEST" || _fail "volume DEST must be an absolute path without : or ," || return 1 ;;
  esac
}

# line_ident DEFAULT_TARGETS: KIND, KEY and the effective targets of the last parsed line.
line_ident() {
  local tg=""
  case "$L_KIND" in
    marketplace|plugin|mcp|skill|agent|command) tg="$(norm_targets "${L_TARGETS:-$1}")" ;;
  esac
  printf '%s\t%s\t%s\n' "$L_KIND" "$L_KEY" "$tg"
}

# setup_errs FILE: the errors of the resolved config's setup lines, one per line.
setup_errs() {
  local dt i=0 l id
  declare -A seen=()
  dt="$(jq -r '(.targets // ["claude","copilot"]) | join(",")' "$1")"
  while IFS= read -r l; do
    if ! parse_line "$l"; then echo ".setup[$i]: $L_ERR"
    else
      id="$(line_ident "$dt")"
      if [ -n "${seen[$id]:-}" ]; then echo ".setup[$i]: same command, key and targets as .setup[${seen[$id]}]"
      else seen[$id]="$i"; fi
    fi
    i=$((i + 1))
  done < <(jq -r '.setup // [] | .[]' "$1")
}
