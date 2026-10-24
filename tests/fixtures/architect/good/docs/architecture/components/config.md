---
id: config
name: Config
summary: "Validated environment, read once at start."
part: backend
layer: commons
sources:
  - backend/src/commons/config.ts
---

# Config

## Purpose and boundary

Validated environment, read once at start. It does not reach past its own layer's neighbours.

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
