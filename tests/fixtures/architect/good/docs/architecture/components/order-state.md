---
id: order-state
name: Order state
summary: "Hooks holding the cart and the user's orders."
part: frontend
layer: state
module: orders
sources:
  - frontend/src/orders/state/order-state.ts
talks_to:
  - { to: orders-client, via: call }
---

# Order state

## Purpose and boundary

Hooks holding the cart and the user's orders. It does not reach past its own layer's neighbours.

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
