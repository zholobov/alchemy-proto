# Compute Shader Migration — Design Spec

## Overview

Migrate the alchemy simulation from GDScript per-cell loops to GPU compute shaders via Godot's `RenderingDevice` API. The particle grid, fluid simulation, and field updates move to GPU. The mediator/reaction system stays on CPU, reading back GPU data each frame.

**Problem:** GDScript iterates 30K cells multiple times per frame (~9M operations), resulting in 3 FPS with just 66 particles.

**Solution:** GPU processes all 30K cells in parallel via compute shaders. CPU handles only reaction logic on the ~66 occupied cells.

**Expected result:** ~10ms per frame (60+ FPS) instead of 333ms (3 FPS). ~30x speedup.

---

## 1. Architecture

### Per-Frame Pipeline

1. **CPU → GPU**: Write player spawn commands into grid buffers via `RenderingDevice.buffer_update()`
2. **GPU Pass 1**: Particle grid update (gravity, stacking, gas rising, liquid spreading)
3. **GPU Pass 2**: Fluid velocity + pressure solve (Jacobi iterations on MAC grid). Skipped if no fluid cells.
4. **GPU Pass 3**: Field updates (temperature diffusion, electric propagation, magnetic radiation, pressure gas counting)
5. **GPU → CPU**: Read back `cells` (120KB) + `temperatures` (120KB) + `fluid_markers` (120KB) = 360KB
6. **CPU**: Mediator scans readback for occupied cells, runs reaction rules on neighbors, writes results back to GPU buffers
7. **CPU**: Render — substance renderer reads cells from readback data for pixel colors

### What Stays on CPU
- Mediator / reaction rules (complex branching, easy to iterate on gameplay)
- Phase change checks
- Player input handling
- Rigid body physics (Godot built-in)
- Game log, debug overlay, sound triggers

### What Moves to GPU
- Particle grid simulation (gravity, stacking, density displacement, gas/liquid behavior)
- Fluid MAC simulation (Jacobi pressure solver, marker advection)
- Temperature field diffusion
- Electric field propagation
- Magnetic field radiation
- Pressure field gas counting

---

## 2. GPU Buffer Layout

All buffers created via `RenderingDevice.storage_buffer_create()`, bound to compute shaders as SSBOs.

### Particle Grid Buffers (200x150 = 30,000 cells)
- `cells` — `int32[30000]`, 120KB — substance ID per cell (0 = empty)
- `cells_out` — `int32[30000]`, 120KB — ping-pong output buffer
- `temperatures` — `float32[30000]`, 120KB — per-cell temperature
- `temperatures_out` — `float32[30000]`, 120KB — ping-pong output
- `charges` — `float32[30000]`, 120KB — per-cell electrical charge
- `boundary` — `uint8[30000]`, 30KB — 1 = valid, 0 = wall (uploaded once)

### Fluid MAC Buffers
- `fluid_markers` — `int32[30000]`, 120KB — substance ID per cell for fluid
- `fluid_markers_out` — `int32[30000]`, 120KB — ping-pong output
- `u_velocity` — `float32[201*150]`, ~120KB — horizontal velocity at cell faces
- `v_velocity` — `float32[200*151]`, ~120KB — vertical velocity at cell faces
- `pressure` — `float32[30000]`, 120KB — pressure at cell centers

### Field Buffers
- `temp_field` — `float32[30000]`, 120KB — temperature field working copy
- `temp_field_out` — `float32[30000]`, 120KB — ping-pong output
- `electric_values` — `float32[30000]`, 120KB
- `electric_values_out` — `float32[30000]`, 120KB
- `magnetic_values` — `float32[30000]`, 120KB

### Substance Lookup Table
- `substance_table` — 13 substances x 12 floats = 624 bytes (uploaded once at startup)
- Per substance: phase (int), density, conductivity_thermal, conductivity_electric, magnetic_permeability, viscosity, flash_point, flammability, color_r, color_g, color_b, color_a

### Simulation Parameters (uniform buffer, ~64 bytes)
- `grid_width: int`, `grid_height: int`
- `delta_time: float`
- `frame_count: int` (for alternating scan direction, random seeds)
- `gravity: float`
- `ambient_temp: float`
- `pressure_iterations: int`

**Total GPU memory: ~2.2MB** (including ping-pong buffers). Trivial.

**Readback per frame:** `cells` + `temperatures` + `fluid_markers` = 360KB. Well under 1ms.

---

## 3. Compute Shaders

### Shader 1: `particle_update.glsl`

Workgroup size: 16x16 (256 threads). Dispatch: ceil(200/16) x ceil(150/16) = 13x10 workgroups.

Each thread processes one cell:
- Read `cells[idx]`, skip if empty
- Read substance phase from `substance_table[cells[idx]]`
- **Powder**: try move down, then diagonal (randomized via hash of position + frame_count)
- **Gas**: try move up, then diagonal, then sideways. Dissipate at top.
- **Liquid**: try move down, then spread sideways to equalize level
- Density displacement: swap if heavier than cell below
- Write result to `cells_out` (ping-pong — read from A, write to B, swap each frame)

Ping-pong prevents race conditions from parallel threads reading cells modified by other threads.

### Shader 2: `fluid_pressure.glsl`

Same workgroup layout. Dispatched only when fluid cells exist (CPU checks before dispatch).

- Apply gravity to `v_velocity` at fluid cell faces
- Jacobi pressure iteration: for each fluid cell, compute divergence from neighboring velocities, apply pressure correction. Fully parallel (unlike Gauss-Seidel). Needs ~40-50 iterations to converge — dispatched as a loop from CPU or as an in-shader loop.
- After pressure solve: advect fluid markers through velocity field using semi-Lagrangian method. Write to `fluid_markers_out`.

