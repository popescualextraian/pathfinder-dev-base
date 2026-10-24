---
id: least-surprise
name: "Least surprise"
kind: principle
summary: "Behave the way a reader of the name and the neighbours expects."
severity: warn
direction: "Behave the way a reader of the name and the neighbours expects."
plan_break: "The plan gives a component a name or place that hides what it does, or breaks a convention."
code_break: "A function with side effects its name omits, or an odd place for a file."
---

# Least surprise

Behave the way a reader of the name and the neighbours expects.

- In a plan: The plan gives a component a name or place that hides what it does, or breaks a convention.
- In code: A function with side effects its name omits, or an odd place for a file.
