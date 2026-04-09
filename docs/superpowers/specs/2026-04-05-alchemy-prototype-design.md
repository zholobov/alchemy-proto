# Alchemy Prototype — Design Spec

> **Historical note (2026-04-08):** This spec captures the original Apr 5
> design. The code architecture has since evolved: liquids moved from the
> CPU `FluidSim` class to GPU PIC/FLIP in `particle_fluid_solver.gd`, gases
> moved to a GPU grid MAC solver in `vapor_sim.gd` (which is the renamed,
> repurposed ex-`FluidSolver`), a `LiquidReadback` class was extracted as
> the CPU snapshot of liquid state, and `gpu_simulation.gd` became the
> integer-grid powder/solid simulator. The file tree below no longer
> matches the repo — it's preserved as a historical reference. Read this
> spec for the property-based reaction design; read the code for the
> current architecture.

## Overview

A 2D alchemy simulation game where the player drops, pours, and dispenses substances into a receptacle and watches emergent chemical reactions unfold. The simulation is property-based — reactions emerge from substance properties interacting, not from hardcoded recipes.

**Goal of this prototype:** Validate the technical approach by testing performance limits of the simulation systems, proving the property-based reaction model produces interesting emergent behavior, and delivering a complete interaction loop from shelf to result.

**Platform:** Godot 4.x, GDScript, with web export as a secondary target.

---

## 1. Substance Property System

Every substance is defined as a data resource (`.tres` file) with the following properties:

- **Phase:** solid, powder, liquid, gas
- **Density:** determines layering (heavy sinks, light floats)
- **Temperature:** current temp + melting point, boiling point, flash point
- **Flammability:** ignition threshold, burn rate, burn product references (list of substance + ratio, e.g., sulfur burns into sulfur_gas 0.7 +ite 0.3)
- **Conductivity:** thermal and electrical (separate values)
- **Reactivity:** acid/base level (pH-like), oxidizer/reducer strength
- **Viscosity:** for liquids (water vs oil vs honey)
- **Volatility:** how readily it becomes gas
- **Luminosity:** emission intensity and color
- **Magnetic permeability:** response to magnetic fields
- **Color/visual:** base color, opacity, glow parameters

### Reaction Model

Reactions are not recipes. When two substances are in contact, their properties are compared against a set of rules:

- Acidic substance + base metal → dissolution, producing salt + heat + gas
- Temperature exceeds flash point + flammable → ignition
- Oxidizer + reducer → exothermic reaction, new product
- Temperature exceeds boiling point → phase change to gas
- Temperature below freezing point → phase change to solid

Rules operate on property ranges and are defined as data in `reaction_rules.gd` — each rule specifies: input property conditions (e.g., "A.flammability > 0.5 AND A.temperature > A.flash_point"), output effects (spawn substances, emit heat, produce gas), and rates. Adding a new substance with "flammable + low flash point" automatically makes it ignite near anything hot — no new reaction code needed.

---

## 2. Simulation Architecture

Three independent simulation systems, each optimized for its substance type, coordinated by a mediator.

### System 1 — Particle Grid (powders, sand, dust)

- 2D cellular automata grid
- Target resolution: 256x256 (benchmark down to 128x128 if needed)
- Rules: gravity, stacking, avalanching, settling
- Each cell holds one particle or is empty
- Each particle references its substance definition + current state (temperature, charge, etc.)
- Update order: top-to-bottom, alternating left-right scan to avoid directional bias

### System 2 — Fluid Simulator (liquids)

- Marker-and-Cell (MAC) grid approach
- Velocity field + pressure solve on a grid
- Substance markers track which liquid is where
- Handles: pouring, pooling, mixing, viscosity differences, simplified surface tension
- Multiple liquids coexist — each marker carries substance reference
- Same grid dimensions as particle system for cross-system alignment
- Fallback: height-field fluid if MAC proves unstable

### System 3 — Rigid Body Physics (solid objects)

- Godot's built-in RigidBody2D / Area2D
- Objects the player drops in: rocks, metal ingots, crystals, ice, bottles
- Each has collision shapes, mass, substance properties
- Lifecycle: when dissolved/melted/shattered, the rigid body is removed and spawns particles or fluid markers into the appropriate system

### The Mediator

Runs after all three systems update each frame. Handles cross-system boundaries:

- Fluid touching powder → erosion, absorption, wet clumping
- Rigid body in fluid → buoyancy, displacement, dissolution if reactive
- Powder on rigid body → surface accumulation
- Any cross-substance contact → property comparison → reaction check

Produces reaction outputs: new substances, field changes (temperature, pressure, charge, etc.), and feeds them back into the appropriate systems.

### Game Loop (per frame)

