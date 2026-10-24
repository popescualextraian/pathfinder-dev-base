---
id: validation
name: Validation
summary: "The global validation pipe."
part: backend
layer: commons
sources:
  - backend/src/commons/validation.ts
---

# Validation

## Purpose and boundary

The global validation pipe. It does not reach past its own layer's neighbours.

## Where changes go

Edit the files listed under sources; add new files next to them.

## Contracts

Callers use only the exported functions of its entry file.

## Invariants

Imports follow the layers in architecture.md.

## Why

Keeps the commons layer small and replaceable.

## Pitfalls

Do not import from the layers above.
