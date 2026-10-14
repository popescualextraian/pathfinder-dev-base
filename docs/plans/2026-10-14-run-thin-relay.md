# `agentic run` as a thin relay — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `agentic run` starts a task container that is the dev container's twin, with the checkout
mounted at `/work`, and hands the prompt to the bridge in it. The host runs no git on the project.

**Architecture:** the host CLI (`bin/agentic`, `lib/host/*.sh`) only resolves the target from
`agentic.yaml`, creates or reuses a container (`agentic-task-hold` as its command, after the full
start), and starts the bridge in it with `docker exec --env-file <host-private env> …
agentic-task-start`. Everything git does (the optional worktree, its check and removal) runs inside
the container through `image/task/worktree.sh`, called by the bridge or by the host via
`docker exec`. The mirror, clone and host-worktree code is deleted.

**Tech Stack:** bash (shellcheck, bats), TypeScript bridge (strict tsc, eslint, vitest), Docker.

**Spec:** `docs/specs/2026-10-14-run-thin-relay-design.md` (read it first; section numbers below
refer to it).

## Global Constraints

- bash: `set -euo pipefail`, short comments, shellcheck-clean (`shellcheck -x`), a bats test for
  every behaviour, written first.
- TypeScript (`bridge/`): strict tsc, eslint clean, a vitest test for every behaviour, written first;
  no new dependencies.
- No company resources: no company names, hosts or URLs; examples use `example.com`; nothing from the private
  denylist. `tools/leak-check.sh` must stay clean.
- No secret in an image layer, `~/.claude.json`, `~/.agentic/env`, a log or a command line: tokens
  reach containers only through `--env-file` of a host-private file (mode 600).
- No `Co-Authored-By` or other attribution lines in commits. Commit on branch `run-thin-relay`;
  never push.
- The host never runs git on the project. The only host git left is reading the user's identity
  (`pgit -C <root> config user.name|user.email` in `shared_run_args`).
- Iterate with the bats files you touch (`bats tests/bats/<file>.bats`), `shellcheck -x` on changed
  scripts and `cd bridge && npm test`. Before the last commit of each task: `make test` and
  `make lint`. Task 8 also runs `make smoke`.
