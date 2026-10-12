---
id: concepts/money
kind: concept
name: Money
summary: Amounts are integer cents with an ISO currency code.
related: []
---

# Money

Every amount is an integer number of cents with an ISO 4217 currency code. Floating point never
holds money; conversion to a display string happens once, in `format_money`.
