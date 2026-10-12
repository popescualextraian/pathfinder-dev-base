# A docker stand-in. Every call is logged to $DOCKER_LOG ("--- <subcommand>" then one argument per line).
# Controls: DOCKER_LABEL (image inspect -f output), DOCKER_IMAGE_EXISTS (1/0),
# DOCKER_RUN_OUT and DOCKER_RUN_RC (docker run), DOCKER_RUNNING (inspect .State.Running output),
# DOCKER_STATUS (inspect .State.Status), DOCKER_PORT (docker port), DOCKER_PS (docker ps ids, space-separated),
# DOCKER_DOWN (inspect .State.Status fails like an unreachable daemon).
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
      if [ -n "${DOCKER_DOWN:-}" ]; then echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2; exit 1; fi
      [ -n "${DOCKER_STATUS:-}" ] || { echo "Error: No such object: stub" >&2; exit 1; }
      echo "$DOCKER_STATUS"; exit 0
    fi
    [ -n "${DOCKER_RUNNING:-}" ] && echo "$DOCKER_RUNNING" || exit 1 ;;
  port) [ -n "${DOCKER_PORT:-}" ] && echo "127.0.0.1:$DOCKER_PORT" ;;
  ps) [ -z "${DOCKER_PS:-}" ] || printf '%s\n' $DOCKER_PS ;;
  run) if [ -n "${DOCKER_RUN_OUT:-}" ]; then printf '%s\n' "$DOCKER_RUN_OUT"; fi; exit "${DOCKER_RUN_RC:-0}" ;;
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