- Git identity: if `git commit` fails with "Author identity unknown", commit with
  `git -c user.name="Alex Popescu" -c user.email="popescualextraian@gmail.com" commit …` (the
  identity of this repository's earlier commits); do not change the git config.

## Review Focus

1. **The original failure: a stale working directory.** The shell's cwd was deleted and recreated;
   `agentic` must still find the project from `$PWD` and never need `getcwd` through git. Task 1
   pins it with a test.
2. **Running `agentic` from inside one repository of a multi-repository project.** The project root
   is the folder with `.agentic/`, not the sub-repository git would return. Task 1 pins it.
3. **A target that is a symlink, `.`/`..`, or has a slash.** It must be refused, never mounted or
   used as a path. Task 2 pins it.
4. **A `--model` value with a newline.** It would inject a line into the host env file the bridge
   reads. `run` must refuse it. Task 6 pins it.
5. **A forged `cleaned: true` in another task's record.** `/tasks` is shared between the project's
   task containers, so an agent can write it. The sweep must not remove a created container that
   still runs, and must take the container from the host file, never the record. Task 7 pins it.

## File map

| File | Responsibility | Tasks |
|---|---|---|
| `lib/host/common.sh` | `project_root` by `.agentic/`, `yaml_set_top`, `project_run_args` split from `build_run_args` | 1, 6 |
| `lib/host/layout.sh` (new) | repositories under the root, layout detection, target hint, target → `/work[/T]` | 2 |
| `bin/agentic` | `init` layout, `target`, `run`, `stop`, `resume`, `takeover`, `clean`, `follow`, usage | 2, 3, 6, 7 |
| `lib/host/task.sh` | task container host file, bridge liveness, readiness, cap, rollback, sweep; mirror/clone code removed | 6, 7 |
| `templates/agentic.yaml.tmpl`, `schema/agentic.schema.json`, `docs/configuration.md` (generated) | `layout`, `target` | 2 |
| `image/bin/agentic-task-hold`, `image/bin/agentic-task-start` (new) | container command; bridge launcher for `docker exec` | 4 |
| `image/task/worktree.sh` (new) | add / check / remove a task's worktree, in the container | 4 |
| `image/entrypoint.sh`, `image/Dockerfile` | gate default for `agentic-task-hold`; `/tasks` mount point | 4 |
| `bridge/src/{config,types,bridge,main}.ts` | worktree, record fields, agent cwd, auto-clean, release | 5 |
| `tests/bats/docker-stub.bash` | `exec`, readiness file, `docker_call_with` | 6 |
| `tests/bats/{cli-core,cli-init,cli-target,task-worktree,task-hold,entrypoint-gate,cli-task-run,cli-task-verbs}.bats` | tests | 1–7 |
| `tests/image/smoke.sh`, `tests/fixtures/smoke-project/.agentic/agentic.yaml` | end to end | 8 |
| `CLAUDE.md`, `docs/architecture.md`, `docs/tasks.md`, `docs/detached-mode.md`, `skills/agentic-setup/SKILL.md`, `docs/backlog.md` | docs | 3, 8 |

---

### Task 1: The project root by `.agentic/`, and `yaml_set_top`

**Files:**
- Modify: `lib/host/common.sh:13-18` (`project_root`), add `yaml_set_top` after `yaml_top`
- Create: `tests/bats/cli-target.bats` (also used by Tasks 2 and 3)

**Interfaces:**
- Produces: `project_root` (prints the nearest directory upwards from `${AGENTIC_PROJECT:-$PWD}`
  holding `.agentic/agentic.yaml`, else that directory); `yaml_set_top FILE KEY VALUE` (replaces the
  first `KEY:` line at column 0, else appends `KEY: VALUE`).

- [ ] **Step 1: Write the failing tests**

Create `tests/bats/cli-target.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  A="$REPO_ROOT/bin/agentic"
  # a folder holding two repositories, with the project config at the top
  M="$BATS_TEST_TMPDIR/multi"
  mkdir -p "$M/.agentic"
  git init -q "$M/api"; git init -q "$M/web"
  printf 'version: 2\nproject: demo\nlayout: multi\n' > "$M/.agentic/agentic.yaml"
}

# shellcheck source=../../lib/host/common.sh
lib() { bash -c "source '$REPO_ROOT/lib/host/common.sh'; $1"; }

@test "project_root is the nearest folder with .agentic/agentic.yaml, not the repository git names" {
  [ "$(cd "$M/api" && lib project_root)" = "$M" ]
  [ "$(cd "$M" && lib project_root)" = "$M" ]
  mkdir -p "$BATS_TEST_TMPDIR/plain/sub"
  [ "$(cd "$BATS_TEST_TMPDIR/plain/sub" && lib project_root)" = "$BATS_TEST_TMPDIR/plain/sub" ]
  [ "$(AGENTIC_PROJECT="$M/web" lib project_root)" = "$M" ]
}

@test "project_root works from a working directory that was deleted and recreated" {
  run bash -c "cd '$M' && cp -a '$M' '$M.new' && rm -rf '$M' && mv '$M.new' '$M' && source '$REPO_ROOT/lib/host/common.sh' && project_root"
  [ "$status" -eq 0 ]
  [ "$output" = "$M" ]
}

@test "yaml_set_top replaces a top-level key or appends it, and leaves nested keys alone" {
  f="$BATS_TEST_TMPDIR/y.yaml"
  printf 'version: 2\nharness:\n  target: nested\n' > "$f"
  lib "yaml_set_top '$f' target api"
  [ "$(cat "$f")" = "$(printf 'version: 2\nharness:\n  target: nested\ntarget: api')" ]
  lib "yaml_set_top '$f' target web"
  [ "$(grep -c '^target:' "$f")" = 1 ]
  grep -qx 'target: web' "$f"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/bats/cli-target.bats`
Expected: FAIL. The first test prints the git top level (`$M/api`), and `yaml_set_top` is not
defined.

- [ ] **Step 3: Implement**

In `lib/host/common.sh`, replace `project_root` (keep `pgit` above it, now used only for the
identity):

```bash
# project_root: the nearest directory, from $AGENTIC_PROJECT (default: the current directory)
# upwards, that holds .agentic/agentic.yaml; else that directory. File tests only: no git, and no
# getcwd (a working directory deleted and recreated still resolves through $PWD).
project_root() {
  local start d
  start="$(cd "${AGENTIC_PROJECT:-$PWD}" && pwd)" || return 1
  d="$start"
  while :; do
    if [ -f "$d/.agentic/agentic.yaml" ]; then printf '%s\n' "$d"; return 0; fi
    [ "$d" != / ] || break
    d="$(dirname "$d")"
  done
  printf '%s\n' "$start"
}
```

After `yaml_top`, add:

```bash
# yaml_set_top FILE KEY VALUE: sets a top-level scalar: replaces the KEY: line, else appends one.
yaml_set_top() {
  local tmp; tmp="$(mktemp "$1.XXXXXX")"
  awk -v key="$2" -v val="$3" 'index($0, key ":") == 1 { if (!done) print key ": " val; done = 1; next }
    { print } END { if (!done) print key ": " val }' "$1" > "$tmp" && mv -- "$tmp" "$1"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/bats/cli-target.bats && shellcheck -x lib/host/common.sh`
Expected: PASS, no shellcheck output.

- [ ] **Step 5: Run the whole suite**

Run: `make test`
Expected: PASS. If a test expected `init` or another command to find the git top level from a
subfolder that has no `.agentic/`, the command now uses that subfolder. Update that test to `cd`
into the repository root, and note it in the commit message.

- [ ] **Step 6: Commit**

```bash
git add lib/host/common.sh tests/bats/cli-target.bats
git commit -m "feat: the project root is the nearest folder with .agentic/agentic.yaml (no host git, no getcwd); yaml_set_top"
```

---

### Task 2: `layout` and `target` in `agentic.yaml`, detected by `init`

**Files:**
- Create: `lib/host/layout.sh`
- Modify: `bin/agentic` (source `layout.sh`; `cmd_init`), `templates/agentic.yaml.tmpl`,
  `schema/agentic.schema.json`, `docs/configuration.md` (regenerated)
- Test: `tests/bats/cli-init.bats`, `tests/bats/cli-target.bats`

**Interfaces:**
- Consumes: `project_root`, `yaml_top` (Task 1).
- Produces (in `lib/host/layout.sh`):
  - `repo_dirs ROOT`: the names of ROOT's direct subfolders holding `.git`, sorted, one per line;
    symlinked folders are skipped.
  - `detect_layout ROOT`: prints `single`, `multi` or nothing.
  - `valid_target ROOT NAME`: status 0 when NAME matches `^[A-Za-z0-9._-]+$`, is not `.` or `..`,
    is no symlink and has `.git`.
  - `target_hint ROOT`: the two-line hint of spec 4.1, without the `agentic: ` prefix.
  - `task_work TARGET`: prints `/work` or `/work/<T>` for the project, or dies (used in Task 6).

- [ ] **Step 1: Write the failing tests**

Append to `tests/bats/cli-init.bats`:

```bash
@test "init writes layout: single for a repository" {
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ "$status" -eq 0 ]
  [ "$(yq .layout "$PROJ/.agentic/agentic.yaml")" = single ]
  [ "$(yq 'has("target")' "$PROJ/.agentic/agentic.yaml")" = false ]
}

@test "init writes layout: multi, with the target when there is exactly one repository" {
  F="$BATS_TEST_TMPDIR/folder"; mkdir -p "$F"; git init -q "$F/api"
  run bash -c "cd '$F' && bash '$A' init"
  [ "$status" -eq 0 ]
  [ "$(yq .layout "$F/.agentic/agentic.yaml")" = multi ]
  [ "$(yq .target "$F/.agentic/agentic.yaml")" = api ]
}

@test "init with several repositories leaves the target out and prints the hint" {
  F="$BATS_TEST_TMPDIR/folder"; mkdir -p "$F"; git init -q "$F/web"; git init -q "$F/api"
  run bash -c "cd '$F' && bash '$A' init"
  [ "$status" -eq 0 ]
  [ "$(yq .layout "$F/.agentic/agentic.yaml")" = multi ]
  [ "$(yq 'has("target")' "$F/.agentic/agentic.yaml")" = false ]
  [[ "$output" == *"the project holds several repositories (api, web) and no target is set."* ]]
  [[ "$output" == *"Run with --target NAME, or set the default: agentic target api"* ]]
  make_agentic_dir
  run "$REPO_ROOT/image/bin/agentic-config" validate "$F/.agentic"
  [ "$status" -eq 0 ]
}

@test "init refuses a folder with no repository, before writing anything" {
  F="$BATS_TEST_TMPDIR/empty"; mkdir -p "$F/notes"
  run bash -c "cd '$F' && bash '$A' init"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no git repository in $F or its direct subfolders"* ]]
  [ ! -e "$F/.agentic" ]
}
```

Append to `tests/bats/cli-target.bats`:

```bash
# shellcheck source=../../lib/host/layout.sh
lay() { bash -c "source '$REPO_ROOT/lib/host/common.sh'; source '$REPO_ROOT/lib/host/layout.sh'; $1"; }

@test "repo_dirs lists the direct subfolders with .git, sorted, and skips symlinks and files" {
  ln -s "$M/api" "$M/link"
  mkdir -p "$M/docs"; : > "$M/README"
  [ "$(lay "repo_dirs '$M'" | tr '\n' ' ')" = "api web " ]
}

@test "valid_target refuses a symlink, dot names, a slash and a folder without .git" {
  ln -s "$M/api" "$M/link"; mkdir -p "$M/docs"
  lay "valid_target '$M' api"
  for t in link . .. 'api/x' docs nope ''; do
    run lay "valid_target '$M' '$t'"; [ "$status" -ne 0 ]
  done
}

@test "detect_layout says single, multi or nothing" {
  [ "$(lay "detect_layout '$M'")" = multi ]
  [ "$(lay "detect_layout '$M/api'")" = single ]
  mkdir -p "$BATS_TEST_TMPDIR/none"
  [ -z "$(lay "detect_layout '$BATS_TEST_TMPDIR/none'")" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/bats/cli-init.bats tests/bats/cli-target.bats`
Expected: the new tests FAIL (no `layout` key; `layout.sh` missing).

- [ ] **Step 3: Implement `lib/host/layout.sh`**

```bash
#!/usr/bin/env bash
# The project's layout (spec run-thin-relay §3): one repository at the root (single) or several in
# its direct subfolders (multi), and the target the agent starts in. File tests only, never git.
# Source after lib/host/common.sh.

# repo_dirs ROOT: the direct subfolders of ROOT that hold .git, sorted; a symlinked folder is skipped.
repo_dirs() {
  local d
  for d in "$1"/*/; do
    d="${d%/}"
    if [ ! -L "$d" ] && [ -e "$d/.git" ]; then basename "$d"; fi
  done | LC_ALL=C sort
}

# detect_layout ROOT: single when ROOT holds .git, multi when a direct subfolder does, else nothing.
detect_layout() {
  if [ -e "$1/.git" ]; then echo single
  elif [ -n "$(repo_dirs "$1")" ]; then echo multi
  fi
}

# valid_target ROOT NAME: NAME is a plain folder name under ROOT, no symlink, with .git.
valid_target() {
  [[ "$2" =~ ^[A-Za-z0-9._-]+$ && "$2" != . && "$2" != .. ]] && [ ! -L "$1/$2" ] && [ -e "$1/$2/.git" ]
}

# target_hint ROOT: what to do when a multi-repository project has no target.
target_hint() {
  local names first
  names="$(repo_dirs "$1" | paste -sd, - | sed 's/,/, /g')"; first="$(repo_dirs "$1" | head -n 1)"
  printf 'the project holds several repositories (%s) and no target is set.\n  Run with --target NAME, or set the default: agentic target %s' "$names" "$first"
}

# task_work TARGET: the agent's directory in the container: /work for a single repository, else
# /work/<TARGET or the configured target>. Dies with the reason otherwise.
task_work() {
  local cfgf root layout t
  cfgf="$(cfg_dir)/agentic.yaml"; root="$(project_root)"
  layout="$(yaml_top "$cfgf" layout)"
  case "$layout" in
    single)
      [ -z "$1" ] || die "--target is for a project with several repositories; this one is a single repository"
      [ -z "$(yaml_top "$cfgf" target)" ] || die "agentic.yaml sets target: but the layout is single; remove the target line"
      echo /work ;;
    multi)
      t="${1:-$(yaml_top "$cfgf" target)}"
      [ -n "$t" ] || die "$(target_hint "$root")"
      valid_target "$root" "$t" || die "$t is not a repository of the project; choose one of: $(repo_dirs "$root" | paste -sd' ' -)"
      echo "/work/$t" ;;
    "") die "no layout in .agentic/agentic.yaml; re-run agentic init" ;;
    *) die "layout must be single or multi, not $layout" ;;
  esac
}
```

In `bin/agentic`, after the `detect.sh` source lines, add:

```bash
# shellcheck source=../lib/host/layout.sh
source "$AGENTIC_ROOT/lib/host/layout.sh"
```

- [ ] **Step 4: Implement `init`, the template and the schema**

`templates/agentic.yaml.tmpl`: after the `project: @PROJECT@` line, add a line `@LAYOUT@`.

In `cmd_init` (`bin/agentic`), right after `root="$(project_root)"; cfg="$root/.agentic"` and
before the `--env-example` branch, nothing changes. Insert after the `--force` check
(`die ".agentic/agentic.yaml already exists…"`) and before `make_cfg "$cfg"`:

```bash
  layout="$(detect_layout "$root")"
  [ -n "$layout" ] || die "no git repository in $root or its direct subfolders; run agentic init in a repository or a folder of repositories"
  tgt=""
  if [ "$layout" = multi ] && [ "$(repo_dirs "$root" | grep -c .)" = 1 ]; then tgt="$(repo_dirs "$root")"; fi
```

Add `layout tgt` to the `local` line of `cmd_init`. In the template loop, add the case:

```bash
      @LAYOUT@) printf 'layout: %s\n' "$layout"; if [ -n "$tgt" ]; then printf 'target: %s\n' "$tgt"; fi ;;
```

After `echo "wrote $cfg/agentic.yaml"`, add:

```bash
  if [ "$layout" = multi ] && [ -z "$tgt" ]; then echo "note: $(target_hint "$root")"; fi
```

`detect_tools "$root"` and the report stay as they are.

`schema/agentic.schema.json`: in `properties`, after `project`, add:

```json
    "layout": {"description": "What /work is: single (the project root is one git repository) or multi (git repositories in its direct subfolders). Written by agentic init; agentic run needs it.", "enum": ["single", "multi"]},
    "target": {"description": "multi only: the default repository agentic run starts the agent in, a direct subfolder of the project root. agentic target NAME sets it.", "type": "string", "pattern": "^[A-Za-z0-9._-]+$"},
```

Regenerate the reference: `tools/gen-config-docs.sh` (it rewrites `docs/configuration.md`; check
with `tools/gen-config-docs.sh --check`).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/bats/cli-init.bats tests/bats/cli-target.bats tests/bats/config.bats && shellcheck -x bin/agentic lib/host/layout.sh && tools/gen-config-docs.sh --check`
Expected: PASS. If an existing `cli-init.bats` test creates a project without `.git`, give it
`git init -q` first.

- [ ] **Step 6: Commit**

```bash
git add lib/host/layout.sh bin/agentic templates/agentic.yaml.tmpl schema/agentic.schema.json docs/configuration.md tests/bats/cli-init.bats tests/bats/cli-target.bats
git commit -m "feat: init detects the layout (single or multi) and writes it, with the target when there is one repository"
```

---

### Task 3: `agentic target [NAME]` and the setup skill's question

**Files:**
- Modify: `bin/agentic` (`cmd_target`, dispatch, usage), `skills/agentic-setup/SKILL.md`
- Test: `tests/bats/cli-target.bats`, `tests/bats/setup-skill.bats`

**Interfaces:**
- Consumes: `repo_dirs`, `valid_target`, `yaml_set_top`, `yaml_top`.
- Produces: the command `agentic target [NAME]`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/bats/cli-target.bats`:

```bash
ag() { (cd "$M" && bash "$A" "$@" </dev/null); }

@test "target NAME writes the default; target prints it and the candidates" {
  run ag target
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'target: (none)\nrepositories: api web')" ]
  run ag target web
  [ "$status" -eq 0 ]; [ "$output" = "target: web" ]
  grep -qx 'target: web' "$M/.agentic/agentic.yaml"
  run ag target api
  [ "$(grep -c '^target:' "$M/.agentic/agentic.yaml")" = 1 ]
  [ "$(ag target | head -n 1)" = "target: api" ]
}

@test "target refuses an unknown name, a single-repository project and a missing layout" {
  run ag target nope
  [ "$status" -eq 1 ]; [[ "$output" == *"nope is not a repository of the project; choose one of: api web"* ]]
  ! grep -q '^target:' "$M/.agentic/agentic.yaml"
  S="$M/api"; mkdir -p "$S/.agentic"; printf 'version: 2\nproject: one\nlayout: single\n' > "$S/.agentic/agentic.yaml"
  run bash -c "cd '$S' && bash '$A' target x"
  [ "$status" -eq 1 ]; [[ "$output" == *"a single-repository project has no target to set"* ]]
  printf 'version: 2\nproject: demo\n' > "$M/.agentic/agentic.yaml"
  run ag target api
  [ "$status" -eq 1 ]; [[ "$output" == *"no layout in .agentic/agentic.yaml; re-run agentic init"* ]]
}
```

Append to `tests/bats/setup-skill.bats` (it already reads the skill file; follow its existing style
for the path variable):

```bash
@test "the setup skill asks for a default target when a multi-repository project has none" {
  grep -q 'layout: multi' "$REPO_ROOT/skills/agentic-setup/SKILL.md"
  grep -q 'agentic target NAME' "$REPO_ROOT/skills/agentic-setup/SKILL.md"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/bats/cli-target.bats tests/bats/setup-skill.bats`
Expected: FAIL (`target` prints the usage and exits 2; the skill has no such text).

- [ ] **Step 3: Implement**

In `bin/agentic`, add before `main()`:

```bash
cmd_target() {
  need_config
  local root cfgf layout cur
  root="$(project_root)"; cfgf="$(cfg_dir)/agentic.yaml"
  layout="$(yaml_top "$cfgf" layout)"
  [ -n "$layout" ] || die "no layout in .agentic/agentic.yaml; re-run agentic init"
  [ $# -le 1 ] || die "usage: agentic target [NAME]"
  if [ $# -eq 0 ]; then
    if [ "$layout" = single ]; then echo "single repository: the agent starts in the project root"; return 0; fi
    cur="$(yaml_top "$cfgf" target)"
    echo "target: ${cur:-(none)}"
    echo "repositories: $(repo_dirs "$root" | paste -sd' ' -)"
    return 0
  fi
  [ "$layout" = multi ] || die "a single-repository project has no target to set"
  valid_target "$root" "$1" || die "$1 is not a repository of the project; choose one of: $(repo_dirs "$root" | paste -sd' ' -)"
  yaml_set_top "$cfgf" target "$1"
  echo "target: $1"
}
```

Add `target` to the `init|remove|list|…` dispatch list in `main`. In `usage`, after the `dev`
entry, add:

```
  target [NAME]                      the default repository of a multi-repository project
```

In `skills/agentic-setup/SKILL.md`, step 1 (**Read**), append this sentence:

```
   If `agentic.yaml` has `layout: multi` and no `target:`, ask the user which repository under
   `/work` the agent should start in by default, then set it with
   `yq -i '.target = "NAME"' /work/.agentic/agentic.yaml` (on the host the same is
   `agentic target NAME`).
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/bats/cli-target.bats tests/bats/setup-skill.bats tests/bats/docs.bats && shellcheck -x bin/agentic`
Expected: PASS. If `docs.bats` checks that every usage line is documented, add `target` to
the command list in `README.md` in the same style.

- [ ] **Step 5: Commit**

```bash
git add bin/agentic skills/agentic-setup/SKILL.md tests/bats/cli-target.bats tests/bats/setup-skill.bats README.md
git commit -m "feat: agentic target [NAME] sets or shows the default repository; the setup skill asks for it"
```

---

### Task 4: Image pieces: the hold command, the bridge launcher and the worktree script

**Files:**
- Create: `image/bin/agentic-task-hold`, `image/bin/agentic-task-start`, `image/task/worktree.sh`
- Modify: `image/entrypoint.sh:9-11`, `image/Dockerfile:103-106` (`/tasks`)
- Test: create `tests/bats/task-hold.bats`, `tests/bats/task-worktree.bats`; modify
  `tests/bats/entrypoint-gate.bats`

**Interfaces:**
- Produces:
  - `agentic-task-hold`: writes its pid to `$AGENTIC_STATE/hold.pid` (default `$HOME/.agentic`),
    creates `$AGENTIC_TASK_DIR/.ready` when `AGENTIC_TASK_DIR` is set, then `exec sleep infinity`.
  - `agentic-task-start`: sources `$AGENTIC_STATE/env`, keeps the exec's `AGENTIC_TASK_DIR`,
    `exec agentic-bridge`, with stdout and stderr appended to `$AGENTIC_TASK_DIR/bridge.out`.
  - `worktree.sh add|check|remove WORK ID BRANCH [--force]`:
    - `add` prints the worktree path `WORK/.worktrees/ID` on stdout; git output goes to stderr.
    - Errors go to stderr as `agentic-worktree: …`, with exit 1.

- [ ] **Step 1: Write the failing tests**

`tests/bats/task-worktree.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  W="$BATS_TEST_TMPDIR/work"
  git init -q -b main "$W"
  git -C "$W" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  S="$REPO_ROOT/image/task/worktree.sh"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
}

@test "add makes the worktree on a new branch from HEAD, excluded from the checkout, and prints its path" {
  run --separate-stderr bash "$S" add "$W" T-1 agentic/T-1-x
  [ "$status" -eq 0 ]
  [ "$output" = "$W/.worktrees/T-1" ]
  [ "$(git -C "$W/.worktrees/T-1" rev-parse --abbrev-ref HEAD)" = agentic/T-1-x ]
  grep -qx '.worktrees/' "$W/.git/info/exclude"
  [ -z "$(git -C "$W" status --porcelain)" ]
}

@test "add refuses a repository without a commit, an existing branch, a bad id and a bad branch" {
  E="$BATS_TEST_TMPDIR/empty"; git init -q "$E"
  run bash "$S" add "$E" T-1 b; [ "$status" -eq 1 ]; [[ "$output" == *"has no commit"* ]]
  git -C "$W" branch taken
  run bash "$S" add "$W" T-2 taken; [ "$status" -ne 0 ]
  run bash "$S" add "$W" ../x b; [ "$status" -eq 1 ]; [[ "$output" == *"bad task id"* ]]
  run bash "$S" add "$W" T-3 -b; [ "$status" -eq 1 ]; [[ "$output" == *"bad branch name"* ]]
}

@test "check refuses uncommitted changes and commits that are only on the task branch" {
  bash "$S" add "$W" T-1 agentic/T-1-x >/dev/null
  bash "$S" check "$W" T-1 agentic/T-1-x
  echo x > "$W/.worktrees/T-1/f"
  run bash "$S" check "$W" T-1 agentic/T-1-x
  [ "$status" -eq 1 ]; [[ "$output" == *"has uncommitted changes"* ]]
  git -C "$W/.worktrees/T-1" add f; git -C "$W/.worktrees/T-1" commit -qm f
  run bash "$S" check "$W" T-1 agentic/T-1-x
  [ "$status" -eq 1 ]; [[ "$output" == *"has commits on no remote branch (agentic/T-1-x)"* ]]
}

@test "remove checks first, --force skips the check; both remove the worktree and the branch" {
  bash "$S" add "$W" T-1 agentic/T-1-x >/dev/null
  echo x > "$W/.worktrees/T-1/f"
  run bash "$S" remove "$W" T-1 agentic/T-1-x
  [ "$status" -eq 1 ]; [ -d "$W/.worktrees/T-1" ]
  bash "$S" remove "$W" T-1 agentic/T-1-x --force
  [ ! -e "$W/.worktrees/T-1" ]
  run git -C "$W" rev-parse -q --verify refs/heads/agentic/T-1-x; [ "$status" -ne 0 ]
  bash "$S" remove "$W" T-1 agentic/T-1-x   # nothing left: still succeeds
}
```

`tests/bats/task-hold.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() { make_tmp_home; export AGENTIC_STATE="$HOME/.agentic"; }

@test "agentic-task-hold records its pid, marks the start done and keeps running" {
  export AGENTIC_TASK_DIR="$BATS_TEST_TMPDIR/tasks/T-1"; mkdir -p "$AGENTIC_TASK_DIR"
  bash "$REPO_ROOT/image/bin/agentic-task-hold" & pid=$!
  for _ in $(seq 50); do [ -f "$AGENTIC_TASK_DIR/.ready" ] && break; sleep 0.1; done
  [ -f "$AGENTIC_TASK_DIR/.ready" ]
  [ "$(cat "$AGENTIC_STATE/hold.pid")" = "$pid" ]
  kill -0 "$pid"
  kill "$pid"
}

@test "agentic-task-start loads the start's environment and runs the bridge with its output in the task directory" {
  mkdir -p "$AGENTIC_STATE" "$BATS_TEST_TMPDIR/bin"
  printf 'export CLAUDE_CONFIG_DIR=/tasks/T-0/home/claude\nexport AGENTIC_TASK_DIR=/wrong\n' > "$AGENTIC_STATE/env"
  printf '#!/usr/bin/env bash\necho "cfg=$CLAUDE_CONFIG_DIR dir=$AGENTIC_TASK_DIR"\n' > "$BATS_TEST_TMPDIR/bin/agentic-bridge"
  chmod +x "$BATS_TEST_TMPDIR/bin/agentic-bridge"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" AGENTIC_TASK_DIR="$BATS_TEST_TMPDIR/tasks/T-2"
  bash "$REPO_ROOT/image/bin/agentic-task-start"
  [ "$(cat "$AGENTIC_TASK_DIR/bridge.out")" = "cfg=/tasks/T-0/home/claude dir=$AGENTIC_TASK_DIR" ]
}
```

Append to `tests/bats/entrypoint-gate.bats`:

```bash
@test "the gate is on by default for a task container's hold command" {
  install_cmd_stub agentic-task-hold
  bash "$REPO_ROOT/image/entrypoint.sh" agentic-task-hold </dev/null
  [ "$(gate)" = gate=1 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/bats/task-worktree.bats tests/bats/task-hold.bats tests/bats/entrypoint-gate.bats`
Expected: FAIL (the files do not exist; the gate is 0 for `agentic-task-hold`).

- [ ] **Step 3: Implement**

`image/task/worktree.sh`:

```bash
#!/usr/bin/env bash
# A task's own worktree, made and removed inside the task container, never by the host
# (spec run-thin-relay §5.2, §6.2).
#   add WORK ID BRANCH               WORK/.worktrees/ID on a new BRANCH from WORK's HEAD; prints the path
#   check WORK ID BRANCH             refuses uncommitted changes or commits on BRANCH only
#   remove WORK ID BRANCH [--force]  check (unless --force), then remove the worktree and BRANCH
set -euo pipefail
die() { echo "agentic-worktree: $*" >&2; exit 1; }
[ $# -ge 4 ] || die "usage: worktree.sh add|check|remove WORK ID BRANCH [--force]"
cmd="$1" work="$2" id="$3" branch="$4" force="${5:-}"
[[ "$id" =~ ^[A-Za-z0-9._-]+$ && "$id" != . && "$id" != .. ]] || die "bad task id $id"
[[ "$branch" != -* ]] && git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "bad branch name $branch"
wt="$work/.worktrees/$id"

# check: nothing uncommitted, and no commit that only the task branch has (not on a remote, not
# on the checkout's HEAD).
check() {
  [ -d "$wt" ] || return 0
  [ -z "$(git -C "$wt" status --porcelain)" ] || die "$wt has uncommitted changes; commit and push them, or clean with --force"
  [ -z "$(git -C "$work" log --oneline --not --remotes HEAD --not --end-of-options "$branch" 2>/dev/null)" ] \
    || die "$wt has commits on no remote branch ($branch); push them, or clean with --force"
}

case "$cmd" in
  add)
    git -C "$work" rev-parse -q --verify HEAD >/dev/null || die "$work has no commit to start a worktree from"
    ex="$(git -C "$work" rev-parse --git-path info/exclude)"; [[ "$ex" == /* ]] || ex="$work/$ex"
    mkdir -p "$(dirname "$ex")" "$work/.worktrees"
    grep -qx '.worktrees/' "$ex" 2>/dev/null || echo '.worktrees/' >> "$ex"
    git -C "$work" worktree add -q -b "$branch" -- "$wt" HEAD >&2
    printf '%s\n' "$wt" ;;
  check) check ;;
  remove)
    [ "$force" = --force ] || check
    if [ -d "$wt" ]; then git -C "$work" worktree remove --force -- "$wt"; fi
    git -C "$work" worktree prune
    if git -C "$work" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then git -C "$work" branch -D -- "$branch" >/dev/null; fi ;;
  *) die "unknown command $cmd" ;;
esac
```

`image/bin/agentic-task-hold`:

```bash
#!/usr/bin/env bash
# The command of a task container, after the start: records its pid (the bridge ends the container
# with it after an auto-clean), tells the host the start is done, then sleeps.
set -euo pipefail
state="${AGENTIC_STATE:-$HOME/.agentic}"
mkdir -p "$state"
echo "$$" > "$state/hold.pid"
if [ -n "${AGENTIC_TASK_DIR:-}" ]; then mkdir -p "$AGENTIC_TASK_DIR"; : > "$AGENTIC_TASK_DIR/.ready"; fi
exec sleep infinity
```

`image/bin/agentic-task-start`:

```bash
#!/usr/bin/env bash
# Starts a task's bridge in a running task container (docker exec): the start's environment first
# (harness homes and the rest of ~/.agentic/env), then the bridge with the exec's own variables.
set -euo pipefail
state="${AGENTIC_STATE:-$HOME/.agentic}"
task_dir="${AGENTIC_TASK_DIR:?AGENTIC_TASK_DIR must be set}"
# shellcheck disable=SC1091
if [ -f "$state/env" ]; then . "$state/env"; fi
export AGENTIC_TASK_DIR="$task_dir"
mkdir -p "$AGENTIC_TASK_DIR"
exec agentic-bridge >>"$AGENTIC_TASK_DIR/bridge.out" 2>&1
```

`chmod 755` both files (`git update-index --chmod=+x` after `git add`).

`image/entrypoint.sh`, the gate default:

```bash
  if [ "${1:-}" = agentic-bridge ] || [ "${1:-}" = agentic-task-hold ] || [ -n "${AGENTIC_WORKER_MODE:-}" ]; then AGENTIC_GATE=1; else AGENTIC_GATE=0; fi
```

`image/Dockerfile`: in the `mkdir -p /etc/agentic /work …` line, add `/tasks`, and add `/tasks`
to the `chown -R dev:dev …` list.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/bats/task-worktree.bats tests/bats/task-hold.bats tests/bats/entrypoint-gate.bats tests/bats/dockerfile.bats && shellcheck -x image/task/worktree.sh image/bin/agentic-task-hold image/bin/agentic-task-start image/entrypoint.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add image/task/worktree.sh image/bin/agentic-task-hold image/bin/agentic-task-start image/entrypoint.sh image/Dockerfile tests/bats/task-worktree.bats tests/bats/task-hold.bats tests/bats/entrypoint-gate.bats
git update-index --chmod=+x image/bin/agentic-task-hold image/bin/agentic-task-start
git commit -m "feat(image): task container hold command, bridge launcher for docker exec, and the in-container worktree script"
```

---

### Task 5: The bridge: worktree, record fields, agent cwd, auto-clean

**Files:**
- Modify: `bridge/src/config.ts`, `bridge/src/types.ts`, `bridge/src/bridge.ts`, `bridge/src/main.ts`
- Test: `bridge/test/config.test.ts`, `bridge/test/bridge.test.ts`

**Interfaces:**
- Consumes: `worktree.sh` (Task 4) through the `worktree` dependency in production.
- Produces:
  - `Config` gains `worktree: boolean` (`AGENTIC_WORKTREE === "1"`), `autoClean: boolean`
    (`AGENTIC_AUTO_CLEAN === "1"`), `target: string | null` (`AGENTIC_TARGET`),
    `container: string | null` (`AGENTIC_CONTAINER`) and `createdContainer: boolean`
    (`AGENTIC_CREATED_CONTAINER === "1"`). `branch` stays (`AGENTIC_BRANCH`).
  - `TaskRecord` gains `target: string | null`, `work: string`, `worktree: string | null`,
    `container: string | null`, `auto_clean: boolean` and `cleaned: boolean`.
  - `BridgeDeps.agentFactory(hooks: AgentHooks, cwd: string): AgentLike`.
  - `BridgeDeps.worktree(args: string[]): WorktreeResult`, where
    `export interface WorktreeResult { ok: boolean; out: string; err: string }` lives in
    `bridge.ts`.
  - `BridgeDeps.release(): void`.

- [ ] **Step 1: Write the failing tests**

In `bridge/test/config.test.ts`, add (follow the file's existing `env` helper for the tokens):

```ts
it("reads the worktree, auto-clean, target and container settings", () => {
  const cfg = loadConfig({ ...tokens, AGENTIC_WORKTREE: "1", AGENTIC_BRANCH: "agentic/T-1-x", AGENTIC_AUTO_CLEAN: "1",
    AGENTIC_TARGET: "api", AGENTIC_CONTAINER: "agentic-demo-task-T-1", AGENTIC_CREATED_CONTAINER: "1", AGENTIC_WORK: "/work/api" });
  expect([cfg.worktree, cfg.autoClean, cfg.target, cfg.container, cfg.createdContainer, cfg.work, cfg.branch])
    .toEqual([true, true, "api", "agentic-demo-task-T-1", true, "/work/api", "agentic/T-1-x"]);
  const off = loadConfig({ ...tokens });
  expect([off.worktree, off.autoClean, off.target, off.container, off.createdContainer]).toEqual([false, false, null, null, false]);
});
```

(If the file names its token object differently, use that name.)

In `bridge/test/bridge.test.ts`, extend `start()` so that it records the agent's cwd, takes a fake
worktree and records the release:

```ts
async function start(dir: string, extra: Record<string, string> = {},
  worktree: (args: string[]) => { ok: boolean; out: string; err: string } = () => ({ ok: true, out: "", err: "" })) {
  const exits: number[] = [];
  const cwds: string[] = [];
  const wt: string[][] = [];
  let released = 0;
  // ...env and cfg unchanged...
  const bridge = new Bridge({
    store, config: cfg, paragraph: "Use agentic-ask.",
    notifier: new Notifier({ eventsLog: null, webhook: null, project: "demo", log: () => {} }),
    agentFactory: (hooks, cwd) => { cwds.push(cwd); return new AgentProcess(harnessFor("claude", { model: null, acpCmd: cfg.acpCmd }),
      { cwd, env: { ...agentEnv, FAKE_AGENT_STATE: join(dir, "fake") }, paragraph: "Use agentic-ask.", model: null }, hooks); },
    worktree: (args) => { wt.push(args); return worktree(args); },
    release: () => { released++; },
    exit: (code) => exits.push(code), now: () => new Date().toISOString(), log: () => {},
  });
  // ...server, agentEnv, running.push, bridge.boot() unchanged...
  return { bridge, exits, store, port: server.port, cwds, wt, released: () => released };
}
```

Add the tests:

```ts
describe("worktree and auto-clean", () => {
  it("records the target, work, container and auto-clean; the agent starts in AGENTIC_WORK", async () => {
    const dir = taskDir("hello");
    const { bridge, store, cwds } = await start(dir, { AGENTIC_TARGET: "api", AGENTIC_CONTAINER: "agentic-demo-task-T-1" });
    await waitState(bridge, "idle");
    const rec = store.readRecord();
    expect([rec.target, rec.work, rec.worktree, rec.container, rec.auto_clean, rec.cleaned, rec.branch])
      .toEqual(["api", dir, null, "agentic-demo-task-T-1", false, false, null]);
    expect(cwds).toEqual([dir]);
  });

  it("with AGENTIC_WORKTREE the worktree is made before the agent starts, and the agent works in it", async () => {
    const dir = taskDir("hello");
    const wtDir = mkdtempSync(join(tmpdir(), "wt-"));
    const { bridge, store, cwds, wt } = await start(dir, { AGENTIC_WORKTREE: "1", AGENTIC_BRANCH: "agentic/T-1-hello" },
      () => ({ ok: true, out: `${wtDir}\n`, err: "" }));
    await waitState(bridge, "idle");
    expect(wt[0]).toEqual(["add", dir, "T-1", "agentic/T-1-hello"]);
    expect(cwds).toEqual([wtDir]);
    const rec = store.readRecord();
    expect([rec.work, rec.worktree, rec.branch]).toEqual([wtDir, wtDir, "agentic/T-1-hello"]);
  });

  it("a worktree that cannot be made refuses the boot with the script's reason", async () => {
    const dir = taskDir("hello");
    await expect(start(dir, { AGENTIC_WORKTREE: "1", AGENTIC_BRANCH: "b" },
      () => ({ ok: false, out: "", err: "agentic-worktree: /work has no commit to start a worktree from\n" })))
      .rejects.toThrow("could not create the worktree: agentic-worktree: /work has no commit to start a worktree from");
  });

  it("auto-clean after a normal turn removes the worktree, stops the task and releases the container it created", async () => {
    const dir = taskDir("hello");
    const wtDir = mkdtempSync(join(tmpdir(), "wt-"));
    const { store, wt, exits, released } = await start(dir,
      { AGENTIC_WORKTREE: "1", AGENTIC_BRANCH: "agentic/T-1-hello", AGENTIC_AUTO_CLEAN: "1", AGENTIC_CREATED_CONTAINER: "1" },
      (args) => ({ ok: true, out: args[0] === "add" ? `${wtDir}\n` : "", err: "" }));
    expect(await exited(exits)).toEqual([0]);
    expect(wt.map((a) => a[0])).toEqual(["add", "remove"]);
    expect(wt[1]).toEqual(["remove", dir, "T-1", "agentic/T-1-hello"]);
    const rec = store.readRecord();
    expect([rec.state, rec.cleaned, rec.reason]).toEqual(["stopped", true, "auto-cleaned"]);
    expect(released()).toBe(1);
  });

  it("auto-clean in a reused container stops the task but does not end the container", async () => {
    const dir = taskDir("hello");
    const { store, exits, released } = await start(dir, { AGENTIC_AUTO_CLEAN: "1" });
    expect(await exited(exits)).toEqual([0]);
    expect(store.readRecord().cleaned).toBe(true);
    expect(released()).toBe(0);
  });

  it("a worktree that cannot be removed keeps the task idle and reports why", async () => {
    const dir = taskDir("hello");
    const wtDir = mkdtempSync(join(tmpdir(), "wt-"));
    const { bridge, store, released } = await start(dir,
      { AGENTIC_WORKTREE: "1", AGENTIC_BRANCH: "b", AGENTIC_AUTO_CLEAN: "1", AGENTIC_CREATED_CONTAINER: "1" },
      (args) => args[0] === "add" ? { ok: true, out: wtDir, err: "" } : { ok: false, out: "", err: "agentic-worktree: x has uncommitted changes" });
    await waitState(bridge, "idle");
    await new Promise((r) => setTimeout(r, 50));
    expect(store.readRecord().cleaned).toBe(false);
    expect(store.readEvents(0).some((e) => e.type === "error" && String(e.data.message).includes("auto-clean kept the task"))).toBe(true);
    expect(released()).toBe(0);
  });
});
```

`start()` calls `bridge.boot()`, which now throws on a failed worktree. The third test relies on
`start()` passing that rejection through. If `start()` must clean up first, wrap `bridge.boot()`
so that it closes the server and then rethrows.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd bridge && npm test`
Expected: FAIL (type errors on `worktree`/`release`/the new fields, then assertion failures).

- [ ] **Step 3: Implement**

`bridge/src/config.ts`: add the fields to `Config` and to `loadConfig`'s result:

```ts
  worktree: boolean;
  autoClean: boolean;
  target: string | null;
  container: string | null;
  createdContainer: boolean;
```

```ts
    worktree: env.AGENTIC_WORKTREE === "1",
    autoClean: env.AGENTIC_AUTO_CLEAN === "1",
    target: opt(env.AGENTIC_TARGET),
    container: opt(env.AGENTIC_CONTAINER),
    createdContainer: env.AGENTIC_CREATED_CONTAINER === "1",
```

`bridge/src/types.ts`, in `TaskRecord` after `branch`:

```ts
  target: string | null;
  work: string;
  worktree: string | null;
  container: string | null;
  auto_clean: boolean;
  cleaned: boolean;
```

`bridge/src/bridge.ts`:

```ts
export interface WorktreeResult { ok: boolean; out: string; err: string }

export interface BridgeDeps {
  store: Store;
  config: Config;
  notifier: Notifier;
  paragraph: string;
  agentFactory(hooks: AgentHooks, cwd: string): AgentLike;
  worktree(args: string[]): WorktreeResult;
  release(): void;
  exit(code: number): void;
  now(): string;
  log(line: string): void;
}
```

In `boot()`, in the `fresh` branch, before building `record`:

```ts
      let work = config.work;
      let worktree: string | null = null;
      if (config.worktree) {
        if (!config.branch) throw new BridgeError("AGENTIC_WORKTREE=1 needs AGENTIC_BRANCH");
        const r = this.d.worktree(["add", config.work, config.task, config.branch]);
        const path = r.out.trim().split("\n").pop() ?? "";
        if (!r.ok || !path) {
          const why = (r.err || r.out).trim();
          this.d.log(`worktree: ${why}`);
          throw new BridgeError(`could not create the worktree: ${why}`);
        }
        worktree = work = path;
      }
```

The record literal: `branch: config.worktree ? config.branch : null`, plus
`target: config.target, work, worktree, container: config.container, auto_clean: config.autoClean, cleaned: false`.

In the non-fresh branch, after `record = store.readRecord();`, fill the fields an older record
lacks:

```ts
      if (typeof record.work !== "string") record.work = config.work;
      record.cleaned = record.cleaned === true;
```

In `spawn()`: `agent = this.d.agentFactory(this.hooks(() => agent), this.m().record.work);`

In `seed()`: use `this.m().record.work` in place of `this.d.config.work`.

In `run()`, at the end, before `return out;`:

```ts
    if (this.cleanable(input)) this.autoClean();
```

Add these private methods:

```ts
  // cleanable: auto-clean is on and a turn just ended normally with nothing left to do.
  private cleanable(input: Input): boolean {
    const m = this.m();
    return this.d.config.autoClean && input.kind === "turnEnd" && input.stopReason !== "cancelled"
      && m.record.state === "idle" && m.record.inbox.length === 0 && m.openQuestions().length === 0 && !m.record.cleaned;
  }

  // autoClean: removes the worktree (refusing unpushed work), then stops the task; the exit releases
  // the container when this task created it.
  private autoClean(): void {
    const rec = this.m().record;
    if (rec.worktree && rec.branch) {
      const r = this.d.worktree(["remove", this.d.config.work, rec.task, rec.branch]);
      if (!r.ok) {
        this.emit("error", { message: `auto-clean kept the task: ${(r.err || r.out).trim()}` });
        return;
      }
    }
    rec.cleaned = true;
    this.run({ kind: "stop" });
    rec.reason = "auto-cleaned";
    rec.stopped_by_user = false;
    this.d.store.writeRecord(rec);
  }
```

In `perform()`, case `"exit"`:

```ts
        void this.drain().then(() => {
          if (this.m().record.cleaned && this.d.config.createdContainer) this.d.release();
          this.d.exit(e.code);
        });
```

`bridge/src/main.ts`: import `spawnSync` from `node:child_process` and pass the dependencies:

```ts
  const agentic = process.env.AGENTIC_DIR ?? "/opt/agentic";
  const stateDir = process.env.AGENTIC_STATE ?? join(process.env.HOME ?? "/home/dev", ".agentic");
```

```ts
    agentFactory: (hooks, cwd) => new AgentProcess(spec, { cwd, env, paragraph, model: cfg.model }, hooks),
    worktree: (args) => {
      const r = spawnSync("bash", [join(agentic, "task", "worktree.sh"), ...args], { encoding: "utf8" });
      return { ok: r.status === 0, out: r.stdout ?? "", err: r.stderr ?? "" };
    },
    release: () => {
      try {
        process.kill(Number(readFileSync(join(stateDir, "hold.pid"), "utf8").trim()), "SIGTERM");
      } catch (e) {
        log(`release failed: ${(e as Error).message}`);
      }
    },
```

Fix any other `agentFactory` or `BridgeDeps` construction in `bridge/test/*.ts` the compiler
names (pass `worktree: () => ({ ok: true, out: "", err: "" })` and `release: () => {}`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd bridge && npm test && npx tsc --noEmit -p . && npx eslint .`
Expected: PASS, no type or lint errors. (`npx` here runs the locally installed, pinned binaries.)

- [ ] **Step 5: Commit**

```bash
git add bridge/src bridge/test
git commit -m "feat(bridge): optional worktree made in the container, record target/work/container, agent cwd from the record, auto-clean"
```

---

### Task 6: `run` creates or reuses a task container; the host's git code goes

**Files:**
- Modify: `lib/host/common.sh` (`project_run_args`), `lib/host/task.sh`, `bin/agentic` (`cmd_run`,
  `run_cleanup`, `usage`), `tests/bats/docker-stub.bash`
- Test: `tests/bats/cli-task-run.bats`

**Interfaces:**
- Consumes: `task_work` (Task 2), `agentic-task-hold`/`agentic-task-start` (Task 4), the bridge's
  `AGENTIC_*` variables (Task 5).
- Produces (`lib/host/task.sh`):
  - `task_container ID`: the name from the host file `container` (line 1), else
    `agentic-<project>-task-<ID>`.
  - `task_created ID`: line 2 = 1.
  - `task_creator ID`: line 3.
  - `bridge_running CONTAINER`
  - `wait_ready ID SECONDS`
  - `start_container ID`
  - `start_bridge ID`
  - `wait_bridge_gone CONTAINER SECONDS`
  - `task_has_worktree ID`
  - `worktree_cmd ID check|remove [--force]`
  - `rollback_task ID` (simplified)
  - `TASK_HOST_FILES=(env container interrupted)`

- [ ] **Step 1: Extend the docker stub**

In `tests/bats/docker-stub.bash`, document and add the following.

The `exec` case:

```bash
  exec)
    if [[ " $* " == *" pgrep "* ]]; then exit "${DOCKER_BRIDGE_RC:-0}"; fi
    if [[ " $* " == *" /opt/agentic/task/worktree.sh "* ]] && [ -n "${DOCKER_WT_ERR:-}" ]; then echo "$DOCKER_WT_ERR" >&2; exit 1; fi
    exit "${DOCKER_EXEC_RC:-0}" ;;
```

At the top of the `run)` case, before the `--entrypoint git` branch:

```bash
    if [[ " $* " == *" agentic-task-hold "* ]] && [ -z "${DOCKER_NO_READY:-}" ]; then
      src="" dir="" prev=""
      for a in "$@"; do
        if [ "$prev" = -v ] && [[ "$a" == *:/tasks ]]; then src="${a%:/tasks}"; fi
        if [ "$prev" = -e ] && [[ "$a" == AGENTIC_TASK_DIR=/tasks/* ]]; then dir="${a#AGENTIC_TASK_DIR=/tasks/}"; fi
        prev="$a"
      done
      if [ -n "$src" ] && [ -n "$dir" ]; then mkdir -p "$src/$dir"; : > "$src/$dir/.ready"; echo "$src/$dir/.ready" > "$BATS_TEST_TMPDIR/docker.ready"; fi
    fi
```

The `start)` case:

```bash
  start) echo running > "$BATS_TEST_TMPDIR/docker.status"
    if [ -z "${DOCKER_NO_READY:-}" ] && [ -f "$BATS_TEST_TMPDIR/docker.ready" ]; then : > "$(cat "$BATS_TEST_TMPDIR/docker.ready")"; fi ;;
```

The header comment gets: `DOCKER_BRIDGE_RC` (exit code of the `pgrep` that tells whether a bridge
runs; default 0, running), `DOCKER_WT_ERR` (makes a `worktree.sh` exec fail with this message),
`DOCKER_EXEC_RC`, and `DOCKER_NO_READY` (the hold command never marks its start done).

Replace `docker_run_with` with a general helper and keep the old name:

```bash
# docker_call_with SUB LINE: the arguments (SUB first) of the first docker SUB call with the argument LINE.
docker_call_with() {
  awk -v s="$1" -v l="$2" 'function out() { if (on && hit && !done) { printf "%s", buf; done = 1 } }
    /^--- /{ out(); on = ($2 == s); hit = 0; buf = ""; next }
    on { buf = buf $0 "\n"; if ($0 == l) hit = 1 }
    END { out() }' "$DOCKER_LOG"
}
docker_run_with() { docker_call_with run "$1"; }
```

- [ ] **Step 2: Write the failing tests**

In `tests/bats/cli-task-run.bats`:

1. In `setup()`, write the layout:
   `printf 'version: 2\nproject: demo\nlayout: single\n' > "$PROJ/.agentic/agentic.yaml"`.
2. In `record()`, write the host container file, the work line and the readiness path after the
   `env` line:

   ```bash
   printf 'agentic-demo-task-%s\n1\n%s\n' "$1" "$1" > "$H/$1/container"
   printf 'AGENTIC_WORK=/work\n' >> "$H/$1/env"
   echo "$T/$1/.ready" > "$BATS_TEST_TMPDIR/docker.ready"
   ```

3. Delete these tests (they cover the removed mirror, clone and host-worktree code):
   - "run --repo gives each named repository a worktree…"
   - "host git ignores hooks and fsmonitor planted in a task clone"
   - "run mounts each changed clone's git config, info and hooks read-only…"
   - "every operation on a task clone runs in a hardened throwaway container…"
   - "host git never opens a task clone once it exists…"
   - "the mirror is private…"
   - "a --repo clone's origin is recorded in its mirror…"
   - "commands planted in a clone never run on the host…"
   - "FETCH_HEAD and packed-refs symlinks planted in a clone…"
   - "clean refuses a worktree whose .git does not name one of the clone's worktrees"
   - "the host's own git (mirror fetch) keeps the user's credential helpers…"
   - "a task from before the move: its files are taken from the workspace once"
   - "git errors from a clone reach the terminal without control characters"
   - "rollback and clean take no clone or worktree path with .. or a symlink in it"
   - "an origin URL that is a git option never runs on the host…"
   - "the project's URL is pinned in its mirror when first made…"
   - "wt_gitdir reads the worktree's .git file…"
   - "a pinned origin must be https, ssh, git or scp-style…"
   - "an https origin is accepted and pinned"
   - "host git talks to a remote only over https, ssh and git…"

   Also delete the helpers that only these tests used (`fake_ssh`, `remote_clone` or similar).
4. Replace "run creates the worktree, the task directory and tokens…" with:

```bash
@test "run creates a task container with the checkout at /work, starts the bridge in it and prints the id" {
  run --separate-stderr ag run --id T-1 --allow push --allow open-pr "Fix the login bug"
  [ "$status" -eq 0 ]
  [ "$output" = T-1 ]
  [ "$stderr" = "follow: agentic follow T-1" ]
  [ "$(cat "$T/T-1/prompt.md")" = "Fix the login bug" ]
  [ "$(stat -c %a "$H/T-1/env")" = 600 ]
  grep -Eq '^AGENTIC_TASK_TOKEN=[0-9a-f]{64}$' "$H/T-1/env"
  grep -Eq '^AGENTIC_AGENT_TOKEN=[0-9a-f]{64}$' "$H/T-1/env"
  for l in AGENTIC_TASK_ID=T-1 AGENTIC_TASK_DIR=/tasks/T-1 AGENTIC_PROJECT=demo AGENTIC_AGENT=claude AGENTIC_WORK=/work \
           AGENTIC_ALLOWED_ACTIONS=push,open-pr AGENTIC_WORKTREE=0 AGENTIC_AUTO_CLEAN=0 AGENTIC_CONTAINER=agentic-demo-task-T-1 \
           AGENTIC_CREATED_CONTAINER=1; do grep -qx "$l" "$H/T-1/env"; done
  [ "$(cat "$H/T-1/container")" = "$(printf 'agentic-demo-task-T-1\n1\nT-1')" ]
  call="$(docker_run_with agentic-task-hold)"
  for l in -d --init agentic-demo-task-T-1 agentic.kind=task agentic.task=T-1 agentic.project=demo 127.0.0.1::8765 ALL \
           no-new-privileges "$PROJ:/work" "$T:/tasks" "$AGENTIC_WORKSPACES/demo/events:/events" AGENTIC_TASK_DIR=/tasks/T-1; do
    grep -qx -- "$l" <<<"$call"
  done
  [ "$(tail -n 1 <<<"$call")" = agentic-task-hold ]
  ! grep -q '/home/dev/.claude' <<<"$call"
  ex="$(docker_call_with exec agentic-task-start)"
  for l in -d --env-file "$H/T-1/env" agentic-demo-task-T-1; do grep -qx -- "$l" <<<"$ex"; done
  [ "$(tail -n 1 <<<"$ex")" = agentic-task-start ]
  run grep -q "$(grep TASK_TOKEN "$H/T-1/env" | cut -d= -f2)" "$DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "run calls no git on the host but the identity lookup" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "$*" >> "%s/hostgit.log"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  run ag run --id T-G --worktree "x"
  [ "$status" -eq 0 ]
  if [ -e "$BATS_TEST_TMPDIR/hostgit.log" ]; then ! grep -vE 'config user\.(name|email)$' "$BATS_TEST_TMPDIR/hostgit.log"; fi
}

@test "--worktree passes the branch to the bridge; --json names the target and the branch" {
  run --separate-stderr ag run --id T-2 --worktree --json "Fix it"
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"task":"T-2","container":"agentic-demo-task-T-2","port":"49153","target":null,"branch":"agentic/T-2-fix-it"}' ]
  grep -qx AGENTIC_WORKTREE=1 "$H/T-2/env"
  grep -qx AGENTIC_BRANCH=agentic/T-2-fix-it "$H/T-2/env"
}

multi() {
  M="$BATS_TEST_TMPDIR/multi"; mkdir -p "$M/.agentic"; git init -q "$M/api"; git init -q "$M/web"
  printf 'version: 2\nproject: demo\nlayout: multi\n' > "$M/.agentic/agentic.yaml"
}
am() { (cd "$M" && bash "$A" "$@" </dev/null); }

@test "a multi-repository project without a target stops with the hint and creates nothing" {
  multi
  run am run "x"
  [ "$status" -eq 1 ]
  [ "$output" = "$(printf 'agentic: the project holds several repositories (api, web) and no target is set.\n  Run with --target NAME, or set the default: agentic target api')" ]
  [ ! -s "$DOCKER_LOG" ] || ! grep -q -- '--- run' "$DOCKER_LOG"
}

@test "the target is --target, else target:; the agent starts in /work/<target>; the checkout is the project folder" {
  multi
  am run --id T-a --target web "x"
  grep -qx AGENTIC_WORK=/work/web "$H/T-a/env"; grep -qx AGENTIC_TARGET=web "$H/T-a/env"
  printf 'target: api\n' >> "$M/.agentic/agentic.yaml"
  am run --id T-b "x"
  grep -qx AGENTIC_WORK=/work/api "$H/T-b/env"
  grep -qx "$M:/work" <<<"$(docker_run_with agentic-task-hold)"
}

@test "an unknown target, --target on a single repository, a missing layout and a bad --model are refused" {
  multi
  run am run --target nope "x"; [ "$status" -eq 1 ]; [[ "$output" == *"nope is not a repository of the project; choose one of: api web"* ]]
  run ag run --target web "x"; [ "$status" -eq 1 ]; [[ "$output" == *"--target is for a project with several repositories"* ]]
  run ag run --model $'a\nb' "x"; [ "$status" -eq 1 ]; [[ "$output" == *"--model"* ]]
  printf 'version: 2\nproject: demo\n' > "$PROJ/.agentic/agentic.yaml"
  run ag run "x"; [ "$status" -eq 1 ]; [[ "$output" == *"no layout in .agentic/agentic.yaml; re-run agentic init"* ]]
  [ ! -d "$T" ] || [ -z "$(ls -A "$T")" ]
}

@test "run --in starts a new task in the container of an earlier task, one task at a time" {
  record T-1 idle
  run ag run --id T-2 --in T-1 "second"
  [ "$status" -eq 1 ]; [[ "$output" == *"a task runs in the container of T-1"* ]]
  [ ! -e "$T/T-2" ]
  DOCKER_BRIDGE_RC=1 run ag run --id T-2 --in T-1 "second"
  [ "$status" -eq 0 ]
  [ "$(cat "$H/T-2/container")" = "$(printf 'agentic-demo-task-T-1\n0\nT-1')" ]
  ! grep -q -- '--- run' "$DOCKER_LOG"
  grep -qx AGENTIC_TASK_DIR=/tasks/T-2 "$H/T-2/env"
  grep -qx AGENTIC_CREATED_CONTAINER=0 "$H/T-2/env"
  grep -qx agentic-demo-task-T-1 <<<"$(docker_call_with exec agentic-task-start)"
}

@test "run --in refuses an unknown task and a container that is gone" {
  run ag run --in T-9 "x"; [ "$status" -eq 1 ]; [[ "$output" == *"no task T-9"* ]]
  record T-1 idle
  DOCKER_STATUS="" run ag run --id T-3 --in T-1 "x"
  [ "$status" -eq 1 ]; [[ "$output" == *"task T-1 has no container"* ]]
  [ ! -e "$T/T-3" ]
}

@test "a container whose start never finishes fails the run and is rolled back" {
  DOCKER_NO_READY=1 AGENTIC_START_TIMEOUT=1 run ag run --id T-7 "x"
  [ "$status" -eq 1 ]; [[ "$output" == *"the container of T-7 did not finish its start"* ]]
  [ ! -e "$T/T-7" ] && [ ! -e "$H/T-7" ]
  grep -qx agentic-demo-task-T-7 <<<"$(docker_sub rm)"
}

@test "a failed bridge in a reused container rolls the task back and keeps the container" {
  record T-1 idle
  CURL_RC=7 DOCKER_BRIDGE_RC=1 AGENTIC_START_TIMEOUT=1 run ag run --id T-2 --in T-1 "x"
  [ "$status" -eq 1 ]
  [ ! -e "$T/T-2" ] && [ ! -e "$H/T-2" ]
  [ -z "$(docker_sub rm)" ]
}
```

5. Update the remaining tests that relied on the old layout:
   - "run --json prints the task, container, port and branch" is replaced by the `--worktree`
     test above; delete it.
   - "a failed start rolls back the container, worktree, branch and files" becomes:

     ```bash
     @test "a failed start rolls back the container and files" {
       DOCKER_RUN_RC=1 run ag run --id T-5 "x"
       [ "$status" -eq 1 ]
       [ ! -e "$T/T-5" ] && [ ! -e "$H/T-5" ]
       grep -qx agentic-demo-task-T-5 <<<"$(docker_sub rm)"
     }
     ```

   - "a prompt over 64 KB starts a task with a short branch": add `--worktree` to its `run` and
     read the branch from `AGENTIC_BRANCH` in `$H/<id>/env`.
   - "run refuses a bind source that goes through a symlink, and drops every capability of the
     task": keep only the capability part. Assert `ALL` and `no-new-privileges` in
     `docker_run_with agentic-task-hold`.
   - "the host's task files (tokens, mounts, repos) live outside the workspace…": rename it to
     "(tokens, container)" and check `env` and `container` under `$H`, with nothing of them
     under `$T`.
   - Any other test that greps `docker_run_with agentic-bridge`: switch it to
     `docker_run_with agentic-task-hold` (the container) or
     `docker_call_with exec agentic-task-start` (the bridge).

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats tests/bats/cli-task-run.bats`
Expected: the new and changed tests FAIL. The status and safety tests that do not depend on the
creation path still pass.

- [ ] **Step 4: Implement the host side**

`lib/host/common.sh`: split `build_run_args`:

```bash
# project_run_args IMAGE: what the dev container and every task container get, in RUN_ARGS: the
# checkout at /work, the workspace clones, the config, and shared_run_args.
project_run_args() {
  local root cfg p repos
  root="$(project_root)"; cfg="$root/.agentic"; p="$(project_name)"
  repos="$(realpath -m -- "$AGENTIC_WORKSPACES")/$p/repos"
  mkdir -p "$repos"
  RUN_ARGS=(--label "agentic.project=$p" -v "$root:/work" -v "$repos:/workspaces/repos" -v "$cfg:/agentic-config:ro")
  shared_run_args "$1"
}

# build_run_args IMAGE: project_run_args plus the project's harness homes (dev, shell, setup, doctor).
# The workspace's tasks/ and events/ stay out of interactive containers.
build_run_args() {
  local data; data="$AGENTIC_DATA/projects/$(project_name)"
  mkdir -p "$data/harness/claude" "$data/harness/copilot"
  project_run_args "$1"
  RUN_ARGS+=(-v "$data/harness/claude:/home/dev/.claude" -v "$data/harness/copilot:/home/dev/.copilot")
}
```

`lib/host/task.sh`:

- Delete: the "Task clones" comment block, `mirror_dir`, `user_cfg`, `ugit`, `mgit`, `clone_ok`,
  `cgit_err`, `cgit`, `wt_gitdir`, `task_image`, `url_ok`, `remote_url_ok`, `project_url`,
  `repo_url`, `sync_mirror`, `project_clone`, `add_worktree`, `task_mounts`, `read_mounts`,
  `task_migrate` (and its call in `need_task`) and `canon_in` (when nothing else uses it;
  `grep -n canon_in lib bin` must be empty).
- Change the host files: `TASK_HOST_FILES=(env container interrupted)` and their comment:
  "(tokens and the bridge's settings, the container, the interrupted marker)".
- Replace `task_container` and add the helpers:

```bash
# task_container ID: the container the task runs in (line 1 of its host file container), else the
# one run creates for it. Never taken from the record, which the agent can write.
task_container() {
  local f n
  if f="$(host_file "$1" container)"; then
    n="$(sed -n 1p "$f")"
    if [[ "$n" =~ ^agentic-[a-z0-9-]+-task-[A-Za-z0-9._-]+$ ]]; then printf '%s\n' "$n"; return 0; fi
  fi
  printf 'agentic-%s-task-%s\n' "$(task_project)" "$1"
}
# task_created ID: the task created its container (line 2 is 1); task_creator ID: the task that did (line 3).
task_created() { local f; f="$(host_file "$1" container)" && [ "$(sed -n 2p "$f")" = 1 ]; }
task_creator() { local f c; f="$(host_file "$1" container)" && c="$(sed -n 3p "$f")" && valid_task_id "$c" && printf '%s\n' "$c"; }

# bridge_running CONTAINER: a task bridge (not a follow client) runs in CONTAINER.
bridge_running() { docker exec "$1" pgrep -f 'bridge/dist/main\.js$' >/dev/null 2>&1; }
# wait_bridge_gone CONTAINER SECONDS: until no bridge runs in CONTAINER.
wait_bridge_gone() {
  local end=$((SECONDS + $2))
  while [ "$SECONDS" -lt "$end" ]; do bridge_running "$1" || return 0; sleep 0.5; done
  return 1
}

# wait_ready ID SECONDS: until the container of the task has finished its start (agentic-task-hold
# marks /tasks/<creator>/.ready).
wait_ready() {
  local id="$1" end=$((SECONDS + $2)) creator f
  creator="$(task_creator "$id")" || return 1
  f="$(task_dir "$creator")/.ready"
  while [ "$SECONDS" -lt "$end" ]; do
    [ "$(container_status "$id")" = running ] || return 1
    if [ -f "$f" ] && [ ! -L "$f" ]; then return 0; fi
    sleep 0.5
  done
  return 1
}

# start_container ID: starts the task's stopped container and waits for its start.
start_container() {
  local creator; creator="$(task_creator "$1")" || die "task $1 has no container record"
  rm -f -- "$(task_dir "$creator")/.ready"
  docker start "$(task_container "$1")" >/dev/null || die "could not start the container of $1"
  wait_ready "$1" "${AGENTIC_START_TIMEOUT:-120}" || die "the container of $1 did not finish its start; see agentic logs $1 --start"
}

# start_bridge ID: the task's bridge in its running container, with the task's host env file.
start_bridge() {
  local envf; envf="$(host_file "$1" env)" || die "the env file of $1 is not a regular file"
  docker exec -d --env-file "$envf" "$(task_container "$1")" agentic-task-start >/dev/null || die "could not start the bridge of $1"
}

# task_has_worktree ID: run gave the task a worktree (its host env file says so).
task_has_worktree() { local envf; envf="$(host_file "$1" env)" && [ "$(dotenv_value "$envf" AGENTIC_WORKTREE)" = 1 ]; }
# worktree_cmd ID check|remove [--force]: the worktree script in the task's container, with the work
# directory and branch from the host env file.
worktree_cmd() {
  local envf; envf="$(host_file "$1" env)" || return 1
  docker exec "$(task_container "$1")" bash /opt/agentic/task/worktree.sh "$2" "$(dotenv_value "$envf" AGENTIC_WORK)" "$1" \
    "$(dotenv_value "$envf" AGENTIC_BRANCH)" ${3:+"$3"}
}
```

- `task_state`: a container that runs without the task's bridge means interrupted:

```bash
    case "$cs" in running) bridge_running "$(task_container "$1")" || st=interrupted ;; unknown) st=unknown ;; *) st=interrupted ;; esac
```

- `check_cap`: count running bridges, not containers:

```bash
check_cap() {
  local n=0 c max="${AGENTIC_MAX_RUNNING:-3}"
  while IFS= read -r c; do
    if [ -n "$c" ] && bridge_running "$c"; then n=$((n + 1)); fi
  done < <(docker ps --format '{{.Names}}' --filter label=agentic.kind=task --filter status=running)
  [ "$n" -lt "$max" ] || die "$n tasks are running (AGENTIC_MAX_RUNNING=$max); stop one or wait"
}
```

- `rollback_task`:

```bash
# rollback_task ID: removes what the task created: its container (only when it created it; a bridge
# left in a reused container is ended) and its files.
rollback_task() {
  local id="$1" ws c
  valid_task_id "$id" || return 0
  ws="$(task_ws)"; c="$(task_container "$id")"
  if task_created "$id"; then docker rm -f "$c" >/dev/null 2>&1 || true
  elif host_file "$id" container >/dev/null; then docker exec "$c" pkill -f 'bridge/dist/main\.js$' >/dev/null 2>&1 || true
  fi
  safe_rm "$ws/tasks" "$(task_dir "$id")"
  safe_rm "$AGENTIC_DATA/projects/$(task_project)/tasks" "$(task_hdir "$id")"
}
```

- `ensure_running`:

```bash
# ensure_running ID: the task's container runs and its bridge answers; starts what is missing (not
# for a stopped task).
ensure_running() {
  local id="$1" st cs c; c="$(task_container "$id")"
  cs="$(container_status "$id")"
  if [ "$cs" = running ] && bridge_running "$c"; then return 0; fi
  st="$(task_state "$id")"
  [ "$st" != stopped ] || die "task $id is stopped"
  case "$cs" in
    missing) die "task $id has no container (state: $st)" ;;
    unknown) die "docker did not answer for task $id" ;;
  esac
  check_cap
  if [ "$cs" != running ]; then start_container "$id"; fi
  ! bridge_running "$c" || die "another task runs in the container of $id"
  start_bridge "$id"
  wait_bridge "$id" "${AGENTIC_START_TIMEOUT:-120}" || die "the bridge of $id did not come up; see agentic logs $id --bridge"
  # revived: a later interruption is logged to the project events log again
  rm -f "$(task_file "$id" interrupted)"
}
```

`bin/agentic`, `cmd_run` (replace its body from the option parsing to the end):

```bash
cmd_run() {
  need_config
  local prompt="" pfile="" agent="" model="" target="" in="" worktree=0 autoclean=0 id="" keep=0 json=0 allow=() a
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt-file) optval "$@"; pfile="$2"; shift 2 ;;
      --agent) optval "$@"; agent="$2"; shift 2 ;;
      --model) optval "$@"; model="$2"; shift 2 ;;
      --target) optval "$@"; target="$2"; shift 2 ;;
      --in) optval "$@"; in="$2"; shift 2 ;;
      --worktree) worktree=1; shift ;;
      --auto-clean) autoclean=1; shift ;;
      --allow) optval "$@"; allow+=("$2"); shift 2 ;;
      --id) optval "$@"; id="$2"; shift 2 ;;
      --keep-on-failure) keep=1; shift ;;
      --json) json=1; shift ;;
      -*) die "unknown option $1 (agentic help)" ;;
      *) [ -z "$prompt" ] || die "one prompt; quote it"; prompt="$1"; shift ;;
    esac
  done
  sweep_cleaned
  if [ -n "$pfile" ]; then
    [ -z "$prompt" ] || die "give either a prompt or --prompt-file"
    [ -f "$pfile" ] || die "no file $pfile"
    prompt="$(cat "$pfile")"
  fi
  [ -n "$prompt" ] || die 'run needs a prompt: agentic run "..." or --prompt-file F'
  [[ "$model" != *[[:cntrl:]]* ]] || die "--model must be one line without control characters"
  local img; img="$(run_image)"
  [ -n "$agent" ] || agent="$(image_label "$img" agentic.harness)"
  agent="${agent:-claude}"
  case "$agent" in claude|copilot) ;; *) die "--agent must be claude or copilot" ;; esac
  for a in ${allow[@]+"${allow[@]}"}; do valid_grant "$a" || die "unknown --allow $a (push, open-pr, deploy:<target>)"; done
  [ -n "$id" ] || id="$(new_task_id)"
  valid_task_id "$id" || die "the task id must match [A-Za-z0-9._-]+"
  [ ! -e "$(task_dir "$id")" ] || die "task $id exists"
  local work tname branch=""
  work="$(task_work "$target")" || exit 1
  tname="${work#/work}"; tname="${tname#/}"
  if [ "$worktree" = 1 ]; then branch="${AGENTIC_BRANCH_PREFIX:-agentic/}$id-$(task_slug "$prompt")"; fi
  local c created=1 creator="$id"
  if [ -n "$in" ]; then
    need_task "$in"
    c="$(task_container "$in")"; creator="$(task_creator "$in")" || die "task $in has no container record"; created=0
    case "$(container_status "$in")" in
      missing) die "task $in has no container" ;;
      unknown) die "docker did not answer for task $in" ;;
      running) ! bridge_running "$c" || die "a task runs in the container of $in; one task at a time per container (stop it first)" ;;
    esac
  else
    c="$(task_container "$id")"
  fi
  check_cap

  # Everything that can refuse (the .env file, a missing mount source) runs before anything is created.
  local p ws dir data port v extra=()
  p="$(task_project)"; ws="$(task_ws)"; dir="$(task_dir "$id")"
  RUN_ARGS=()
  if [ "$created" = 1 ]; then project_run_args "$img"; fi
  v="$(dotenv_value "$(project_root)/.agentic/.env" AGENTIC_GATE)"
  if [ -n "$v" ] && [ "$v" != 1 ]; then say "warning: .agentic/.env sets AGENTIC_GATE=$(printf '%s' "$v" | plain): the gate is off for every task"; fi

  # From here any failure, die or signal removes what was created (unless --keep-on-failure).
  RUN_ROLLBACK_ID="$id"; RUN_KEEP="$keep"
  trap run_cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
  mkdir -p "$dir/home/claude" "$dir/home/copilot" "$ws/events"
  (umask 077; mkdir -p "$(task_hdir "$id")")
  for v in "${TASK_HOST_FILES[@]}"; do rm -f -- "$(task_file "$id" "$v")"; done
  printf '%s\n' "$prompt" > "$dir/prompt.md"
  (umask 077; printf '%s\n%s\n%s\n' "$c" "$created" "$creator" > "$(task_file "$id" container)")
  (umask 077; {
    printf 'AGENTIC_TASK_TOKEN=%s\nAGENTIC_AGENT_TOKEN=%s\n' "$(new_token)" "$(new_token)"
    printf 'AGENTIC_TASK_ID=%s\nAGENTIC_TASK_DIR=/tasks/%s\nAGENTIC_PROJECT=%s\nAGENTIC_AGENT=%s\nAGENTIC_MODEL=%s\n' "$id" "$id" "$p" "$agent" "$model"
    printf 'AGENTIC_WORK=%s\nAGENTIC_TARGET=%s\nAGENTIC_CONTAINER=%s\nAGENTIC_CREATED_CONTAINER=%s\n' "$work" "$tname" "$c" "$created"
    printf 'AGENTIC_ALLOWED_ACTIONS=%s\nAGENTIC_WORKTREE=%s\nAGENTIC_BRANCH=%s\nAGENTIC_AUTO_CLEAN=%s\n' \
      "$(IFS=,; echo "${allow[*]+"${allow[*]}"}")" "$worktree" "$branch" "$autoclean"
    for v in AGENTIC_IDLE_TIMEOUT AGENTIC_NOTIFY_WEBHOOK AGENTIC_GATE_PROTECTED; do
      if [ -n "${!v:-}" ]; then printf '%s=%s\n' "$v" "${!v}"; fi
    done
  } > "$(task_file "$id" env)")
  host_file "$id" env >/dev/null || die "the env file of $id is not a regular file"
  if [ "$created" = 1 ]; then
    data="$AGENTIC_DATA/projects/$p/harness"
    for v in claude/.credentials.json copilot/config.json; do
      if [ -f "$data/$v" ] && [ ! -L "$data/$v" ]; then (umask 077; read_agent_file "$data/$v" > "$dir/home/$v"); fi
    done
    read -ra extra <<<"${AGENTIC_TASK_DOCKER_ARGS:-}"
    rm -f -- "$dir/.ready"
    docker run -d --init --name "$c" --cap-drop ALL --security-opt no-new-privileges --label agentic.kind=task --label "agentic.task=$id" \
      -p "127.0.0.1::$TASK_PORT" "${RUN_ARGS[@]}" -v "$ws/tasks:/tasks" -v "$ws/events:/events" -e "AGENTIC_TASK_DIR=/tasks/$id" \
      ${extra[@]+"${extra[@]}"} "$img" agentic-task-hold >/dev/null || die "docker run failed for $id"
    wait_ready "$id" "${AGENTIC_START_TIMEOUT:-120}" || {
      docker logs --tail 20 "$c" 2>&1 | plain >&2 || true
      die "the container of $id did not finish its start; see agentic logs $id --start"
    }
  elif [ "$(container_status "$id")" != running ]; then
    start_container "$id"
  fi
  start_bridge "$id"
  if ! wait_bridge "$id" "${AGENTIC_START_TIMEOUT:-120}"; then
    # the bridge's own reason, before the rollback removes the task directory
    for v in bridge.log bridge.out; do
      if task_readable "$id" "$v" && [ -s "$dir/$v" ]; then { echo "$v:"; task_read "$id" "$v" | tail -n 20 | plain; } >&2; fi
    done
    die "the bridge of $id did not come up"
  fi
  RUN_ROLLBACK_ID=""; trap - EXIT INT TERM
  port="$(task_port "$id")"
  if [ "$json" = 1 ]; then
    jq -cn --arg t "$id" --arg c "$c" --arg p "$port" --arg tg "$tname" --arg b "$branch" \
      '{task: $t, container: $c, port: $p, target: (if $tg == "" then null else $tg end), branch: (if $b == "" then null else $b end)}'
  else
    echo "$id"
  fi
  echo "follow: agentic follow $id" >&2
}
```

`sweep_cleaned` belongs to Task 7. Until then, define it in `lib/host/task.sh` as an empty function
with its final comment (`sweep_cleaned() { :; }`), so that `cmd_run` runs.

`usage`: replace the `run` line with:

```
  run "prompt" [--target T] [--in ID] [--worktree] [--auto-clean] [--agent A] [--allow push|open-pr|deploy:T]... [--id ID] [--json]
                                     start a detached task in a new container (or in task ID's); prints its id
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/bats/cli-task-run.bats tests/bats/cli-run.bats tests/bats/cli-core.bats && shellcheck -x bin/agentic lib/host/*.sh`
Expected: PASS.

- [ ] **Step 6: Run the whole suite and lint**

Run: `make test && make lint`
Expected: PASS. `cli-task-verbs.bats` may fail where it depends on `read_mounts` or the clean of
repos files. If so, mark those tests `skip "rewritten in Task 7"` and commit; Task 7 replaces them.

- [ ] **Step 7: Commit**

```bash
git add lib/host bin/agentic tests/bats
git commit -m "feat: run creates or reuses a task container with the checkout at /work and starts the bridge by docker exec; host mirror, clone and worktree code removed"
```

---

### Task 7: The task verbs: stop, resume, takeover, follow, clean, and the auto-clean sweep

**Files:**
- Modify: `bin/agentic` (`cmd_stop`, `cmd_takeover`, `cmd_follow`, `cmd_clean`, `cmd_status`,
  `usage`), `lib/host/task.sh` (`sweep_cleaned`)
- Test: `tests/bats/cli-task-verbs.bats`, `tests/bats/cli-task-run.bats`

**Interfaces:**
- Consumes: everything Task 6 produced.
- Produces: `sweep_cleaned` (removes the auto-cleaned tasks of the project).

- [ ] **Step 1: Write the failing tests**

In `tests/bats/cli-task-verbs.bats`:

1. In `setup()`, write `layout: single` as in Task 6.
2. In `record()`, write the container file and the readiness path, and drop the `mounts` line:

   ```bash
   printf 'agentic-demo-task-%s\n1\n%s\n' "$1" "$1" > "$H/$1/container"
   printf 'AGENTIC_WORK=/work\n' >> "$H/$1/env"
   echo "$T/$1/.ready" > "$BATS_TEST_TMPDIR/docker.ready"
   ```

3. Delete these tests:
   - "takeover stops the task and resumes its session interactively, gate on"
   - "clean refuses unpushed commits unless forced, then removes everything but remote branches"
   - "clean refuses uncommitted changes, a git error and a missing repos file; --force proceeds"
   - "clean takes the branch from the repos file as a revision, never as an option"
   - "clean of a clean, pushed-nowhere-but-unchanged task succeeds"
   - "clean refuses a running task unless forced, then stops it first"
   - "takeover refuses a mounts file with anything the host does not write"
   - "takeover refuses a mounts source through a symlink and drops every capability"

   Also replace "stop asks the bridge, then waits for the container; without an answer it stops
   the container".
4. Add:

```bash
@test "stop asks the bridge to stop, then stops the container; without an answer it stops the container" {
  record T-1 running
  AGENTIC_STOP_TIMEOUT=1 run ag stop T-1
  [ "$status" -eq 0 ]
  [[ "$(posted)" == *"/stop"* ]]
  grep -qx agentic-demo-task-T-1 <<<"$(docker_sub stop)"
  : > "$DOCKER_LOG"
  CURL_RC=7 AGENTIC_STOP_TIMEOUT=1 run ag stop T-1
  [[ "$output" == *"did not answer"* ]]
  grep -qx agentic-demo-task-T-1 <<<"$(docker_sub stop)"
}

@test "resume starts the bridge again in the running container when it died" {
  record T-1 running
  DOCKER_BRIDGE_RC=1 run ag resume T-1
  [ "$status" -eq 0 ]
  grep -qx -- "$H/T-1/env" <<<"$(docker_call_with exec agentic-task-start)"
  [ -z "$(docker_sub start)" ]
  [[ "$(posted)" == *"/prompt"* ]]
}

@test "resume of a task whose container stopped starts it, waits for its start, then the bridge" {
  record T-1 running
  DOCKER_STATUS=exited DOCKER_BRIDGE_RC=1 run ag resume T-1
  [ "$status" -eq 0 ]
  grep -qx agentic-demo-task-T-1 <<<"$(docker_sub start)"
  [ -n "$(docker_call_with exec agentic-task-start)" ]
  DOCKER_STATUS=exited DOCKER_NO_READY=1 AGENTIC_START_TIMEOUT=1 run ag resume T-1
}

@test "takeover stops the bridge and resumes the session in the task's container and directory" {
  record T-1 idle
  printf 'AGENTIC_WORKTREE=1\nAGENTIC_BRANCH=agentic/T-1-x\n' >> "$H/T-1/env"
  AGENTIC_STOP_TIMEOUT=1 run ag takeover T-1
  [ "$status" -eq 0 ]
  [[ "$(posted)" == *"/stop"* ]]
  ex="$(docker_call_with exec claude)"
  for l in -w /work/.worktrees/T-1 -e AGENTIC_TASK_DIR=/tasks/T-1 agentic-demo-task-T-1 --dangerously-skip-permissions --resume s1; do
    grep -qx -- "$l" <<<"$ex"
  done
  [ -z "$(docker_sub run)" ]
}

@test "follow passes the task token through the host env file" {
  record T-11 idle
  ag follow T-11 --since 3
  call="$(docker_call_with exec follow)"
  grep -qx -- --env-file <<<"$call"; grep -qx -- "$H/T-11/env" <<<"$call"
  [ "$(tail -n 5 <<<"$call" | tr '\n' ' ')" = "agentic-demo-task-T-11 agentic-bridge follow --since 3 " ]
}

@test "clean of a task with a worktree removes it in the container, then the container and the files" {
  record T-1 stopped
  printf 'AGENTIC_WORKTREE=1\nAGENTIC_BRANCH=agentic/T-1-x\n' >> "$H/T-1/env"
  DOCKER_BRIDGE_RC=1 run ag clean T-1
  [ "$status" -eq 0 ]
  wt="$(docker_call_with exec /opt/agentic/task/worktree.sh)"
  for l in agentic-demo-task-T-1 remove /work T-1 agentic/T-1-x; do grep -qx -- "$l" <<<"$wt"; done
  ! grep -qx -- --force <<<"$wt"
  grep -qx agentic-demo-task-T-1 <<<"$(docker_sub rm)"
  [ ! -e "$T/T-1" ] && [ ! -e "$H/T-1" ]
}

@test "clean refuses unpushed work unless forced" {
  record T-1 stopped
  printf 'AGENTIC_WORKTREE=1\nAGENTIC_BRANCH=agentic/T-1-x\n' >> "$H/T-1/env"
  DOCKER_BRIDGE_RC=1 DOCKER_WT_ERR="agentic-worktree: /work/.worktrees/T-1 has commits on no remote branch (agentic/T-1-x); push them, or clean with --force" \
    run ag clean T-1
  [ "$status" -eq 1 ]; [[ "$output" == *"has commits on no remote branch"* ]]
  [ -d "$T/T-1" ]
  : > "$DOCKER_LOG"
  DOCKER_BRIDGE_RC=1 run ag clean T-1 --force
  [ "$status" -eq 0 ]
  grep -qx -- --force <<<"$(docker_call_with exec /opt/agentic/task/worktree.sh)"
}

@test "clean without a worktree never touches /work; a reused container stays" {
  record T-1 stopped
  printf 'agentic-demo-task-T-0\n0\nT-0\n' > "$H/T-1/container"
  DOCKER_BRIDGE_RC=1 run ag clean T-1
  [ "$status" -eq 0 ]
  [ -z "$(docker_sub rm)" ]
  ! grep -q worktree.sh "$DOCKER_LOG"
}

@test "clean refuses a running task unless forced, and a container another task runs in" {
  record T-1 running
  run ag clean T-1
  [ "$status" -eq 1 ]; [[ "$output" == *"task T-1 is running; run agentic stop T-1 first, or --force"* ]]
  record T-2 stopped
  run ag clean T-2
  [ "$status" -eq 1 ]; [[ "$output" == *"another task runs in the container of T-2; stop it first"* ]]
  [ -d "$T/T-2" ]
}
```

In `tests/bats/cli-task-run.bats`, add:

```bash
@test "status removes auto-cleaned tasks whose container has exited, and keeps the others" {
  record T-1 stopped; jq '.cleaned = true' "$T/T-1/state.json" > "$T/x" && mv "$T/x" "$T/T-1/state.json"
  record T-2 stopped
  DOCKER_STATUS=exited run ag status
  [ "$status" -eq 0 ]
  [ ! -e "$T/T-1" ] && [ ! -e "$H/T-1" ]
  [ -d "$T/T-2" ]
  grep -qx agentic-demo-task-T-1 <<<"$(docker_sub rm)"
}

@test "a forged cleaned flag never removes a task whose created container still runs" {
  record T-1 idle; jq '.cleaned = true' "$T/T-1/state.json" > "$T/x" && mv "$T/x" "$T/T-1/state.json"
  run ag status
  [ "$status" -eq 0 ]
  [ -d "$T/T-1" ]
  [ -z "$(docker_sub rm)" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/bats/cli-task-verbs.bats tests/bats/cli-task-run.bats`
Expected: the new tests FAIL.

- [ ] **Step 3: Implement**

`lib/host/task.sh`, replace the empty `sweep_cleaned`:

```bash
# sweep_cleaned: removes the project's auto-cleaned tasks (the bridge marked the record cleaned).
# The record is agent-writable: a task whose created container still runs (or whose state docker
# cannot tell) is kept, and rollback_task takes the container from the host file only.
sweep_cleaned() {
  local f id
  for f in "$(task_ws)"/tasks/*/state.json; do
    { [ -f "$f" ] && [ ! -L "$f" ]; } || continue
    id="$(basename "$(dirname "$f")")"
    valid_task_id "$id" || continue
    [ "$(record_get "$id" .cleaned)" = true ] || continue
    if task_created "$id"; then
      case "$(container_status "$id")" in running|unknown) continue ;; esac
    fi
    rollback_task "$id"
  done
}
```

`bin/agentic`:

`cmd_status`: call `sweep_cleaned` after `need_config` in the project branch (not for `--all`
and not for a single id).

```bash
cmd_stop() {
  need_config; need_task "${1:-}"
  local id="$1" c; c="$(task_container "$1")"
  if [ "$(task_state "$id")" = stopped ]; then echo "$id: stopped"; return 0; fi
  ensure_running "$id"
  if bridge_req "$id" POST /stop; then
    [[ "$BRIDGE_CODE" == 2* ]] || bridge_result "$id"
    wait_bridge_gone "$c" "${AGENTIC_STOP_TIMEOUT:-30}" || say "the bridge of $id did not end; stopping its container"
  else
    say "the bridge of $id did not answer; stopping its container (the task will show interrupted)"
  fi
  docker stop "$c" >/dev/null || die "could not stop the container of $id"
  echo "$id: $(task_state "$id" | plain)"
}

