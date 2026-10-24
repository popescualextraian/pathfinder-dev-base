---
id: catalog-client
name: Catalog client
summary: "The only frontend code that calls the catalog API."
part: frontend
layer: api-client
module: catalog
sources:
  - frontend/src/catalog/api-client/catalog-client.ts
talks_to:
  - { to: catalog-api, via: rest }
---

# Catalog client

## Purpose and boundary

The only frontend code that calls the catalog API. It does not reach past its own layer's neighbours.

## Where changes go

Edit the files listed under sources; add new files next to them.

## Contracts

Callers use only the exported functions of its entry file.

## Invariants

Imports follow the layers in architecture.md.

## Why

Keeps the api-client layer small and replaceable.

## Pitfalls

Do not import from the layers above.
