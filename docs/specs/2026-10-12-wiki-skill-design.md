# Wiki skill and the agent-context split

Status: draft for review, 2026-10-12. Umbrella: `docs/architecture.md`. Builds on sub-project 1
(base skills are copied into both harnesses by `60-skills`).

## 1. Outcome

Every project built on the base gets one skill, `/wiki`, and one script, `agentic-wiki`. Together
they give the agent the knowledge the code does not carry, and they decide where each piece of
that knowledge lives:

- **CLAUDE.md** is always loaded. It holds what is true for every task: what the project is, how
  to work, the commands, and the rules that apply everywhere.
- **Path rules** load when the agent touches a path. They hold instructions for one area.
- **Skills and templates** load on demand. They hold repeated procedures.
- **The wiki** in `docs/wiki/` is read on demand, through an index that is always loaded. It holds
  descriptions the code does not reveal: components and their boundaries, the whys, the ADRs, the
  contracts, the concepts and the business flows.

Without this, the agent falls back to its defaults. It re-implements a helper that already sits in
the shared module, puts logic in the wrong component, or breaks a contract it cannot see.

Success criteria:

- On a repository with no wiki, `/wiki seed` writes the wiki, a lean CLAUDE.md and the path rules,
  and `agentic-wiki check` passes.
- Every new session of either harness has the wiki index in context without being told to read it.
- After a change, `/wiki update` brings the affected pages in line with the diff in the same PR.
- The always-on context (CLAUDE.md plus the index) stays under 200 lines, and `check` enforces it.
- `make test`, `make lint` and `make smoke` pass.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| W1 | One skill, `wiki`, with modes. Detail lives in supporting files; mechanics live in a script. | Routing a fact needs all layers in view. Two skills would each keep content for itself. One description costs less always-on context. |
| W2 | The wiki lives in the project repository at the fixed path `docs/wiki/`. | It is versioned and reviewed with the code and present in every worktree and container without a mount. |
| W3 | The index is always loaded: `@docs/wiki/index.md` in CLAUDE.md for Claude, and a generated block in `.github/copilot-instructions.md` for Copilot. | Reading first is enforced by files, not by a prompt the agent may skip. |
| W4 | The index is fully generated. The skill writes pages, the script writes everything derived from them, and people only review. | Nothing is typed by hand, and nothing generated can drift. |
| W5 | Components are the core of the wiki. A component is a logical block with `sources` of any kind: code, IaC, config, migrations, pipelines. | Real responsibilities cross folder and language boundaries. |
| W6 | Contracts are a section of the component page that owns them. There is no separate interface tree. | A contract only makes sense next to its owner. This keeps it from growing into copied schemas. |
| W7 | Rules use each harness's native mechanism: `.claude/rules/<area>.md` with `paths:`, and a generated mirror in `.github/instructions/<area>.instructions.md` with `applyTo:`. | Both harnesses load them by path. One source of truth, mirrored by a script. |
| W8 | Copilot CLI reads the same root CLAUDE.md. `copilot-instructions.md` holds only the generated index block. | Copilot CLI reads CLAUDE.md natively but does not resolve `@` imports. |
| W9 | Lessons learned per task are a separate skill, outside this spec. Their landing place is the component's "Pitfalls" section. | Lessons have their own trigger (task end) and their own judgement. |

## 3. The routing test

The skill applies the test to every statement, in order. The first match decides.

1. **The code already says it, or a command prints it.** It goes nowhere; at most a pointer to the
   folder or the command. Examples: file trees, signatures, field lists, routes, environment
   variables, versions, step-by-step algorithms.
2. **A repeated procedure.** A skill or a template, plus one line in CLAUDE.md naming it.
3. **An instruction ("do", "never") that holds on every task, where removing it would cause
   mistakes.** CLAUDE.md.
4. **An instruction that matters only when certain paths are touched.** A path rule.
5. **A description ("is", "because") that the code does not reveal.** A wiki page.