cmd_follow() {
  need_config
  local id="${1:-}" envf; [ -n "$id" ] || die "usage: agentic follow ID [--since N] [--raw] [--forever]"
  shift; need_task "$id"
  [ "$(container_status "$id")" = running ] || die "task $id is $(task_state "$id" | plain); agentic logs $id shows its transcript"
  envf="$(host_file "$id" env)" || die "the env file of $id is not a regular file"
  # The token reaches the client through the host env file; none goes on a command line.
  local tty=(-i); if [ -t 0 ] && [ -t 1 ]; then tty=(-it); fi
  docker exec "${tty[@]}" --env-file "$envf" "$(task_container "$id")" agentic-bridge follow "$@"
}

cmd_takeover() {
  need_config; need_task "${1:-}"
  local id="$1" agent session c envf work argv=() tty=(-i)
  agent="$(record_get "$id" .agent)"; session="$(record_get "$id" .session)"; c="$(task_container "$id")"
  envf="$(host_file "$id" env)" || die "the env file of $id is not a regular file"
  [ -n "$session" ] || die "task $id has no session yet"
  case "$agent" in
    claude) argv=(claude --dangerously-skip-permissions --resume "$session") ;;
    copilot) argv=(copilot --allow-all "--resume=$session") ;;
    *) die "task $id has an unknown agent '$agent'" ;;
  esac
  # the directory from the host's own file, never from the record
  work="$(dotenv_value "$envf" AGENTIC_WORK)"
  if task_has_worktree "$id"; then work="$work/.worktrees/$id"; fi
  case "$(container_status "$id")" in
    running)
      if bridge_running "$c"; then
        bridge_req "$id" POST /stop >/dev/null 2>&1 || true
        wait_bridge_gone "$c" "${AGENTIC_STOP_TIMEOUT:-30}" || docker exec "$c" pkill -f 'bridge/dist/main\.js$' >/dev/null 2>&1 || true
      fi ;;
    missing) die "task $id has no container" ;;
    *) start_container "$id" ;;
  esac
  if [ -t 0 ] && [ -t 1 ]; then tty=(-it); fi
  echo "Taking over $id with $agent; the task stays stopped afterwards." >&2
  # docker exec skips the start's environment, so load the harness homes first.
  docker exec "${tty[@]}" -w "$work" -e "AGENTIC_TASK_DIR=/tasks/$id" "$c" \
    bash -c '[ ! -f "$HOME/.agentic/env" ] || . "$HOME/.agentic/env"; exec "$@"' bash "${argv[@]}"
}

