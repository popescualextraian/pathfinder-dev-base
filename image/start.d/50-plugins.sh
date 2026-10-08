#!/usr/bin/env bash
# Links the plugins baked into the image, enables the configured Claude plugins and installs
# missing Copilot plugins into the persistent ~/.copilot.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
src="${AGENTIC_PLUGINS_DIR:-$AGENTIC_DIR/claude-plugins}"
cdir="$(claude_dir)"
link="$cdir/plugins"
rc=0

if [ -L "$link" ] || [ ! -e "$link" ]; then
  if [ "$(readlink "$link" 2>/dev/null)" != "$src" ]; then
    if [ "$check" = 1 ]; then say "the image's plugins are not linked into $link"; rc=2
    else mkdir -p "$cdir"; ln -sfn "$src" "$link"; fi
  fi
else
  say "$link is a real directory; not linking the image's plugins"
  rc=2
fi

read_json() { if [ -s "$1" ] && jq -e . "$1" >/dev/null 2>&1; then cat "$1"; else echo '{}'; fi; }
settings="$cdir/settings.json"
cur="$(read_json "$settings")"; next="$cur"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if jq -e --arg k "$p" '.plugins[$k]' "$src/installed_plugins.json" >/dev/null 2>&1; then
    next="$(jq --arg k "$p" '.enabledPlugins[$k] = true' <<<"$next")"
  else
    say "plugin $p is not in the image; run agentic build"
    rc=2
  fi
done < <(jq -r '.plugins.claude[]?' "$RESOLVED")
if [ "$(jq -S . <<<"$cur")" != "$(jq -S . <<<"$next")" ]; then
  if [ "$check" = 1 ]; then say "configured plugins are not enabled"; rc=2
  else write_if_changed "$settings" "$next"; fi
fi

mapfile -t copilot_plugins < <(jq -r '.plugins.copilot[]?' "$RESOLVED")
if [ "${#copilot_plugins[@]}" -gt 0 ] && command -v copilot >/dev/null 2>&1; then
  t="${AGENTIC_NET_TIMEOUT:-300}"
  list="$(timeout "$t" copilot plugin list </dev/null 2>/dev/null || true)"
  [ "$check" = 1 ] || while IFS= read -r m; do
    timeout "$t" copilot plugin marketplace add "$m" </dev/null >/dev/null 2>&1 || true
  done < <(jq -r '.plugins.marketplaces[]?' "$RESOLVED")
  for p in "${copilot_plugins[@]}"; do
    grep -qF "$p" <<<"$list" && continue
    if [ "$check" = 1 ]; then say "Copilot plugin $p is not installed"; rc=2; continue; fi
    timeout "$t" copilot plugin install "$p" </dev/null >/dev/null 2>&1 || { say "Copilot plugin $p failed to install"; rc=2; }
  done
fi
exit "$rc"