1. Process player input (drops, pours, dispenser)
2. Update rigid bodies (Godot physics step)
3. Update fluid simulation
4. Update particle grid
5. Run mediator — check interactions, apply reactions
6. Update all fields (propagate temperature, pressure, charge, magnetism, light)
7. Fields influence substances (phase changes, ignitions, pressure failures)
8. Steps 5-7 may trigger new reactions — capped at 3 iteration passes per frame
9. Render substances + fields
10. Update debug overlay (FPS, perf stats)

---

## 3. Fields System

Fields are continuous properties that exist across the simulation space. They are not output-only effects — they propagate, interact with substances, and feed back into the reaction system. This is what enables emergent phenomena like explosions and chain reactions.

Each field is a pluggable module extending `field_base.gd`, defining:

1. **Propagation rules** — how the field spreads across the simulation space
2. **Sources** — what substance properties or reactions produce it
3. **Influences** — what it does to substances and other fields
4. **Rendering** — how to visualize it

### Fields in the prototype

**Temperature**
- Propagation: conducts through substances based on thermal conductivity, radiates through air slowly
- Sources: exothermic reactions, friction, electrical resistance
- Influences: phase changes (melting, boiling, freezing, condensation), ignition, reaction rate acceleration
- Rendering: hot → red/orange/white color shift, cold → blue. Heat shimmer shader for extreme temperatures
- Ambient cooling toward room temperature at configurable rate

**Pressure**
- Propagation: equalizes across connected gas regions
- Sources: gas production, thermal expansion
- Influences: containment failure (explosion/crack), substance compression
- Rendering: receptacle shaking/vibrating, stress crack glow on walls
- Model: gas particle count vs available volume → pressure value

**Electrical Charge**
- Propagation: flows through conductive paths (metals, water), blocked by insulators
- Sources: certain reactions (electrolysis), crystal piezoelectric effect on impact
- Influences: ignition (sparks), electrolysis, resistive heating, magnetism induction
- Rendering: spark/arc effects along conduction paths (Line2D + shader)

**Light**
- Propagation: instant, radiates from source with falloff
- Sources: hot/incandescent substances, luminous reactions, electrically charged crystals
- Influences: photosensitive reactions (future extensibility)
- Rendering: Godot Light2D / PointLight2D, capped active count, merge nearby sources

**Magnetism**
- Propagation: field radiates from magnetic/magnetized substances, follows inverse-square falloff
- Sources: naturally magnetic substances (iron), electric current through conductors
- Influences: attracts/repels ferrous materials, aligns magnetic particles
- Rendering: subtle field line visualization, particle drift toward magnetic sources

**Sound**
- Propagation: triggered by events, no spatial propagation needed (single receptacle)
- Sources: reactions (sizzle, hiss, crack), impacts, pressure release (boom)
- Influences: aesthetic only
- Rendering: AudioStreamPlayer nodes, intensity scales with reaction magnitude

### Emergent Explosion Example

No "explosion" is coded. It emerges from the field interactions:

1. Volatile powder's temperature rises (temperature field, conductivity)
2. Flash point exceeded → combustion (reaction rule)
3. High burn rate + high energy density → massive heat + rapid gas production
4. Gas particles accumulate faster than dissipation (pressure field)
5. Pressure exceeds receptacle containment threshold
6. Pressure release → shockwave: particles scatter, rigid bodies fly, fluid splashes
7. Scattered burning material contacts other flammable substances → secondary ignition
8. Chain reaction

---

## 4. Player Interaction

### Workspace Layout

- Receptacle centered in the lower portion of the screen
- Shelf/workbench along the top with draggable objects
- Dispenser tool in a toolbar area
- Clean, uncluttered — the receptacle is the focus

### Draggable Objects

- Click and drag from shelf toward receptacle
- Object follows cursor while dragging
- Drop over receptacle → object falls in under gravity
- **Bottles** (liquids): tilt to pour (angle-based stream), release to drop the bottle
- **Bags** (powders): tilt to pour, release to drop
- **Solid chunks**: drop directly

### Dispenser Tool

- Select substance from a palette
- Click/drag over receptacle to emit a fine particle stream
- Hold longer = more substance
- Mouse scroll or UI slider adjusts flow rate
- For precise amounts of reactive powders

### Feedback

- Cursor changes near receptacle to indicate drop zone
- Substances react visually on contact (sizzle, glow, splash)
- Dangerous reactions show warning cues (receptacle shaking, cracks glowing)

### Reset

- "Clean out receptacle" button to empty and start fresh
- No undo — commit to your choices

---

## 5. The Receptacle

### Physical Properties

- Stone mortar/cauldron shape — open top, solid walls, flat bottom
- Defined as a data resource with substance properties: high heat resistance, high pressure threshold, non-reactive to most substances
- Extensible: future receptacle types (glass beaker, iron crucible) by changing the resource

### Behavior

