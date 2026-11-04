# Multi-repository tasks: every repository in the task, apps from the root

Status: designed, 2026-11-04. Umbrella: `docs/architecture.md`. Changes tasks (`docs/tasks.md`, the
worktree of run-thin-relay §5.2) and apps (`docs/specs/2026-10-20-app-run-design.md`) for
`layout: multi`. Single-repository projects are not touched.

## 1. Problem

A multi-repository project is a root folder with `.agentic/` (itself a git repository, or not) and
repositories one level down (`/work/<name>`, each with its own `.git`). Today a task works on one of
them: `AGENTIC_WORK=/work/<target>`, and its worktree is `/work/<target>/.worktrees/<id>`. Two things
follow:

- The task sees only the target. Work that spans repositories (an API and the frontend that calls
  it) cannot be done in one task, and the other repositories it can reach through `/work/<other>` are
  the user's own checkouts, shared with every other task.
- An app's `dir` is resolved against whatever the checkout is in that context: `/work` in the dev
  container, the target's worktree in a task. One `dir` works in one context only. With
  `dir: frontend` for an app in repository `webapp`, `agentic-app start frontend` fails in the dev
  container (`/work/frontend` does not exist) and works in a task for `webapp`; an app in another
  repository cannot be started from a task at all. `agentic-app list` shows every app in both contexts; starting is what
  breaks.

## 2. Outcome

- A worktree task in a multi-repository project gets a task root that mirrors `/work`: the root and
  every repository, each in its own worktree on the task's branch. The agent starts in the target.
- An app's `dir` is a path from the root (`webapp/frontend`) and resolves the same
  way in the dev container and in every task: against `/work` there, against the task root in a task.
  Every configured app can be started from every task, from the task's own copies.
- Pushing, and one pull or merge request per repository the task changed, stay the agent's work. The
  framework only creates and removes the worktrees; the gate (`push`, `open-pr`) applies in every
  repository as it does today.
- Single-repository projects and the host CLI's role (a thin relay; worktrees are made inside the
  container) are unchanged.

Success criteria:

- In a multi project, a worktree task has `<root>/.worktrees/<id>/` holding the root's worktree (when
  the root is a git repository) and `<id>/<repo>` for every repository, all on the task's branch; the
  agent's working directory is `<id>/<target>`.
- `agentic-app start NAME` works for every app with a root-relative `dir`, in the dev container and in
  any task of the project.
- The bridge's `GET /apps` (and `agentic-app list`) returns every app of the project, whichever
  repository the task targets; none is filtered by target or by `dir`. `POST /apps/NAME/start`
  starts any of them. A bats test and a vitest test pin this with a task whose target is not the
  repository of the app.
- Cleaning a task (auto-clean, `agentic clean`, a scheduled run) removes every worktree and branch,
  and keeps the whole task when any one repository has uncommitted changes or commits on no remote.
- `make test`, `make lint` and `make smoke` pass.

## 3. Decisions

