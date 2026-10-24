---
id: payment-gateway
name: Payment gateway
summary: "Talks to the payment provider; implements the service's Payments interface."
part: backend
layer: integration
module: orders
sources:
  - backend/src/integration/orders/payment-gateway.ts
---

# Payment gateway

## Purpose and boundary

Talks to the payment provider; implements the service's Payments interface. It does not reach past its own layer's neighbours.

## Where changes go

Edit the files listed under sources; add new files next to them.

## Contracts

Callers use only the exported functions of its entry file.

## Invariants

Imports follow the layers in architecture.md.

## Why

Keeps the integration layer small and replaceable.

## Pitfalls

Do not import from the layers above.