Instructions go to CLAUDE.md or rules, descriptions to the wiki. When both are needed, the rule
states the instruction in one line and links the wiki page that explains it. The explanation never
sits in always-on context.

The test for a wiki sentence: would a senior engineer tell a new colleague this before they touch
the component, because an hour of reading the code would not reveal it? Under-claim rather than
over-claim. The code wins over the wiki.

| Knowledge | Goes to |
|---|---|
| Whys, ADRs | `decisions/` |
| Contracts | The owning component's "Contracts" section: that it is fixed, who relies on it, where its schema lives. "Never change it without versioning" is a path rule on its folder. |
| Architecture, components, responsibilities | `overview.md`, component pages, the generated map in `index.md` |
| Concept map | `concepts/` (cross-cutting ideas) and `glossary.md` (term → meaning → page) |
| Business flows | `flows/`: steps across components, naming components, not code |
| Shared code ("we have a commons module") | One line in CLAUDE.md naming the module and `docs/wiki/reuse.md`; `reuse.md` is generated from the components' `offers` |
| Project structure | Only the components' `sources` and the map. No tree, no folder tour. |
| Commands, how to work, git and PR rules | CLAUDE.md |
| Gotchas | For every task: CLAUDE.md. For one component: its "Pitfalls". Enforced for one area: a path rule. |
| Lessons from tasks | The affected component's "Pitfalls" (written by the lessons skill, W9) |

## 4. Layout in a project

```
CLAUDE.md                               always on; imports the index
.claude/rules/<area>.md                 path rules (paths:)
.github/instructions/<area>.instructions.md   generated mirror (applyTo:)
.github/copilot-instructions.md         generated index block only
docs/wiki/
  index.md            generated
  overview.md         what the system is and its main building blocks, ≤ 10 lines of body
  components/<id>.md  sub-components in components/<parent>/<id>.md
  decisions/adr-<n>.md
  decisions/index.md  generated list of ADRs
  concepts/<id>.md
  flows/<id>.md
  glossary.md
  reuse.md            generated
  omitted.yaml        paths deliberately owned by no component, each with a reason
```

A page id is its path under `docs/wiki/` without `.md`, for example `components/api` or
`decisions/adr-3`. Front matter refers to pages by id. Body links are ordinary relative Markdown
links, so they work on any git host, and `check` resolves them.

Generated content sits between `<!-- generated:<name>:start -->` and
`<!-- generated:<name>:end -->`. Fully generated files carry a first-line note that they are
generated by `agentic-wiki build`.

## 5. Pages

### 5.1 Component

```yaml
---
id: components/billing
kind: component
name: Billing
summary: Turns usage records into invoices and owns the payment provider integration.
parent: null                 # or the parent component's id
lifecycle: active            # active | migrating | retiring
status: draft                # draft | reviewed
sources:                     # folders or files of any kind
  - services/billing/
  - infra/billing.tf
  - db/migrations/billing/
depends_on: [components/accounts, concepts/money]
decisions: [decisions/adr-4]
offers:
  - name: format_money
    location: libs/common/money.py::format_money
    use: Format an amount with currency for display; never round by hand.
---
```

Body sections, each left out when empty:

- **Purpose and boundary:** what the component owns and what it must not do.
- **Where changes go:** the intended place for the two or three most common changes.
- **Contracts:** what it exposes or consumes that others rely on, whether it is fixed, and where the
  schema lives. No field lists.
- **Invariants:** what must stay true.
- **Why:** links to ADRs, local decisions, rejected alternatives.
- **Pitfalls:** known traps.
- **Outside the repo:** external systems and consumers.

Generated at the end: "Parts", the sub-components (the index lists only top-level components), and
"Used by", the reverse of other components' `depends_on`.

Limits, enforced by `check`: at most 80 lines; no table longer than 10 rows; no more than 10 lines
naming paths. A part gets its own page only when it has its own folder or file boundary.

### 5.2 Other kinds

