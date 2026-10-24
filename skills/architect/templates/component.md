---
id: order-service
name: Order service
summary: "One line: what it owns. This is its line in the index."
part: app
layer: service
module: orders
sources:
  - src/service/orders/
talks_to:
  - { to: order-store, via: call }
patterns: []
status: draft
---

# Order service

## Purpose and boundary

What it owns, and what it must not do (the jobs that belong to its neighbours).

## Where changes go

Which file or folder takes which kind of change.

## Contracts

What others rely on: the entry point, events, shapes that must not change.

## Invariants

What must stay true.

## Why

Why it is built this way, when the code does not make it obvious.

## Pitfalls

The mistakes someone new would make here.