cmd_clean() {
  need_config
  local id="" force=0 a c out
  for a in "$@"; do case "$a" in --force) force=1 ;; -*) die "unknown option $a" ;; *) id="$a" ;; esac; done
  need_task "$id"
  c="$(task_container "$id")"
  if [[ " $TASK_ACTIVE " == *" $(task_state "$id") "* ]]; then
    [ "$force" = 1 ] || die "task $id is running; run agentic stop $id first, or --force"
    bridge_req "$id" POST /stop >/dev/null 2>&1 || true
    wait_bridge_gone "$c" "${AGENTIC_STOP_TIMEOUT:-30}" || docker exec "$c" pkill -f 'bridge/dist/main\.js$' >/dev/null 2>&1 || true
  fi
  if task_created "$id" && [ "$(container_status "$id")" = running ] && bridge_running "$c"; then
    die "another task runs in the container of $id; stop it first"
  fi
  if task_has_worktree "$id"; then
    case "$(container_status "$id")" in
      running) ;;
      missing)
        [ "$force" = 1 ] || die "the container of $id is gone, so its worktree cannot be checked; run agentic clean $id --force"
        say "the container of $id is gone: remove .worktrees/$id and its branch in the checkout by hand" ;;
      *) start_container "$id" ;;
    esac
    if [ "$(container_status "$id")" = running ]; then
      if [ "$force" = 1 ]; then out="$(worktree_cmd "$id" remove --force 2>&1)" || die "$(printf '%s' "$out" | plain | tail -n 1)"
      else out="$(worktree_cmd "$id" remove 2>&1)" || die "$(printf '%s' "$out" | plain | tail -n 1 | sed 's/^agentic-worktree: //')"
      fi
    fi
  fi
  rollback_task "$id"
  echo "$id: removed (remote branches stay)"
}
```

`usage`: `clean ID [--force]` reads "remove what the task created: worktree and branch, its container, its files".

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/bats/cli-task-verbs.bats tests/bats/cli-task-run.bats && shellcheck -x bin/agentic lib/host/task.sh`
Expected: PASS. Remove any `skip "rewritten in Task 7"` left from Task 6 and make those tests pass
or delete them when a test above replaces them.

