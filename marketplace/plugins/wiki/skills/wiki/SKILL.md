---
name: wiki
description: Keep the project's agent knowledge in the right place and true to the code - the wiki in docs/wiki/ (components, decisions, concepts, flows, glossary, reuse), CLAUDE.md and path rules. Use to seed a wiki, to update it after a change or before a PR, to record a fact learned during work ("remember that...", "add to the wiki"), and to audit the wiki or CLAUDE.md.
argument-hint: "seed | update [<range>] | add \"<fact>\" | audit"
---

# Wiki

Agents read code well. What they cannot read from it is what each component is for and where its
limits are, where a change belongs, which contracts others rely on, what must stay true, why it is
built this way, which shared code already exists, and how the business flows run. That knowledge
lives in three places, and this skill writes all three:

- **CLAUDE.md**, always loaded: what the project is, how to work, commands, rules for every task.
  It imports the wiki index with `@docs/wiki/index.md`. Copilot CLI reads the same file.
- **Path rules** in `.claude/rules/<area>.md` with `paths:`, loaded when those paths are touched.
- **The wiki** in `docs/wiki/`: component pages, decisions, concepts, flows, a glossary.

Read `reference/routing.md` before you move or write anything, and `reference/pages.md` before you
write a page. Start every page from `templates/`.

## The routing test

For every statement, in order; the first match decides:

1. The code says it, or a command prints it → nowhere; at most a pointer to the folder or command.
2. A repeated procedure → a skill or a template, plus one line in CLAUDE.md naming it.
3. An instruction for every task, where removing it would cause mistakes → CLAUDE.md.
4. An instruction for some paths only → a path rule.
5. A description the code does not reveal → a wiki page.

Instructions go to CLAUDE.md or rules, descriptions to the wiki. When both are needed, the rule
says what to do in one line and links the page that says why.

The test for a wiki sentence: would a senior engineer tell a new colleague this before they touch
the component, because an hour of reading the code would not reveal it? Under-claim rather than
over-claim. The code wins over the wiki.

## Commands

`agentic-wiki` does everything a script can decide. Run it from anywhere in the repository.

- `agentic-wiki build`: writes `index.md`, `decisions/index.md`, `reuse.md` and the "Parts" and
  "Used by" blocks from the pages.
- `agentic-wiki sync`: mirrors `.claude/rules/` to `.github/instructions/` for Copilot and puts the
  index into `.github/copilot-instructions.md`.
- `agentic-wiki check`: validates pages, sources, links, sizes, CLAUDE.md, rules and generated
  files. Fix every line it prints.
- `agentic-wiki affected <range>`: maps changed files to components. `<base>..<head>` compares
  commits; `<base>` alone also covers uncommitted changes. Untracked files need `git status`.

After any change: `build`, `sync`, `check`, until `check` prints `wiki: ok`.

## Modes

### seed

Once per repository.

1. Read the layout of the code, the existing CLAUDE.md, AGENTS.md, `.claude/rules/`,
   `.github/copilot-instructions.md`, `.github/instructions/` and `docs/`.
2. Define the components: logical blocks with one responsibility each, whose `sources` may span
   code, infrastructure, configuration, migrations and pipelines. Aim for 5 to 25 top-level
   components; give a part its own page only when it has its own folder or file boundary. Put
   paths that belong to no component into `omitted.yaml` with a reason.
3. Write `overview.md`, then one page per component, then the decisions, concepts, flows and the
   glossary the code and the documents support. Seeded pages are `status: draft`.
4. Route every statement of the existing instruction files with the test. Rewrite CLAUDE.md from
   `templates/CLAUDE.template.md`, keeping every instruction that passes. Turn area instructions
   into rules from `templates/rule.md`. Delete a hand-written `.github/instructions/` file once its
   content is in a rule; `sync` never overwrites a hand-written file.
5. Run `build`, `sync`, `check` until it passes.
6. Summarise: pages written, statements moved (from → to), statements dropped because the code
   says them (with the reason), and "Needs a human".

### update [<range>]

At the end of a task before the PR, or as a catch-up. Without a range use
`$(git merge-base HEAD <default branch>)`, which also covers uncommitted changes.

1. Run `agentic-wiki affected <range>`.
2. For each component listed, read `git diff <range> -- <its files>` and its page. Correct only
   the claims the diff contradicts. Check `depends_on`, `offers` and `lifecycle` against the code.
   Add what the change decided: a boundary, a why, a new offer, a pitfall it hit.
3. Each unclaimed file: add it to the `sources` of the component that owns it, write a new
   component, or add it to `omitted.yaml`. A removed component loses its page and every link to it.
4. Route any new instruction the change brought to CLAUDE.md or a rule.
5. Run `build`, `sync`, `check`. Summarise the changes, or print `wiki: no changes`.

### add "<fact>"

Route the fact with the test, write it where it belongs, then `build`, `sync`, `check`, and say
where it went.

### audit

Change nothing. Run `agentic-wiki check`, then report what a script cannot see: statements in the
wrong layer, the same statement in two layers, claims the code contradicts, pages that copy the
code, components without a page, and CLAUDE.md lines that fail "would removing this cause
mistakes?".

## Guardrails

- Moving is fine; losing is not. A statement you take out of CLAUDE.md or a rule is moved to its
  new place or listed in the summary as dropped, with the reason.
- Never edit a generated file or block; change the pages and run `build` and `sync`.
- Never write or change the decision of an ADR on your own. Put a proposed draft under "Needs a
  human".
- No ticket ids in pages, except in ADRs that already cite them.
- Write only CLAUDE.md, `.claude/rules/`, `.github/instructions/`,
  `.github/copilot-instructions.md` and `docs/wiki/`. Do not commit.
- Plain, results-only prose in full sentences; no process narrative.
