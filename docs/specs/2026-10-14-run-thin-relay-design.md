# `agentic run` as a thin relay

Status: draft for review, 2026-10-14. Umbrella: `docs/architecture.md`. Changes sub-project 2
(tasks): how `run` gets the project into a task container. Keeps the bridge, the API, the gate and
the task verbs.

## 1. Outcome

`agentic run "..."` starts a container that is set up exactly like the dev container, with the
project checkout mounted at `/work`, and hands the prompt to the bridge in it. The agent works on
the checkout in the target repository. The host never runs git on the project: no mirror, no
clone, no worktree, no branch.

The first real run failed on exactly that host work: `run` tried to clone the project's remote into
`~/agentic-workspaces/<project>/repos` from WSL, which needs host git, host credentials and a
readable working directory, none of which a task should depend on.

Success criteria:

- `agentic run "..."` in a project works with no git credentials on the host.
- The task container's environment equals the dev container's: same image, run arguments, `/work`
  mount, setup lines and start. The differences are listed in section 5 and nowhere else.
- In a folder that holds several repositories, the agent starts in the target repository; a missing
  target is a clear error with the one command that fixes it.
- `--worktree` gives a task its own worktree and branch, made inside the container.
- `agentic clean ID` removes everything the task created and nothing else.
- The host CLI gets smaller: the mirror, clone and host-worktree code is gone (counted in the PR).
- `make test`, `make lint` and `make smoke` pass.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| T1 | **The host CLI is a thin relay.** It builds images, starts and stops containers, passes mounts and env, and relays requests to the bridge. It never works on the project: no git, no clone, no branch, no worktree, no build. Workflow rules live in the container (agent instructions, skills, the bridge). | Host work needs host tools and host credentials, differs per platform (WSL, macOS, remote VM) and duplicates what the container already does. This rule goes into `CLAUDE.md` and `docs/architecture.md`. |
| T2 | A task container is the dev container's twin: same `docker run` arguments from `build_run_args`, the checkout at `/work`, the full start. | The agent sees the same environment interactively and detached; one setup to maintain. |
| T3 | The project layout is stated in `agentic.yaml` (`layout: single\|multi`), written by `init`; the default repository of a multi layout is `target:`. | Nothing is guessed at run time; the file says what `/work` is. |
| T4 | The target is the agent's working directory: the bridge opens the ACP session with `cwd=/work/<target>`. | ACP takes the cwd per session; the bridge already reads `AGENTIC_WORK`. |
| T5 | The task id and the container are separate. A task records its container and whether it created it. | A task can run in a container another task created (`--in`); `clean` removes a container only when its task created it. |
| T6 | One task at a time per container (`--in` refuses a container whose bridge runs). | The bridge stays one task per container. Several tasks per container is backlog. |
| T7 | The bridge is started with `docker exec`, not as the container's command. The container runs `agentic-task-hold`, which sleeps. | A container outlives its first task and can take the next one. |
| T8 | `--worktree` is an option, off by default. The worktree and branch are made and removed inside the container. | A workflow rule, so it lives in the container (T1). It may become the default later. |
| T9 | Containers are kept by default. `--auto-clean` removes a task that ended successfully. | Inspecting a finished task is the common case; unattended runs can opt out of the leftovers. |
| T10 | Task containers keep `--cap-drop ALL` and `--security-opt no-new-privileges`; the dev container keeps neither. | Unattended work stays hardened; dev keeps `sudo`. The environment the agent sees (T2) is the same. |
| T11 | The checkout is mounted read-write, `.git` included, as in dev. | The same exposure as dev mode: an agent can write `.git/hooks` or `.git/config`, which host git later runs. Documented in the threat model, not mounted around. |

## 3. Configuration

```yaml
# .agentic/agentic.yaml
layout: multi   # single: the project root is a git repository
                # multi:  the project root holds git repositories in its direct subfolders
target: api     # multi only: the default target, a direct subfolder of the project root
```

- Both keys are top-level, added to `schema/agentic.schema.json` and `docs/configuration.md`
  (generated). `target` is refused with `layout: single`.
- `layout` is required by `run` and `target`. A file without it is refused with "no layout in
  .agentic/agentic.yaml; re-run agentic init" (no external users yet, no migration).

### 3.1 Detection (`init`)

`init` checks with file tests only (a `.git` directory or file), never with git:

| The project root | `layout` | `target` |
|---|---|---|
| has `.git` | `single` | not written |
| has no `.git`; exactly one direct subfolder has `.git` | `multi` | that folder |
| has no `.git`; several direct subfolders have `.git` | `multi` | not written; `init` prints the hint (section 4.1) |
| neither | refused: "no git repository in <root> or its direct subfolders" | |

### 3.2 The project root

