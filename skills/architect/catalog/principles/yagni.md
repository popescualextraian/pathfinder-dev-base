---
id: yagni
name: "YAGNI"
kind: principle
summary: "Build what the task needs now; leave out hooks for futures nobody asked for."
severity: warn
direction: "Build what the task needs now; leave out hooks for futures nobody asked for."
plan_break: "The plan adds options, layers or extension points no requirement names."
code_break: "Unused parameters, flags, classes or exports."
tool: knip
---

# YAGNI

Build what the task needs now; leave out hooks for futures nobody asked for.

- In a plan: The plan adds options, layers or extension points no requirement names.
- In code: Unused parameters, flags, classes or exports.