| Kind | Front matter | Body |
|---|---|---|
| `decision` | `id`, `kind`, `title`, `status` (`proposed`, `accepted`, `superseded`), `superseded_by` | Context, Decision, Consequences |
| `concept` | `id`, `kind`, `name`, `summary`, `related` | A few paragraphs, ≤ 60 lines |
| `flow` | `id`, `kind`, `name`, `summary`, `components` | Trigger, steps naming components, outcome, failure paths; ≤ 60 lines |
| `overview` | `id: overview`, `kind: overview` | ≤ 10 lines |
| `glossary` | `id: glossary`, `kind: glossary` | One line per term: term, meaning, link |

### 5.3 The index

`agentic-wiki build` writes `index.md` from the pages:

1. A two-line header: what the wiki is, and "the code wins; never guess a page id".
2. The `overview.md` body.
3. The top-level components, one line each: link, name, summary. Sub-components appear on their
   parent's page.
4. Concepts and flows, one line each.
5. One line each linking `decisions/index.md`, `glossary.md` and `reuse.md`.

The index is at most 70 lines, so that with CLAUDE.md (at most 130 lines) the always-on context
stays under 200.

## 6. `agentic-wiki`

`image/bin/agentic-wiki`, bash with yq and jq. It runs from the repository root (or `-C <dir>`) and
needs nothing beyond the base image.

| Command | What it does |
|---|---|
| `build` | Writes `index.md`, `decisions/index.md`, `reuse.md` and the "Used by" blocks. |
| `sync` | Writes the `.github/instructions/` mirror of every `.claude/rules/*.md`, removes mirrors whose source is gone, and writes the index block into `.github/copilot-instructions.md`. |
| `check` | Validates; prints one line per problem; exits 1 if any. |
| `affected <base>..<head>` | Maps changed files to components by the longest matching `sources` entry. Prints `component <id> <file>`, `omitted <file>` and `unclaimed <file>` lines. |

`check` fails on:

- missing or invalid front matter, a wrong `kind`, or an `id` that does not match the path;
- a front matter reference or body link to a page that does not exist;
- a `sources` or `offers` location that does not exist in the repository;
- two components claiming the same `sources` entry;
- a page, the index or CLAUDE.md over its line limit, or a copied inventory (§5.1);
- generated files or blocks that differ from what `build` and `sync` would write;
- a rule without `paths:` (it belongs in CLAUDE.md);
- CLAUDE.md without the `@docs/wiki/index.md` line.

`check` runs only when `docs/wiki/` exists, so a project without a wiki is not affected.

## 7. The `/wiki` skill

`skills/wiki/` in this repository, copied into both harnesses by `60-skills`:

```
skills/wiki/
  SKILL.md               routing test, modes, guardrails (short)
  reference/routing.md   §3 in full, with examples per row
  reference/pages.md     §4 and §5: the page contract
  templates/             component, decision, concept, flow, overview, glossary, CLAUDE.md, rule
```

### 7.1 Modes

**`seed`** runs once per repository.

1. Read the code layout, the existing CLAUDE.md, AGENTS.md, rules, Copilot instruction files and
   `docs/`.
2. Define the components: logical blocks with their `sources` across code, IaC and config. Write
   `overview.md`.
3. Route every statement of the existing instruction files with the routing test.
4. Write the component, decision, concept and flow pages and the glossary from the templates, the
   lean CLAUDE.md and the path rules. Seeded pages are `status: draft`.
5. Run `agentic-wiki build`, `sync` and `check`, and fix every problem until `check` passes.
6. Summarise: pages written, statements moved (from → to), statements dropped because the code says
   them, and "Needs a human".

**`update [<base>..<head>]`** runs at the end of a task, before the PR, or as a catch-up over a
range. With no range it uses the merge base with the default branch.

1. Run `agentic-wiki affected`.
2. For each affected component, read the diff and its page. Correct only the claims the diff
   contradicts. Check `depends_on`, `offers` and `lifecycle` against the code. Add what the change
   decided: a boundary, a why, a new offer.
