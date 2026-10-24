---
id: layered
name: "Layered"
kind: style
summary: "One codebase in horizontal layers; each layer uses only the one below."
detect:
  - folders named api, service, repository or similar
  - imports always flow in one direction
layers:
  - { id: api, name: API, mayUse: [service] }
  - { id: service, name: Service, mayUse: [repository] }
  - { id: repository, name: Repository, mayUse: [] }
rules:
  - A layer imports only from the layers it may use.
  - No layer imports from one above it.
  - Cross-cutting helpers live in one shared place.
---

# Layered

One codebase in horizontal layers; each layer uses only the one below.
