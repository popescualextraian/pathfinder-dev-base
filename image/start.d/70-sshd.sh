#!/usr/bin/env bash
# With allowed keys mounted (agentic dev ssh): a key-only sshd for this user on port 2222, so an
# editor connects over SSH. A failure warns (rc 2): the container still starts without SSH.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
keys="${AGENTIC_SSH_KEYS:-/etc/agentic/ssh/authorized_keys}"
hostdir="${AGENTIC_SSH_HOST_DIR:-/home/dev/.sshd}"
sshd="${AGENTIC_SSHD:-/usr/sbin/sshd}"
[ -s "$keys" ] || exit 0
[ "${1:-}" = --check ] && exit 0

umask 077
# the host key lives on the mounted dir, so it stays the same across recreates
if [ ! -f "$hostdir/host_ed25519" ] \
  && ! { mkdir -p "$hostdir" && ssh-keygen -q -t ed25519 -N '' -C agentic-dev -f "$hostdir/host_ed25519"; }; then
  say "cannot create the SSH host key in $hostdir"; exit 2
fi

# StrictModes no: the keys are a read-only mount owned by the host user, whose uid may differ
cat > "$AGENTIC_STATE/sshd_config" <<EOF
Port 2222
HostKey $hostdir/host_ed25519
PidFile $AGENTIC_STATE/sshd.pid
AuthorizedKeysFile $keys
AllowUsers $(id -un)
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowAgentForwarding no
AllowTcpForwarding local
X11Forwarding no
PermitUserEnvironment no
PrintMotd no
EOF

if ! "$sshd" -f "$AGENTIC_STATE/sshd_config" -E "$AGENTIC_STATE/sshd.log"; then
  say "sshd did not start; see $AGENTIC_STATE/sshd.log"; exit 2
fi
