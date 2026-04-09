# Rigid Body ↔ Liquid Interaction — Design Spec

> **Task #1 from `2026-04-08-simulation-interactions-roadmap.md`.**
> Implementation plan: `docs/superpowers/plans/2026-04-08-rb-liquid-buoyancy-plan.md`.

## Goal

A wooden block of **irregular polygon shape** dropped into a water pool
floats at the correct depth (~2/3 submerged for density 0.65), rocks
realistically when tilted, and the surrounding water routes around its
submerged volume instead of passing through it. Iron ingot dropped in
the same pool sinks to the bottom. Ice bobs with a small crown above
the surface (density 0.92).

Same code path should work for any `SOLID`-phase substance that defines
a polygon.

## Non-goals (explicit)

The following are deliberately out of scope for this task — each is its
own future work item, listed in the roadmap:

- **Body → liquid momentum transfer.** When a body moves through liquid,
  it should push the liquid aside with its own velocity (making a wake).
  This MVP treats the body as a static obstacle per frame — the liquid
  routes around the body but the body doesn't donate its velocity to the
  surrounding cells. Result: no visible wake behind a moving block, no
  splash when a block first hits water. Acceptable for a prototype;
  defer to a later "splash/wake" task.
- **Pressure-gradient integration over the body surface.** Real buoyancy
  comes from integrating `p · n̂ dA` around the body's wetted surface.
  This MVP approximates with the simpler "displaced mass × gravity"
  formula from elementary Archimedes. The approximation is exact for a
  body fully at rest in a hydrostatic liquid column, slightly off when
  the liquid is in motion.
- **Thermal coupling.** Iron doesn't heat up, ice doesn't melt, wood
  doesn't burn. Task #2.
- **Coupling with VaporSim.** Wind doesn't push rigid bodies, rigid
  bodies don't obstruct gas flow. Task #4.
- **Rigid body → powder grid interaction.** Rigid bodies still pass
  through powder cells (grid-based solids) as today. Task #5.
- **Sub-cell precision / fraction-occupied cells.** When a body's
  polygon overlaps a cell by only 20% of the cell's area, this MVP
  still marks the cell fully occupied. Sub-cell fractional occupancy
  would require modifying the pressure solver to understand partial
  cells — deferred indefinitely.
- **Per-substance rigid body sprites or visual effects.** The body is
  still drawn as a `ColorRect` matching the polygon bounding box tinted
  by the substance colour. Task #7.

## Architecture overview

Four new pieces, touching ~6 existing files plus 3 new files.

**New**
1. `SubstanceDef.polygon: PackedVector2Array` — per-substance polygon
   vertices in substance-local pixel coordinates.
2. `src/simulation/polygon_rasterizer.gd` — CPU utility that converts a
   polygon transform → a cell-occupancy mask, point-in-polygon per cell.
3. `src/shaders/pflip_classify.glsl` gains an `obstacle_mask` binding
   that OR-combines with the existing static boundary to produce
   `cell_type`.
4. `ParticleFluidSolver.buf_obstacle_mask` — dynamic uint buffer
   uploaded each frame from the rasterizer's output.

**Modified**
- `rigid_body_mgr.gd`: spawn uses polygon, per-frame `compute_obstacle_mask()`, per-frame `apply_liquid_forces()`.
- `particle_fluid_solver.gd`: new buffer, `upload_obstacle_mask()`, classify + advect uset binding.
- `pflip_classify.glsl`: read obstacle mask, OR into WALL.
- `pflip_advect.glsl`: read obstacle mask in `is_wall()` so particles collide with bodies, not just container walls.
- `main.gd` (or `receptacle.gd`): call `compute_obstacle_mask` → `upload_obstacle_mask` each frame before `fluid_solver.step()`.
- `data/substances/`: new `wood.tres`, polygon added to `rock.tres`, `ice.tres`, `iron_ingot.tres`, `crystal.tres`.

## Per-frame flow