- [ ] **Step 5: Run the whole suite and lint**

Run: `make test && make lint`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/agentic lib/host/task.sh tests/bats
git commit -m "feat: stop, resume, takeover, follow and clean work on a container that outlives its bridge; clean removes the worktree in the container; status sweeps auto-cleaned tasks"
```

---

### Task 8: Docs, the architecture rule and the smoke test

**Files:**
- Modify: `CLAUDE.md`, `docs/architecture.md`, `docs/tasks.md`, `docs/detached-mode.md`,
  `README.md` (task lines if any), `tests/image/smoke.sh`,
  `tests/fixtures/smoke-project/.agentic/agentic.yaml`

**Interfaces:**
- Consumes: the whole feature.

- [ ] **Step 1: The architecture rule**

`CLAUDE.md`, under `## Rules`, add as the first bullet:

```
- The host CLI is a thin relay: it builds images, starts and stops containers, passes mounts and
  env, and relays requests to the bridge. It never works on the project (no git, clone, branch,
  worktree or build on the host); workflow rules live in the container.
```

`docs/architecture.md`:
- Under `## Principles`, add the same rule as a bullet, beginning **Thin host.**.
- In `## Components`, the CLI bullet gets: "It never runs git on the project; a task's worktree is
  made in its container."
- The Task files bullet gets: "under the workspace (`/tasks/<id>` in the task containers)".

