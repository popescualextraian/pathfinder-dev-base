---
id: modular-monolith
name: "Modular monolith, layered"
kind: style
summary: "One deployable split into business modules, each built in strict layers."
detect:
  - top-level folders per business module
  - each module has its own layers and one entry file
  - one build, one deployable
layers:
  - { id: api, name: API, mayUse: [service] }
  - { id: service, name: Service, mayUse: [repository, integration] }
  - { id: integration, name: Integration, mayUse: [] }
  - { id: repository, name: Repository, mayUse: [] }
rules:
  - A module owns its data; no other module reads its tables.
  - Modules meet only through the service interface of the other module.
  - Inside a module, layers use only the layers they may use.
  - Shared code is generic and knows no module.
---

# Modular monolith, layered

One deployable split into business modules, each built in strict layers.
