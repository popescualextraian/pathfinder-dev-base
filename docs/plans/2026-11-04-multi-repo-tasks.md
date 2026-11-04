# Multi-repository tasks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In a `layout: multi` project, a worktree task gets every repository in its own worktree under
one task root that mirrors `/work`, and every app resolves `dir` from that root, so the bridge lists and
starts every app from every task.

**Architecture:** `image/task/worktree.sh` learns a multi mode, chosen by `AGENTIC_LAYOUT=multi`; its
command line stays `add|check|remove WORK ID BRANCH [--force]` with `WORK=/work/<target>`, and the root
is `dirname WORK`. The host writes `AGENTIC_LAYOUT` into the task env file and builds the worktree paths
from it. The bridge keeps a new record field `root` and passes it to `agentic-app` as `AGENTIC_WORK`.
`agentic-app` keeps its rule (`dir` against `AGENTIC_WORK`) and gains clear refusals for multi.

**Tech Stack:** bash (bats), TypeScript (vitest), git worktrees.

**Spec:** `docs/specs/2026-11-04-multi-repo-tasks-design.md`

## Global Constraints

- bash: `set -euo pipefail`, short comments, shellcheck-clean, a bats test per behaviour, written first.
- TypeScript: strict tsc, eslint clean, a vitest test per behaviour, written first; no new dependency.
- The host never runs git or reads the checkout's files to decide (thin relay); worktrees are made in the container.
- Single-repository projects, and tasks whose env file has no `AGENTIC_LAYOUT` (written before this change), behave exactly as today.
- No company names; examples use `webapp`, `api`, `example.com`.
- No `Co-Authored-By` or other attribution in commits. Commit on `main` only when the user asks; do not push.

## Review Focus

1. The root's `.gitignore` does not ignore the repository folders: the root worktree's `check` must still pass on a clean task (Task 1 test "check ignores the repository folders in the root worktree").
2. A repository folder that is a symlink, or whose `.git` is a file (submodule, linked worktree): skipped with a warning, never followed (Task 1 test "add skips a symlinked repository and a .git file").
3. The target itself has no commit or is mid-rebase: the task fails and nothing is left behind (Task 1 test "add rolls back when the target cannot get a worktree").
4. A task started before this change (env file without `AGENTIC_LAYOUT`, record without `root`) keeps its worktree path for `check`, `remove`, `takeover` and its apps (Task 2 test "an env file without AGENTIC_LAYOUT keeps the single paths"; Task 3 test "an old record gets root = work").
5. `env_files` `to` that names no folder of the root in a multi project is refused, not copied into `/work` (Task 4 test "multi: env_files to outside any folder of the root is refused").

---

### Task 1: worktree.sh multi mode

**Files:**
- Modify: `image/task/worktree.sh`
- Test: `tests/bats/task-worktree.bats`

**Interfaces:**
- Consumes: nothing new.
- Produces: with `AGENTIC_LAYOUT=multi` in the environment and `WORK=/work/<target>`:
  - `add WORK ID BRANCH` makes `W=$(dirname WORK)/.worktrees/ID` (root worktree on BRANCH when the root is a git repository, else `mkdir`), then `W/<repo>` on BRANCH for every repository; prints `W/<target>` as its last stdout line; each skipped repository is one stderr line `agentic-worktree: skipped <repo>: <reason>`; exit 0.
  - `check` and `remove [--force]` cover every worktree under `W` (repositories first, then the root); `check` runs over all of them before `remove` removes anything; `remove` then deletes BRANCH in each repository that has it, and `W` itself.
  - Without `AGENTIC_LAYOUT=multi`: exactly today's behaviour.

A repository is a folder `ROOT/<name>` that is not a symlink and has a `.git` directory (M-6). Skip
reasons (M-9): `.git is a file`, `no commit`, `mid-rebase` (`rebase-merge` or `rebase-apply` in its git
dir), `worktree add failed`. The target is never skipped: any of these for the target rolls back what
`add` made and exits 1 with today's message style.

