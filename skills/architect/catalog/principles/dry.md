---
id: dry
name: "DRY"
kind: principle
summary: "Keep one source of truth for each piece of knowledge."
severity: warn
direction: "Keep one source of truth for each piece of knowledge."
plan_break: "Two components own the same rule, data or behaviour."
code_break: "Copied blocks, or the same rule written in two places."
tool: jscpd
---

# DRY

Keep one source of truth for each piece of knowledge.

- In a plan: Two components own the same rule, data or behaviour.
- In code: Copied blocks, or the same rule written in two places.
