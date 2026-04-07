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

## Investigation findings

### "Liquid is leaking" — actually compression, not a leak

User report: pool appears to shrink while pouring continues, and continues to shrink after the pour stops. Hypothesized "pixel gap in the floor" causing leak.

**Investigation result: there is no leak.** Verified by adding `debug_particle_locations()` which counts all live particles and reports how many are in wall cells vs interior cells.

Test: continuous spawn for 600 frames (5 cells/frame × 4 particles each = 11852 total particles), then watched particle count and pool size for another 30 seconds.

```
[f600]  particles=11852 in_wall=0 visible=230 (51.5 p/cell) x=[77..130] y=[8..149]
[f1200] particles=11852 in_wall=0 visible=190 (62.4 p/cell) x=[73..137] y=[114..149]
[f1800] particles=11852 in_wall=0 visible=81  (146.3 p/cell) x=[73..137] y=[145..149]
[f2340] particles=11852 in_wall=0 visible=59  (200.9 p/cell) x=[73..137] y=[145..149]
```

- **Particle count is constant** at 11852 throughout — no particles disappear, none get stuck in walls.
- **The visible pool keeps shrinking**: from 230 cells (51 particles/cell) at frame 600 down to 59 cells (200 particles/cell!) at frame 2340.

This is the **PIC/FLIP compression artifact** documented in V0 limitation #1. Particles cluster densely in the lowest-pressure region (the curved cauldron bottom). The pressure projection step enforces "velocity is divergence-free" but **does not enforce a target density**, so there's no force pushing particles apart when they're over-packed.

User perception is "leaking" because the visible pool gets smaller — but it's actually getting *denser*, not losing mass. 200 particles in one cell render the same as 4 (we cap density at 1.0 for alpha), so visually you can't tell.

The cauldron's curved bottom amplifies this: the deepest point is the energy minimum, so particles continuously fall *into* it and pack arbitrarily tight. A flat-bottomed container would compress less aggressively.

### Fix for compression: density-driven divergence correction

Standard PIC/FLIP solvers add a "density correction" term to the divergence:

```
divergence_corrected = divergence_velocity + k * max(0, density - target_density) / dt
```

Where `k` is a stiffness constant (~1.0) and `target_density` is the rest density (4 particles/cell in our setup). When a cell has *more* particles than target, the corrected divergence becomes positive, telling the pressure solve "this cell is over-packed, push particles outward". The pressure gradient then pushes neighboring face velocities outward, and the next g2p step picks up those velocities and the particles spread out.

