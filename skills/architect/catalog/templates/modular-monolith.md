---
kind: template
id: modular-monolith
name: "Modular monolith, layered"
summary: "One deployable split into business modules, each built in strict layers."
style: modular-monolith
parts:
  - id: backend
    name: Backend
    layers:
      - { id: api, name: API, mayUse: [service] }
      - { id: service, name: Service, mayUse: [repository, integration] }
      - { id: integration, name: Integration, mayUse: [service] }
      - { id: repository, name: Repository, mayUse: [service] }
    modules:
      - { id: example, name: Example }
principles: [make-it-work, yagni, least-surprise, kiss, consistent, dry, clean-code, solid]
patterns: [ports-and-adapters, repository]
---

# Architecture of NAME

Describe the project in a few lines: what it does and who uses it.

## Style

Modular monolith, layered: One deployable split into business modules, each built in strict layers.

## Layers

Each module has API, Service, Integration and Repository layers.

## Rules

- Modules meet only through service interfaces.
- A module owns its data.
