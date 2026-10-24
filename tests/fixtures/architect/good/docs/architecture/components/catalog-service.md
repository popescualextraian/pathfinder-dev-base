---
id: catalog-service
name: Catalog service
summary: "Owns products, prices and search."
part: backend
layer: service
module: catalog
sources:
  - backend/src/service/catalog/catalog-service.ts
talks_to:
  - { to: catalog-store, via: call }
---

# Catalog service

## Purpose and boundary

Owns products, prices and search. It does not reach past its own layer's neighbours.

## Where changes go

Edit the files listed under sources; add new files next to them.

## Contracts

Callers use only the exported functions of its entry file.

## Invariants

Imports follow the layers in architecture.md.

## Why

Keeps the service layer small and replaceable.

## Pitfalls

Do not import from the layers above.
