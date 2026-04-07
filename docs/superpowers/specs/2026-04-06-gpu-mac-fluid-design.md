# GPU MAC Fluid Simulation — Design Spec

## Overview

A proper GPU-accelerated Marker-and-Cell (MAC) fluid solver for the alchemy prototype. This document captures the correct algorithm, lessons from the failed first attempt, and a path to a working implementation.

**Status:** Design only. The previous GPU MAC attempt failed due to fundamental algorithm errors (documented below). Liquids currently use falling-sand rules as a fallback.

**Goal:** Physically-motivated fluid behavior for water, oil, acid — pressure-driven flow, free surface with proper atmospheric boundary, density preservation, multi-substance mixing.

**Non-goal:** Perfect physical accuracy. This is a game, not a simulator. "Looks plausibly fluid-like" is enough.

---

## 1. Why The First Attempt Failed

The initial implementation had six distinct issues, each sufficient to cause failure:

### 1.1 Broken Jacobi Pressure Solve

The Jacobi method requires reading from the previous iteration's pressure and writing to a separate output. Our shader did:
```glsl
// WRONG — reads and writes same buffer in parallel
pressure.data[idx] += p;
u_vel.data[u_idx(x, y)] -= s_left * p;
u_vel.data[u_idx(x + 1, y)] += s_right * p;
```
Multiple threads simultaneously modify the same velocity cells (via `s_right` from cell X and `s_left` from cell X+1). Result: race conditions, garbage velocities.

### 1.2 Algorithm Conflation

Standard MAC pressure projection has three distinct steps:
1. Compute divergence from current velocities → store in a divergence buffer
2. Solve pressure Poisson equation (Jacobi iteration on pressure alone)
3. Subtract pressure gradient from velocity → write new velocities

Our shader conflated all three into one step, modifying velocities during the pressure iteration. The pressure solver never converges because its inputs (the velocity field) are changing underneath it.

### 1.3 No Ping-Pong Pressure Buffer

Jacobi is `p_new[i] = f(p_old[i-1], p_old[i+1], ...)`. Without two buffers, we were computing `p[i] = f(p[i-1], p[i+1])` where some neighbors are already updated from this iteration. This is closer to Gauss-Seidel, which is sequential and can't be parallelized correctly.

### 1.4 No Free-Surface Boundary Condition

In a proper MAC solver, the fluid-air interface must have pressure = 0 (atmospheric). Our solver treated this boundary as a wall (no-flow), which creates a "sealed container" of fluid that can't relax into the free space above.

### 1.5 Bilinear Interpolation at Walls

Semi-Lagrangian advection samples the density field at fractional positions. When the sample point is near a wall, the bilinear interpolation averages fluid density with wall cells (which have density 0), destroying mass. We partially fixed this by masking wall cells in the interpolation, but it was never the full cause.

### 1.6 Velocity Accumulation Without Damping

Each frame, gravity adds velocity. The pressure solver is supposed to cancel out the divergent component, but since it was broken, residual velocity accumulated frame after frame. No viscosity or damping meant velocities grew unbounded.

---

## 2. Correct Algorithm

### 2.1 Data Layout

All buffers sized to a **fluid grid** at `fluid_scale` × the particle grid resolution (default 4x = 800x600).

**Density & substance fields** (cell-centered, width × height):
- `density[]` — float, amount of fluid per cell, range [0.0, 1.0+]
- `density_out[]` — float, ping-pong for advection
- `substance[]` — int, which substance type occupies this cell (0 = empty)
- `substance_out[]` — int, ping-pong

**Velocity field** (staggered MAC layout):
- `u_vel[]` — float, (width+1) × height, horizontal velocity at vertical cell faces
- `v_vel[]` — float, width × (height+1), vertical velocity at horizontal cell faces

**Pressure solve buffers** (cell-centered, width × height):
- `divergence[]` — float, velocity divergence, computed fresh each frame
- `pressure[]` — float, pressure field being solved
- `pressure_out[]` — float, ping-pong for Jacobi iterations

