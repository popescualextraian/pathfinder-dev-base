---
id: order-service
name: Order service
summary: "Owns orders: pricing, checkout, the payment step."
part: backend
layer: service
module: orders
sources:
  - backend/src/service/orders/order-service.ts
  - backend/src/service/orders/payments.ts
talks_to:
  - { to: payment-gateway, via: call }
  - { to: order-store, via: call }
  - { to: catalog-service, via: call }
---

# Order service

## Purpose and boundary

Owns orders: pricing, checkout, the payment step. It does not reach past its own layer's neighbours.

## Where changes go

Edit the files listed under sources; add new files next to them.

## Contracts

Callers use only the exported functions of its entry file.

## Invariants

Imports follow the layers in architecture.md.

## Why

Keeps the service layer small and replaceable.

## Pitfalls

Do not import from the layers above.
