---
id: order-views
name: Order views
summary: "Cart, checkout and order history screens."
part: frontend
layer: views
module: orders
sources:
  - frontend/src/orders/views/order-views.ts
talks_to:
  - { to: order-state, via: call }
---

# Order views

## Purpose and boundary

Cart, checkout and order history screens. It does not reach past its own layer's neighbours.

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
