# PIC/FLIP Fluid Solver Experiment

**Branch:** `experiment/pic-flip`

## Purpose

Test whether PIC/FLIP (particle-based fluid simulation) eliminates the
"water turning to vapor" diffusion artifact of the grid-based semi-Lagrangian
solver. Particles carry mass discretely; the MAC grid is used only for the
pressure projection step. This means there is **no bilinear interpolation of
density between cells** — the source of all the diffusion problems.

## How to test

```bash
godot --path . tests/pflip_test.tscn
```

### Controls

- **LMB drag**: pour water particles at the cursor
- **R**: clear and respawn the default center blob
- **SPACE**: pause / resume
- **1**: spawn a center blob (default)
- **2**: spawn a top stream (continuous-pour-like)
- **3**: spawn a tall column

### What to look for

- **Mass conservation**: the on-screen "Particles: N / 65536 alive" should
  not decrease over time. If you spawn 1000 particles, you have 1000 particles
  forever (until clear).
- **No haze / no vapor**: each particle is a discrete entity. There should
  be no faded "water vapor" hovering above the pool.
- **Coherent falling**: a blob should fall as a connected mass, not stretch
  or dissolve.
- **Pooling at the bottom**: particles should pile up in the curved cauldron
  bottom.

## Architecture

Pipeline per `step()`:

1. `pflip_clear_grid` — zero u, v, weights, density count, substance buffers
2. `pflip_p2g` — particle-to-grid scatter (atomic CompSwap for float add)
3. `pflip_normalize` — divide accumulated u/v by weights, density count → float
4. `fluid_classify` (reused) — cell type from density
5. `fluid_wall_zero` (reused) — zero walls
6. `fluid_body_forces` (reused) — apply gravity to grid v-velocity
7. `fluid_wall_zero` (reused) — zero walls again
8. `pflip_save_vel` — snapshot u/v as u_old/v_old for FLIP delta
9. `fluid_divergence` (reused)
10. `fluid_jacobi` (reused) — pressure projection (80 iterations)
11. `fluid_gradient` (reused) — apply pressure gradient
12. `fluid_wall_zero` (reused)
13. `pflip_g2p` — gather grid velocity back to particles, FLIP delta blend
14. `pflip_advect` — apply gravity per-particle, move, boundary collision

## Key files

- `src/simulation/particle_fluid_solver.gd` — main solver class
- `src/shaders/pflip_clear_grid.glsl`
- `src/shaders/pflip_p2g.glsl`
- `src/shaders/pflip_normalize.glsl`
- `src/shaders/pflip_save_vel.glsl`
- `src/shaders/pflip_g2p.glsl`
- `src/shaders/pflip_advect.glsl`
- `tests/pflip_test.gd` + `.tscn`

Reuses (unchanged) from main branch:
- `src/shaders/fluid_classify.glsl`
- `src/shaders/fluid_body_forces.glsl`
- `src/shaders/fluid_wall_zero.glsl`
- `src/shaders/fluid_divergence.glsl`
- `src/shaders/fluid_jacobi.glsl`
- `src/shaders/fluid_gradient.glsl`

## Known limitations of this V0

1. **Compression**: PIC/FLIP doesn't enforce a *target density*, only that
   velocity is divergence-free. Particles can pile up densely in curved
   regions. Verified: a 452-particle blob compresses to ~65 cells (7
   particles/cell) at the bottom of the oval cauldron, instead of
   spreading to ~113 cells (4/cell). Real PIC/FLIP solvers add a "density
   correction" force to handle this.

2. **Bouncing at walls**: simple collision (zero velocity component on wall
   contact, push-back to cell edge) causes small visible bounces because
   gravity reaccelerates each frame. Real fluid would damp this. A small
   coefficient of restitution or substep-aware collision would help.

3. **Atomic float add via CompSwap is slow**. Each scatter atomic op takes
   1-3 CAS attempts under contention. With 50k+ particles this is the
   dominant cost. A native float atomic extension (`GL_EXT_shader_atomic_float`)
   would be ~3x faster.

4. **PARTICLES_PER_CELL = 4** is hardcoded. Should match the spawn density.
   If you spawn fewer particles per cell, the density float will be < 1.0
   and the cells won't be classified as fluid (threshold 0.001 might still
   pass but the pressure response will be weak).

5. **No FLIP/PIC ratio tuning yet** — hardcoded to 0.95 FLIP / 0.05 PIC. This
   is the standard recommendation but might want to be exposed.

6. **Substance ID is "last writer wins"** in the scatter pass — race
   condition, but visual only. For mixing fluids you'd want a more
   careful approach (e.g., dominant substance per cell).

## Decision criteria for keeping this approach

- **Visual**: water looks like water, no vapor-like swirls
- **Mass conservation**: total particle count never drops (check on-screen)
- **Performance**: at least 60 FPS for ~5000 particles in a 200x150 grid
- **Behavior**: pool forms at the bottom, doesn't split into ghosts

If V0 looks promising, the V1 work would be:
- Density correction (push particles apart when over-compressed)
- Better wall collision (no bouncing)
- Substance handling (mixing reactions)
- Integration into main game (replace the FluidSolver in Receptacle)
