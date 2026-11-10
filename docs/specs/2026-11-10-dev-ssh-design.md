# SSH into the dev container

Status: draft for review, 2026-11-10. Umbrella: `docs/architecture.md`. Extends dev mode
(`docs/dev-mode.md`): the dev container runs an SSH server, so an editor that connects over SSH
(VS Code Remote-SSH, JetBrains Gateway, Orca and similar) opens the project in it.

## 1. Outcome

    agentic dev ssh ~/.ssh/id_ed25519.pub   allow this key; prints the ssh config block
    agentic dev ssh                         prints the ssh config block and whether the port is published
    agentic dev recreate                    the container now publishes 127.0.0.1:2222 and runs sshd

Then on the laptop:

    Host agentic-<project>
      HostName localhost
      Port 2222
      User dev
      IdentityFile ~/.ssh/id_ed25519

Success criteria:

- With no key allowed, `agentic dev` behaves exactly as today: nothing is installed, published or started.
- With a key, `ssh agentic-<project>` logs in as `dev`. `agentic dev stop`/start, a Docker restart and
  `agentic dev recreate` keep the same host key and the allowed keys.
- Only key login works: no password, no root, no agent forwarding.
- An interactive SSH shell sees the same environment as `agentic dev` (the `.agentic/.env` values,
  git identity, proxy), and no secret is written to a file to get it there.
- `make test`, `make lint` and `make smoke` pass; `docs/dev-mode.md` and `agentic help` describe it.

## 2. Verified facts (2026-11-10, base image, OpenSSH 9.6p1 from Ubuntu)

- `openssh-server` adds about 2 MB installed.
- sshd runs as the non-root user `dev`, with no sudo and no capability added. Key login as `dev` works
  in both daemon mode (`sshd -f CONFIG`, port 2222) and inetd mode (`ProxyCommand sshd -i -f CONFIG`).
  A non-root sshd can only log in its own user, which is what we want.
- If `authorized_keys` belongs to another uid, `StrictModes yes` refuses it ("bad ownership or modes"),
  and login fails. A bind mount from the host carries the host user's uid, which is 1000 on a typical
  WSL setup but not everywhere. The file is mounted read-only, so the ownership check protects
  nothing here; `StrictModes no` makes login work.
- The dev container has no `--init` and no `--cap-drop` (`dev_start`); the entrypoint runs the start
  steps on every container start, including Docker's `--restart unless-stopped`. A step that starts
  sshd in daemon mode returns at once, because sshd detaches and closes its stdio.

## 3. Decisions

**D1. Opt-in by the keys file, not by a flag or schema key.** The host keeps
`$AGENTIC_DATA/projects/<project>/ssh/keys/authorized_keys`. If it exists and is not empty, `dev_start`
mounts the SSH paths and publishes the port; otherwise nothing changes. No `agentic.yaml` key and no
image rebuild are needed.

**D2. `openssh-server` goes in the base image.** About 2 MB, so every project can turn SSH on without
a `tools.apt` line or a rebuild. The package's own service, host keys and `/etc/ssh/sshd_config` are
not used. The Dockerfile removes the host keys the package generates (`/etc/ssh/ssh_host_*`), so no
private key stays in an image layer.

**D3. Two mounts, in the dev container only** (`dev_start`, not `build_run_args`: shell, setup, doctor
and tasks get neither):

| Host | Container | Mode | Holds |
|---|---|---|---|
| `…/ssh/keys` | `/etc/agentic/ssh` | ro | `authorized_keys`, written only by the CLI |
| `…/ssh/host` | `/home/dev/.sshd` | rw | `host_ed25519`, `host_ed25519.pub` |