```
_process(delta):
    # 1. Rasterize all rigid bodies into a shared mask (CPU)
    rigid_body_mgr.compute_obstacle_mask(width, height, cell_size_px)
        → returns PackedInt32Array of size w*h, cell=1 if any body overlaps

    # 2. Upload mask to GPU
    fluid_solver.upload_obstacle_mask(mask)

    # 3. Run the solver (now treats masked cells as walls)
    fluid_solver.step(delta)

    # 4. Sync CPU-side liquid readback
    receptacle.sync_from_gpu()

    # 5. Apply liquid forces back to rigid bodies (reads the same mask
    #    + liquid_readback)
    rigid_body_mgr.apply_liquid_forces(fluid_solver, liquid_readback)
```

Order matters: the mask is built BEFORE `fluid_solver.step()` so the
pressure solve routes around bodies, and `apply_liquid_forces()` runs
AFTER `sync_from_gpu()` so it sees the post-step liquid density field.

Rasterization is O(bodies × bbox_cells) per frame. With ≤10 bodies each
covering ~50 cells, that's ~500 point-in-polygon tests/frame — ~0.1 ms
on CPU.

## Shape representation

### Decision: polygon, not SDF, not bitmap

| Option | Pros | Cons |
|---|---|---|
| **Polygon (PackedVector2Array)** | Shared with Godot CollisionPolygon2D — single source of truth. Handles rotation trivially (rotate verts). Point-in-polygon is fast enough at grid resolution. | Sub-cell precision is binary (center in/out). |
| SDF texture per substance | Sub-cell accurate. | Needs precomputed texture. Rotation requires either texture rotation or storing the polygon anyway. Over-engineered for grid-resolution physics. |
| Bitmap mask per substance | Easy to compute once. | Rotation is expensive (re-rasterize every frame), fixed scale, no clean way to share with Godot physics. |

**Picked polygon.** It's the simplest representation that composes
cleanly with Godot's existing `CollisionPolygon2D` (we pass the same
array to both physics and the rasterizer), and the point-in-polygon
test is only called on cells within the body's axis-aligned bounding
box, so the work scales with body area, not grid area.

### Polygon coordinate convention

- Vertices in substance-local **pixel** coordinates (not grid cells, not
  normalized). The origin (0, 0) is the body's centre of mass.
- Winding: counter-clockwise.
- Convex or concave both work — we use the even-odd rule in
  point-in-polygon.
- The polygon should be designed so its area × substance.density gives a
  plausible mass.

Example `wood.tres` — trapezoidal block, ~32×24 px, irregular:

```gdscript
polygon = PackedVector2Array([
    Vector2(-16, -10),
    Vector2( 18,  -12),
    Vector2( 16,   11),
    Vector2( -4,   13),
    Vector2(-18,    8),
])
```

### Backward compatibility

A substance without a polygon (empty `PackedVector2Array`) falls back to
the current 30×24 rectangle behaviour. This lets us land the polygon
field without breaking existing solids.

## Obstacle mask buffer

### Data layout

`uint[grid_width * grid_height]`, row-major, same indexing as
`buf_boundary` and `buf_density_count`. Value:
- `0` = no rigid body overlaps this cell
- `1` = at least one rigid body overlaps this cell

Using `uint` (not `float` / `bit`) keeps it simple and allows atomic
operations if we ever want parallel writes from multiple bodies.

### Upload frequency

**Once per wall frame**, not once per substep. Rigid bodies move slowly
enough compared to the solver substep (1–2 per frame at 60 FPS) that
intra-frame mask updates would be wasted work.

If `ParticleFluidSolver.step()` takes N substeps internally, all N
substeps see the same obstacle mask. The body's position is effectively
frozen from the solver's point of view during one game tick.

### Separate from `buf_boundary` — decision

Keep them distinct buffers. The container boundary is static (set at
solver setup, representing the oval receptacle). The obstacle mask is
dynamic (updated each frame, representing rigid bodies).

