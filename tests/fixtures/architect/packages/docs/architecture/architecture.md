---
style: modular-monolith
parts:
  - id: backend
    name: Backend
    layers:
      - { id: boot, name: Boot, mayUse: [api, commons] }
      - { id: api, name: API, mayUse: [service, commons] }
      - { id: service, name: Service, mayUse: [repository, commons], folders: [backend/src/schedule/service/] }
      - { id: repository, name: Repository, mayUse: [commons] }
      - { id: commons, name: Commons, mayUse: [] }
    modules:
      - { id: backlog, name: Backlog }
      - { id: schedule, name: Schedule }
  - id: frontend
    name: Frontend
    layers:
      - { id: ui, name: UI, mayUse: [] }
boundaries:
  - { id: backlog-package, folder: backend/src/backlog/, uses: [commons], entry: backend/src/backlog/index.ts }
  - { id: schedule-package, folder: backend/src/schedule/, uses: [commons], entry: backend/src/schedule/index.ts }
principles: [kiss]
patterns: []
---

# Architecture of the planner

A backend of sealed packages, each with its own layers and one entry file, and a frontend.