- [ ] **Step 2: `docs/tasks.md` and `docs/detached-mode.md`**

`docs/tasks.md`:
- **Quick start:** use `agentic run --worktree --allow open-pr "…"`, and show `clean` as
  "worktree and branch, container, record".
- **Run options:** replace the options paragraph with the `run` line of the usage. Explain each
  option in one sentence: `--target`, `--in ID`, `--worktree`, `--auto-clean`. Remove
  `--repo`, `--base` and `--branch`.
- **A new section "Tasks and containers":**
  - A task is identified by its id; it runs in a container.
  - `run` creates `agentic-<project>-task-<id>`, set up like the dev container: the checkout at
    `/work`, the setup lines and the full start. Its command is `agentic-task-hold`.
  - The bridge is started with `docker exec` and writes to `/tasks/<id>`.
  - `--in ID` runs a new task in that task's container, one task at a time.
  - The container is kept until `clean`. `stop` stops it, and `resume` starts it again,
    followed by the bridge.
  - The host-private files are `env`, holding the tokens and the bridge's settings, and
    `container`.
- **Threat model:**
  - The checkout and its `.git` are writable by the task, as in dev mode.
  - The project's task containers share `/tasks`, so one task's agent can write another task's
    record. The host takes the container and the work directory only from its own files.
  - The host runs no git in the checkout except reading the user's identity. Delete the
    paragraphs about mirrors, clone hardening and throwaway git containers.

