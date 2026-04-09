# Simulation Interactions — Roadmap

> **Status doc, not a spec.** This is a tracker of which pair-wise
> interactions exist today between the four simulation systems (rigid
> bodies, powder grid, PIC/FLIP liquid, VaporSim gas) and the auxiliary
> thermal field. Each missing interaction gets its own design spec and
> implementation plan when it's scheduled.

## Current state matrix

| A \ B          | Rigid Body       | Powder         | Liquid                     | Gas                     | Thermal                |
|----------------|------------------|----------------|----------------------------|-------------------------|------------------------|
| **Rigid Body** | ✓ Godot physics  | ✗              | ✗ **(next — task #1)**     | ✗                       | ✗                      |
| **Powder**     | ✗                | ✓ CA grid      | ~ chemistry only           | ✗                       | ~ heat tracked per cell|
| **Liquid**     | ✗ **(task #1)**  | ~ chemistry    | ✓ PIC/FLIP var-density     | ✓ shared ambient density| ✓ thermal buoyancy     |
| **Gas**        | ✗                | ✗              | ✓                          | ✓ VaporSim              | ✓ thermal buoyancy     |
| **Thermal**    | ✗                | ~              | ✓                          | ✓                       | —                      |

Legend: ✓ implemented and working · ~ partial / chemistry-only · ✗ not implemented

## Backlog

Each task below becomes its own `docs/superpowers/specs/YYYY-MM-DD-<task>-design.md` and
`docs/superpowers/plans/YYYY-MM-DD-<task>-plan.md` pair when scheduled. Ordered by
likely gameplay impact, not strict dependency order.

### Task #1 — Rigid Body ↔ Liquid (buoyancy, drag, displacement)

**Status:** In design. See `2026-04-08-rb-liquid-buoyancy-design.md` and
`docs/superpowers/plans/2026-04-08-rb-liquid-buoyancy-plan.md`.

Wooden block floats, iron sinks, ice bobs partially submerged. Two-way
coupling: liquid cells occupied by a rigid body become walls for the fluid
solver (liquid routes around the body), and the body receives buoyancy +
drag forces from the liquid it's displacing. MVP scope: irregular polygon
shapes per substance, static-fluid drag approximation (no body→liquid
momentum transfer, no pressure-gradient integration).

**Prerequisites it unlocks:** per-substance polygon shapes (previously all
rigid bodies were 30×24 rectangles), dynamic fluid boundary infrastructure
(previously the boundary was static at solver setup).

### Task #2 — Thermal ↔ Rigid Body

Ice melts, iron glows hot, wood ignites and burns. Adds per-body
temperature state, heat transfer from neighbouring cells proportional to
contact area, and phase-change hooks: a melted-ice body deletes itself
and spawns water particles; a burning wood body deletes itself and spawns
smoke + ash. Depends on task #1 for the cell-occupancy mask (heat
transfer happens at the body↔cell interface, so we need to know which
cells a body touches).

### Task #3 — Powder ↔ Liquid (physical)

Sand sinks in water, salt dissolves, iron filings settle and rust.
Requires a density-based transfer path between the integer powder grid
and the particle-based liquid simulator: when a powder cell is inside a
liquid region with lower density, the powder cell disappears and a
particle of the powder's substance spawns in its place (now behaving as
a dense liquid). Dissolution adds a per-substance timer before the
particle is replaced by its dissolved-substance particle.

### Task #4 — Rigid Body ↔ Gas (drag / wind)

VaporSim velocity field applies drag force to rigid bodies in gas cells.
Light objects (feathers, leaves) get carried; heavy objects barely
notice. Lower priority than task #1 because the visual impact is subtle
unless the scene has fast gas flows. Reuses task #1's cell-occupancy
mask infrastructure.

### Task #5 — Powder ↔ Rigid Body

A rigid body dropped onto a powder pile rests on it, displaces powder
cells, and sinks if the powder is loose enough. Requires integer-grid
collision detection for rigid bodies (similar to the liquid obstacle
mask but against the powder grid), plus powder compaction rules.

### Task #6 — Powder ↔ Gas (aerosolization)

Fast gas flows pick up light powder cells and carry them as suspended
dust. Heavy gas flows knock down settled dust. Requires a density-based
cutoff for which powders can aerosolize, and a transfer mechanism
between the powder grid and VaporSim (spawn a "dust gas" cell from the
powder, respawn powder when gas velocity drops).

### Task #7 — Rigid body visual variety beyond polygons

Per-substance sprites, multi-part bodies (a rock with a crack, a
semi-transparent ice crystal), particle effects on collision. Pure
polish, depends on task #1 providing the per-substance polygon plumbing.

## Dependency graph

```
task #1 (rb-liquid) ────┬──► task #2 (thermal-rb)
                        ├──► task #4 (rb-gas drag)
                        ├──► task #5 (rb-powder)
                        └──► task #7 (rb visual polish)

task #3 (powder-liquid) ─── independent
task #6 (powder-gas)   ─── independent
```

Task #1 is on the critical path for four of the seven items, which is
why it's being done first.
