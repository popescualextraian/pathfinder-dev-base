# Host CLI refactoring — design

Status: refactoring done (on main; `bin/agentic` kept as one file, its commands dispatched as
`cmd_<command>`); sections 2-4 are the original draft. Section 5 is in progress.

The host CLI (`bin/agentic` and `lib/host/*.sh`) has grown to about 1,500 lines,
with `bin/agentic` alone holding 35 functions across unrelated commands. This spec splits it into
one file per command group without changing behaviour, and records the changes agreed to follow
once the split is done.

## 1. Goals

- Each command group lives in its own file; `bin/agentic` keeps only the usage text, option-free
  dispatch and the shared bootstrap.
- No behaviour change: same commands, options, output, exit codes and files written. The bats
  suite is the contract and passes unchanged after every step (tests may move between files, but
  no assertion is weakened).
- Shared helpers stay in `lib/host/common.sh`; a helper used by one group moves into that group.

## 2. Current layout

| File | Lines | Holds |
|---|---|---|
| `bin/agentic` | 681 | usage, build-base, build, init, login, setup, shell, dev, doctor, run, status, send, answer, cancel, stop, resume, logs, follow, task shell, takeover, clean, dispatch |
| `lib/host/common.sh` | 137 | die, config reads, project root and name, run arguments |
| `lib/host/detect.sh` | 122 | tool detection for init |
| `lib/host/setup.sh` | 129 | add, copy, mount, volume, remove, list |
| `lib/host/task.sh` | 470 | task files, mounts, worktrees, containers |

## 3. Proposed layout (to be confirmed)

| File | Commands |
|---|---|
| `bin/agentic` | usage, dispatch |
| `lib/host/cmd-build.sh` | build-base, build |
| `lib/host/cmd-init.sh` | init (with `detect.sh`) |
| `lib/host/cmd-container.sh` | login, setup, shell, doctor, dev |
| `lib/host/cmd-task.sh` | run, status, send, answer, cancel, stop, resume, logs, follow, shell ID, takeover, clean |
| `lib/host/setup.sh` | add, copy, mount, volume, remove, list (unchanged) |
| `lib/host/task.sh` | task internals (unchanged) |

## 4. Approach

- One command group per commit, moved verbatim first, tidied in a later commit, so each diff is
  reviewable as a move.
- `make test` and `make lint` green after every commit; `make smoke` once at the end.
- shellcheck `source=` directives for every new file.

## 5. Follow-ups agreed for after the refactoring

- **`agentic login git`** (done: `image/bin/agentic-git`, `agentic login git`, a `doctor` check,
  the setup skill's Git section and docs/setup.md): push credentials and identity as a fixed command instead of the setup
  skill's prose. The logic is an in-image command (next to `agentic-env`), because the setup skill
  runs inside the container and cannot call the host CLI. It reads the `origin` URL, proposes the
  user name and token variable (`x-access-token` and `GH_TOKEN` for GitHub, `oauth2` and a GitLab
  token for GitLab), writes the `GIT_CONFIG_*` keys with `agentic-env`, sets an identity only when
  the host passes none, and checks with `git ls-remote` using the new keys inline (`.env` is read
  only at container start). `agentic login git` on the host runs it in a throwaway container like
  the other logins; the setup skill calls the in-image command directly; `doctor` checks the result.
- **Workspace folder: several repositories in one project.** A project folder need not be a
  repository: the user makes a folder, puts repositories in it (cloned on the host or inside the
  container, where `/work` is the live mount), and agentic mounts it at `/work` as it does today.
  agentic does not manage the repositories. A single-repository project is unchanged. Decided:
  the workspace folder is the project folder at `/work`, visible on the host where the user works.
  In order:
  1. `agentic login git` (above) comes first: cloning inside the container needs the credentials.
  2. `init` detects the shape and says it; it never prompts (the setup skill and scripts run it):
     - the folder is a repository, and its parent holds no other repository: single repository,
       as today;
     - the folder is a repository, and its parent holds other repositories: as today, plus a hint
       naming them: "to work on them together, run agentic init in <parent>";
     - the folder is not a repository and holds repositories one level down: workspace folder;
       `init` lists them, and warns about a `.agentic/` inside one of them (it is not read; move
       what is needed up);
     - the folder is not a repository and holds none: an empty workspace folder (or plain code
       without git); next steps: `agentic login git`, then clone into it.
     The shape is found at each use, not stored in `agentic.yaml`; `detect-report.md` records it.
  3. Tasks: `agentic run --repo NAME` takes a git repository directly under the project folder;
     without `--repo`, a workspace folder takes its only repository or refuses with the list.
     Task worktrees still come from clones in `$AGENTIC_WORKSPACES/<project>/repos/` (with private
     mirrors); the clone of a workspace repository is made from its `origin`, as `project_clone`
     does today for the project itself, which assumes the project root is a repository.
  4. Detection: `init` and the setup skill also read build files in each repository one level down.
  5. Discoverability: `docs/setup.md` gets a "several repositories" section (including that a
     folder on the Linux filesystem is faster than `/mnt/c`); `doctor` lists the repositories.
  6. `add workspace`: kept for repositories outside the folder; to be revisited once the
     workspace folder works (a URL line could clone into `/work/<name>` so a teammate or a remote
     host gets the same set).
- **Generated `agentic.yaml` comments**: what `targets` (where setup lines install) and
  `harness.default` (which agent runs) each mean, and above `setup:` the built-in mounts (the
  repository at `/work`, a task's own worktree there instead; `.agentic/` read-only at
  `/agentic-config`). `agentic list` shows the built-in mounts as fixed entries.
