---
id: orders-api
name: Orders API
summary: "REST for carts and orders; validation only."
part: backend
layer: api
module: orders
sources:
  - backend/src/api/orders/orders-api.ts
talks_to:
  - { to: order-service, via: call }
---

# Orders API

## Purpose and boundary

REST for carts and orders; validation only. It does not reach past its own layer's neighbours.

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
