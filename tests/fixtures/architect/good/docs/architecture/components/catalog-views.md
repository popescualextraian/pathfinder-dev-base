---
id: catalog-views
name: Catalog views
summary: "Product list and product page."
part: frontend
layer: views
module: catalog
sources:
  - frontend/src/catalog/views/catalog-views.ts
talks_to:
  - { to: catalog-state, via: call }
---

# Catalog views

## Purpose and boundary

Product list and product page. It does not reach past its own layer's neighbours.

## Where changes go

Edit the files listed under sources; add new files next to them.

## Contracts

Callers use only the exported functions of its entry file.

## Invariants

Imports follow the layers in architecture.md.

## Why

Keeps the views layer small and replaceable.

## Pitfalls

Do not import from the layers above.
