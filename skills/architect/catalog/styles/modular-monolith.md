---
id: modular-monolith
name: "Modular monolith, layered"
kind: style
summary: One deployable split into business modules, each built in strict layers.
---

# Modular monolith, layered

One deployable. Business modules own their data and talk through service interfaces; inside a
module, code sits in layers that may only use the layers below them.