**Cell type mask** (cell-centered):
- `cell_type[]` — int, 0=air, 1=fluid, 2=wall. Computed fresh each frame from density and boundary.

**Boundary mask** (cell-centered, uploaded once at setup):
- `boundary[]` — int, 1=inside receptacle, 0=wall

### 2.2 Per-Frame Pipeline

Eight distinct shader passes per frame. Each pass has a single, well-defined responsibility:

**Pass 1: Classify cells** (1 dispatch)
```
For each cell:
  if boundary[i] == 0: cell_type[i] = WALL
  elif density[i] > 0.05: cell_type[i] = FLUID
  else: cell_type[i] = AIR
```

**Pass 2: Apply body forces** (1 dispatch)
```
For each cell marked FLUID:
  v_vel[bottom_face] += gravity * delta_time
```

**Pass 3: Compute divergence** (1 dispatch)
```
For each cell marked FLUID:
  div = (u[right] - u[left] + v[bottom] - v[top]) / dx
  divergence[i] = div
```
Stored in a dedicated buffer. Not modified during pressure solve.

**Pass 4: Jacobi pressure iteration** (N dispatches, alternating buffers)

Uses ping-pong: read `pressure_in`, write `pressure_out`, swap.
```
For each cell marked FLUID:
  p_left   = is_air(left)   ? 0.0 : pressure_in[left]
  p_right  = is_air(right)  ? 0.0 : pressure_in[right]
  p_top    = is_air(top)    ? 0.0 : pressure_in[top]
  p_bottom = is_air(bottom) ? 0.0 : pressure_in[bottom]

  // Air boundary: pressure = 0 (atmospheric).
  // Wall boundary: zero-gradient (p_wall = p_this).
  // The standard Jacobi update:
  pressure_out[i] = (p_left + p_right + p_top + p_bottom - divergence[i]) / 4
```

For each iteration: dispatch, swap buffer bindings, repeat. 20-40 iterations typical.

**Pass 5: Subtract pressure gradient** (1 dispatch)
```
For each velocity face adjacent to a fluid cell:
  u[face] -= (pressure[right_cell] - pressure[left_cell]) / dx
  v[face] -= (pressure[bottom_cell] - pressure[top_cell]) / dx
```
Now velocity is (approximately) divergence-free.

**Pass 6: Zero wall velocities** (1 dispatch)
```
For each velocity face at a wall boundary:
  u[face] = 0
  v[face] = 0
```

**Pass 7: Advect density** (1 dispatch, writes to density_out)
```
For each cell (x, y):
  if cell_type[i] == WALL:
    density_out[i] = 0
    continue

  // Velocity at cell center
  vx = (u[left] + u[right]) * 0.5
  vy = (v[top] + v[bottom]) * 0.5

  // Backward trace
  src_x = x - vx * delta_time
  src_y = y - vy * delta_time

  // Bilinear interpolation, skipping wall cells and renormalizing weights
  density_out[i] = sample_density_wall_aware(src_x, src_y)
  substance_out[i] = sample_substance_nearest(src_x, src_y)
```

Swap density/substance buffers for next frame.

**Pass 8: Velocity damping** (1 dispatch)
```
For each velocity face:
  u[face] *= 0.99  // 1% damping per frame, approximates viscosity
  v[face] *= 0.99
```
Optional but recommended — prevents velocity blowup over long simulations.

### 2.3 Dispatch Count

- Classification: 1
- Body forces: 1
- Divergence: 1
- Pressure Jacobi: 20-40
- Pressure gradient: 1
- Wall velocity zero: 1
- Advection: 1
- Damping: 1
- **Total: 26-46 dispatches per frame**

At 800x600 = 480K cells, each dispatch is ~0.1ms on a modern GPU. Total fluid cost: 3-5ms per frame. Acceptable.

---

## 3. Critical Implementation Details

### 3.1 Jacobi Convergence

