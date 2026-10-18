# Cost tracking

What the agents of a project spend: per task, scheduled run and interactive session, per model and
day. Design: `docs/specs/2026-10-15-cost-tracking-design.md`.

## Install

`agentic init` adds two recommended lines; an existing project adds them with
`agentic add marketplace /opt/agentic/marketplace` and `agentic add plugin cost@agentic`:

```yaml
setup:
  - add marketplace /opt/agentic/marketplace
  - add plugin cost@agentic
```

After `agentic build` and `agentic dev recreate`, every Claude and Copilot session of the project,
interactive, task or scheduled, writes a snapshot after every turn and at its end. Delete the two
lines to stop.

## Read

```
agentic cost [--since D] [--until D] [--task ID] [--schedule NAME] [--by context|model|day] [--json]
```

`--by context` (the default) shows one line per task run, scheduled run, and `dev`; `--schedule
NAME` keeps the runs of one schedule.

- **EST. USD** is the list price of the tokens (ccusage, the LiteLLM table, offline). A
  subscription or a negotiated price bills differently; it is an estimate.
- **CREDITS USD** is Copilot AI credits of a session that has not shut down yet (1 credit = $0.01).
- **+?** marks tokens of a model without a price; `--by model` shows which. Add a price in
  `.agentic/cost/ccusage.json` (below).
- A session counts once, with its latest snapshot, in the window of that snapshot's day.
- A task counts every session of its container, not only the main one; **SESSIONS** says how many.
- Subagents count in the session that started them (ccusage adds them to their parent); there is no
  line per subagent.

The ledger is `$AGENTIC_WORKSPACES/<project>/cost/ledger.jsonl` on the host (`/cost` in every
container). It survives `clean` and recreation. It only grows: when `agentic cost` refuses it as
too large (64 MiB, `AGENTIC_COST_LEDGER_MAX`), move it aside and start a new one.

## Contracts

| Contract | Where | For |
|---|---|---|
| `cost-record/v1` | `schema/cost-record.schema.json` | one ledger line; what collectors produce |
| collector | `<collector> EVENT HARNESS`, payload on stdin, records on stdout | a harness ccusage does not read |
| `cost-summary/v1` | `schema/cost-summary.schema.json`; `image/cost/summary.jq` | `agentic cost --json`, a UI |

A UI or another reader runs `summary.jq` on the ledger (`jq -n -R -L image/cost -f
image/cost/summary.jq --arg project P --arg since "" --arg until "" --arg task "" --arg schedule ""
--arg by context < ledger.jsonl`; in a container the path is `/opt/agentic/cost`) or calls `agentic cost --json`. Adding an optional field or a
new `by` value keeps a version; anything else is v2.

## Extend

- **Another harness ccusage reads** (Codex, Gemini, opencode, …): only a hook, calling
  `/opt/agentic/cost/snapshot turn|end <harness>`; the generic collector does the rest.
- **A harness ccusage does not read:** an executable `.agentic/cost/collectors/<harness>` prints
  `cost-record/v1` lines for the session in the hook payload, without `project` and `context`.
  It also replaces the generic collector for a harness ccusage reads.
- **Prices:** `.agentic/cost/ccusage.json` is passed to ccusage as its config:
  `{"defaults": {"pricingOverrides": {"<model>": {"inputCostPerToken": 0.000003, "outputCostPerToken": 0.000015}}}}`.
- **Diagnostics:** `~/.agentic/cost.log` in the container says why a snapshot was not written.
