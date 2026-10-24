# Review mode: the code against the architecture

Review mode writes `docs/architecture/reviews/full.json`. Deterministic tools run first; then you
read the code for what they cannot see.

## Scope

- Incremental (the default): read the previous `reviews/full.json`. For each component, the commit
  it was last reviewed at is `components.<id>.reviewedAt`. Run
  `agentic-arch affected <last-commit>..HEAD` from the oldest of those commits (or the review's
  `commit`) and review only the components it lists whose sources changed since their own commit.
  Components missing from `components` are reviewed in full.
- `--full`, or no previous review, or a changed `architecture.md` (layers, rules, boundaries):
  review every component.

## 1. Deterministic checks

1. `agentic-arch build` so the rules match the doc.
2. `agentic-arch deps` (full) or `agentic-arch deps --affected <last-commit>` (incremental). Exit 1
   means findings, not failure; exit 2 means no TS/JS sources or no dependency-cruiser: say so in
   the summary and go on. Its findings keep their id and get `source: "depcruise"`.
   A file belongs to its longest owner. For a file owned only by a layer's `folders`, the layer id
   takes the component slot (`layers/<layer-id>/imports-<to>`, `component: <layer-id>`); `check`
   accepts it. A break from a file no component or layer owns (omitted or unclaimed) is not in the
   JSON: deps prints it on stderr and exits 1. Give that file an owner, or list the break in the
   summary.
3. Only when the project already has them in its own tooling: jscpd for DRY (copied blocks,
   `source: "jscpd"`) and knip for YAGNI (unused exports and files, `source: "knip"`). Never
   install them.

## 2. What tools cannot see

Read the sources of each component in scope against its page, `architecture.md` and the catalog:

- business logic in the API or integration layer;
- the same logic copied across components, such as one copy per database type instead of one
  service with an adapter per data source;
- a component doing two jobs, or a page whose purpose the code no longer matches;
- a pattern the doc names but the code ignores; a project rule the code breaks.

Each becomes a finding with `source: "llm"`, an id `<rule>/<component>/<slug>` and one sentence of
text naming the place and the simpler fix. Under-claim: report what you can show.

## 3. Merge

Start from the previous findings:

- found again: keep the finding, its id and its `since`;
- found for the first time: status `open`, `since` = HEAD;
- previously `open` and not found in a component that was in scope: status `fixed`;
- previously `fixed`: drop it (fixed findings are kept for one review only);
- out of scope this time: keep as it was;
- id in `exceptions` of `architecture.md`: status `accepted`, whatever was found. Never report
  an accepted finding as new.

## 4. Write

- `version`: 1; `kind`: `"full"`; `commit`: HEAD; `reviewedAt`: ISO 8601 UTC.
- `components`: every component of the model; `reviewedAt` is the HEAD sha for each one reviewed
  now, the previous value for the others.
- `findings`: `[{id, rule, component, severity, source, text, status, since}]`.

Run `agentic-arch check` and fix what it reports. A `warn:` about an exception that matches no
finding means the exception is stale; list it in the summary for a person to remove.

## 5. Summary

New findings first (with the fix), then fixed ones, then a count of accepted ones. Name what was
not checked (no TS/JS, no deps tool) so nobody reads silence as a pass.