The keys directory is read-only, so nothing running in the container (an agent included) can add a key
to log in with later. A directory is mounted rather than the file, so replacing the file on the host
(an editor's atomic save) still reaches the container.

**D4. The host port comes from `AGENTIC_SSH_PORT` in `.agentic/.env`; the default is 2222.** It is
published as `-p 127.0.0.1:$AGENTIC_SSH_PORT:2222`, so sshd is reachable only from this machine (and
from Windows through WSL's localhost forwarding). A second project with SSH on sets its own port. A
port already in use fails the start with the same message as an app port. The port is fixed when the
container is created, so a change needs `agentic dev recreate`; `agentic dev ssh` says so when the
running container does not publish it.

**D5. A start step `image/start.d/70-sshd.sh`:**

1. Exits 0 when `/etc/agentic/ssh/authorized_keys` is missing (every task, shell and setup container,
   and a dev container with SSH off).
2. Creates `/home/dev/.sshd/host_ed25519` with `ssh-keygen -t ed25519 -N ''` under `umask 077` if it
   is missing, so the host key stays the same across recreates.
3. Writes `$AGENTIC_STATE/sshd_config` (the start state, rebuilt on every start, holds no secret):

        Port 2222
        HostKey /home/dev/.sshd/host_ed25519
        PidFile /home/dev/.agentic/sshd.pid
        AuthorizedKeysFile /etc/agentic/ssh/authorized_keys
        AllowUsers dev
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        AllowAgentForwarding no
        AllowTcpForwarding local
        X11Forwarding no
        PermitUserEnvironment no
        PrintMotd no

   `AllowTcpForwarding local` lets an editor forward a port it previews (a dev server). Agent
   forwarding stays off, because the container deliberately has no SSH keys (README, "git").
4. Starts `/usr/sbin/sshd -f "$AGENTIC_STATE/sshd_config" -E "$AGENTIC_STATE/sshd.log"`.
5. If sshd fails, the step exits 2: the entrypoint prints a warning and the container still starts.
   SSH is a convenience, and `agentic dev` must keep working without it.

**D6. The SSH session gets the container's environment from PID 1, not from a file.** sshd gives each
session a fresh environment, so `docker run -e`/`--env-file` values would be missing. When
`SSH_CONNECTION` is set, `/etc/profile.d/agentic.sh` exports the entries of `/proc/1/environ`
(PID 1 runs as `dev`, so it is readable), except `HOME`, `HOSTNAME`, `PWD`, `SHLVL`, `TERM` and
anything already set. `PATH` is the exception to the last rule: sshd sets a default `PATH` without the
image's tool directories, so PID 1's `PATH` replaces it. The values stay in process memory, as with `docker exec`; nothing is written
to `~/.agentic/env` or a log. Interactive shells read this through `/etc/bash.bashrc`.
Non-interactive commands (`ssh host CMD`) stop at the early return at the top of
`/etc/bash.bashrc` and do not get it: an editor's server starts without the project env, but the
terminals it opens are interactive and do.

**D7. `agentic dev ssh [PUBKEY]` is the only new verb.** With a file, it checks that every line is a
public key (first field `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-*` or `sk-*`). It refuses a private key
("this is a private key; pass the .pub file") and anything else. It appends the lines it does not
already hold to `authorized_keys` (mode 600, directory 700). Without a file, it prints the
config block. Either way it prints the block and, when the container does not publish the port,
"run agentic dev recreate". Removing a key means editing `authorized_keys`; no verb for it.
`agentic dev status` adds `ssh=127.0.0.1:<port>` when the port is published.

## 4. Changes

| File | Change |
|---|---|
| `image/Dockerfile` | `openssh-server` in the apt list; remove `/etc/ssh/ssh_host_*` |
| `image/start.d/70-sshd.sh` | new (D5) |
| `image/profile.d/agentic.sh` | the PID 1 env import for SSH sessions (D6) |
| `bin/agentic` | `dev_start` mounts and publishes (D3, D4); `cmd_dev` gains `ssh`; `dev_status` line; help text |
| `docs/dev-mode.md` | an "SSH" section: setup, the config block, the inetd alternative, what survives |
| `README.md` | one line under dev mode |

## 5. Tests (written first)

- bats, CLI (docker stub): no keys file means no new `-v` or `-p` args; a keys file adds both mounts
  (ro on keys) and `-p 127.0.0.1:2222:2222`; `AGENTIC_SSH_PORT=2233` gives `-p 127.0.0.1:2233:2222`;
  `dev ssh` refuses a private key and a non-key file, adds a key once (twice is a no-op), and sets
  modes 600/700; `dev ssh` says to recreate when the container lacks the port; `dev status` shows the line.
- bats, step (stubbed `sshd` and `ssh-keygen`): skips without keys; generates the host key only when
  missing; writes the config with each line from D5; exits 2 when sshd fails.
- bats, profile: with `SSH_CONNECTION` set and a fake environ file, the variables are exported, the
  excluded ones and those already set are left alone; without `SSH_CONNECTION` nothing changes.
- smoke (`tests/image/smoke.sh`): a dev container with a generated key; `ssh -p PORT dev@127.0.0.1
  'bash -ic "id -un; echo \$X"'` prints `dev` and the value of `X` from `.agentic/.env`; a password
  login fails; after `docker restart` the host key fingerprint is unchanged.

## 6. Not in scope

- **Persisting editor caches** (`~/.cache/<editor>`, `~/.vscode-server`). The editor downloads its
  server again after a recreate, which is a delay, not data loss. Mounting `~/.cache` would also hide
  whatever the image build put there. Possible follow-up: one mount per editor cache directory.
- **SSH into task containers.** Tasks run unattended, behind the gate and with `--cap-drop ALL`; a way
  in from outside does not belong there.
- **Reaching the container from another machine.** The port is bound to 127.0.0.1. A remote dev box
  is a launcher's job (`docs/remote.md`).
- **The inetd alternative as a feature.** `ProxyCommand wsl.exe docker exec -i agentic-<project>-dev
  /usr/sbin/sshd -i -f /home/dev/.agentic/sshd_config` uses the same config and keys with no published
  port. It only works when the editor runs the system ssh client, so `docs/dev-mode.md` documents it,
  and no code is added for it.