`project_root` becomes the nearest directory, from the current directory upwards, that holds
`.agentic/agentic.yaml` (or `AGENTIC_PROJECT`). Before `init`, it is the current directory. Today
it is `git rev-parse --show-toplevel`, which in a multi layout returns the subfolder repository you
stand in, not the project, and which is host git (T1).

## 4. CLI

### 4.1 `agentic target [NAME]`

- `agentic target NAME`: checks that `layout` is `multi` and that `NAME` is a direct subfolder of
  the project root with `.git`, then writes `target: NAME` (through the same yaml editing path as
  setup lines).
- `agentic target`: prints the current target and the candidates.
- The hint, printed by `init` and by `run` when no target is known:

  ```
  agentic: the project holds several repositories (api, docs, web) and no target is set.
    Run with --target NAME, or set the default: agentic target api
  ```

### 4.2 `agentic run`

```
agentic run [--target NAME] [--in ID] [--worktree] [--auto-clean]
            [--agent claude|copilot] [--model M] [--allow GRANT]... [--id ID]
            [--prompt-file F] [--keep-on-failure] [--json] ["prompt"]
```

- Target: `single` refuses `--target`; the agent starts in `/work`. `multi` takes `--target`, else
  `target:`, else stops with the hint. A name that is not a direct subfolder with `.git` is refused.
- `--in ID`: run in the container of task `ID` (a container `run` created). Refused when that
  container is missing or its bridge still runs; started when it is stopped.
- `--worktree`: the task works in its own worktree (section 5.2).
- `--auto-clean`: section 6.3.
- Removed: `--repo`, `--base`, `--branch`. `AGENTIC_BRANCH_PREFIX` stays, for `--worktree`.
- Unchanged: the task id printed on stdout, `follow:` on stderr, `--json` (now `{task, container,
  port, target, branch}`, `branch` null without `--worktree`), validation before anything is
  created, rollback of what this run created on failure.

### 4.3 The other verbs

`status`, `follow`, `send`, `answer`, `cancel`, `logs` and `shell` work as today, through the task's
recorded container. `stop`, `resume`, `takeover` and `clean` change as described in section 6.

## 5. The task container

### 5.1 Creation

`run` without `--in` creates `agentic-<project>-task-<id>` with:

