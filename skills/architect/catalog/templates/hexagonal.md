---
kind: template
id: hexagonal
name: "Hexagonal"
summary: "A domain core surrounded by ports; adapters connect it to the outside."
style: hexagonal
parts:
  - id: app
    name: App
    layers:
      - { id: adapters, name: Adapters, mayUse: [ports, domain] }
      - { id: ports, name: Ports, mayUse: [domain] }
      - { id: domain, name: Domain, mayUse: [] }
principles: [make-it-work, yagni, least-surprise, kiss, consistent, dry, clean-code, solid]
patterns: [ports-and-adapters]
---

# Architecture of NAME

Describe the project in a few lines: what it does and who uses it.

## Style

Hexagonal: A domain core surrounded by ports; adapters connect it to the outside.

## Layers

Adapters implement Ports; the Domain uses nothing.

## Rules

- The domain imports no framework.
- Adapters never call each other.
