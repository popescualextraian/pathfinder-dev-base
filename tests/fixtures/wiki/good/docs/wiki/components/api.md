---
id: components/api
kind: component
name: API
summary: Public HTTP API; owns the routes and their versioning.
lifecycle: active
status: reviewed
sources:
  - src/api/
  - infra/api.tf
depends_on:
  - components/common
  - concepts/money
decisions:
  - decisions/adr-1
offers: []
---

# API

## Purpose and boundary

The API turns HTTP requests into calls to the shared helpers. It holds no pricing logic.

## Where changes go

- A new route goes into `src/api/routes.py` under the current version prefix.

## Contracts

The public routes are fixed for clients; a breaking change needs a new version prefix
([ADR-1](../decisions/adr-1.md)).

## Pitfalls

- Amounts reach the API as integer cents; format them with `format_money`, never by hand.
