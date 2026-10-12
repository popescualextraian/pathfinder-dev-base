---
id: flows/checkout
kind: flow
name: Checkout
summary: From a cart to a paid order.
components:
  - components/api
  - components/common
---

# Checkout

1. The client posts the cart to the API.
2. The API prices it with the shared helpers and returns the total.
3. On payment, the API records the order.
