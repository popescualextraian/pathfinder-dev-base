---
id: ports-and-adapters
name: "Ports and adapters"
kind: pattern
summary: "The core declares ports; adapters implement them for each outside system."
use_when: "The core must stay free of a framework, a store or a remote system."
spot: "An interface in the core with an implementation in an adapter folder."
layers_implied: [ports, adapters]
---

# Ports and adapters

The core declares ports; adapters implement them for each outside system.
