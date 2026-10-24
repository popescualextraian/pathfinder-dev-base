---
id: catalog-api
name: Catalog API
summary: "REST for products and search."
part: backend
layer: api
module: catalog
sources:
  - backend/src/api/catalog/catalog-api.ts
talks_to:
  - { to: catalog-service, via: call }
---

# Catalog API

## Purpose and boundary

REST for products and search. It does not reach past its own layer's neighbours.

## Where changes go

Edit the files listed under sources; add new files next to them.

## Contracts

Callers use only the exported functions of its entry file.

## Invariants

Imports follow the layers in architecture.md.

## Why

Keeps the api layer small and replaceable.

## Pitfalls

Do not import from the layers above.
