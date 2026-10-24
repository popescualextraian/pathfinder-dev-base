---
id: orders-client
name: Orders client
summary: "The only frontend code that calls the orders API."
part: frontend
layer: api-client
module: orders
sources:
  - frontend/src/orders/api-client/orders-client.ts
talks_to:
  - { to: orders-api, via: rest }
---

# Orders client

## Purpose and boundary

The only frontend code that calls the orders API. It does not reach past its own layer's neighbours.

## Where changes go

Edit the files listed under sources; add new files next to them.

## Contracts

Callers use only the exported functions of its entry file.

## Invariants

Imports follow the layers in architecture.md.

## Why

Keeps the api-client layer small and replaceable.

## Pitfalls

Do not import from the layers above.
