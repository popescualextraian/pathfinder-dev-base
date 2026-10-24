---
kind: template
id: layered
name: "Layered"
summary: "One codebase in horizontal layers; each layer uses only the one below."
style: layered
parts:
  - id: app
    name: App
    layers:
      - { id: api, name: API, mayUse: [service] }
      - { id: service, name: Service, mayUse: [repository] }
      - { id: repository, name: Repository, mayUse: [] }
principles: [make-it-work, yagni, least-surprise, kiss, consistent, dry, clean-code, solid]
patterns: [repository]
---

# Architecture of NAME

Describe the project in a few lines: what it does and who uses it.

## Style

Layered: One codebase in horizontal layers; each layer uses only the one below.

## Layers

API calls Service, Service calls Repository.

## Rules

- A layer uses only the layer below it.
