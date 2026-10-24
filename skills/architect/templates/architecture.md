---
style: layered
parts:
  - id: app
    name: App
    layers:
      - { id: api, name: API, mayUse: [service] }
      - { id: service, name: Service, mayUse: [repository] }
      - { id: repository, name: Repository, mayUse: [] }
    modules:
      - { id: orders, name: Orders }
principles: [make-it-work, yagni, least-surprise, kiss, consistent, dry, clean-code, solid]
patterns: [repository]
exceptions: []
---

# Architecture of PROJECT

Two or three lines: what the project does, who uses it, and how it is cut (parts, modules).
Replace the front matter above with the detected style, parts, layers and modules; drop `modules`
when the code has no feature folders.

## Style

One line naming the style, then the choices the label leaves open (e.g. "services own the
interfaces they need; repositories implement them").

## Layers

One line per layer, only where the folder layout does not say it.

## Rules

- One project rule per line, e.g. "modules meet only through service interfaces".

## Exceptions

- `<finding-id>`: why the break is accepted. One line per entry of `exceptions`.

## Where to start

- Two or three pointers for a newcomer: the entry point, the busiest component, the main flow.