- Walls and floor are boundaries for all three simulation systems
- Heat conducts through walls slowly (stone = poor conductor)
- Pressure tracked as gas count vs interior volume
- Containment failure: pressure exceeds threshold or acid eats through → crack → contents spill → reset moment

### Rendering

- Drawn as foreground layer — contents visible inside
- Contents clipped/masked to interior shape
- Fill level indicator on the side for quick reading

### Simulation Dimensions

- Interior maps onto ~200x150 cells of the particle/fluid grid
- This is the primary performance bottleneck to benchmark

---

## 6. Prototype Substance Set

12 substances covering all field types and interaction patterns:

### Powders
- **Sulfur** — flammable, low flash point, burns producing gas + heat + light
- **Iron filings** — conductive (thermal + electric), magnetic, reacts with acid, rusts with water
- **Salt** — dissolves in water, lowers freezing point, mostly inert
- **Charcoal powder** — highly flammable, slow burn, high energy density

### Liquids
- **Water** — baseline. Conducts electricity, dissolves salt, rusts iron, evaporates/freezes
- **Oil** — flammable, floats on water (low density), insulating, high viscosity
- **Acid** — dissolves metals, reacts with bases, produces gas + heat on reactive contact

### Solids (rigid bodies)
- **Rock** — inert, heavy, high heat capacity. Baseline rigid body
- **Iron ingot** — conductive, magnetic, dissolves in acid slowly, melts at high temp
- **Crystal** — brittle, shatters on impact → crystal powder. Luminous when electrically charged (piezoelectric)
- **Ice block** — melts into water when heated, cools surroundings, cracks under pressure

### Gases (produced by reactions, not player-placed)
- **Steam** — from boiling water. Hot, rises fast, condenses on cold surfaces
- **Flammable gas** — from certain reactions. Ignites near spark/flame → explosion chain

### Key Emergent Scenarios
- Sulfur + charcoal + heat → rapid combustion → gas → pressure → explosion
- Acid + iron → gas + heat + dissolved iron
- Oil on water + spark → surface fire
- Ice in acid → melts → dilutes acid → slows reaction
- Iron filings + electricity → resistive heat → ignites nearby sulfur
- Crystal + impact → powder + piezoelectric charge → attracts iron filings (magnetism)
- Water + electricity → dangerous conduction through liquid

---

## 7. Debug & Performance Monitoring

### FPS Overlay
- Always visible on screen (top corner)
- Shows current FPS, target FPS, and frame time in ms

### Game Log
- In-game console/log panel, togglable with a hotkey
- Logs significant events: reactions triggered, phase changes, field threshold crossings, containment warnings
- Timestamped entries

### Performance Logging
- Toggleable detailed perf stats overlay
- Per-system frame time breakdown: particle grid, fluid sim, rigid bodies, mediator, fields, rendering
- Particle count, fluid marker count, active rigid body count
- Field update times
- Logs to file for post-session analysis when enabled

---

## 8. Project Structure

```
gd-alchemy-proto/
├── project.godot
├── CLAUDE.md
├── .gitignore
├── doc/
│   └── vision.md
├── src/
│   ├── main.tscn
│   ├── main.gd
│   ├── substance/
│   │   ├── substance_def.gd
│   │   └── reaction_rules.gd
│   ├── simulation/
│   │   ├── particle_grid.gd
│   │   ├── fluid_sim.gd
│   │   ├── rigid_body_mgr.gd
│   │   └── mediator.gd
│   ├── fields/
│   │   ├── field_base.gd
│   │   ├── temperature_field.gd
│   │   ├── pressure_field.gd
│   │   ├── electric_field.gd
│   │   ├── light_field.gd
│   │   ├── magnetic_field.gd
│   │   └── sound_field.gd
│   ├── interaction/
│   │   ├── drag_drop.gd
│   │   ├── dispenser.gd
│   │   └── shelf.gd
│   ├── receptacle/
│   │   ├── receptacle.tscn
│   │   └── receptacle.gd
│   ├── rendering/
│   │   ├── substance_renderer.gd
│   │   └── field_renderer.gd
│   └── debug/
│       ├── fps_overlay.gd
│       ├── game_log.gd
│       └── perf_monitor.gd
├── data/
│   └── substances/
│       ├── sulfur.tres
│       ├── iron_filings.tres
│       ├── salt.tres
│       ├── charcoal.tres
│       ├── water.tres
│       ├── oil.tres
│       ├── acid.tres
│       ├── rock.tres
│       ├── iron_ingot.tres
│       ├── crystal.tres
│       ├── ice.tres
│       ├── steam.tres
│       └── flammable_gas.tres
├── assets/
│   ├── sprites/
│   ├── shaders/
│   └── audio/
└── docs/
    └── superpowers/
        └── specs/
```