- [ ] **Step 1: Write the failing tests.** A `setup_multi` helper builds `$BATS_TEST_TMPDIR/root` (a git repo with one commit and a `.gitignore` that lists nothing) holding `webapp/` and `api/` (each a git repo with one commit). Tests, each run with `AGENTIC_LAYOUT=multi`:
  - `"multi add makes the root and every repository a worktree on the branch and prints the target's"`: `add "$R/webapp" T-1 agentic/T-1-x` → last stdout line `$R/.worktrees/T-1/webapp`; `git -C "$R/.worktrees/T-1" rev-parse --abbrev-ref HEAD` and the same for `webapp` and `api` print `agentic/T-1-x`; `git -C "$R" status --porcelain` is empty.
  - `"multi add with a root that is no git repository makes a plain folder"`: `rm -rf "$R/.git"` first; `$R/.worktrees/T-1` is a directory without `.git`; both repositories are worktrees.
  - `"add skips a symlinked repository and a .git file"`: `ln -s "$R/api" "$R/link"`, a folder `sub` with a `.git` file → stderr has `agentic-worktree: skipped sub: .git is a file`; no `link` or `sub` under `W`; status 0.
  - `"add skips a repository without a commit or mid-rebase"`: `empty/` (git init, no commit) and `api` with `mkdir "$R/api/.git/rebase-merge"` → two `skipped` lines with `no commit` and `mid-rebase`; status 0.
  - `"add rolls back when the target cannot get a worktree"`: target `empty` → status 1; `$R/.worktrees/T-1` does not exist; `git -C "$R/webapp" branch --list agentic/T-1-x` is empty.
  - `"check ignores the repository folders in the root worktree"`: after `add`, `check` → status 0.
  - `"multi check refuses when any one repository has uncommitted changes, and remove removes nothing then"`: `echo x > "$W/api/f"` → `check` status 1 with `has uncommitted changes`; `remove` status 1 and `$W/webapp` still exists.
  - `"multi remove deletes every worktree and branch"`: after `add`, `remove` → `$W` gone; no repository has `agentic/T-1-x`.