`docs/detached-mode.md`: update the how-to commands the same way. For each removed option,
`grep -n -- '--repo\|--base\|--branch\|mirror\|repos/' docs/*.md README.md` must find no leftover
mention outside `docs/specs/` and `docs/plans/`.

- [ ] **Step 3: The smoke test**

`tests/fixtures/smoke-project/.agentic/agentic.yaml`: add `layout: single` after `project:`.

`tests/image/smoke.sh`, section "detached tasks through bin/agentic":
- Give the project an origin the task can push to, mounted at the same path:

  ```bash
  git clone -q --bare "$proj" "$tmp/origin.git"
  git -C "$proj" remote add origin "$tmp/origin.git"
  export AGENTIC_TASK_DOCKER_ARGS="-v $tmp/origin.git:$tmp/origin.git -v $root/bridge/test:/fake:ro -e AGENTIC_ACP_CMD=[\"node\",\"/fake/fake-agent.mjs\"] -e FAKE_AGENT_STATE=/home/dev/fake -e FAKE_ASK=cli"
  ```

- `wait_exited` becomes `wait_suspended ID` (state `suspended`, container still running).
- The first task runs with `--worktree`. After the granted push, check
  `git --git-dir="$tmp/origin.git" rev-parse -q --verify "refs/heads/$(jq -r .branch "$tasks/$id/state.json")"`.
