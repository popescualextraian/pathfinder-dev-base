---
id: catalog-store
name: Catalog store
summary: "Products in the database, with a read cache."
part: backend
layer: repository
module: catalog
sources:
  - backend/src/repository/catalog/catalog-store.ts
---

# Catalog store

## Purpose and boundary

Products in the database, with a read cache. It does not reach past its own layer's neighbours.

## Where changes go

Edit the files listed under sources; add new files next to them.

## Contracts

Callers use only the exported functions of its entry file.

## Invariants

Imports follow the layers in architecture.md.

## Why

Keeps the repository layer small and replaceable.

## Pitfalls

Do not import from the layers above.
