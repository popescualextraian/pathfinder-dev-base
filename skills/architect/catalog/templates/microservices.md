---
kind: template
id: microservices
name: "Microservices"
summary: "Independently deployable services, each owning its data and its API."
style: microservices
parts:
  - id: service
    name: Service
    layers:
      - { id: api, name: API, mayUse: [service] }
      - { id: service, name: Service, mayUse: [repository, client] }
      - { id: client, name: Client, mayUse: [] }
      - { id: repository, name: Repository, mayUse: [] }
principles: [make-it-work, yagni, least-surprise, kiss, consistent, dry, clean-code, solid]
patterns: [repository, adapter]
---

# Architecture of NAME

Describe the project in a few lines: what it does and who uses it.

## Style

Microservices: Independently deployable services, each owning its data and its API.

## Layers

One part per service, with the layers above.

## Rules

- No shared database.
- Services talk only through published APIs.