- Replace the "clone's config read-only" exec with a check that the worktree exists:
  `[ -d "$proj/.worktrees/$id" ]`.
- Delete the planted-symlink block (FETCH_HEAD, packed-refs, `.git/worktrees`) and the
  mirror/mounts checks.
- Task 2 (`docker kill` → interrupted → resume): unchanged except the container name, which is
  `agentic-smoke-project-task-$id2`.
- Add:

  ```bash
  id3="$(ag run --in "$id2" "third")"   # after ag stop "$id2"
  wait_state "$id3" idle || fail "task 3: --in"
  [ "$(sed -n 1p "$AGENTIC_DATA/projects/smoke-project/tasks/$id3/container")" = "agentic-smoke-project-task-$id2" ] || fail "task 3: not in task 2's container"
  ag stop "$id3" >/dev/null

  id4="$(ag run --auto-clean "fourth")"
  for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Status}}' "agentic-smoke-project-task-$id4" 2>/dev/null)" = exited ] && break; sleep 1; done
  ag status >/dev/null
  [ ! -e "$tasks/$id4" ] || fail "task 4: auto-clean left the record"
  [ -z "$(docker ps -aq --filter "name=agentic-smoke-project-task-$id4")" ] || fail "task 4: auto-clean left the container"
  ```

- Multi layout, from the base image without a build (`run` falls back to the base):

  ```bash
  mp="$tmp/multi-project"; mkdir -p "$mp"
  for r in api web; do git init -q "$mp/$r"; git -C "$mp/$r" -c user.name=s -c user.email=s@example.com commit -q --allow-empty -m init; done
  (cd "$mp" && "$A" init --bare >/dev/null)
  (cd "$mp" && "$A" target api >/dev/null)
  idm="$(cd "$mp" && "$A" run "hello")"
  # wait as wait_state does, from $mp
  ```

  Assert that `jq -r .work` of its record is `/work/api`, then `clean` it.
- At the end: `ag clean "$id" --force`, `ag clean "$id2"` and `ag clean "$id3"`. Assert that
  `[ ! -e "$proj/.worktrees/$id" ]` and that no container with the project label is left.

- [ ] **Step 4: Run everything**

Run: `tools/leak-check.sh && make test && make lint && make smoke`
Expected: all PASS. If the smoke test fails, fix the cause in the task code, not by loosening the
assertion.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs README.md tests/image/smoke.sh tests/fixtures/smoke-project/.agentic/agentic.yaml
git commit -m "docs: the thin-host rule; tasks and containers, run options, threat model; smoke covers worktree, --in, auto-clean and a multi-repository project"
```
