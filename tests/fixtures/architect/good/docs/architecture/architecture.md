---
style: modular-monolith
parts:
  - id: frontend
    name: Frontend
    layers:
      - { id: views, name: Views, mayUse: [state] }
      - { id: state, name: State, mayUse: [api-client] }
      - { id: api-client, name: API client, mayUse: [] }
    modules:
      - { id: orders, name: Orders }
      - { id: catalog, name: Catalog }
  - id: backend
    name: Backend
    layers:
      - { id: api, name: API, mayUse: [service, commons] }
      - { id: service, name: Service, mayUse: [integration, repository, commons] }
      - { id: integration, name: Integration, mayUse: [service, commons] }
      - { id: repository, name: Repository, mayUse: [commons] }
      - { id: commons, name: Commons, mayUse: [] }
    modules:
      - { id: orders, name: Orders }
      - { id: catalog, name: Catalog }
principles: [make-it-work, yagni, least-surprise, kiss, consistent, dry, clean-code, solid]
patterns: [ports-and-adapters, repository]
exceptions:
  - id: layers/orders-api/imports-order-store
    rule: layers
    component: orders-api
    reason: The CSV export streams millions of rows; going through the service would load them all into memory.
---

# Architecture of the shop

A web shop: a frontend and a backend in one repository, split into the modules orders and catalog.
Each module has its own screens, endpoints and tables. Modules meet only through service
interfaces. The order service asks the catalog service for prices; nothing else crosses over.
