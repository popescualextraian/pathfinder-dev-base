# CLAUDE.md — agentic-dev-base

A generic container toolbox for agentic development: base image, per-project derived image from
`.agentic/agentic.yaml`, start steps, host CLI. Design: `docs/architecture.md`; specs in
`docs/specs/`; plans in `docs/plans/`.

## Rules

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

    make test     # bats and the bridge's vitest (needs bats, jq, yq v4, Node 22)
    make lint     # shellcheck, schema, generated docs, leak check, tsc and eslint
    make build    # base image agentic-dev-base:local
    make smoke    # build, then tests/image/smoke.sh (Docker, openssl, script)

Every change needs `make test` and `make lint` green; a change under `image/`, `derive/`,
`config/` or `schema/` also needs `make smoke`.
