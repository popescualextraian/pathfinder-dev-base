---
id: catalog-state
name: Catalog state
summary: "Hooks holding products and filters."
part: frontend
layer: state
module: catalog
sources:
  - frontend/src/catalog/state/catalog-state.ts
talks_to:
  - { to: catalog-client, via: call }
---

# Catalog state

## Purpose and boundary

Hooks holding products and filters. It does not reach past its own layer's neighbours.

## Where changes go

Edit the files listed under sources; add new files next to them.

## Contracts

Callers use only the exported functions of its entry file.

## Invariants

Imports follow the layers in architecture.md.

## Why

Keeps the state layer small and replaceable.

## Pitfalls

Do not import from the layers above.
