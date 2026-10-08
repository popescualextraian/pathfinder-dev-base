#!/usr/bin/env bash
# Fails when tracked or new files contain a denylisted term, a key or certificate outside
# tests/fixtures/, or a real .env. The denylist lives outside the repository.
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)}"
list="${AGENTIC_LEAK_DENYLIST:-$HOME/.config/agentic/leak-denylist.txt}"
if [ ! -s "$list" ]; then
  echo "leak-check: no denylist at $list; configure your denylist (one term per line)" >&2
  exit 1
fi
cd "$root"
mapfile -d '' -t files < <(git ls-files -z --cached --others --exclude-standard)
fail=0
existing=()
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  existing+=("$f")
  case "$f" in
    tests/fixtures/*) ;;
    *.crt|*.pem|*.key) echo "leak-check: $f: key or certificate outside tests/fixtures/"; fail=1 ;;
  esac
  case "$(basename "$f")" in
    .env.example) ;;
    .env|.env.*) echo "leak-check: $f: real .env file"; fail=1 ;;
  esac
done
# A CRLF denylist would leave \r on every term and match nothing: strip it.
terms="$(tr -d '\r' < "$list" | grep -vE '^[[:space:]]*(#|$)' || true)"
if [ -z "$terms" ]; then
  echo "leak-check: denylist $list has no terms; configure your denylist (one term per line)" >&2
  exit 1
fi
if [ "${#existing[@]}" -gt 0 ]; then
  # Only grep exit 1 (no match) is clean; 0 is a finding, anything else is an error.
  rc=0
  hits="$(grep -I -n -i -F -f <(printf '%s\n' "$terms") -- "${existing[@]}")" || rc=$?
  case "$rc" in
    0) printf '%s\n' "$hits" | sed 's/^/leak-check: /'; fail=1 ;;
    1) ;;
    *) echo "leak-check: grep failed (exit $rc)" >&2; fail=1 ;;
  esac
fi
if [ "$fail" -eq 0 ]; then echo "leak-check: clean"; fi
exit "$fail"
