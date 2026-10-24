---
id: repository
name: "Repository"
kind: pattern
summary: "One class per aggregate hides how it is stored behind a collection-like interface."
use_when: "Several callers read or write the same data."
spot: "A class named *Repository or *Store holding all queries for one entity."
layers_implied: [repository]
---

# Repository

One class per aggregate hides how it is stored behind a collection-like interface.
