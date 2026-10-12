---
id: components/common
kind: component
name: Common
summary: Shared helpers used by more than one component.
lifecycle: active
status: reviewed
sources:
  - src/common/
depends_on: []
offers:
  - name: format_money
    location: src/common/money.py::format_money
    use: Format an amount in cents with its currency for display.
---

# Common

## Purpose and boundary

Helpers that two or more components use. A helper used by one component stays in that component.

<!-- generated:used-by:start -->
## Used by

- [API](api.md)
<!-- generated:used-by:end -->