### Conventions
- GDScript throughout — no C# or C++/GDExtension unless performance demands it
- Substance definitions are data (`.tres`), not code
- Fields are pluggable: extend `field_base.gd`, register in game loop
- One class per file, one responsibility per class
- Keep scripts focused and small

---

## 9. Deterministic Simulation (Core Architectural Requirement)

The simulation MUST be fully deterministic and frame-rate independent.
Same user inputs with the same timing MUST produce the same outcomes
on any machine at any FPS. If a machine lacks the resources to run the
simulation in real time, the game renders slower — but nothing is
skipped and no physics time is lost.

**Why:** A core feature is recording user actions and internal game
clock timing, then replaying them on another game instance on another
machine to reproduce the same outcomes. This is essential for bug
reports, sharing experiments, and automated testing.

### Architectural rules

1. **Fixed simulation timestep.** All simulation systems (fluid solver,
   vapor sim, GPU particle grid, mediator) step at a fixed dt, never
   a variable frame delta. Use accumulator-based stepping: accumulate
   real time, drain it in fixed-dt increments, carry leftovers to the
   next frame.

2. **No render-frame-dependent logic.** Never use
   `Engine.get_process_frames()`, `delta` from `_process()`, or any
   value that varies with render FPS in code that affects simulation
   state. Throttling (e.g. mediator skip) must use simulation time,
   not frame count.

3. **No simulation time loss.** At low FPS, the simulation runs fewer
   steps per frame but never skips time. `MAX_SUBSTEPS` caps per-frame
   work to prevent death spirals, but leftover time carries over in
   the accumulator.

4. **Deterministic RNG.** All random numbers that affect simulation
   state (particle jitter, reaction randomness) must come from a
   seeded `RandomNumberGenerator`, not global `randf()`. The seed is
   part of the replay recording.

5. **Replay recording (future).** Record user inputs (mouse position,
   button state, substance selected) at each simulation step, along
   with the RNG seed. Replay feeds the same inputs at the same sim
   steps to reproduce identical outcomes.

### Current status (2026-04-09)

- Fluid solver: accumulator-based, always uses TARGET_DT. ✓
- Mediator: throttled by sim time, not frame count. ✓
- Vapor sim: single-step with variable delta. ✗ (needs accumulator)
- GPU particle grid: single-step with variable delta. ✗ (needs accumulator)
- RNG: uses unseeded randf() everywhere. ✗ (needs seeded RNG)
- Ambient density / buoyancy: computed once per frame, not per substep. ~
- Replay recording: not implemented. ✗

---

## 10. Performance Strategy & Technical Risks

### Performance Budgets
- **Desktop:** 60 FPS target
- **Web export:** 30 FPS acceptable
- **Mobile minimum supported device:** **Realme C85 Pro** (Qualcomm Snapdragon 685 / Adreno 610, Vulkan 1.1, LPDDR4X). 30 FPS target, expected to require lowered settings (smaller grid, fewer Jacobi iterations, reduced particle cap). Anything below this tier is out of scope — devices with only OpenGL ES 3.1 or GPUs without uint-atomic storage buffers will not be supported.
- **Particle grid:** 256x256 cells (65K), benchmark down to 128x128 if needed
- **Fluid sim:** same grid, can run at half resolution with upscaling if needed
- **Rigid bodies:** up to 10 simultaneous
- **Fields:** update every frame for temperature/pressure, every N frames for magnetism/light if needed
- **Visible particles:** target 10K-20K

### Technical Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Grid simulation too slow in GDScript | High | Optimize with typed arrays, minimal allocations. Fallback: compute shader or GDExtension (C++) for hot loops |
| Fluid sim instability | Medium | MAC grid is more stable than SPH. Small timesteps, velocity clamping. Fallback: height-field fluid |
| Web export performance | Medium | Accept lower resolution/framerate. Test early and often |
| Field feedback loops (runaway cascades) | Medium | Cap reaction iterations at 3 passes per frame. Energy conservation — reactions consume reactants |
| Too many dynamic lights | Low | Cap active Light2D count, merge nearby sources |
| Mediator complexity | Medium | Pairwise checks in small region around contact points, not global scans. Spatial hashing if needed |

### Benchmark Sequence
1. Empty grid update speed — iterate 256x256 cells per frame
2. Grid with 10K particles — gravity + stacking rules
3. Fluid sim standalone — stability and visual quality
4. Combined: grid + fluid + 5 rigid bodies
5. Add fields — find the breaking point

---

## 11. Visual Style

**Prototype phase:** Clean and minimal. Simple shapes, clear colors, readable simulation state. Functional placeholder art.

**Target (post-prototype):** Stylized/painterly. Soft edges, glowing effects, magical atmosphere. Shader-driven visual polish — heat shimmer, liquid sheen, particle glow, magical sparks.

The prototype visual approach prioritizes readability of the simulation over aesthetics. Each substance type should be visually distinct at a glance.
