---
id: hexagonal
name: "Hexagonal"
kind: style
summary: "A domain core surrounded by ports; adapters connect it to the outside."
detect:
  - folders named domain, ports, adapters
  - domain code imports no framework or driver
layers:
  - { id: adapters, name: Adapters, mayUse: [ports, domain] }
  - { id: ports, name: Ports, mayUse: [domain] }
  - { id: domain, name: Domain, mayUse: [] }
rules:
  - The domain imports nothing from ports or adapters.
  - Ports are interfaces owned by the core.
  - Adapters implement ports and hold all framework and driver code.
  - Adapters never call each other.
---

# Hexagonal

A domain core surrounded by ports; adapters connect it to the outside.
