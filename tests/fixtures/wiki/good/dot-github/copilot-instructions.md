<!-- generated:wiki-index:start -->
# Project wiki

What the code does not tell: components, decisions, concepts and flows. Paths are relative to
docs/wiki/. Read a component's page before you change it. The code wins over the wiki; never
guess a page id.

Shop sells items through a public HTTP API. The API keeps business logic thin and calls the
shared helpers for anything used twice.

## Components

- [API](components/api.md): Public HTTP API; owns the routes and their versioning.
- [Common](components/common.md): Shared helpers used by more than one component.

## Concepts

- [Money](concepts/money.md): Amounts are integer cents with an ISO currency code.

## Flows

- [Checkout](flows/checkout.md): From a cart to a paid order.

## More

- [Decisions](decisions/index.md), [Reuse](reuse.md), [Glossary](glossary.md)
<!-- generated:wiki-index:end -->
