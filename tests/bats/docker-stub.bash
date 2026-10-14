# A docker stand-in. Every call is logged to $DOCKER_LOG ("--- <subcommand>" then one argument per line).
# Controls: DOCKER_LABEL (image inspect -f output), DOCKER_IMAGE_EXISTS (1/0),
# DOCKER_RUN_OUT and DOCKER_RUN_RC (docker run), DOCKER_RUNNING (inspect .State.Running output),
# DOCKER_STATUS (inspect .State.Status), DOCKER_PORT (docker port), DOCKER_PS (docker ps ids, space-separated),
# DOCKER_MOUNTS (inspect .Mounts output, printed as is),
# DOCKER_BRIDGE_RC (exit code of the `pgrep` that tells whether a bridge runs; default 0, running),
# DOCKER_WT_ERR (makes a worktree.sh exec fail with this message), DOCKER_EXEC_RC (exit code of any other
# `docker exec`), DOCKER_NO_READY (the hold command never marks its start done).
# A docker.known file in $BATS_TEST_TMPDIR (one container name per line) makes inspect of a task container
# not in it fail as missing; `run --name` adds to it.
# `docker start` makes later status inspects say running. DOCKER_DOWN (inspect .State.Status fails like an unreachable daemon).
# A throwaway git container (`run ... --entrypoint git IMAGE ARG...`, the image right after the entrypoint)
# runs git here on ARG... with its -e variables and DOCKER_STUB_CONTAINER=1, so a planted command can
# tell where it ran. It does not isolate: mounts are only recorded.
install_docker_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
{ echo "--- $1"; printf '%s\n' "$@"; } >> "$DOCKER_LOG"
case "$1" in
  image)
    if [ "$3" = -f ]; then echo "${DOCKER_LABEL:-}"; exit 0; else [ "${DOCKER_IMAGE_EXISTS:-1}" = 1 ]; exit $?; fi ;;
  inspect)
    if [[ "$*" == *.Mounts* ]]; then printf '%s' "${DOCKER_MOUNTS:-}"; exit 0; fi
    if [[ "$*" == *State.Status* ]]; then
      # with a docker.known file, a task container not listed in it (made by `run --name` or by a test) is missing
      if [ -f "$BATS_TEST_TMPDIR/docker.known" ] && [[ "${@: -1}" == *-task-* ]] && ! grep -qxF -- "${@: -1}" "$BATS_TEST_TMPDIR/docker.known"; then
        echo "Error: No such object: ${@: -1}" >&2; exit 1
      fi
      if [ -f "$BATS_TEST_TMPDIR/docker.status" ]; then cat "$BATS_TEST_TMPDIR/docker.status"; exit 0; fi
      if [ -n "${DOCKER_DOWN:-}" ]; then echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2; exit 1; fi
      [ -n "${DOCKER_STATUS:-}" ] || { echo "Error: No such object: stub" >&2; exit 1; }
      echo "$DOCKER_STATUS"; exit 0
    fi
    [ -n "${DOCKER_RUNNING:-}" ] && echo "$DOCKER_RUNNING" || exit 1 ;;
  stop) [ -z "${DOCKER_STOP_FAIL:-}" ] || exit 1 ;;
  start) echo running > "$BATS_TEST_TMPDIR/docker.status"
    if [ -z "${DOCKER_NO_READY:-}" ] && [ -f "$BATS_TEST_TMPDIR/docker.ready" ]; then : > "$(cat "$BATS_TEST_TMPDIR/docker.ready")"; fi ;;
  exec)
    if [[ " $* " == *" pgrep "* ]]; then exit "${DOCKER_BRIDGE_RC:-0}"; fi
    if [[ " $* " == *" /opt/agentic/task/worktree.sh "* ]] && [ -n "${DOCKER_WT_ERR:-}" ]; then echo "$DOCKER_WT_ERR" >&2; exit 1; fi
    exit "${DOCKER_EXEC_RC:-0}" ;;
  port) [ -n "${DOCKER_PORT:-}" ] && echo "127.0.0.1:$DOCKER_PORT" ;;
  ps) [ -z "${DOCKER_PS:-}" ] || printf '%s\n' $DOCKER_PS ;;
  run)
    if [[ " $* " == *" agentic-task-hold "* ]] && [ -z "${DOCKER_NO_READY:-}" ]; then
      src="" dir="" prev=""
      for a in "$@"; do
        if [ "$prev" = -v ] && [[ "$a" == *:/tasks ]]; then src="${a%:/tasks}"; fi
        if [ "$prev" = -e ] && [[ "$a" == AGENTIC_TASK_DIR=/tasks/* ]]; then dir="${a#AGENTIC_TASK_DIR=/tasks/}"; fi
        prev="$a"
      done
      if [ -n "$src" ] && [ -n "$dir" ]; then mkdir -p "$src/$dir"; : > "$src/$dir/.ready"; echo "$src/$dir/.ready" > "$BATS_TEST_TMPDIR/docker.ready"; fi
    fi
    if [[ " $* " == *" --entrypoint git "* ]]; then
      envs=()
      while [ "$1" != --entrypoint ]; do
        if [ "$1" = -e ]; then envs+=("$2"); shift; fi
        shift
      done
      shift 3
      exec env "${envs[@]}" DOCKER_STUB_CONTAINER=1 git "$@"
    fi
    prev=""
    for a in "$@"; do
      if [ "$prev" = --name ] && [ -f "$BATS_TEST_TMPDIR/docker.known" ] && [ "${DOCKER_RUN_RC:-0}" = 0 ]; then echo "$a" >> "$BATS_TEST_TMPDIR/docker.known"; fi
      prev="$a"
    done
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

# docker_call_with SUB LINE: the arguments (SUB first) of the first docker SUB call with the argument LINE.
docker_call_with() {
  awk -v s="$1" -v l="$2" 'function out() { if (on && hit && !done) { printf "%s", buf; done = 1 } }
    /^--- /{ out(); on = ($2 == s); hit = 0; buf = ""; next }
    on { buf = buf $0 "\n"; if ($0 == l) hit = 1 }
    END { out() }' "$DOCKER_LOG"
}
docker_run_with() { docker_call_with run "$1"; }

# install_git_log: a git in front of the real one that logs each host call (not the stub's container
# calls) to $BATS_TEST_TMPDIR/hostgit.log as "pwd=... git_dir=... args: ...".
install_git_log() {
  local real; real="$(command -v git)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\n[ -n "${DOCKER_STUB_CONTAINER:-}" ] || echo "pwd=$PWD git_dir=${GIT_DIR:-} args: $*" >> "%s/hostgit.log"\nexec %q "$@"\n' \
    "$BATS_TEST_TMPDIR" "$real" > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
}