3. Each unclaimed file: add it to the owning component's `sources`, write a new component, or add it
   to `omitted.yaml` with a reason. A removed component loses its page and every link to it.
4. Route any new instruction the change introduced to CLAUDE.md or a rule.
5. Run `build`, `sync` and `check`. Summarise the changes, or print `wiki: no changes`.

**`add "<fact>"`** routes a single fact the user or the agent learned during work, and writes it
where the routing test puts it. Then `build`, `sync`, `check`.

**`audit`** changes nothing. It runs `check` and adds judgement findings: statements in the wrong
layer, duplicates across layers, stale claims checked against the code, pages over-claiming,
components with no page, and CLAUDE.md lines that fail the removal test.

### 7.2 Guardrails

- Moving is fine; losing is not. A statement removed from CLAUDE.md or a rule is either moved to its
  new place or listed in the summary as dropped, with the reason.
- Never edit a generated file or block by hand; run `build` and `sync`.
- Never write or change an ADR's decision on its own. A change that needs a new ADR goes under
  "Needs a human" with a proposed draft.
- No ticket ids in pages, except in ADRs that already cite them.
- Do not commit. The changes go into the PR of the task, or the user commits them.
- Write only CLAUDE.md, `.claude/rules/`, `.github/instructions/`, `.github/copilot-instructions.md`
  and `docs/wiki/`.
- Plain, results-only prose in full sentences; no process narrative.

## 8. CLAUDE.md template

`templates/CLAUDE.md` gives the shape the skill writes and keeps:

```markdown
# <project>

<Three lines: what the system is, the stack.>

@docs/wiki/index.md

## Wiki
- Before you change a component, read its page in docs/wiki/components/. The code wins over the
  wiki; when they disagree, say so.
- Before writing a helper, check docs/wiki/reuse.md.
- Run /wiki update before you open a PR.

## How to work
## Commands
## Rules
```

At most 130 lines.

## 9. Integration with the base

- `image/bin/agentic-wiki` is installed like the other `agentic-*` commands, and
  `agentic-inventory` lists it.
- `skills/wiki/` is copied by `60-skills` with no change to the step.
- The `/agentic-setup` hand-over suggests `/wiki seed` when the project has no `docs/wiki/`.

## 10. Testing

bats, `make test`:

- `agentic-wiki build` against a fixture repository with golden `index.md`, `decisions/index.md`,
  `reuse.md` and "Used by" blocks.
- `sync`: rule mirror with `applyTo`, removal of an orphaned mirror, the index block in
  `copilot-instructions.md` with surrounding content kept.
- `check`: one failing fixture per rule in §6, and a passing fixture.
- `affected`: longest-prefix mapping, omitted and unclaimed files, files under a Terraform source.
- The skill: the files of §7 exist, and every `agentic-wiki` command `SKILL.md` names exists.

`make lint`: shellcheck and the leak check over the new files. `make smoke`: `agentic-wiki check`
passes on the fixture inside the image, and `/wiki` is present in both harnesses' skill folders.

Manual: one `/wiki seed` and one `/wiki update` on a sample repository, reviewed by a human.

## 11. Out of scope

- The lessons-learned skill (W9).
- Diagrams and an architecture view bound to the components.
- Scheduling a periodic `update`; the runtime calls the same mode later.
- Running `agentic-wiki check` in a project's own CI outside the container.
- Migrating an existing project wiki that has its own tooling.

## 12. Risks

- **Seed quality.** It depends on how strictly the routing test is applied. The `draft` status and
  one human review of the seeded set are the safeguard.
- **Copilot surfaces.** Copilot surfaces other than the CLI may not read the root CLAUDE.md. Then
  the always-on rules reach them only through the index block. A full mirror of CLAUDE.md into
  `copilot-instructions.md` is a possible follow-up.
- **Index size.** A project with many top-level components may exceed 70 lines. Then the fix is
  grouping components under parents, which also improves the map.