Alternative considered: combine them on CPU before upload ("effective
boundary"). Rejected because:
- `buf_boundary` is currently uploaded once in `_create_buffers()` and
  never touched again — it's effectively immutable. Making it mutable
  introduces a change that affects the container oval code path.
- Keeping the split lets us reason about the two separately:
  "container boundary = permanent walls" vs "obstacle mask = temporary
  walls". Debugging is easier when these are distinct.
- The cost of a second buffer binding + a second `data[idx]` read in
  the classify and advect shaders is negligible (< 1% of pass cost).

### Shader read pattern

`pflip_classify.glsl`:
```glsl
int ct;
if (boundary.data[idx] == 0 || obstacle_mask.data[idx] > 0u) {
    ct = CELL_WALL;
} else if (density.data[idx] > FLUID_THRESHOLD) {
    ct = CELL_FLUID;
} else {
    ct = CELL_AIR;
}
```

`pflip_advect.glsl`'s `is_wall()`:
```glsl
bool is_wall(int cx, int cy, int w, int h) {
    if (cx < 0 || cx >= w || cy < 0 || cy >= h) return true;
    int idx = cy * w + cx;
    return boundary.data[idx] == 0 || obstacle_mask.data[idx] > 0u;
}
```

No other solver shader needs the obstacle mask. The Jacobi, gradient,
divergence, g2p, and p2g passes all operate on `cell_type`, and
`cell_type` already encodes the obstacle as `CELL_WALL`.

## Rasterization algorithm

```gdscript
# polygon_rasterizer.gd

class_name PolygonRasterizer

static func rasterize(
    polygon_local: PackedVector2Array,
    body_pos: Vector2,
    body_rotation: float,
    grid_width: int,
    grid_height: int,
    cell_size_px: float,
    out_mask: PackedInt32Array,
) -> void:
    # 1. Transform polygon to world (receptacle-local) coordinates.
    var world_verts := PackedVector2Array()
    world_verts.resize(polygon_local.size())
    var cos_r := cos(body_rotation)
    var sin_r := sin(body_rotation)
    for i in range(polygon_local.size()):
        var v := polygon_local[i]
        world_verts[i] = Vector2(
            body_pos.x + v.x * cos_r - v.y * sin_r,
            body_pos.y + v.x * sin_r + v.y * cos_r,
        )

    # 2. Axis-aligned bounding box in world pixels.
    var min_x := INF
    var max_x := -INF
    var min_y := INF
    var max_y := -INF
    for v in world_verts:
        if v.x < min_x: min_x = v.x
        if v.x > max_x: max_x = v.x
        if v.y < min_y: min_y = v.y
        if v.y > max_y: max_y = v.y

    # 3. Convert bbox to grid cells, clamp to grid bounds.
    var cx_min: int = maxi(0, int(floor(min_x / cell_size_px)))
    var cx_max: int = mini(grid_width - 1, int(floor(max_x / cell_size_px)))
    var cy_min: int = maxi(0, int(floor(min_y / cell_size_px)))
    var cy_max: int = mini(grid_height - 1, int(floor(max_y / cell_size_px)))

    # 4. For each cell in bbox, point-in-polygon test on cell center.
    for cy in range(cy_min, cy_max + 1):
        for cx in range(cx_min, cx_max + 1):
            var cell_center := Vector2(
                (cx + 0.5) * cell_size_px,
                (cy + 0.5) * cell_size_px,
            )
            if _point_in_polygon(cell_center, world_verts):
                out_mask[cy * grid_width + cx] = 1


static func _point_in_polygon(p: Vector2, verts: PackedVector2Array) -> bool:
    # Even-odd rule (ray casting from p to +x infinity, count crossings).
    var inside := false
    var n := verts.size()
    var j := n - 1
    for i in range(n):
        var vi := verts[i]
        var vj := verts[j]
        if (vi.y > p.y) != (vj.y > p.y):
            var x_cross := (vj.x - vi.x) * (p.y - vi.y) / (vj.y - vi.y) + vi.x
            if p.x < x_cross:
                inside = not inside
        j = i
    return inside
```

**Why centre-of-cell, not area-weighted:** simpler, matches the solver's
cell-as-unit model, avoids the edge case of "cell is 40% occupied — is
it a wall?". Stair-stepping at body edges is a known trade-off, fine for
a grid-resolution simulation.

**Worst case perf:** a body whose bbox covers the entire 200×150 grid
would do 30k point-in-polygon tests. Each test is O(polygon_verts),
typically 5–10 vertices for our substance polygons, so ~150k scalar ops
— still under 1 ms. Bodies that cover the whole grid are a pathological
case anyway.

## Buoyancy force computation

### Formula

For each rigid body `b`:

```
submerged_mass = Σ over cells(idx) in b's mask where liquid_readback.densities[idx] > 0:
                    liquid_substance_density(idx) * cell_area_px² * liquid_readback.densities[idx]

submerged_center = Σ ... weighted_cell_center / Σ ... weight

F_buoyancy = submerged_mass * GRAVITY   (upward)
```

Applied at `submerged_center` (not the body's centre of mass — that's
what gives torque when the body is asymmetrically submerged).

### Reading liquid state

- `liquid_readback.densities[idx]` — normalized fill (1.0 = 8 particles
  per cell, the reference full density).
- `liquid_readback.markers[idx]` — substance id of the dominant liquid
  in the cell. Substance density looked up via
  `SubstanceRegistry.get_substance(markers[idx]).density`.

For mixed cells (water + mercury), `markers[idx]` returns whichever
substance won the racy p2g write. In the MVP we accept this error —
it only matters at cell-level mixed boundaries, and the error is small
compared to the overall submerged volume. A future refinement could
use the mass-weighted cell density from `buf_cell_mass` we just added
for the variable-density solver (read it back from the GPU), but that
adds a readback stall and isn't worth it for the MVP.

### Units

`cell_area_px²` is `CELL_SIZE * CELL_SIZE` (currently 4×4 = 16). The
actual force magnitude is `submerged_mass × 60 (GRAVITY constant in
solver pixels/s²)`. The body's mass in `rigid_body_mgr.gd` is currently
`substance.density × 0.5` (a placeholder). We need to reconcile:

**Decision**: recompute body mass from the polygon area × substance
density × `cell_area_px² / PIXELS_PER_SIM_UNIT`. This gives a body mass
in the same units as the buoyancy force, so the equilibrium depth comes
out right without ad-hoc tuning.

Concretely, in `spawn_object()`:
```gdscript
var area_px := _polygon_area(substance.polygon)
body.mass = substance.density * area_px * MASS_SCALE
```
where `MASS_SCALE` is a single tunable constant that also shows up in
`apply_liquid_forces()` so that buoyancy and gravity balance at the
physically correct depth.

### When is the force applied?

In `rigid_body_mgr._physics_process(delta)`, using
`body.apply_force(upward, submerged_center - body.global_position)`.
`_physics_process` is Godot's physics tick (60 Hz by default), which
lines up with the solver's wall frame rate.

## Drag force

### MVP: stationary-fluid approximation

```
F_drag = -DRAG_COEF * body.linear_velocity * submerged_cell_count
```

Applied to the centre of mass (no angular drag in MVP). `DRAG_COEF`
starts at ~5.0 and gets tuned empirically.

**Rationale for the stationary-fluid approximation:** proper drag needs
`fluid_velocity - body_velocity` per cell, which requires a readback of
the solver's `u_vel` and `v_vel` buffers. That's a new GPU→CPU sync per
frame, which is expensive. The stationary approximation is wrong when
the liquid is genuinely in motion (e.g. a strong current flowing past
a fixed block), but for the common case of "a block bobbing in a still
pool" it's indistinguishable.

**When the approximation hurts:** if the user pours water onto a
floating block, the incoming liquid should push the block aside. Under
our approximation, the block sees only its own velocity and doesn't
feel the incoming flow. Accept this limitation in MVP; add velocity
readback as a later refinement.

## Stability concerns

### 1. Rapidly changing cell states

When a body moves, cells flip from FLUID to WALL and vice versa between
frames. The existing pflip_advect.glsl has a "stuck in wall" fallback
(lines 263–272 in the current code) that pushes particles out of wall
cells using a 4-connected search. This already handles particles caught
inside a newly-arrived body — no new code needed.

### 2. Body inside container

Existing oval container walls are StaticBody2D collision shapes. A
rigid body inside the container collides with those physically, so the
body can't tunnel through the container. The fluid solver's obstacle
mask doesn't change this — the container boundary is handled separately
by `buf_boundary`.

### 3. Bodies overlapping each other

Godot physics prevents rigid bodies from interpenetrating. The rasterizer
simply ORs each body's mask contribution, so overlapping masks are
idempotent. No special handling.

### 4. Body sitting exactly on liquid surface

At the equilibrium depth, the body's bottom is submerged and top is
above water. Buoyancy and gravity balance; tiny perturbations get
damped by drag. This is a stable equilibrium by construction (buoyancy
increases with depth, gravity is constant), so we expect damped
oscillation, not divergence.

### 5. Polygon area near zero

A substance with a degenerate polygon (< 3 vertices, zero area) would
produce zero mass and zero buoyancy. The spawn method should detect
this and refuse to create the body, with a warning log.

### 6. Body partially outside the grid

If a body extends outside the grid bounds (e.g. a wall hit pushing it
briefly out), the rasterizer clamps to grid bounds, so we only count
cells inside. Buoyancy force is then computed from the visible cells
only. This is an under-estimate but a transient; the body's Godot
physics will resolve the wall contact within a frame or two.

## Integration points with existing code

| File | Change | Lines (approx) |
|---|---|---|
| `src/substance/substance_def.gd` | Add `@export var polygon: PackedVector2Array` + `@export var polygon_pixel_scale: float = 1.0` | +2 |
| `src/simulation/rigid_body_mgr.gd` | Use polygon in `spawn_object()`, add `compute_obstacle_mask()`, add `_physics_process()` with `apply_liquid_forces()` | +~100 |
| `src/simulation/polygon_rasterizer.gd` (new) | Utility class, static methods | +~60 |
| `src/simulation/particle_fluid_solver.gd` | `buf_obstacle_mask`, `upload_obstacle_mask()`, extend classify + advect usets | +~30 |
| `src/shaders/pflip_classify.glsl` | OR obstacle mask into WALL | +5 |
| `src/shaders/pflip_advect.glsl` | Extend `is_wall()` | +3 |
| `src/receptacle/receptacle.gd` | Orchestration: rasterize → upload → step → forces | +~10 |
| `src/main.gd` | Possibly update the tick loop | +~5 |
| `data/substances/wood.tres` (new) | New substance | — |
| `data/substances/rock.tres`, `ice.tres`, `iron_ingot.tres`, `crystal.tres` | Add polygon field | ~15 per file |

Total: ~250 lines of GDScript, ~10 lines of GLSL, 5 resource updates.

## Test strategy

### Unit tests (automated, no visuals)

Under `tests/unit/` (new directory). A minimal test runner script that
runs them headless via `godot --headless --script`.

1. **Polygon rasterizer — axis-aligned square**
   Given a square `[(-4,-4), (4,-4), (4,4), (-4,4)]` at origin, no
   rotation, 2px cells, expect a 4×4 cell block starting at cell (-2,-2).

2. **Polygon rasterizer — translated square**
   Same square at position (10, 0). Expect same 4×4 block shifted 5 cells.

3. **Polygon rasterizer — rotated square**
   Same square rotated 45°. Expect a diamond pattern with more marked
   cells (corners extend beyond the original bbox).

4. **Polygon rasterizer — irregular pentagon**
   The wood polygon defined in the design. Compare against a hand-
   computed expected mask.

5. **Polygon rasterizer — clamping**
   Polygon whose bbox extends beyond the grid. Verify no out-of-bounds
   writes and only in-grid cells are marked.

6. **Polygon area**
   Rectangle area via the shoelace formula matches w*h.

### Integration tests (automated with simulation)

Under `tests/integration/`. These run the actual fluid solver headless
and verify numerical outcomes.

7. **Block in empty receptacle falls freely**
   Spawn one wooden block at the top, step 2 seconds, verify it's on
   the floor. Baseline sanity check — no buoyancy involvement.

8. **Block in full water pool floats at ~1/3 above surface**
   Fill the receptacle with water, spawn a wooden block (density 0.65),
   step 3 seconds, verify the block's top is above the liquid surface
   and the bottom is below, with the ratio within 20% of `1 - 0.65`.
   Tolerance is generous because drag and oscillation affect the exact
   final position.

9. **Iron ingot sinks**
   Same setup with iron ingot (density 7.87), step 3 seconds, verify
   the block is at the bottom of the receptacle.

10. **Ice floats with ~8% above surface**
    Ice density 0.92, step 3 seconds, verify bottom of ice is below
    surface and top is just above, within tolerance.

11. **Wood routes water around it**
    Pour water sideways onto a fixed (kinematic) wooden block. Verify
    water particles don't appear inside the block's cells (i.e. that
    the obstacle mask is correctly marking cells as walls).

12. **Multiple bodies don't double-apply**
    Drop two blocks overlapping horizontally (both at the surface).
    Verify both float, neither gets double forces from shared cells.

### Manual tests (visual confirmation, list for the implementer to run)

After each implementation phase completes, the following manual checks
should look "right":

- **M1** (after Phase 0): drop a wooden block in empty receptacle — it
  appears as an irregular polygon shape, not a 30×24 rectangle.
- **M2** (after Phase 3): drop any block into water — water cells under
  the block stop being particles (rasterizer working). No forces yet,
  so the block still falls straight through.
- **M3** (after Phase 4): drop wooden block into water — it floats at
  ~1/3 above surface. Iron sinks. Ice bobs.
- **M4** (after Phase 4): spawn a floating wooden block, drag it below
  the surface with the mouse, release — it should rise back to
  equilibrium with visible overshoot/bounce.
- **M5** (after Phase 5): same as M4 but the overshoot should damp out
  within a couple of oscillations. Raw M4 (no drag) should oscillate
  indefinitely or grow.
- **M6** (after Phase 6): drop every solid substance in turn. Rock
  sinks fast. Wood floats. Ice bobs. Iron sinks. Crystal sinks (defined
  density > 1).
- **M7**: pour water over a floating block. The block's rotation should
  change as the surrounding liquid level rises asymmetrically.

## Open questions / decisions deferred to implementation

1. **Body mass formula tuning.** The `MASS_SCALE` constant that ties
   body mass (Godot units) to buoyancy mass (simulation units) will
   need to be tuned by trial with the ice test case, since ice's
   near-water density makes it the most sensitive.

2. **`_physics_process` vs `_process` for force application.** Godot
   physics updates in `_physics_process` at a fixed 60 Hz, but the
   fluid solver runs in `_process` at wall FPS. There's a minor phase
   mismatch. Likely negligible. Start with `_physics_process` for
   numerical stability; switch to `_process` if the phase mismatch
   causes artefacts.

3. **Whether to expose the velocity readback for proper drag.** MVP
   uses stationary-fluid approximation. If the "pour water onto a
   floating block" test (M7) looks bad, add velocity readback as a
   small follow-up before shipping. Otherwise, ship without.

4. **Grid cell centre vs. corner for rasterization.** Using centre is
   simpler but is biased by half a cell compared to sampling at the
   corner. Corner sampling would mark slightly more cells. Pick centre,
   revisit if stair-stepping at low body-relative-to-cell-size looks
   bad.

## Why this design is the right scope

- **Minimal new infrastructure.** One new buffer, one new class, two
  shader edits — that's the entire footprint in the fluid solver code.
- **Reuses existing machinery.** The variable-density Jacobi we just
  shipped handles the harder case (mercury sinking through water).
  This design only adds "rigid solid = static wall cells" on top of it.
- **Backward compatible.** Substances without a polygon keep working
  as 30×24 rectangles. Wood can be added without touching existing
  substances.
- **Testable at each phase.** The polygon rasterizer is a pure
  function, unit-testable without the solver. The buffer plumbing is
  smoke-testable without force feedback. The force feedback is visibly
  verifiable without the automated tests. Each phase delivers a
  manually-observable intermediate result.
- **Opens the door for tasks #2, #4, #5, #7.** The cell-occupancy mask
  is a prerequisite infrastructure piece for thermal coupling, gas
  drag, powder contact, and per-substance visuals. This spec pays for
  infrastructure that four other specs need.