- `build_run_args` (what the dev container gets: `/work`, `/workspaces/repos`, `/agentic-config`,
  the setup lines' mounts and volumes, `.env`, git identity, proxy), except the harness homes;
- the task harness homes `<workspace>/tasks/<id>/home/{claude,copilot}` of the task that creates
  the container (`AGENTIC_TASK_DIR=/tasks/<id>` at creation), seeded with the credentials as today,
  then merged with the image's seed by the start (so setup lines apply); a later task in the same
  container (`--in`) uses the same homes, with its own session;
- `-v <workspace>/tasks:/tasks` and `-v <workspace>/events:/events` (replacing the per-task `/task`
  mount, so a later task can run in this container);
- `-p 127.0.0.1::<bridge port>`, `--cap-drop ALL`, `--security-opt no-new-privileges`, the labels
  `agentic.kind=task` and `agentic.project=<project>`;
- command `agentic-task-hold` under `--init`, after the full start (`image/start.d`): it records its
  pid (so the bridge can end the container for auto-clean), touches `/tasks/<creator>/.ready` (the
  host waits for it before it starts a bridge) and sleeps.

The container's name and whether the task created it are a host-private file of the task, never
the record: the record is agent-writable, and the host must not `docker exec` into or remove a
container an agent named.

The dev container's own `docker run` is not changed.

### 5.2 The bridge

`run` then starts the bridge:

```
docker exec -d --env-file <host-private task env> \
  -e AGENTIC_TASK_ID=<id> -e AGENTIC_WORK=/work[/<target>] -e AGENTIC_AGENT=... \
  -e AGENTIC_MODEL=... -e AGENTIC_ALLOWED_ACTIONS=... [-e AGENTIC_WORKTREE=1] \
  [-e AGENTIC_AUTO_CLEAN=1] <container> agentic-bridge
```

- The bridge writes its record, events and transcript to `/tasks/<id>` (was `/task`).
- The record gets `target`, `container`, `created_container`, `worktree` and `branch` (null without
  `--worktree`).
- With `AGENTIC_WORKTREE=1`, before the session starts, the bridge runs `agentic-worktree add` (a
  new script in `image/task/`): `git -C <work> worktree add -b <prefix><id>-<slug> .worktrees/<id>`
  from the target's current `HEAD`, adds `.worktrees/` to `.git/info/exclude`, and uses the
  worktree as the session's cwd. A failure fails the task before the agent starts.
- The host keeps the token file host-private, as today; it reaches the bridge only through
  `docker exec --env-file`.

## 6. Lifecycle

### 6.1 Stop and resume

- `stop ID`: the bridge's `/stop`, then `docker stop` of the container, unless another task's bridge
  runs in it (not possible while T6 holds; checked anyway).
- `resume ID`: `docker start` if needed, then the bridge again with `docker exec` and the recorded
  settings, then the resume prompt as today.
- `takeover ID`: stops the bridge, then `docker exec -it <container>` the harness with the recorded
  session, in the task's cwd. No throwaway container.

### 6.2 Clean

`agentic clean ID [--force]` removes what the task created:

1. With a worktree: `agentic-worktree check` in the task's container (started if stopped) refuses
   uncommitted changes or commits on no remote branch, unless `--force`; then `agentic-worktree
   remove` deletes the worktree and the branch. All git runs in the container.
2. The container, when this task created it. While another task's bridge runs in that container,
   `clean` refuses ("task <other> runs in this container; stop it first"): the container's harness
   homes live in its creator's task directory.
3. The task's directory under `<workspace>/tasks/<id>` and its host-private files.

Without a worktree, `clean` does not touch `/work`: the agent's changes in the checkout are the
user's to keep or discard.

### 6.3 Auto-clean

With `--auto-clean`, when the task ends successfully (a turn ends normally, not cancelled, and the
task settles in `idle` with no open question and an empty inbox), the bridge removes the worktree and branch (`agentic-worktree remove`, no
`--force`; a refusal keeps the task and logs why), marks the record `cleaned`, and stops the
container's main process. The next `agentic run` or `agentic status` of the project removes the
exited containers and the records marked `cleaned`. A failed, waiting or interrupted task is kept.

## 7. Removed

From the host: `project_clone`, `add_worktree`, `sync_mirror`, `repo_url`, `project_url`, `ugit`,
`mgit`, `cgit`/`cgit_err` and the throwaway git containers, `clone_ok`, `wt_gitdir`, the `repos` host
file, the mirrors under `~/.agentic/projects/<project>/mirrors`, the host-side unpushed-work check
in `clean`, and the worktree part of `rollback_task`. `task_mounts` shrinks to the mounts of
section 5.1.

From the bridge: nothing; `AGENTIC_BRANCH` is set only with `--worktree` and names the worktree's branch.

`pgit` stays only for reading the host's git identity (`user.name`, `user.email`), which is
configuration, not project work.

## 8. Error handling

| Case | Result |
|---|---|
| No `layout:` | refused, "re-run agentic init" |
| Multi layout, no target | refused with the hint (4.1); nothing created |
| Unknown target | refused, lists the candidates |
| `--target` with `single` | refused |
| `--in ID`: unknown task, missing container, bridge running | refused; nothing created |
| `--worktree` and the target has no commit | the bridge refuses before the agent starts; `run` shows its reason and rolls back |
| The bridge does not come up | rollback of what this run created; a container reused through `--in` is kept |
| `clean` finds unpushed work | refused unless `--force` |

## 9. Testing

Tests are written first.

- bats:
  - `init`: layout detection for each row of 3.1.
  - `target`: set, print, refuse.
  - `project_root` from a subfolder.
  - `run`: target resolution, the hint text, `--in` refusals.
  - The docker calls (create vs exec, the mounts, no `/task`, no host git), with docker stubbed as
    today.
  - `clean`: removes the container only when created.
  - `agentic-worktree`: add, check, remove, in a temporary repository.
  - A test that `run` makes no `git` call on the host (git stubbed to fail).
- vitest:
  - `/tasks/<id>`.
  - The record fields.
  - `AGENTIC_WORKTREE` calling the script and changing the cwd.
  - The auto-clean rule (only `done`).
- smoke:
  - `run` in a single and in a multi project.
  - `run --in`.
  - `--worktree`, then `clean`.
- Removed: the mirror, clone and host-worktree tests.
- Manual, recorded in the PR: the failed WSL case of section 1, with no git credentials on the host.

## 10. Documentation

- `CLAUDE.md` (Rules) and `docs/architecture.md`: rule T1.
- `docs/tasks.md`:
  - the model (task vs container);
  - the `run` options;
  - stop, resume, clean and auto-clean;
  - the threat model, changed by T11 and by `/tasks` being shared between the project's task
    containers.
- `docs/detached-mode.md`: the how-to.
- `docs/configuration.md` and the schema: `layout`, `target`.
- The setup skill (`skills/`): when `layout: multi` has no `target:`, ask the user for the default
  and run `agentic target NAME`.
- `docs/backlog.md`: the items of section 11.

## 11. Out of scope and backlog

- Several tasks in one container (the bridge manages several sessions).
- `run --in dev`: a task in the dev container. Needs the dev container created with the bridge port
  and the `/tasks` and `/events` mounts, and the security flags settled (T10).
- `--worktree` as the default.