Jacobi is slower than Gauss-Seidel but parallelizable. It needs more iterations:
- Gauss-Seidel with ω=1.9 (SOR): ~20 iterations to converge
- Jacobi: ~40-80 iterations for equivalent quality

**Iteration count is a performance dial.** Fewer iterations = faster but less accurate (water compresses slightly). More iterations = slower but more stable.

**Red-black Jacobi** (a compromise) can roughly double effective convergence by updating cells in two passes per iteration — even-parity cells first, then odd-parity. Still parallelizable, just in two phases.

### 3.2 Free-Surface Pressure Boundary

At the fluid-air interface, pressure must be 0 (atmospheric). This is what distinguishes "fluid pooling under gravity" from "fluid compressed in a sealed container."

Implementation: in the Jacobi iteration, when reading neighbor pressures, if the neighbor is AIR, use 0.0 instead of the pressure buffer value.

```glsl
float p_left = (cell_type[left] == AIR) ? 0.0 : pressure_in[left];
```

Walls use zero-gradient (use the current cell's pressure): `p_wall = pressure_in[i]`.

### 3.3 Velocity Extrapolation

After the pressure solve, velocities are only meaningful inside fluid cells and at fluid-adjacent faces. When advection traces backward from an air cell to a fluid cell, the velocity at the air cell is used — but air cell velocities are undefined.

**Solution:** Extrapolate velocity from fluid into the surrounding air by 2-3 cells. This can be done as an extra shader pass after the pressure gradient step:
```
For each air cell within 3 cells of fluid:
  Find the nearest fluid cell
  Copy its velocity
```

Without extrapolation, the advection step produces artifacts at the free surface.

### 3.4 Multi-Substance Handling

With multiple liquid types (water, oil, acid), each cell stores:
- A single float density (total fluid amount)
- A single int substance ID (dominant substance)

**On advection:**
- Density: bilinear interpolation (smooth)
- Substance: nearest-neighbor (avoids blending type IDs)

**On substance mixing:** If two different substances are in the same cell, the denser substance stays, the other displaces upward. This approximates immiscible fluids without tracking separate density fields per substance.

**Alternative:** Separate density buffer per substance (3 floats per cell). More memory, better mixing behavior. Can be a later upgrade.

### 3.5 Rigid Body Interaction

Rigid bodies (Godot RigidBody2D) need to displace fluid and experience buoyancy. Two approaches:

**Option A (simple):** Mark cells under rigid bodies as WALL. Fluid treats them as solid. Rigid bodies experience buoyancy from cells they push into (volume integral of displaced fluid × gravity).

**Option B (better):** Use fluid density at the body's position to compute buoyancy force. Apply this to the Godot rigid body each frame. Cells under the body are still treated as walls for fluid purposes.

Defer this until base MAC works.

---

## 4. Failure Modes and Detection

A MAC fluid sim has many failure modes. Each should be detectable with debug output:

| Failure | Symptom | Debug check |
|---------|---------|-------------|
| Pressure not converging | Fluid compresses/expands visibly | Log max divergence after Jacobi — should be near 0 |
| Velocity accumulation | Fluid moves faster over time | Log max velocity magnitude per frame |
| Mass loss | Total density decreases over time | Log total density sum per frame |
| Unstable advection | Fluid scatters randomly | Log number of cells with density > 0.5 |
| Wall penetration | Fluid leaks through walls | Log density in WALL cells (should be 0) |

**All of these must be instrumented during development.** Without them, debugging is guesswork.

---

## 5. Testing Strategy

### Phase 1: Minimal Test Case

Before connecting to the game, test the solver with a minimal scenario:
- Empty 64x64 grid
- A single blob of fluid in the center
- No walls (all cells valid)
- No rigid bodies, no other substances

Verify:
1. Total density is preserved frame-to-frame (mass conservation)
2. Fluid falls and settles flat at the bottom (gravity + pressure work)
3. Max velocity stays bounded (no blowup)
4. Divergence after pressure solve is near zero (convergence)

All four must pass before moving on.

### Phase 2: Walls

Add boundaries:
- Rectangular container (box)
- Curved container (oval, matching our cauldron)

Verify:
1. Fluid doesn't leak through walls
2. Surface settles flat (respects gravity)
3. Pouring from above produces pooling and ripples

### Phase 3: Multi-Substance

Add a second fluid type. Verify immiscible behavior (denser sinks).

### Phase 4: Integration

Connect to the main game. Route liquid spawns through `gpu_sim.spawn_fluid()`. Verify rendering, reactions, and performance.

---

## 6. Alternative: Stable Fluids (Jos Stam)

If MAC proves too complex, consider Jos Stam's "Stable Fluids" method. It's conceptually simpler:
- Everything is on a regular grid (no staggered faces)
- Velocity stored at cell centers
- Unconditionally stable (never blows up regardless of time step)
- Uses implicit diffusion step for viscosity

Trade-offs:
- Less physically accurate at the free surface
- More numerical diffusion
- Same pressure projection structure as MAC

The "Stable Fluids" paper is short (~6 pages) and has clear pseudocode. Might be a better starting point for a first GPU fluid implementation.

---

## 7. Performance Budget

Target: 60 FPS with GPU sim consuming <10ms per frame.

| Component | Budget |
|-----------|--------|
| Particle grid update | 1ms |
| Fluid classification | 0.1ms |
| Body forces | 0.1ms |
| Divergence | 0.1ms |
| Jacobi (40 iterations) | 4ms |
| Pressure gradient | 0.1ms |
| Wall velocities | 0.1ms |
| Advection | 0.2ms |
| Damping | 0.1ms |
| Fields shader | 0.5ms |
| Readback | 0.5ms |
| **Total GPU** | **~7ms** |

Grid resolution: 800x600 for fluid, 200x150 for particles. If Jacobi proves too slow, options:
- Reduce to 400x300 fluid (4x faster)
- Reduce iteration count
- Use red-black Jacobi (equivalent quality in half the iterations)

---

## 8. File Structure

```
src/shaders/
  fluid_classify.glsl       — Pass 1: cell type classification
  fluid_body_forces.glsl    — Pass 2: gravity
  fluid_divergence.glsl     — Pass 3: compute divergence
  fluid_jacobi.glsl         — Pass 4: Jacobi pressure iteration
  fluid_gradient.glsl       — Pass 5: subtract pressure gradient
  fluid_wall_zero.glsl      — Pass 6: zero wall velocities
  fluid_advect.glsl         — Pass 7: semi-Lagrangian advection
  fluid_damping.glsl        — Pass 8: velocity damping

src/simulation/
  gpu_simulation.gd         — Manages all fluid buffers and dispatches
                               Separate methods per pass
                               Ping-pong buffer swapping
                               Debug instrumentation (max velocity, total density, etc.)
```

Each shader in its own file for clarity. The current approach (one shader with a `phase` parameter) was convenient but obscured which pass was doing what — harder to debug.

---

## 9. Estimated Effort

- Phase 1 (minimal test case, 64x64 blob): 1 day
- Phase 2 (walls, container): 0.5 day
- Phase 3 (multi-substance): 0.5 day
- Phase 4 (integration, rendering, perf tuning): 1 day
- **Total: 3 days of focused work**

Plus unknown time for debugging convergence issues, boundary artifacts, and performance tuning. Plan for 4-5 days realistically.

---

## 10. Decision Criteria

Before starting this work, decide:

1. **Is the visual difference worth 3-5 days?** Falling-sand liquids work. They look pixelated but functional. MAC fluid would look more realistic but the art style may hide the difference.

2. **Is this blocking gameplay?** If yes, prioritize. If no, ship the prototype with falling-sand and revisit later.

3. **Start with Stable Fluids instead?** Simpler algorithm, faster to get working, maybe "good enough" visually.

The prototype is currently functional with falling-sand. This MAC work is an enhancement, not a requirement.
