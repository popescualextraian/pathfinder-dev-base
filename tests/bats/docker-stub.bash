# A docker stand-in. Every call is logged to $DOCKER_LOG ("--- <subcommand>" then one argument per line).
# Controls: DOCKER_LABEL (image inspect -f output), DOCKER_IMAGE_EXISTS (1/0),
# DOCKER_RUN_OUT and DOCKER_RUN_RC (docker run), DOCKER_RUNNING (inspect .State.Running output),
# DOCKER_STATUS (inspect .State.Status), DOCKER_PORT (docker port), DOCKER_PS (docker ps ids, space-separated),
# `docker start` makes later status inspects say running. DOCKER_DOWN (inspect .State.Status fails like an unreachable daemon).
# A throwaway git container (`run ... --entrypoint git IMAGE ARG...`, the image right after the entrypoint)
# runs git here on ARG... with DOCKER_STUB_CONTAINER=1, so a planted command can tell where it ran.
install_docker_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
{ echo "--- $1"; printf '%s\n' "$@"; } >> "$DOCKER_LOG"
case "$1" in
  image)
    if [ "$3" = -f ]; then echo "${DOCKER_LABEL:-}"; exit 0; else [ "${DOCKER_IMAGE_EXISTS:-1}" = 1 ]; exit $?; fi ;;
  inspect)
    if [[ "$*" == *State.Status* ]]; then
      if [ -f "$BATS_TEST_TMPDIR/docker.status" ]; then cat "$BATS_TEST_TMPDIR/docker.status"; exit 0; fi
      if [ -n "${DOCKER_DOWN:-}" ]; then echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2; exit 1; fi
      [ -n "${DOCKER_STATUS:-}" ] || { echo "Error: No such object: stub" >&2; exit 1; }
      echo "$DOCKER_STATUS"; exit 0
    fi
    [ -n "${DOCKER_RUNNING:-}" ] && echo "$DOCKER_RUNNING" || exit 1 ;;
  stop) [ -z "${DOCKER_STOP_FAIL:-}" ] || exit 1 ;;
  start) echo running > "$BATS_TEST_TMPDIR/docker.status" ;;
  port) [ -n "${DOCKER_PORT:-}" ] && echo "127.0.0.1:$DOCKER_PORT" ;;
  ps) [ -z "${DOCKER_PS:-}" ] || printf '%s\n' $DOCKER_PS ;;
  run)
    if [[ " $* " == *" --entrypoint git "* ]]; then
      while [ "$1" != --entrypoint ]; do shift; done
      shift 3
      DOCKER_STUB_CONTAINER=1 exec git "$@"
    fi
    if [ -n "${DOCKER_RUN_OUT:-}" ]; then printf '%s\n' "$DOCKER_RUN_OUT"; fi; exit "${DOCKER_RUN_RC:-0}" ;;
esac
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
}

# docker_sub SUB [N]: the arguments (subcommand first) of the Nth docker call with subcommand SUB.
docker_sub() {
  awk -v s="$1" -v n="${2:-1}" '/^--- /{ if ($2 == s) k++; on = ($2 == s && k == n); next } on' "$DOCKER_LOG"
}

# docker_run_with LINE: the arguments (run first) of the first docker run call with the argument LINE.
docker_run_with() {
  awk -v l="$1" 'function out() { if (on && hit && !done) { printf "%s", buf; done = 1 } }
    /^--- /{ out(); on = ($2 == "run"); hit = 0; buf = ""; next }
    on { buf = buf $0 "\n"; if ($0 == l) hit = 1 }
    END { out() }' "$DOCKER_LOG"
}