### Shader 3: `fields_update.glsl`

Single shader, same workgroup layout. Each thread processes one cell:
- **Temperature**: 4-neighbor diffusion using substance conductivity from lookup table, ambient cooling. Write to `temp_field_out`.
- **Electric**: propagate charge through conductive cells, dissipate in insulators. Runs every 2nd frame (`frame_count % 2`). Write to `electric_values_out`.
- **Magnetic**: accumulate field from nearby magnetic sources (inverse-square within radius 8). Runs every 4th frame (`frame_count % 4`).
- **Pressure**: count gas-phase cells using atomic counter for global gas count.

All fields read from current buffers, write to output buffers. Temperature syncs to `temperatures` buffer for CPU readback.

---

## 4. CPU-Side Changes

### New File: `src/simulation/gpu_simulation.gd`

Central manager owning the RenderingDevice, buffers, shaders, and readback.

Interface:
- `setup(width: int, height: int, boundary: PackedByteArray)` — create GPU buffers, compile shaders, upload boundary mask and substance lookup table
- `spawn_cells(positions: Array[Vector2i], substance_id: int)` — write player-spawned particles into cells buffer
- `spawn_fluid(positions: Array[Vector2i], substance_id: int)` — write into fluid_markers buffer
- `step(delta: float)` — dispatch compute passes 1-3, read back cells + temperatures + fluid_markers
- `get_cells() -> PackedInt32Array` — last readback
- `get_temperatures() -> PackedFloat32Array` — last readback
- `get_fluid_markers() -> PackedInt32Array` — last readback
- `write_cells(positions: Array[Vector2i], substance_ids: Array[int])` — mediator writes reaction outputs back
- `write_temperatures(positions: Array[Vector2i], values: Array[float])` — mediator writes heat outputs back

### Modified Files

- **`main.gd` `_process()`** — replace individual system update calls with `gpu_simulation.step(delta)`, then run mediator on readback data, then write reaction outputs back. No more 3-pass feedback loop — single GPU dispatch + single CPU reaction pass.

- **`receptacle.gd`** — still owns grid dimensions and boundary shape. Passes them to `gpu_simulation.setup()` instead of creating ParticleGrid/FluidSim directly. Keeps references to CPU-side mirror data for the renderer and mediator.

- **`particle_grid.gd`** — becomes a thin CPU-side mirror. Its `cells`, `temperatures`, `charges` arrays are populated from GPU readback each frame. `update()` is no longer called.

- **`fluid_sim.gd`** — same treatment. `markers` populated from readback. `update()` no longer called.

- **`substance_renderer.gd`** — reads from CPU-side mirror arrays (same interface as before). No changes needed.

- **All field `.gd` files** — `update()` no longer called. Field values come from GPU readback if needed for rendering (light sources, pressure level for the warning overlay).

- **`mediator.gd`** — modified to iterate only occupied cells from readback data instead of scanning the full grid. Builds a sparse list of occupied positions from the readback, then checks neighbors only for those.

### Deleted/Disabled
- `ParticleGrid.update()` — not called
- `FluidSim.update()` — not called
- All field `update()` methods — not called
- The 3-pass feedback loop in `main.gd _process()` — replaced by single GPU dispatch + CPU reaction pass

---

## 5. Grid Size Flexibility

Grid dimensions are not hardcoded in shaders. The shaders read `grid_width` and `grid_height` from the uniform parameter buffer and bounds-check against them. Buffer sizes are calculated from `Receptacle.GRID_WIDTH` and `Receptacle.GRID_HEIGHT` at setup time.

To change grid size: modify the two constants in `receptacle.gd`. Buffers, shader dispatches, boundary mask, and renderer all adapt automatically.

Constraint: at very large sizes (>500x500), readback cost grows proportionally. At that point, switch to GPU-side sparse list extraction instead of full buffer readback.

---

## 6. Performance Budget

| Step | Expected Time |
|------|--------------|
| CPU: Handle input, write spawns | ~0.1ms |
| GPU: particle_update.glsl | ~0.5ms |
| GPU: fluid_pressure.glsl (50 Jacobi iterations) | ~1-2ms |
| GPU: fields_update.glsl | ~0.5ms |
| GPU→CPU: Readback 360KB | ~0.5ms |
| CPU: Mediator on sparse occupied cells | ~1-5ms |
| CPU: Write reaction outputs back | ~0.1ms |
| CPU: Render (pixel color lookup) | ~5ms |
| **Total** | **~8-14ms → 60+ FPS** |

---

## 7. File Structure

```
src/
├── simulation/
│   ├── gpu_simulation.gd       # NEW: GPU compute manager
│   ├── particle_grid.gd        # Modified: CPU mirror, no update()
│   ├── fluid_sim.gd            # Modified: CPU mirror, no update()
│   ├── rigid_body_mgr.gd       # Unchanged
│   └── mediator.gd             # Modified: sparse iteration from readback
├── shaders/
│   ├── particle_update.glsl    # NEW: particle sim compute shader
│   ├── fluid_pressure.glsl     # NEW: MAC fluid compute shader
│   └── fields_update.glsl      # NEW: all fields compute shader
└── ...existing files unchanged
```

---

## 8. Web Export Limitation

Compute shaders require Vulkan/Metal. Web export (WebGL2) does not support them. If web export is needed later, options are:
- Keep the GDScript simulation as a fallback (with the sparse-iteration optimization)
- Use WebGPU when Godot adds support
- Accept lower particle counts on web

This is not a concern for the current prototype.
