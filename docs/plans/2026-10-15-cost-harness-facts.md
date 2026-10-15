# Cost tracking: measured harness facts

Measured on 2026-10-15 in `agentic-dev-base:local` (Claude Code 2.1.300, Copilot CLI 1.0.98,
ccusage 20.0.32) with synthetic transcripts, `--network none`, no model tokens. The cost tracking
plan (`docs/plans/2026-10-15-cost-tracking.md`) relies on these facts; the fixtures under
`tests/fixtures/cost/` are the ones measured here.

## ccusage

- 20.0.32 is the Rust rewrite behind a Node shim (`@ccusage/ccusage-linux-x64`). npm's latest on the
  day was 20.0.34; we pin 20.0.32, the measured one.
- `ccusage claude session --json --offline --config FILE` and `ccusage copilot session ...` print
  `{sessions: [{sessionId, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
  totalTokens, totalCost, modelsUsed, modelBreakdowns: [{modelName, inputTokens, outputTokens,
  cacheCreationTokens, cacheReadTokens, cost}], firstActivity, lastActivity, projectPath}], totals}`.
  `inputTokens` excludes the cache.
- `--id` exists for Claude only, and its output has another shape (`entries[]`, no per-model split,
  every `costUSD` 0). Copilot has no `--id`. So the collectors list and select: 0.27 s on 380 MB
  of real transcripts (0.13 s with `--id`).
- `--offline` prices from the bundled table, also with no network; it knows `claude-opus-5-5`.
- `--config FILE` takes `{"defaults": {"pricingOverrides": {"<model>": {"inputCostPerToken": N,
  "outputCostPerToken": N}}}}`; `{}` is a valid empty file.

## Claude

- Data: `$CLAUDE_CONFIG_DIR/projects/<dir>/<session>.jsonl`. Real 2.1.300 lines (`requestId`,
  `message.id`, `message.usage` with `iterations[]`, `speed`) are counted.
- Lines repeated with the same `message.id`/`requestId` (up to 8 in real files) are counted once.
- `<session>/subagents/agent-*.jsonl` (its `sessionId` is the parent's) is added to the parent.
- `--resume` keeps the session id and file; `--fork-session` makes a new id.
- Hook payloads: `SessionStart` has `session_id, transcript_path, cwd, hook_event_name, source`;
  `SessionEnd` adds `reason, prompt_id`. `Stop` needs a model turn: not measured.
- Plugin hooks: `hooks/hooks.json`, `${CLAUDE_PLUGIN_ROOT}` set.

## Copilot

- `ccusage copilot` reads `$COPILOT_HOME/session-state/<id>/events.jsonl`; OTel is optional.
- A shut-down session: tokens from `session.shutdown` `tokenDetails`, priced per token from the
  LiteLLM table (an estimate, like Claude's).
- A session with no shutdown yet (only `session.usage_checkpoint`): 0 tokens, model `unknown`, and
  `totalNanoAiu` / 1e9 × $0.01 as its cost (3 196 233 000 nano-AIU → $0.03196233).
- `--resume=<id>` keeps the id; each shutdown is cumulative and ccusage takes the last one.
- Plugins: Copilot runs a plugin's Claude-format `hooks/hooks.json` (PascalCase events, nested
  `matcher/hooks`), sets `PLUGIN_ROOT`, `COPILOT_PLUGIN_ROOT` and `CLAUDE_PLUGIN_ROOT`, and passes
  snake_case payloads (`session_id`) to PascalCase events. In `-p` mode `sessionEnd` fires after
  every turn. From the changelog and the superpowers plugin seen firing; not fired here (needs a
  login).

## Not measured

A real Claude `Stop` payload and a real Copilot hook firing need a logged-in harness. Task 7 of the
plan checks both once by hand.