- [ ] **Step 2: Run** `bats tests/bats/task-worktree.bats`. Expected: the new tests FAIL, the old ones pass.
- [ ] **Step 3: Implement** in `worktree.sh`: `multi=0; [ "${AGENTIC_LAYOUT:-}" = multi ] && multi=1`; in multi `root="$(dirname "$work")" target="$(basename "$work")" wt="$root/.worktrees/$id"`; functions `repos` (the M-6 list, sorted), `add_one DIR PATH`, `check_one DIR PATH` (today's `check`, parameterised), and for the root worktree `git status --porcelain -- . ':(exclude)<repo>'...` for every repository name so untracked repository folders do not count. Keep the single path untouched.
- [ ] **Step 4: Run** `bats tests/bats/task-worktree.bats && shellcheck -x image/task/worktree.sh`. Expected: all pass, no warnings.
- [ ] **Step 5: Commit** `feat: worktree.sh gives a multi-repository task the root and every repository as worktrees on one branch`.

### Task 2: host writes the layout and builds the paths from it

**Files:**
- Modify: `bin/agentic` (`cmd_run` env file block near line 552; `cmd_takeover` near line 832), `lib/host/task.sh` (`worktree_cmd`, new helpers), `lib/host/schedule.sh` (leftover check near line 361)
- Test: `tests/bats/cli-task-run.bats`, `tests/bats/cli-task-verbs.bats`

**Interfaces:**
- Consumes: Task 1's `AGENTIC_LAYOUT=multi` contract.
- Produces:
  - Env file line `AGENTIC_LAYOUT=single|multi`, from `yaml_top "$(cfg_dir)/agentic.yaml" layout`.
  - `task_wt_root ID` → container path of the task root: multi `$(dirname WORK)/.worktrees/ID`, else `WORK/.worktrees/ID`.
  - `task_wt_dir ID` → the agent's directory in it: multi `$(task_wt_root ID)/$(basename WORK)`, else `$(task_wt_root ID)`.
  - `worktree_cmd` passes `-e AGENTIC_LAYOUT=<value>` to `docker exec` when the env file has it.

- [ ] **Step 1: Write the failing tests:**
  - `cli-task-run.bats` `"run writes AGENTIC_LAYOUT into the env file"`: a multi fixture with target `web` → `grep -qx AGENTIC_LAYOUT=multi "$H/T-a/env"`; a single one → `AGENTIC_LAYOUT=single`.
  - `cli-task-verbs.bats` `"takeover of a multi worktree task opens the target inside the task root"`: env file with `AGENTIC_WORK=/work/web AGENTIC_WORKTREE=1 AGENTIC_LAYOUT=multi` → the docker stub sees `-w /work/.worktrees/T-1/web`.
  - `cli-task-verbs.bats` `"clean of a multi task passes the layout to worktree.sh"`: the stub's argv has `-e AGENTIC_LAYOUT=multi` before the container name.
  - `cli-task-verbs.bats` `"an env file without AGENTIC_LAYOUT keeps the single paths"`: `AGENTIC_WORK=/work/web AGENTIC_WORKTREE=1`, no layout → `-w /work/web/.worktrees/T-1`, and no `-e AGENTIC_LAYOUT`.
- [ ] **Step 2: Run** `bats tests/bats/cli-task-run.bats tests/bats/cli-task-verbs.bats`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** the helpers in `lib/host/task.sh`; use `task_wt_dir` in `cmd_takeover` and `task_wt_root` in `schedule.sh` (the host path is `$(project_root)${root#/work}`); add the env line in `cmd_run`.
- [ ] **Step 4: Run** the two bats files plus `bats tests/bats/cli-schedule.bats` and `shellcheck -x bin/agentic lib/host/*.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: the task env file says the layout; takeover, clean and scheduled runs find a multi task's worktrees from it`.

### Task 3: bridge keeps the task root and gives it to the apps

**Files:**
- Modify: `bridge/src/config.ts` (`layout`), `bridge/src/types.ts` (`TaskRecord.root`), `bridge/src/sessions.ts` (`upgradeRecord`), `bridge/src/bridge.ts` (fresh record near line 80; app calls at lines 159, 168, 175, 192, 547; worktree warnings)
- Test: `bridge/test/bridge.test.ts`, `bridge/test/config.test.ts`

**Interfaces:**
- Consumes: Task 1's stdout/stderr contract; Task 2's `AGENTIC_LAYOUT` (in the bridge's env through `--env-file`).
- Produces: `BridgeConfig.layout: "single" | "multi"` (`env.AGENTIC_LAYOUT === "multi" ? "multi" : "single"`); `TaskRecord.root: string`. Fresh record: multi with worktree `root = dirname(worktree path)`; multi without `dirname(config.work)`; single `root = work`. `upgradeRecord`: a missing `root` becomes `work`. Every `apps.list/act/logs` call and autostart use `record.root`.

- [ ] **Step 1: Write the failing tests:**
  - `config.test.ts` `"AGENTIC_LAYOUT=multi sets layout multi, anything else single"`.
  - `bridge.test.ts` `"multi: the apps run against the task root, whatever the target"`: config `{layout: "multi", work: "/work/webapp", worktree: true}`, worktree stub returns `out: "/work/.worktrees/T-1/webapp\n"` → `rec.work === "/work/.worktrees/T-1/webapp"`, `rec.root === "/work/.worktrees/T-1"`; `bridge.apps()` and `appAction("api", "start")` call the runner with work `/work/.worktrees/T-1`; the runner returns two apps (`webapp-ui`, `api`) and `apps()` returns both.
  - `"multi without a worktree: the apps run against /work"`: `work: "/work/webapp"`, `worktree: false` → runner work `/work`.
  - `"single: root is the work directory"` → runner work equals `rec.work`.
  - `"an old record gets root = work"`: `upgradeRecord` of a record without `root`.
  - `"skipped repositories become one error event each and a log line"`: worktree stub `err: "agentic-worktree: skipped api: no commit\n"`, ok → one `error` event whose message contains `skipped api: no commit`, and the log has the line.
- [ ] **Step 2: Run** `cd bridge && npm test`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** as in Interfaces; the warning lines are those of `r.err` starting with `agentic-worktree: skipped`.
- [ ] **Step 4: Run** `cd bridge && npm test && npx tsc --noEmit && npx eslint .` (from the lockfile, nothing fetched). Expected: all pass.
- [ ] **Step 5: Commit** `feat: the bridge runs every app of a multi-repository task against the task root`.

### Task 4: agentic-app refuses target-relative paths in a multi project

**Files:**
- Modify: `image/bin/agentic-app` (`appdir`, `copy_env_files`)
- Test: `tests/bats/agentic-app.bats`

**Interfaces:**
- Consumes: `.layout` in `~/.agentic/config.json`.
- Produces: in multi, `appdir` for a missing `dir` dies with `dir <d> does not exist under <root>; in a project with several repositories, dir starts with the repository's name (<repo>/<d>)`, `<repo>` being the first repository found under the root; `copy_env_files` dies with the same sentence for a `to` whose first path segment is not a folder of the root. Single projects keep today's messages and behaviour.

- [ ] **Step 1: Write the failing tests:**
  - `"multi: a dir that is not under the root names the fix"`: config `{layout: "multi", apps: {web: {run: "true", dir: "frontend"}}}`, `AGENTIC_WORK=$R` with `$R/webapp/frontend` → `start web` status 1, output contains `dir starts with the repository's name (webapp/frontend)`.
  - `"multi: a root-relative dir starts from any task root"`: `dir: "webapp/frontend"` → `start web` status 0 and the window's directory is `$R/webapp/frontend`.
  - `"multi: env_files to outside any folder of the root is refused"`: `to: ".env.local"` → status 1, same sentence, and `$R/.env.local` does not exist.
  - `"list returns every app whatever AGENTIC_WORK is"`: three apps in two repositories, `AGENTIC_WORK=$R/.worktrees/T-1` → `list --json | jq length` is `3`.
- [ ] **Step 2: Run** `bats tests/bats/agentic-app.bats`. Expected: the new tests FAIL (the list test may already pass; keep it as the pin).
- [ ] **Step 3: Implement** the two refusals; read the layout once with `jq -r '.layout // "single"' "$conf"`.
- [ ] **Step 4: Run** `bats tests/bats/agentic-app.bats && shellcheck -x image/bin/agentic-app`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: agentic-app says how to write dir and env_files in a multi-repository project`.

### Task 5: tell the agent and the user

**Files:**
- Modify: `image/task/task-prompt.md`, `schema/agentic.schema.json` (`dir` and `env_files.to` descriptions), `docs/configuration.md` (regenerated), `docs/tasks.md` (worktree and Apps sections), `skills/agentic-setup/SKILL.md` (**Apps**: `env_files` `to` from the root too)
- Test: `tests/bats/docs.bats` (existing generated-docs check), `tests/bats/setup-skill.bats`, `tests/bats/task-harness.bats`

**Interfaces:**
- Consumes: the behaviour of Tasks 1-4.
- Produces: text only.

- [ ] **Step 1: Write the failing tests:** `setup-skill.bats` `"the setup skill writes env_files to from the root in a multi project"` greps `to` and `repository's name` in the **Apps** section; a new test in `tests/bats/task-harness.bats` greps `own pull or merge request` in `image/task/task-prompt.md`.
- [ ] **Step 2: Run** them. Expected: FAIL.
- [ ] **Step 3: Write:** the prompt sentence `In a project with several repositories, the others sit beside yours under the task's root folder, on the same branch; push each repository you changed and give each its own pull or merge request.`; schema `dir`: `Working directory relative to the checkout; in a project with several repositories, relative to the root and starting with the repository's name. Default the checkout.`, and `to` likewise; then `tools/gen-config-docs.sh`; `docs/tasks.md`: the task root table of spec §4.
- [ ] **Step 4: Run** `make test && make lint && make smoke`. Expected: all pass.
- [ ] **Step 5: Commit** `docs: tasks, apps and the setup skill describe the task root of a multi-repository project`.
