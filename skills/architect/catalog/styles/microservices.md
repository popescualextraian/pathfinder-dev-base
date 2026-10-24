---
id: microservices
name: "Microservices"
kind: style
summary: "Independently deployable services, each owning its data and its API."
detect:
  - one deployable and one repository folder per service
  - separate datastores per service
  - calls between services go over the network
layers:
  - { id: api, name: API, mayUse: [service] }
  - { id: service, name: Service, mayUse: [repository, client] }
  - { id: client, name: Client, mayUse: [] }
  - { id: repository, name: Repository, mayUse: [] }
rules:
  - A service owns its data; no shared database.
  - Services talk only through published APIs or events.
  - A service is deployed and versioned alone.
  - Clients of other services sit in one layer and tolerate failure.
---

# Microservices

Independently deployable services, each owning its data and its API.
