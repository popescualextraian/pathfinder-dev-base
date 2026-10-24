---
id: order-store
name: Order store
summary: "Orders in the database."
part: backend
layer: repository
module: orders
sources:
  - backend/src/repository/orders/order-store.ts
---

# Order store

## Purpose and boundary

Orders in the database. It does not reach past its own layer's neighbours.

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
