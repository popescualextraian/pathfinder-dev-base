#!/usr/bin/env bash
# Applies the project config through the start steps, then runs the command or a worker adapter.
set -euo pipefail
AGENTIC_DIR="${AGENTIC_DIR:-/opt/agentic}"
AGENTIC_STATE="${AGENTIC_STATE:-$HOME/.agentic}"
steps="${AGENTIC_STEPS_DIR:-$AGENTIC_DIR/start.d}"
export AGENTIC_DIR AGENTIC_STATE
mkdir -p "$AGENTIC_STATE"
: > "$AGENTIC_STATE/env"
log="$AGENTIC_STATE/start.log"
echo "== start $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$log"

for s in "$steps"/[0-9][0-9]-*.sh; do
  [ -f "$s" ] || continue
  name="$(basename "$s" .sh)"
  out="$(mktemp)"
  set +e
  bash "$s" </dev/null >"$out" 2>&1
  rc=$?
  set -e
  { echo "-- $name rc=$rc"; cat "$out"; } >> "$log"
  if [ "${AGENTIC_DEBUG:-}" = 1 ]; then cat "$out" >&2; fi
  case "$rc" in
    0) ;;
    2) echo "agentic: $name: $(tail -n 1 "$out" | sed 's/^agentic: //')" >&2 ;;
    *) cat "$out" >&2
       echo "agentic: start step $name failed (rc=$rc); its output is above (AGENTIC_DEBUG=1 shows every step)" >&2
       rm -f "$out"; exit 1 ;;
  esac
  rm -f "$out"
  # shellcheck disable=SC1091
  source "$AGENTIC_STATE/env"
done

if [ -n "${AGENTIC_WORKER_MODE:-}" ]; then
  adapter="$AGENTIC_DIR/worker.d/$AGENTIC_WORKER_MODE.sh"
  if [ ! -f "$adapter" ]; then
    echo "agentic: no worker adapter $AGENTIC_WORKER_MODE (expected $adapter)" >&2
    exit 1
  fi
  exec bash "$adapter" "$@"
fi
if [ "$#" -eq 0 ]; then set -- bash; fi
exec "$@"
