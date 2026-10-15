# CLAUDE.md — agentic-dev-base

A generic container toolbox for agentic development: base image, per-project derived image from
`.agentic/agentic.yaml`, start steps, host CLI. Design: `docs/architecture.md`; specs in
`docs/specs/`; plans in `docs/plans/`.

## Rules

- The host CLI is a thin relay: it builds images, starts and stops containers, passes mounts and
  env, and relays requests to the bridge. It never works on the project (no git, clone, branch,
  worktree or build on the host); workflow rules live in the container.
- No company resources in this repository: no certificates, company names, hosts, URLs or
  product-specific integrations. Examples use `example.com`. `make lint` runs
  `tools/leak-check.sh` against your private denylist (`~/.config/agentic/leak-denylist.txt`).
- Company-specific pieces belong in a downstream overlay image built `FROM` the base
  (`docs/overlay.md`), never here.
- No secret in an image layer, `~/.claude.json`, `~/.agentic/env` or a log.
- bash style: `set -euo pipefail`, short comments, shellcheck-clean, a bats test for every
  behaviour, written first.
- TypeScript (`bridge/`): strict tsc, eslint clean, a vitest test for every behaviour, written
  first; dependencies pinned exactly with the lockfile committed; nothing fetched with `npx` or at
  run time.
- No `Co-Authored-By` or other attribution lines in commits. Remote `origin` is public GitHub;
  push only `main`, only when asked.

## Commands

    make test     # bats and the bridge's vitest (needs bats, jq, yq v4, python3 with jsonschema, Node 22)
    make lint     # shellcheck, schema, generated docs, leak check, tsc and eslint
    make build    # base image agentic-dev-base:local
    make smoke    # build, then tests/image/smoke.sh (Docker, openssl, script)

What to run depends on what changed:

- Docs only (`*.md` outside `skills/`): `tools/leak-check.sh`; add `tools/gen-config-docs.sh --check`
  if you touched docs/configuration.md or the schema. No tests.
- While iterating: the bats files for what you touch (`bats tests/bats/cli-init.bats`),
  `shellcheck -x` on the changed scripts, `cd bridge && npm test` for bridge changes.
- Before committing code: `make test` and `make lint`, once.
- Under `image/`, `derive/`, `config/` or `schema/`: also `make smoke`.
