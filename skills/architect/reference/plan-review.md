# Plan mode: reviewing a plan against the architecture

Plan mode reads a plan or spec and the doc, writes `docs/architecture/reviews/plans/<slug>.json`
and prints a short summary. It is advisory: it never blocks, never edits the plan, and never asks
a question inside a detached task.

## Procedure

1. Read the plan file. It need not be in the repository; record its repository path in `plan`, or
   a short note ("pasted in chat") when it has none.
2. Read `architecture.md`, `model.json` (component ids, parts, layers, modules), the pages of the
   components the plan names or implies, and the catalog entries for the doc's principles and
   patterns. Note `git rev-parse HEAD` as `baseCommit`.
3. Changes: for each component the plan touches, one entry `new`, `changed` or `removed` with one
   line saying what happens to it. Match the plan's wording to existing components by their
   sources and summaries; a component the plan creates is `new` and carries `proposed`
   (`name`, `part`, `layer`, `summary`, and `module` and `talks_to` when they apply; `part` is
   required even in a one-part project).
4. Rule check, in the manner of a constitution check: take each principle of `architecture.md` in
   order, each rule of its body, the style's implied rules, the layers' `mayUse`, the boundaries
   and the patterns. For each, decide whether the plan breaks it. A break becomes a finding with
   the rule, why the plan breaks it (`text`) and the simpler alternative (`alternative`). A rule
   checked without a break goes into `passed`.
5. Drop nothing silently: when a break matches an id in `exceptions`, keep the finding with status
   `accepted`.
6. Size, as a rule of thumb:
   - **S**: one or two components changed, one layer, one module, no new component.
   - **M**: up to about six components, or a new component, or two layers or two modules.
   - **L**: more than that, a new module or part, or a change to the layers or boundaries.
7. Write the JSON, run `agentic-arch check` and fix what it reports.
8. Print the summary: size, one sentence, the changes (one line each), the open findings with
   their alternative, and how to accept one (`accept <finding-id> "<reason>"`).

## Finding ids

`<rule>/<component>/<slug>`: the rule id (a principle id such as `dry`, `layers`, `boundaries`, or
the slug of a body rule), the component the break sits in (a new one by its proposed id), and a
short kebab-case slug of the break, without line numbers or plan step numbers, for example
`layers/order-views/calls-orders-client-directly`. The same break found again gets the same id.

## The plan slug

The plan file's name without its extension (`docs/plans/2026-10-20-gift-cards.md` gives
`2026-10-20-gift-cards`); when there is no file, a kebab-case slug of the plan's title. A second
review of the same plan overwrites the file.

## The JSON

All fields are required; `schema/plan-review.schema.json` is the truth.

- `version`: 1; `kind`: `"plan"`; `title`: the plan's title.
- `plan`: the repository path of the plan, or a note.
- `baseCommit`: HEAD when the model was read; `reviewedAt`: ISO 8601 UTC, e.g. `2026-10-22T14:05:00Z`.
- `size`: `S`, `M` or `L`; `summary`: one sentence.
- `changes`: `[{component, change, line, proposed}]`; `proposed` only and always for `new`.
- `findings`: `[{id, rule, component, severity, text, alternative, status}]`; severity `error`,
  `warn` or `info` (start from the principle's default severity in the catalog); status `open`
  or `accepted`.
- `passed`: the rule ids checked without a break.

Every component id is in the model or is a `new` change with `proposed`; `check` rejects others.
