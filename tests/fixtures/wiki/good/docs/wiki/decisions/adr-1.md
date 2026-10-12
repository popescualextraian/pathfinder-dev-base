---
id: decisions/adr-1
kind: decision
title: Versioned public routes
status: accepted
---

# ADR-1: Versioned public routes

## Context

Mobile clients update slowly and call the API for months after a release.

## Decision

Every public route carries a version prefix; a breaking change gets a new prefix.

## Consequences

Old prefixes stay until their traffic stops.
