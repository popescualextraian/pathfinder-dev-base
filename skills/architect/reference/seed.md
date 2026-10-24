# Seed: detecting the architecture

Seed describes what is there, not what should be. When the code is unclear, write the most likely
reading as `status: draft` and list the doubt under "Needs a human".

## 1. Read

- The top-level layout and the build files: one build or several (frontend and backend, one per
  service). Each separately built or run piece is a part.
- CLAUDE.md, AGENTS.md, `README.md`, `docs/` and any existing wiki or ADRs: they often name the
  style and the rules outright.
- A sample of imports in each top-level folder: which folders import which.

## 2. Detect the style

Read the `detect` hints of every catalog style (built-in, overlay, project) and pick the one the
most hints match:

- `layered`: folders named after technical layers (api, service, repository); imports flow down.
- `modular-monolith`: one deployable, feature folders (orders, catalog) each with its own layers;
  modules meet only through service interfaces.
- `hexagonal`: a core with ports (interfaces it owns) and adapters around it; imports point inward.
- `microservices`: several deployables, each with its own build and data, talking over the network.

When two styles fit equally, take the simpler one and say so under "Needs a human".

## 3. Layers, modules, boundaries

- Layers per part, top to bottom. What the project states wins over the catalog default: its
  CLAUDE.md, README, boundary tests and the patterns the doc names set each `mayUse`; the style's
  usual directions are only the starting point. The imports you sampled confirm them. Rename
  layers to the project's folder names.
- With `ports-and-adapters` named (service-owned interfaces implemented by adapters):
  integration and repository may use service, so `mayUse` lists `service` for both.
- An import against the stated direction is a finding for the first review, not a reason to
  change the layers.
- Modules only when the code has feature folders that repeat across layers.
- Boundaries only when a folder is clearly meant to be sealed (a package with an index or an
  explicit public API).

## 4. Components

Aim for 5 to 30 top-level components. A component is a logical block with one responsibility, at
one layer of one part, in at most one module. Give it its own page only when it has its own folder
or file boundary. Too many: merge the small ones of one layer and module. Too few: split a folder
that does two jobs.

Paths that belong to no component (an entry point that only wires things, generated code, test
fixtures) go into `omitted.yaml` with a reason.

## 5. Pages

Write `architecture.md` from `templates/architecture.md`, then one page per component from
`templates/component.md`, then two or three flows for the main business flows. Everything seeded is
`status: draft`.

Leave out:

- what the code shows: routes, fields, classes, folder listings, dependency versions;
- what a textbook says about the style or a pattern; name it and link the catalog id;
- statements you cannot support from the code or the existing documents.

## 6. Needs a human

The summary ends with this list:

- the style and layer calls you were not sure of, with the alternative;
- components whose boundary you guessed;
- statements in CLAUDE.md that the doc now holds (seed does not rewrite CLAUDE.md; a person
  decides whether to remove them);
- documents that contradict the code.