| # | Decision | Why |
|---|---|---|
| M-1 | **Every repository gets a worktree, on the same branch name** (`AGENTIC_BRANCH`). | Cross-repository changes are the reason for the layout. A repository the task never touched has a branch with no own commit, which removal already deletes without asking. A detached, read-only worktree was rejected: a commit made there anyway is on no branch and lost silently. |
| M-2 | **The task root mirrors `/work`**: `/work/.worktrees/<id>` is the root's worktree, or a plain folder when the root is no git repository; each repository's worktree goes to `<id>/<repo>`. | Paths are the same as in `/work`, so a root-relative `dir` and the agent's own relative paths mean the same thing in both. The root's `.gitignore` already ignores the repositories, so their worktrees do not show in the root's status. |
| M-3 | **`dir` is relative to the root in a multi project**, in every context. | One rule; the old one was the cause of the bug. |
| M-4 | **No compatibility for target-relative `dir`.** A `dir` that does not exist under the root fails `agentic-app start` with a message that says a `dir` starts with the repository's name. | Existing multi projects add the repository's name in front of each `dir`; the error says so. A fallback that guesses the repository would hide the mistake. |
| M-5 | **The framework does not push, open pull requests or link them.** | The agent decides which repositories changed and opens one request per repository with the tools it already has; the gate guards those commands. |
| M-6 | **The repositories are the folders one level down with a `.git`** (as `repo_dirs` on the host), read in the container when the task starts. | A repository added later through `add workspace` is in the next task. |
| M-7 | **`env_files` `to` is relative to the root too**, like `dir`, and a `to` whose first folder is no repository and no folder of the root fails the start with the M-4 message instead of copying. | Same rule as `dir`; the copy must never land silently in the wrong place. |
| M-8 | **A root that is no git repository gives a plain `W` with only the repositories' worktrees.** Root files (`README.md`, scripts) are not in it; `.agentic/` is read from the `/agentic-config` mount as today, never from `W`. | Copies would drift and links would be shared by every task; the config never comes from the checkout anyway. |
| M-9 | **A repository that cannot get a worktree is skipped with a warning** (the task's event log and the bridge log), unless it is the target, which fails the task as today. A repository with no commit, a `.git` file (submodule, linked worktree) and a repository mid-rebase are such cases. | One odd repository must not stop every task of the project. |
| M-10 | **The task prompt (`image/task/task-prompt.md`) says, for a multi project,** that the other repositories sit beside the target under the task root, on the same branch, and that each changed repository gets its own push and pull or merge request. | The agent cannot use what it is not told about; M-5 leaves the requests to it. |

## 4. Behaviour

Terms: `R` is the root (`/work`), `T` the target, `W` the task root `R/.worktrees/<id>`.

| Moment | Today (multi) | New (multi) |
|---|---|---|
| task start, worktree | `T/.worktrees/<id>` on the branch | `W` (root worktree or folder), then `W/<repo>` for every repository, all on the branch; the agent's directory `W/T` |
| task start, `--no-worktree` | `R/T` | unchanged; apps resolve against `R` |
| `agentic-app` in the task | `dir` against the agent's directory | `dir` against `W` (or `R` without a worktree) |
| `agentic-app` in the dev container | `dir` against `R` | unchanged |
| check / remove | one worktree | every worktree in `W`, the repositories first, then the root; check refuses when any one has uncommitted changes or unpushed commits, before anything is removed |
| `agentic takeover` | `-w T/.worktrees/<id>` | `-w W/T`, computed from the host's env file as today |

A creation that fails part way removes the worktrees it made, then fails the task as today.

## 5. What changes where

- `image/task/worktree.sh`: `add`, `check` and `remove` take the root and the target and work over
  every repository (M-2, M-6); single projects keep today's path.
- Bridge (`bridge/src/bridge.ts`, `types.ts`): the task record keeps the task root next to `work`
  (the agent's directory); app calls pass the root as `AGENTIC_WORK` to `agentic-app`.
- `image/bin/agentic-app`: unchanged rule (`dir` against `AGENTIC_WORK`); only the message of M-4.
- Host: the env file says the root and the target; `takeover` and `worktree_cmd` build `W/T` from
  them. No git on the host.
- Docs: `docs/tasks.md`, `docs/configuration.md` (the `dir` description in the schema, then
  `tools/gen-config-docs.sh`), the setup skill's **Apps** section (already says "in a workspace
  folder it starts with the repository's name").
- Existing multi projects (outside this repository): prefix each `dir` and `env_files` `to` with the
  repository's name; the hand-over of the setup skill and the M-4 error say so.

## 6. Left to the builder

- How the env file names the root and the target (new keys, or `AGENTIC_WORK` becomes the root
  with `AGENTIC_TARGET` beside it), as long as the host never reads the checkout.
- The record field's name and its upgrade for records written before this change (an old record
  keeps working with its single worktree).
- The tests: bats for `worktree.sh` with a root that is and is not a git repository, a failed
  creation part way, and a refused check in one repository; vitest for the root reaching
  `agentic-app`.