This is implemented in roughly 5-10 lines added to `fluid_divergence.glsl` (or a new shader, since the existing one is shared with the grid solver and I don't want to change its semantics there). Required for V1.

## TODO 1: Liquid peppered with black/faded cells (dithering)

User observation: even within the visible pool, individual cells appear black or much fainter than their neighbors, creating a visible salt-and-pepper / dithered appearance.

### Root cause hypothesis (needs verification)

This is most likely the **per-cell particle count being uneven** due to the random sub-cell jitter at spawn time:

```gdscript
for ii in range(4):
    var jx := randf() * 0.8 + 0.1
    var jy := randf() * 0.8 + 0.1
    positions.append(Vector2(cx + dx + jx, cy + dy + jy))
```

Each particle is spawned at a random sub-cell position. Over time, as they advect via PIC/FLIP, they end up in cells with variable counts: some cells get 8 particles (density 2.0), others get 1 particle (density 0.25), some get 0 (density 0).

Cells with 0 particles render as background (dark). Cells with low count render with low alpha. The result is a checkerboard / stipple pattern.

This is amplified by:
- Bilinear scatter spreading particles to 4 grid cells with fractional weights
- Pressure projection moving particles in non-uniform ways
- The gradient sharpening artifacts (cells gain or lose particles unevenly)

### Options for fixing

1. **Increase particles per cell** (cheapest). Spawn 8-16 particles per cell instead of 4. With more particles, statistical fluctuation per cell drops as 1/sqrt(N). Cost: ~2-4× memory, ~2-4× scatter atomics.

2. **Render with bilinear upsampling.** Instead of one pixel per cell, render at a higher resolution and bilinear-interpolate density between cells. Smooths out gaps. Cost: only renderer work, no solver change.

3. **Density-based opacity floor.** When density > 0, render with at least alpha 0.5 (or some minimum). Prevents very faint cells from looking like holes. Cost: 1 line in renderer. Con: blocky appearance.

4. **Anisotropic kernel for density estimation.** Standard fluid rendering technique: instead of "particle is in cell C", spread each particle's contribution to a 3×3 or 5×5 kernel via Gaussian weights. Smoother density field. Cost: rewrite the density-from-particles step (~20 lines).

5. **Marching squares / metaballs renderer.** Treat particles as metaballs and run marching squares on a density iso-surface. Produces smooth fluid surface. The existing `marching_squares_renderer.gd` already does this for grid-based fluid; could be adapted. Cost: moderate, mostly renderer side.

6. **Increase classify threshold + bilinear render**. Use a higher threshold for "this cell is fluid" (like 0.5 instead of 0.001) so only well-populated cells render. Combined with bilinear upsampling between cells, this would give clean edges without gaps.

**Recommendation:** Combine #1 (more particles per cell, e.g., 8) with #4 (Gaussian density kernel). #1 fixes the statistical noise; #4 makes the density field smooth even at the boundary. Both are ~30 lines total.

## TODO 3: Add viscosity (water feels too dynamic / lively)

User observation: water moves too freely — swirls and momentum persist
forever, unlike real water which has internal drag.

We currently have zero viscosity. Real water has *some*. Implementation
in PIC/FLIP is a velocity-diffusion pass: after pressure projection but
before g2p, each grid face's velocity averages with a fraction of its
neighbors. ~30 lines, one new shader. Tunable: 0 (none) to 1 (molasses).

```glsl
// pflip_viscosity.glsl (sketch)
float laplacian_u = u[i-1] + u[i+1] + u[j-1] + u[j+1] - 4*u[ij];
u_new[ij] = u[ij] + viscosity * dt * laplacian_u;
// (and same for v)
```

Standard fluid sim trick. Probably want viscosity ≈ 0.05–0.2 to start.

## TODO 2: Slow falling and movement speed

User observation: water falls and moves visibly slower than real water would.

### Why it's slow

Three causes, ranked by impact:

1. **Velocity cap `MAX_VELOCITY = 30`** in `pflip_advect.glsl`. At dt = 1/120 sec (the test runs at ~100 FPS), max distance per frame = 30/120 = 0.25 cells. To cross the 150-cell-tall cauldron at terminal velocity = 150 / 30 = **5 seconds**. Real water in a 60 cm cauldron would fall in ~0.35 seconds (free fall). So we're ~14× slower than reality.

2. **Damping `DAMPING = 0.999`**. Per-frame damping at 120 FPS = 0.999^120 ≈ 0.886, i.e. 11% velocity loss per second. Mild but adds up.

3. **Gravity `GRAVITY = 20.0` cells/sec²**. Real gravity at 1 cell = 1 cm would be 980 cells/sec². We're 50× weaker than real gravity.

The reason velocities are capped is the **CFL condition**: to prevent particles from *tunneling through walls* in one frame, the per-frame displacement must be < 1 cell. At dt = 1/120 the limit is 120 cells/sec. So `MAX_VELOCITY = 30` is way under the limit and could be raised.

### NOT viscosity

We don't have any viscosity term. Viscosity in real PIC/FLIP would be implemented as a velocity diffusion step (each grid face's velocity averages with neighbors). We don't do that. So this isn't a viscosity problem.

### Options for tuning

1. **Raise `MAX_VELOCITY` to 60 or 100** (1 line). Will let particles fall faster. CFL is fine — at 120 FPS, displacement per frame at v=100 is 0.83 cells, still under 1. Direct fix.

2. **Raise `GRAVITY` to 60-100** (1 line). Particles accelerate to terminal velocity faster. With `MAX_VELOCITY` also raised, they hit the higher cap quickly. Combined with #1, water falls in ~1 second instead of 5.

3. **Reduce damping** from 0.999 → 1.0 (1 line). Eliminates the 11%/sec drag. Might cause swirls to persist longer (could look more "alive" or could look unstable).

4. **Sub-stepping in `step()`** (10 lines). Run the simulation N times per frame with `dt/N`. This **doesn't** make particles fall faster — same physics over the same wall-clock time — but it allows raising the velocity cap (each substep covers less ground, so less risk of tunneling). Trade-off: linear performance cost.

5. **Better wall collision** (50 lines). Implement proper continuous collision detection (raycast each particle's swept path against walls) instead of "discrete check at new position". Then any velocity is safe and `MAX_VELOCITY` can be removed entirely. Ideal solution but more code.

**Recommendation:** Start with #1 + #2 (raise both `MAX_VELOCITY` and `GRAVITY` to ~80). This is two single-line changes and will make water visibly fall fast enough. If tunneling becomes an issue (water disappearing into walls), add #4 (substepping with N=2-4). If you want a "real water" feel later, do #5.

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
