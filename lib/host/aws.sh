#!/usr/bin/env bash
# A per-project ~/.aws holding one profile. Source, do not execute.

# ini_section FILE SECTION: the section verbatim, header included; nothing if absent.
ini_section() {
  [ -f "$1" ] || return 0
  awk -v want="$2" '
    /^[[:space:]]*\[/ {
      h = $0
      sub(/^[[:space:]]*\[/, "", h); sub(/\].*$/, "", h)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", h); gsub(/[[:space:]]+/, " ", h)
      inside = (h == want)
    }
    inside { print }' "$1" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

# build_aws_dir SRC DEST PROFILE: DEST gets the profile, its sso-session, its credentials and the
# SSO cache. Rewritten in place on every start, so the cache is fresh; the directory itself is
# never removed, because a running dev container has it bind-mounted. Never fails: AWS is optional.
build_aws_dir() {
  local src="$1" dest="$2" profile="$3" want section sso creds
  mkdir -p "$dest"
  : > "$dest/config"
  if [ "$profile" = default ]; then want="default"; else want="profile $profile"; fi
  section="$(ini_section "$src/config" "$want")"
  if [ -z "$section" ]; then
    echo "agentic: AWS profile '$profile' not found in $src/config" >&2
  else
    printf '%s\n' "$section" > "$dest/config"
    sso="$(sed -nE 's/^[[:space:]]*sso_session[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' <<<"$section" | head -1)"
    if [ -n "$sso" ]; then { echo; ini_section "$src/config" "sso-session $sso"; } >> "$dest/config"; fi
  fi
  creds="$(ini_section "$src/credentials" "$profile")"
  if [ -n "$creds" ]; then
    touch "$dest/credentials"
    chmod 600 "$dest/credentials"
    printf '%s\n' "$creds" > "$dest/credentials"
  else
    rm -f "$dest/credentials"
  fi
  # Sync the cache: drop what the host no longer has, then copy the host's files over.
  if [ -d "$dest/sso/cache" ]; then find "$dest/sso/cache" -mindepth 1 -delete 2>/dev/null || true; fi
  if [ -d "$src/sso/cache" ]; then
    mkdir -p "$dest/sso/cache"
    cp -r "$src/sso/cache/." "$dest/sso/cache/"
  fi
  return 0
}
