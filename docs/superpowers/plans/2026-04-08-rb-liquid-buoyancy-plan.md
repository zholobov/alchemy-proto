# Rigid Body ↔ Liquid Buoyancy — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans
> to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax
> for tracking.

**Spec:** `docs/superpowers/specs/2026-04-08-rb-liquid-buoyancy-design.md`

**Goal:** Wooden block of irregular polygon shape floats correctly in a
water pool, iron sinks, ice bobs, drag damps oscillation. Water routes
around submerged rigid bodies instead of passing through them.

**Architecture:** Per-substance polygon → CPU rasterizer → GPU obstacle
mask buffer → `pflip_classify` + `pflip_advect` treat masked cells as
walls → back-pressure: iterate mask cells per-body to compute buoyancy
and drag, apply forces via Godot physics.

**Tech Stack:** Godot 4.6 (GDScript + GLSL compute shaders), existing
`ParticleFluidSolver` PIC/FLIP infrastructure.

---

## Phase ordering rationale

Each phase produces an independently-testable, manually-observable
result. If the plan is abandoned mid-way, every completed phase still
leaves the codebase in a working state — no half-plumbed dangling state.

| Phase | Delivers | Verifiable by |
|---|---|---|
| 0 | Polygon shape data + irregular body visual | M1 — drop block, see shape |
| 1 | Rasterizer utility (pure CPU) | Unit tests 1–6 |
| 2 | Obstacle mask buffer infrastructure (no rasterizer wiring) | Smoke test: solver still runs |
| 3 | Rasterizer → solver wiring | M2 — water routes around body |
| 4 | Buoyancy force | M3, M4, Integration tests 8–10 |
| 5 | Drag force | M5 — oscillation damps out |
| 6 | Per-substance polygons (rock, ice, iron, crystal) | M6 — all solids behave correctly |
| 7 | Automated test harness + CI wiring | Integration tests run headless |

---

## Phase 0 — Polygon data + wood substance

Adds the `polygon` field to `SubstanceDef`, creates `wood.tres`, and
updates `rigid_body_mgr.spawn_object()` to use the polygon when
defined (falling back to the existing 30×24 rectangle when empty).

No fluid solver changes. No rasterizer. Just shape data flowing from
a `.tres` file into a `CollisionPolygon2D` and a matching visual.

### Task 0.1 — Add `polygon` field to `SubstanceDef`

**Files:**
- Modify: `src/substance/substance_def.gd:27` (after the Thermal group,
  before Flammability)

**Steps:**

- [ ] **Step 1: Add the field**

```gdscript
@export_group("Shape (SOLID phase only)")
## Polygon vertices in substance-local pixel coordinates, counter-
## clockwise. The rigid body's CollisionPolygon2D, visual, and fluid
## obstacle mask are all derived from this. Empty array falls back to
## the legacy 30×24 rectangle so existing substances keep working.
@export var polygon: PackedVector2Array = PackedVector2Array()
```

Insert this after the `@export var conductivity_thermal` line.

- [ ] **Step 2: Verify the project still imports cleanly**

Run: `godot --path . --headless --import 2>&1 | tail -5`
Expected: no errors, import succeeds.

- [ ] **Step 3: Verify all existing substance .tres files still load**

Run:
```bash
godot --path . src/main.tscn --quit-after 30 2>&1 | grep -iE "error|warning" | head -20
```
Expected: no substance-related errors. The new `polygon` field should
default to an empty array and existing substances (no `polygon=` line)
should use the default.

- [ ] **Step 4: Commit**

```bash
git add src/substance/substance_def.gd
git commit -m "feat(substance): add polygon field for rigid body shape"
```

### Task 0.2 — Create `wood.tres`

**Files:**
- Create: `data/substances/wood.tres`

**Steps:**

- [ ] **Step 1: Write the resource file**

Look at the existing `data/substances/rock.tres` for the `[gd_resource]`
header format, then create `wood.tres` with:

```
[gd_resource type="Resource" script_class="SubstanceDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://src/substance/substance_def.gd" id="1"]

[resource]
script = ExtResource("1")
substance_name = "Wood"
phase = 0
density = 0.65
viscosity = 1.0
flip_ratio = 0.95
melting_point = 1000.0
boiling_point = 2000.0
flash_point = 200.0
conductivity_thermal = 0.03
polygon = PackedVector2Array(-16, -10, 18, -12, 16, 11, -4, 13, -18, 8)
flammability = 0.8
burn_rate = 0.5
energy_density = 0.5
burn_products = []
acidity = 7.0
oxidizer_strength = 0.0
reducer_strength = 0.1
volatility = 0.0
conductivity_electric = 0.0
magnetic_permeability = 0.0
base_color = Color(0.45, 0.3, 0.15, 1.0)
opacity = 1.0
luminosity = 0.0
luminosity_color = Color(1.0, 1.0, 1.0, 1.0)
glow_intensity = 0.0
```

Note: the polygon is 5 vertices defining an irregular pentagon (wider
on the right, shorter on the left, slightly sloped top and bottom).
This makes it visibly non-rectangular so we can see at a glance the
polygon is being used.

- [ ] **Step 2: Register wood in `SubstanceRegistry`**

Find the `SUBSTANCE_PATHS` list in `src/substance/substance_registry.gd`
and add `"res://data/substances/wood.tres"` to it.

- [ ] **Step 3: Verify registration**

Run the game briefly:
```bash
godot --path . src/main.tscn --quit-after 60 2>&1 | grep -iE "wood|error" | head -10
```
Expected: no errors. The shelf should have a new "Wood" button (visible
in manual testing, not the quit-after run).

- [ ] **Step 4: Commit**

```bash
git add data/substances/wood.tres src/substance/substance_registry.gd
git commit -m "feat(substance): add wood with irregular polygon shape"
```

### Task 0.3 — Update `rigid_body_mgr.spawn_object()` to use polygon

**Files:**
- Modify: `src/simulation/rigid_body_mgr.gd:20-48`

**Steps:**

- [ ] **Step 1: Replace rectangle-only shape logic with polygon fallback**

Change the `spawn_object` function to:

```gdscript
func spawn_object(substance_id: int, screen_pos: Vector2) -> void:
    var substance := SubstanceRegistry.get_substance(substance_id)
    if not substance or substance.phase != SubstanceDef.Phase.SOLID:
        return

    var body := RigidBody2D.new()
    body.gravity_scale = 1.0
    body.position = screen_pos - receptacle_position

    # Use the substance's polygon if defined, otherwise fall back to a
    # 30×24 rectangle. The same vertex array drives both the collision
    # shape and the visual.
    var verts: PackedVector2Array
    if substance.polygon.size() >= 3:
        verts = substance.polygon
    else:
        verts = PackedVector2Array([
            Vector2(-15, -12),
            Vector2( 15, -12),
            Vector2( 15,  12),
            Vector2(-15,  12),
        ])

    var collision := CollisionPolygon2D.new()
    collision.polygon = verts
    body.add_child(collision)

    var visual := Polygon2D.new()
    visual.polygon = verts
    visual.color = substance.base_color
    body.add_child(visual)

    # Mass from polygon area × density so buoyancy equilibrium depth
    # comes out correct from the physics, not from ad-hoc scaling.
    var area := _polygon_area(verts)
    body.mass = substance.density * area * MASS_SCALE

    body.set_meta("substance_id", substance_id)
    body.set_meta("substance_name", substance.substance_name)

    add_child(body)
    _bodies.append(body)


static func _polygon_area(verts: PackedVector2Array) -> float:
    # Shoelace formula. Returns absolute area in the polygon's
    # coordinate system (pixels²).
    var n := verts.size()
    if n < 3:
        return 0.0
    var a := 0.0
    var j := n - 1
    for i in range(n):
        a += (verts[j].x + verts[i].x) * (verts[j].y - verts[i].y)
        j = i
    return abs(a) * 0.5
```

- [ ] **Step 2: Add `MASS_SCALE` constant at the top of the class**

Near the class-level declarations (after `var _bodies`):

```gdscript
## Converts polygon-area × density (pixels² × normalized density) into
## a Godot RigidBody2D mass in the same unit system as the buoyancy
## forces in `apply_liquid_forces()`. Tuned empirically against the
## ice-floats test (ice density 0.92 should sit with ~8% above surface).
## If changed here, also update the MASS_SCALE reference in
## apply_liquid_forces to keep the equilibrium depth stable.
const MASS_SCALE: float = 0.01
```

Starting value `0.01`; final value set during Phase 4 tuning.

- [ ] **Step 3: Run the project, verify no errors**

```bash
godot --path . src/main.tscn --quit-after 60 2>&1 | grep -iE "error" | head -10
```
Expected: no errors.

- [ ] **Step 4: Manual test M1**

Launch the game manually, pick "Wood" from the shelf, drop it in the
empty receptacle. Verify:
- The body visibly has the irregular pentagon shape from `wood.tres`
  (NOT a rectangle).
- It falls under gravity and rests on the receptacle bottom.
- Rotation looks natural (no weird spinning from wrong inertia).

Also drop a Rock. It should still appear as a 30×24 rectangle (since
rock.tres has no polygon yet) — this verifies the fallback path works.

- [ ] **Step 5: Commit**

```bash
git add src/simulation/rigid_body_mgr.gd
git commit -m "feat(rigid_body): use polygon shape + mass from area"
```

---

## Phase 1 — Polygon rasterizer

A pure CPU utility that converts `(polygon, transform, grid_dims)` →
occupancy mask. No solver integration yet. Tested in isolation.

### Task 1.1 — Create `polygon_rasterizer.gd` class

**Files:**
- Create: `src/simulation/polygon_rasterizer.gd`

**Steps:**

- [ ] **Step 1: Write the class file**

```gdscript
class_name PolygonRasterizer
extends RefCounted
## Pure CPU utility that rasterizes a polygon into a grid cell mask.
## Used by RigidBodyMgr to build the obstacle mask uploaded to the
## PIC/FLIP fluid solver each frame.
##
## All methods are static — this class holds no state.

## Rasterize one polygon into `out_mask`, setting `1` at cells whose
## centre falls inside the transformed polygon.
##
## polygon_local: vertex positions in body-local pixel coordinates
## body_pos:      body world position (receptacle-local) in pixels
## body_rotation: radians, counter-clockwise positive
## grid_width/height: grid dimensions in cells
## cell_size_px:  pixels per cell
## out_mask:      pre-sized PackedInt32Array of length grid_width*grid_height
static func rasterize(
    polygon_local: PackedVector2Array,
    body_pos: Vector2,
    body_rotation: float,
    grid_width: int,
    grid_height: int,
    cell_size_px: float,
    out_mask: PackedInt32Array,
) -> void:
    var n := polygon_local.size()
    if n < 3:
        return

    # Transform polygon to world space.
    var world_verts := PackedVector2Array()
    world_verts.resize(n)
    var cos_r := cos(body_rotation)
    var sin_r := sin(body_rotation)
    for i in range(n):
        var v := polygon_local[i]
        world_verts[i] = Vector2(
            body_pos.x + v.x * cos_r - v.y * sin_r,
            body_pos.y + v.x * sin_r + v.y * cos_r,
        )

    # Axis-aligned bounding box.
    var min_x := world_verts[0].x
    var max_x := min_x
    var min_y := world_verts[0].y
    var max_y := min_y
    for i in range(1, n):
        var v := world_verts[i]
        if v.x < min_x: min_x = v.x
        elif v.x > max_x: max_x = v.x
        if v.y < min_y: min_y = v.y
        elif v.y > max_y: max_y = v.y

    # Bounding box in cell indices, clamped to grid.
    var cx_min: int = maxi(0, int(floor(min_x / cell_size_px)))
    var cx_max: int = mini(grid_width - 1, int(floor(max_x / cell_size_px)))
    var cy_min: int = maxi(0, int(floor(min_y / cell_size_px)))
    var cy_max: int = mini(grid_height - 1, int(floor(max_y / cell_size_px)))
    if cx_min > cx_max or cy_min > cy_max:
        return  # Bounding box entirely outside grid.

    # Point-in-polygon test per cell center.
    for cy in range(cy_min, cy_max + 1):
        var py := (cy + 0.5) * cell_size_px
        for cx in range(cx_min, cx_max + 1):
            var px := (cx + 0.5) * cell_size_px
            if _point_in_polygon(px, py, world_verts):
                out_mask[cy * grid_width + cx] = 1


static func _point_in_polygon(px: float, py: float, verts: PackedVector2Array) -> bool:
    # Even-odd rule: cast ray to +x from (px,py), count edge crossings.
    var inside := false
    var n := verts.size()
    var j := n - 1
    for i in range(n):
        var vi := verts[i]
        var vj := verts[j]
        if (vi.y > py) != (vj.y > py):
            var x_cross := (vj.x - vi.x) * (py - vi.y) / (vj.y - vi.y) + vi.x
            if px < x_cross:
                inside = not inside
        j = i
    return inside


static func polygon_area(verts: PackedVector2Array) -> float:
    # Shoelace formula, absolute value. Pixels².
    var n := verts.size()
    if n < 3:
        return 0.0
    var a := 0.0
    var j := n - 1
    for i in range(n):
        a += (verts[j].x + verts[i].x) * (verts[j].y - verts[i].y)
        j = i
    return abs(a) * 0.5
```

- [ ] **Step 2: Verify the script parses**

```bash
godot --path . --headless --quit 2>&1 | grep -iE "polygon_rasterizer|error" | head -10
```
Expected: no parse errors.

### Task 1.2 — Unit test harness

**Files:**
- Create: `tests/unit/test_polygon_rasterizer.gd`
- Create: `tests/unit/run_unit_tests.gd`

**Steps:**

- [ ] **Step 1: Write the test runner**

`tests/unit/run_unit_tests.gd`:
```gdscript
extends SceneTree
## Headless unit test runner. Discovers scripts in tests/unit/ matching
## test_*.gd, calls each script's run_tests() static method, collects
## results, and exits with code 0 (all pass) or 1 (any fail).
##
## Usage: godot --path . --headless --script tests/unit/run_unit_tests.gd

func _init() -> void:
    var total := 0
    var passed := 0
    var failures: Array[String] = []

    var dir := DirAccess.open("res://tests/unit/")
    if not dir:
        push_error("Cannot open tests/unit/")
        quit(1)
        return

    dir.list_dir_begin()
    while true:
        var fname := dir.get_next()
        if fname == "":
            break
        if not fname.begins_with("test_") or not fname.ends_with(".gd"):
            continue
        var script_path := "res://tests/unit/" + fname
        var script := load(script_path) as GDScript
        if not script:
            failures.append("%s: failed to load" % fname)
            total += 1
            continue
        var results: Array = script.run_tests()
        for r in results:
            total += 1
            if r["pass"]:
                passed += 1
            else:
                failures.append("%s::%s — %s" % [fname, r["name"], r["msg"]])
    dir.list_dir_end()

    print("\n=== Unit tests: %d/%d passed ===" % [passed, total])
    if failures.size() > 0:
        print("Failures:")
        for f in failures:
            print("  " + f)
        quit(1)
    else:
        quit(0)
```

- [ ] **Step 2: Write the rasterizer test file**

`tests/unit/test_polygon_rasterizer.gd`:
```gdscript
extends RefCounted
## Unit tests for PolygonRasterizer.

static func run_tests() -> Array:
    var results: Array = []
    results.append(_test_axis_aligned_square())
    results.append(_test_translated_square())
    results.append(_test_rotated_square())
    results.append(_test_irregular_pentagon())
    results.append(_test_out_of_bounds_clamping())
    results.append(_test_polygon_area_rectangle())
    return results


static func _make_mask(w: int, h: int) -> PackedInt32Array:
    var m := PackedInt32Array()
    m.resize(w * h)
    return m


static func _count_set(mask: PackedInt32Array) -> int:
    var c := 0
    for v in mask:
        if v > 0:
            c += 1
    return c


static func _test_axis_aligned_square() -> Dictionary:
    # 8×8 px square centred at (10, 10) in a 10×10 grid with 2 px cells.
    # Expected: cells where center ∈ [6, 14] × [6, 14].
    # Cell centres: (1, 3, 5, 7, 9, 11, 13, 15, 17, 19) in each axis.
    # → cell centres in [6,14] are at x=7,9,11,13 and y=7,9,11,13.
    # So 4×4 = 16 cells.
    var poly := PackedVector2Array([
        Vector2(-4, -4), Vector2(4, -4), Vector2(4, 4), Vector2(-4, 4)
    ])
    var mask := _make_mask(10, 10)
    PolygonRasterizer.rasterize(poly, Vector2(10, 10), 0.0, 10, 10, 2.0, mask)
    var count := _count_set(mask)
    var ok := count == 16
    return {
        "name": "axis_aligned_square",
        "pass": ok,
        "msg": "expected 16 cells, got %d" % count,
    }


static func _test_translated_square() -> Dictionary:
    # Same square but at (20, 10). Same 4×4 = 16 cells, shifted 5 cells right.
    var poly := PackedVector2Array([
        Vector2(-4, -4), Vector2(4, -4), Vector2(4, 4), Vector2(-4, 4)
    ])
    var mask := _make_mask(20, 10)
    PolygonRasterizer.rasterize(poly, Vector2(20, 10), 0.0, 20, 10, 2.0, mask)
    var count := _count_set(mask)
    # Verify we can identify which cells are set — check one corner.
    # Cell (8, 3) has centre (17, 7) which is inside [16,24]×[6,14] → should be set.
    var ok := count == 16 and mask[3 * 20 + 8] == 1
    return {
        "name": "translated_square",
        "pass": ok,
        "msg": "expected 16 cells with cell(8,3) set, got %d cells, cell(8,3)=%d" % [count, mask[3 * 20 + 8]],
    }


static func _test_rotated_square() -> Dictionary:
    # 8×8 px square rotated 45°, centred at (10, 10). Diagonal ~= 11.3 px,
    # so bbox is roughly [4.35, 15.65]. More cells than the axis-aligned
    # case because the rotated shape is circumscribed by a larger bbox.
    # Exact cell count depends on which centres fall inside — we just
    # verify it's > 16 (more than axis-aligned) and < 36 (less than
    # the full bbox).
    var poly := PackedVector2Array([
        Vector2(-4, -4), Vector2(4, -4), Vector2(4, 4), Vector2(-4, 4)
    ])
    var mask := _make_mask(10, 10)
    PolygonRasterizer.rasterize(poly, Vector2(10, 10), PI / 4.0, 10, 10, 2.0, mask)
    var count := _count_set(mask)
    var ok := count > 12 and count < 36
    return {
        "name": "rotated_square",
        "pass": ok,
        "msg": "expected 12<count<36 for 45° square, got %d" % count,
    }


static func _test_irregular_pentagon() -> Dictionary:
    # Wood polygon. Area ≈ 620 px². At 2 px/cell (cell area 4), that's
    # roughly 620/4 ≈ 155 cells if all cell centres align perfectly.
    # Due to stair-stepping, accept a range 100..200.
    var poly := PackedVector2Array([
        Vector2(-16, -10), Vector2(18, -12), Vector2(16, 11), Vector2(-4, 13), Vector2(-18, 8)
    ])
    var mask := _make_mask(40, 30)
    PolygonRasterizer.rasterize(poly, Vector2(30, 20), 0.0, 40, 30, 2.0, mask)
    var count := _count_set(mask)
    var ok := count > 100 and count < 200
    return {
        "name": "irregular_pentagon",
        "pass": ok,
        "msg": "expected 100<count<200 for wood polygon, got %d" % count,
    }


static func _test_out_of_bounds_clamping() -> Dictionary:
    # Square positioned so half is outside the grid. Rasterizer must not
    # write out of bounds and must only mark the in-grid portion.
    var poly := PackedVector2Array([
        Vector2(-4, -4), Vector2(4, -4), Vector2(4, 4), Vector2(-4, 4)
    ])
    var mask := _make_mask(10, 10)
    # Position so half the square is past x=20 (grid edge at 2 px/cell × 10 cells = 20 px).
    PolygonRasterizer.rasterize(poly, Vector2(20, 10), 0.0, 10, 10, 2.0, mask)
    var count := _count_set(mask)
    # Half of 16 = 8, but cell-centre sampling may round down/up; accept 6..10.
    var ok := count >= 6 and count <= 10
    return {
        "name": "out_of_bounds_clamping",
        "pass": ok,
        "msg": "expected 6..10 clamped cells, got %d" % count,
    }


static func _test_polygon_area_rectangle() -> Dictionary:
    # 8×8 = 64 px² for the 4-corner square above.
    var poly := PackedVector2Array([
        Vector2(-4, -4), Vector2(4, -4), Vector2(4, 4), Vector2(-4, 4)
    ])
    var area := PolygonRasterizer.polygon_area(poly)
    var ok := abs(area - 64.0) < 0.001
    return {
        "name": "polygon_area_rectangle",
        "pass": ok,
        "msg": "expected area 64.0, got %f" % area,
    }
```

- [ ] **Step 3: Run the unit tests**

```bash
godot --path . --headless --script tests/unit/run_unit_tests.gd
```

Expected output includes `=== Unit tests: 6/6 passed ===`. Exit code 0.

If any fail, fix the rasterizer and re-run until all 6 pass.

- [ ] **Step 4: Commit**

```bash
git add src/simulation/polygon_rasterizer.gd tests/unit/
git commit -m "feat(rasterizer): polygon-to-cellmask utility + unit tests"
```

---

## Phase 2 — Dynamic obstacle mask buffer (plumbing only, no rasterizer wiring)

Adds `buf_obstacle_mask` to `ParticleFluidSolver`, the classify/advect
shader reads, and an `upload_obstacle_mask()` method. The mask starts
empty and stays empty in this phase — we're just wiring it so the next
phase can plug the rasterizer in.

### Task 2.1 — Add buffer and upload method to `ParticleFluidSolver`

**Files:**
- Modify: `src/simulation/particle_fluid_solver.gd` — buffer declaration, creation, upload, cleanup

**Steps:**

- [ ] **Step 1: Declare the buffer**

Add next to `buf_cell_density` / `buf_cell_mass`:

```gdscript
var buf_obstacle_mask: RID  # uint per cell, 1 = rigid body occupies this cell
```

- [ ] **Step 2: Create the buffer in `_create_buffers()`**

In the block that creates `buf_cell_density` etc., add:

```gdscript
var obstacle_zeros := PackedInt32Array()
obstacle_zeros.resize(cell_count)
buf_obstacle_mask = rd.storage_buffer_create(cell_count * 4, obstacle_zeros.to_byte_array())
```

- [ ] **Step 3: Add `upload_obstacle_mask()` method**

Near the other `upload_*` methods:

```gdscript
func upload_obstacle_mask(data: PackedInt32Array) -> void:
    ## Uploads the rigid body occupancy mask to the GPU. Cells where
    ## data[i] > 0 will be classified as CELL_WALL for this step.
    ## Caller (RigidBodyMgr) is responsible for sizing data == cell_count.
    if data.size() < cell_count:
        return
    rd.buffer_update(buf_obstacle_mask, 0, cell_count * 4, data.to_byte_array())
```

- [ ] **Step 4: Add to cleanup**

Extend the `for b in [..]` list in `cleanup()` to include
`buf_obstacle_mask`.

- [ ] **Step 5: Smoke test**

```bash
godot --path . src/main.tscn --quit-after 60 2>&1 | grep -iE "error" | head -10
```
Expected: no errors. Solver initializes normally.

- [ ] **Step 6: Commit**

```bash
git add src/simulation/particle_fluid_solver.gd
git commit -m "feat(pflip): add buf_obstacle_mask + upload method"
```

### Task 2.2 — Shader: classify reads obstacle mask

**Files:**
- Modify: `src/shaders/pflip_classify.glsl` — add binding, combine with boundary
- Modify: `src/simulation/particle_fluid_solver.gd` — add binding to `uset_classify`

**Steps:**

- [ ] **Step 1: Edit `pflip_classify.glsl`**

Add binding 4 (current bindings are 0-3: Params, DensityBuffer,
BoundaryBuffer, CellTypeBuffer):

```glsl
layout(set = 0, binding = 4, std430) restrict buffer ObstacleMask {
    uint data[];
} obstacle_mask;
```

Change the classification block from:
```glsl
if (boundary.data[idx] == 0) {
    cell_type.data[idx] = CELL_WALL;
} else if (density.data[idx] > FLUID_THRESHOLD) {
    ...
```
to:
```glsl
if (boundary.data[idx] == 0 || obstacle_mask.data[idx] > 0u) {
    cell_type.data[idx] = CELL_WALL;
} else if (density.data[idx] > FLUID_THRESHOLD) {
    ...
```

- [ ] **Step 2: Update the classify uset**

In `particle_fluid_solver.gd` find `uset_classify = _build_uset(shader_classify, [...])`
and append `[4, buf_obstacle_mask]` to the binding list.

- [ ] **Step 3: Reimport shaders**

```bash
godot --path . --headless --import 2>&1 | tail -5
```

- [ ] **Step 4: Smoke test**

```bash
godot --path . src/main.tscn --quit-after 60 2>&1 | grep -iE "error" | head -10
```
Expected: no errors. Since we never upload a non-zero mask in this
phase, classification behaviour is unchanged (`obstacle_mask.data[idx]`
reads as 0 everywhere).

- [ ] **Step 5: Commit**

```bash
git add src/shaders/pflip_classify.glsl src/simulation/particle_fluid_solver.gd
git commit -m "feat(pflip): classify shader reads obstacle_mask"
```

### Task 2.3 — Shader: advect reads obstacle mask in `is_wall()`

**Files:**
- Modify: `src/shaders/pflip_advect.glsl`
- Modify: `src/simulation/particle_fluid_solver.gd` — add binding to `uset_advect`

**Steps:**

- [ ] **Step 1: Find next free binding in advect**

Current advect bindings go 0–6 (Params, Particles, Boundary, SubstanceProps,
DensityField, AmbientDensity, Temperature). Add 7 for ObstacleMask.

- [ ] **Step 2: Add the binding declaration**

After the Temperature block in `pflip_advect.glsl`:

```glsl
layout(set = 0, binding = 7, std430) restrict buffer ObstacleMask {
    uint data[];
} obstacle_mask;
```

- [ ] **Step 3: Extend `is_wall()`**

Current:
```glsl
bool is_wall(int cx, int cy, int w, int h) {
    if (cx < 0 || cx >= w || cy < 0 || cy >= h) return true;
    return boundary.data[cy * w + cx] == 0;
}
```

New:
```glsl
bool is_wall(int cx, int cy, int w, int h) {
    if (cx < 0 || cx >= w || cy < 0 || cy >= h) return true;
    int idx = cy * w + cx;
    return boundary.data[idx] == 0 || obstacle_mask.data[idx] > 0u;
}
```

- [ ] **Step 4: Update advect uset**

In `particle_fluid_solver.gd` find `uset_advect = _build_uset(...)` and
append `[7, buf_obstacle_mask]` to the binding list.

- [ ] **Step 5: Reimport + smoke test**

```bash
godot --path . --headless --import 2>&1 | tail -5 && \
godot --path . src/main.tscn --quit-after 60 2>&1 | grep -iE "error" | head -10
```
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add src/shaders/pflip_advect.glsl src/simulation/particle_fluid_solver.gd
git commit -m "feat(pflip): advect is_wall checks obstacle_mask"
```

---

## Phase 3 — Rasterizer → solver wiring

Connect the rasterizer we built in Phase 1 to the buffer we added in
Phase 2. After this phase, rigid bodies actually block liquid flow —
the first visually-observable milestone of the spec.

### Task 3.1 — Add `compute_obstacle_mask()` to `RigidBodyMgr`

**Files:**
- Modify: `src/simulation/rigid_body_mgr.gd`

**Steps:**

- [ ] **Step 1: Add the CPU mask member**

After the existing `var _bodies`:

```gdscript
## Reusable CPU buffer for the obstacle mask. Resized once per call if
## grid dimensions changed; otherwise filled with zero then filled by
## the rasterizer. Sized grid_width × grid_height.
var _obstacle_mask_cpu: PackedInt32Array = PackedInt32Array()
var _mask_width: int = 0
var _mask_height: int = 0
```

- [ ] **Step 2: Add `compute_obstacle_mask()`**

```gdscript
func compute_obstacle_mask(grid_width: int, grid_height: int, cell_size_px: float) -> PackedInt32Array:
    ## Rasterize all rigid bodies into a shared cell-occupancy mask. The
    ## returned array is owned by this manager and reused between calls
    ## — if the caller needs to keep the data around, copy it.
    ##
    ## grid_width/height:   fluid grid dimensions in cells
    ## cell_size_px:        px per cell (same units as rigid body positions)
    var n := grid_width * grid_height
    if _mask_width != grid_width or _mask_height != grid_height:
        _obstacle_mask_cpu.resize(n)
        _mask_width = grid_width
        _mask_height = grid_height
    _obstacle_mask_cpu.fill(0)

    for body in _bodies:
        if not is_instance_valid(body):
            continue
        var sub_id: int = body.get_meta("substance_id", 0)
        var sub := SubstanceRegistry.get_substance(sub_id)
        if not sub:
            continue
        var polygon: PackedVector2Array = sub.polygon
        if polygon.size() < 3:
            # Fallback rectangle (matches spawn_object fallback).
            polygon = PackedVector2Array([
                Vector2(-15, -12),
                Vector2( 15, -12),
                Vector2( 15,  12),
                Vector2(-15,  12),
            ])
        PolygonRasterizer.rasterize(
            polygon,
            body.position,  # receptacle-local pixel coordinates
            body.rotation,
            grid_width,
            grid_height,
            cell_size_px,
            _obstacle_mask_cpu,
        )

    return _obstacle_mask_cpu
```

- [ ] **Step 3: Verify script parses**

```bash
godot --path . --headless --quit 2>&1 | grep -iE "rigid_body_mgr|error" | head -10
```

### Task 3.2 — Wire up rasterizer in the main tick

**Files:**
- Modify: `src/main.gd` (or `src/receptacle/receptacle.gd`, wherever the
  solver's `step()` is called)

**Steps:**

- [ ] **Step 1: Locate the per-frame simulation update**

Find the place in `main.gd` where `receptacle.fluid_solver.step(dt)` is
called. The order should become:

```gdscript
# 1. Rasterize rigid bodies → obstacle mask
var mask := receptacle.rigid_body_mgr.compute_obstacle_mask(
    Receptacle.GRID_WIDTH,
    Receptacle.GRID_HEIGHT,
    float(Receptacle.CELL_SIZE),
)
receptacle.fluid_solver.upload_obstacle_mask(mask)

# 2. Existing solver step
receptacle.fluid_solver.step(delta)
```

- [ ] **Step 2: Run and smoke test**

```bash
godot --path . src/main.tscn --quit-after 60 2>&1 | grep -iE "error" | head -10
```
Expected: no errors.

- [ ] **Step 3: Manual test M2**

Launch the game. Pour water to fill the receptacle halfway. Then drop a
wooden block (or any solid) above the water line. Expected:

- The block falls through the air normally.
- Once the block enters the water, particles directly below it should
  push sideways (routing around the block) instead of passing through
  the block's interior.
- **The block still sinks** at this phase — buoyancy hasn't been
  implemented yet. That's expected.
- No particles should be visible *inside* the block's polygon shape.

If particles are still visible inside the block → the obstacle mask
isn't reaching the shader. Re-check bindings in task 2.2/2.3.

- [ ] **Step 4: Commit**

```bash
git add src/main.gd src/simulation/rigid_body_mgr.gd
git commit -m "feat(rigid_body): rasterize obstacle mask every frame"
```

### Task 3.3 — Integration test: obstacle mask blocks particles

**Files:**
- Create: `tests/integration/test_rb_obstacle_mask.gd`
- Create: `tests/integration/run_integration_tests.gd` (new runner, similar to unit)

**Steps:**

- [ ] **Step 1: Write the integration runner**

`tests/integration/run_integration_tests.gd`:
```gdscript
extends SceneTree
## Headless integration test runner. Each test script defines a
## run_test(tree: SceneTree) -> Dictionary function. Tests may spawn
## nodes, step the sim, and assert on final state.
##
## Usage: godot --path . --headless --script tests/integration/run_integration_tests.gd

func _init() -> void:
    var total := 0
    var passed := 0
    var failures: Array[String] = []

    var tests := [
        "res://tests/integration/test_rb_obstacle_mask.gd",
        # more tests get appended here in later tasks
    ]

    for path in tests:
        var script := load(path) as GDScript
        if not script:
            failures.append("%s: failed to load" % path)
            total += 1
            continue
        var result: Dictionary = await script.run_test(self)
        total += 1
        if result.get("pass", false):
            passed += 1
            print("  PASS %s" % result.get("name", path))
        else:
            failures.append("%s — %s" % [result.get("name", path), result.get("msg", "")])
            print("  FAIL %s: %s" % [result.get("name", path), result.get("msg", "")])

    print("\n=== Integration tests: %d/%d passed ===" % [passed, total])
    if failures.size() > 0:
        quit(1)
    else:
        quit(0)
```

- [ ] **Step 2: Write the obstacle mask test**

`tests/integration/test_rb_obstacle_mask.gd`:
```gdscript
extends RefCounted
## Integration test: a wooden block placed in a water pool should
## prevent liquid particles from existing inside its polygon cells.

const MainScene := preload("res://src/main.tscn")

static func run_test(tree: SceneTree) -> Dictionary:
    var main := MainScene.instantiate()
    tree.root.add_child(main)
    # Let the scene initialize.
    await tree.process_frame
    await tree.process_frame

    var receptacle: Receptacle = main.receptacle
    var fluid_solver = receptacle.fluid_solver
    var rb_mgr = receptacle.rigid_body_mgr

    # 1. Flood the bottom half of the receptacle with water particles.
    var water_id := SubstanceRegistry.find_id_by_name("Water")
    var positions: Array[Vector2] = []
    for y in range(90, 145):
        for x in range(20, 180):
            positions.append(Vector2(x + 0.5, y + 0.5))
    fluid_solver.spawn_particles_batch(positions, water_id)

    # 2. Spawn a wooden block near the center, submerged.
    var wood_id := SubstanceRegistry.find_id_by_name("Wood")
    rb_mgr.spawn_object(wood_id, Vector2(400, 450) + receptacle.global_position)

    # 3. Step the sim for ~1 second (60 frames).
    for i in range(60):
        var mask := rb_mgr.compute_obstacle_mask(
            Receptacle.GRID_WIDTH, Receptacle.GRID_HEIGHT, float(Receptacle.CELL_SIZE),
        )
        fluid_solver.upload_obstacle_mask(mask)
        fluid_solver.step(1.0 / 60.0)
        receptacle.sync_from_gpu()
        await tree.process_frame

    # 4. Verify: cells marked in the final obstacle mask should have
    #    zero liquid density.
    var mask := rb_mgr.compute_obstacle_mask(
        Receptacle.GRID_WIDTH, Receptacle.GRID_HEIGHT, float(Receptacle.CELL_SIZE),
    )
    var densities := receptacle.liquid_readback.densities
    var violations := 0
    for i in range(mask.size()):
        if mask[i] > 0 and densities[i] > 0.1:
            violations += 1

    main.queue_free()
    return {
        "name": "rb_obstacle_mask_blocks_liquid",
        "pass": violations == 0,
        "msg": "expected 0 cells with liquid inside body, got %d" % violations,
    }
```

- [ ] **Step 3: Add `find_id_by_name()` helper to SubstanceRegistry if not present**

If it doesn't exist, add:
```gdscript
func find_id_by_name(name: String) -> int:
    for id in substances:
        if substances[id].substance_name == name:
            return id
    return 0
```

- [ ] **Step 4: Run the integration test**

```bash
godot --path . --headless --script tests/integration/run_integration_tests.gd 2>&1 | tail -20
```

Expected: `Integration tests: 1/1 passed`.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/
git commit -m "test(rigid_body): integration test for obstacle mask blocking liquid"
```

---

## Phase 4 — Buoyancy force

Compute submerged volume per body, apply an upward force scaled by
the displaced liquid mass. The first phase where bodies actually float.

### Task 4.1 — Add `apply_liquid_forces()` to `RigidBodyMgr`

**Files:**
- Modify: `src/simulation/rigid_body_mgr.gd`

**Steps:**

- [ ] **Step 1: Add constants**

Near the top of the class:

```gdscript
## Gravity constant — must match GRAVITY in pflip_advect.glsl so
## buoyancy uses the same "g" as the liquid physics. If pflip_advect's
## GRAVITY changes, change this in lockstep.
const BUOYANCY_G: float = 60.0

## Safety cap on buoyancy force per body, in Godot mass-× units. Prevents
## numerical explosions when a tiny body is suddenly surrounded by a very
## dense liquid. Tuned to "a few times body weight".
const MAX_BUOYANCY_FACTOR: float = 8.0
```

- [ ] **Step 2: Add the main per-body force application**

```gdscript
func apply_liquid_forces(
    fluid_solver,  # ParticleFluidSolver
    liquid_readback,  # LiquidReadback
    grid_width: int,
    grid_height: int,
    cell_size_px: float,
) -> void:
    ## For each rigid body, walk the cells it occupies, sum the liquid
    ## mass displaced, and apply a buoyancy force at the submerged
    ## center of mass. Must be called AFTER compute_obstacle_mask()
    ## (which fills _obstacle_mask_cpu) and AFTER fluid_solver.step()
    ## + liquid_readback sync.

    var densities := liquid_readback.densities
    var markers := liquid_readback.markers

    for body in _bodies:
        if not is_instance_valid(body):
            continue
        var sub_id: int = body.get_meta("substance_id", 0)
        var sub := SubstanceRegistry.get_substance(sub_id)
        if not sub:
            continue
        var polygon: PackedVector2Array = sub.polygon
        if polygon.size() < 3:
            polygon = PackedVector2Array([
                Vector2(-15, -12), Vector2(15, -12), Vector2(15, 12), Vector2(-15, 12)
            ])

        # Walk the body's bounding box, check cell centres against the
        # polygon, and for inside cells sum displaced liquid mass.
        var cos_r := cos(body.rotation)
        var sin_r := sin(body.rotation)
        var n := polygon.size()

        var min_x := INF
        var max_x := -INF
        var min_y := INF
        var max_y := -INF
        var world_verts := PackedVector2Array()
        world_verts.resize(n)
        for i in range(n):
            var v := polygon[i]
            var wv := Vector2(
                body.position.x + v.x * cos_r - v.y * sin_r,
                body.position.y + v.x * sin_r + v.y * cos_r,
            )
            world_verts[i] = wv
            if wv.x < min_x: min_x = wv.x
            elif wv.x > max_x: max_x = wv.x
            if wv.y < min_y: min_y = wv.y
            elif wv.y > max_y: max_y = wv.y

        var cx_min := maxi(0, int(floor(min_x / cell_size_px)))
        var cx_max := mini(grid_width - 1, int(floor(max_x / cell_size_px)))
        var cy_min := maxi(0, int(floor(min_y / cell_size_px)))
        var cy_max := mini(grid_height - 1, int(floor(max_y / cell_size_px)))

        var total_mass := 0.0
        var sum_x := 0.0
        var sum_y := 0.0

        for cy in range(cy_min, cy_max + 1):
            var py := (cy + 0.5) * cell_size_px
            for cx in range(cx_min, cx_max + 1):
                var px := (cx + 0.5) * cell_size_px
                if not PolygonRasterizer._point_in_polygon(px, py, world_verts):
                    continue
                var idx := cy * grid_width + cx
                if idx < 0 or idx >= densities.size():
                    continue
                var fill := densities[idx]
                if fill <= 0.0:
                    continue
                var marker: int = markers[idx]
                if marker <= 0:
                    continue
                var liq_sub := SubstanceRegistry.get_substance(marker)
                if not liq_sub:
                    continue
                var cell_mass := liq_sub.density * cell_size_px * cell_size_px * fill
                total_mass += cell_mass
                sum_x += px * cell_mass
                sum_y += py * cell_mass

        if total_mass <= 0.0:
            continue

        var center_world := Vector2(sum_x / total_mass, sum_y / total_mass)
        var force_magnitude := total_mass * BUOYANCY_G * MASS_SCALE
        var max_force := body.mass * BUOYANCY_G * MAX_BUOYANCY_FACTOR
        if force_magnitude > max_force:
            force_magnitude = max_force

        body.apply_force(
            Vector2(0.0, -force_magnitude),
            center_world - body.position,
        )
```

- [ ] **Step 3: Wire into main.gd after `sync_from_gpu()`**

```gdscript
# After the existing fluid_solver.step() + sync_from_gpu():
receptacle.rigid_body_mgr.apply_liquid_forces(
    receptacle.fluid_solver,
    receptacle.liquid_readback,
    Receptacle.GRID_WIDTH,
    Receptacle.GRID_HEIGHT,
    float(Receptacle.CELL_SIZE),
)
```

- [ ] **Step 4: Smoke test**

```bash
godot --path . src/main.tscn --quit-after 60 2>&1 | grep -iE "error" | head -10
```
Expected: no errors. Buoyancy is now running but no water present yet,
so no visible change.

- [ ] **Step 5: Commit**

```bash
git add src/simulation/rigid_body_mgr.gd src/main.gd
git commit -m "feat(rigid_body): buoyancy force from submerged liquid mass"
```

### Task 4.2 — Manual test M3 + MASS_SCALE tuning

**Steps:**

- [ ] **Step 1: Launch the game**

```bash
godot --path . src/main.tscn
```

- [ ] **Step 2: Run the M3 suite**

In the running game:
1. Pour water to fill the receptacle ~2/3 full.
2. Drop a wooden block above the water.
3. Observe: the block should fall, hit the water, sink partway, then
   rise and settle with ~1/3 of its height above the surface.
4. Drop an iron ingot. It should sink and rest on the bottom.
5. Drop an ice block (density 0.92). It should bob with a tiny crown
   above the surface.

- [ ] **Step 3: Tune `MASS_SCALE` if the wood block is too low/high**

If the block sits entirely underwater → MASS_SCALE is too high (body
mass overwhelms buoyancy). Lower it.

If the block barely touches the water → MASS_SCALE is too low (body is
too light). Raise it.

Target: wood block sits with ~30–35% of its polygon height above the
surface, matching its 0.65 density.

Expected final MASS_SCALE after tuning: between 0.005 and 0.05. Update
the constant, re-run, iterate.

- [ ] **Step 4: Commit tuned constant**

```bash
git add src/simulation/rigid_body_mgr.gd
git commit -m "fix(rigid_body): tune MASS_SCALE for correct float depth"
```

### Task 4.3 — Integration tests for buoyancy equilibrium

**Files:**
- Create: `tests/integration/test_rb_buoyancy_equilibrium.gd`
- Modify: `tests/integration/run_integration_tests.gd` (append new test)

**Steps:**

- [ ] **Step 1: Write the test**

`tests/integration/test_rb_buoyancy_equilibrium.gd`:
```gdscript
extends RefCounted
## Integration test: a wooden block dropped in a water pool reaches a
## stable depth with 25-45% of its height above the water surface.

const MainScene := preload("res://src/main.tscn")

static func run_test(tree: SceneTree) -> Dictionary:
    var main := MainScene.instantiate()
    tree.root.add_child(main)
    await tree.process_frame
    await tree.process_frame

    var receptacle: Receptacle = main.receptacle
    var fluid_solver = receptacle.fluid_solver
    var rb_mgr = receptacle.rigid_body_mgr

    # Flood bottom half with water.
    var water_id := SubstanceRegistry.find_id_by_name("Water")
    var positions: Array[Vector2] = []
    for y in range(75, 145):
        for x in range(20, 180):
            positions.append(Vector2(x + 0.5, y + 0.5))
    fluid_solver.spawn_particles_batch(positions, water_id)

    # Drop wooden block just above the water surface.
    var wood_id := SubstanceRegistry.find_id_by_name("Wood")
    rb_mgr.spawn_object(wood_id, Vector2(400, 250) + receptacle.global_position)

    # Settle for 3 seconds.
    for i in range(180):
        var mask := rb_mgr.compute_obstacle_mask(
            Receptacle.GRID_WIDTH, Receptacle.GRID_HEIGHT, float(Receptacle.CELL_SIZE)
        )
        fluid_solver.upload_obstacle_mask(mask)
        fluid_solver.step(1.0 / 60.0)
        receptacle.sync_from_gpu()
        rb_mgr.apply_liquid_forces(
            fluid_solver, receptacle.liquid_readback,
            Receptacle.GRID_WIDTH, Receptacle.GRID_HEIGHT, float(Receptacle.CELL_SIZE),
        )
        await tree.process_frame

    # The water surface y is ~75 (grid cells). The block centre should
    # be near the surface with some portion above. Measure the block's
    # y position and its approximate extent in grid cells.
    var bodies := rb_mgr._bodies
    if bodies.size() == 0:
        main.queue_free()
        return {"name": "wood_block_floats", "pass": false, "msg": "no body spawned"}
    var block := bodies[0]
    var block_grid_y := block.position.y / float(Receptacle.CELL_SIZE)

    # For our wood polygon, height extent is ~25 px → ~6 cells.
    # Block half-height is ~3 cells. Water surface at y=75.
    # If perfectly balanced at 65% submerged, block centre y should be
    # ~75 - 3 + 3.9 ≈ 75.9 (centre 0.9 cells below surface).
    # Accept a range [73, 79] (half cell tolerance + oscillation).
    var ok := block_grid_y > 73.0 and block_grid_y < 79.0
    main.queue_free()
    return {
        "name": "wood_block_floats",
        "pass": ok,
        "msg": "expected block y in [73, 79], got %f" % block_grid_y,
    }
```

- [ ] **Step 2: Register test in the runner**

Append to the `tests` array in `tests/integration/run_integration_tests.gd`:
```gdscript
"res://tests/integration/test_rb_buoyancy_equilibrium.gd",
```

- [ ] **Step 3: Run**

```bash
godot --path . --headless --script tests/integration/run_integration_tests.gd 2>&1 | tail -20
```
Expected: `Integration tests: 2/2 passed`.

If the wood test fails, it means MASS_SCALE is off — iterate back to
Task 4.2 and re-tune.

- [ ] **Step 4: Commit**

```bash
git add tests/integration/
git commit -m "test(rigid_body): buoyancy equilibrium test for wooden block"
```

### Task 4.4 — Sink test for iron ingot

**Files:**
- Create: `tests/integration/test_rb_iron_sinks.gd`
- Modify: integration runner

**Steps:**

- [ ] **Step 1: Add iron polygon**

Quick one-liner in `data/substances/iron_ingot.tres`:
```
polygon = PackedVector2Array(-14, -8, 14, -8, 14, 8, -14, 8)
```
(Rectangular 28×16 — denser than wood.)

- [ ] **Step 2: Write the test**

Pattern similar to 4.3 but with iron, expect block_grid_y near the
floor (y > 130 say).

```gdscript
extends RefCounted
## Iron ingot dropped in water should sink to the receptacle floor.

const MainScene := preload("res://src/main.tscn")

static func run_test(tree: SceneTree) -> Dictionary:
    var main := MainScene.instantiate()
    tree.root.add_child(main)
    await tree.process_frame
    await tree.process_frame

    var receptacle: Receptacle = main.receptacle
    var fluid_solver = receptacle.fluid_solver
    var rb_mgr = receptacle.rigid_body_mgr

    var water_id := SubstanceRegistry.find_id_by_name("Water")
    var positions: Array[Vector2] = []
    for y in range(75, 145):
        for x in range(20, 180):
            positions.append(Vector2(x + 0.5, y + 0.5))
    fluid_solver.spawn_particles_batch(positions, water_id)

    var iron_id := SubstanceRegistry.find_id_by_name("Iron Ingot")
    rb_mgr.spawn_object(iron_id, Vector2(400, 250) + receptacle.global_position)

    for i in range(240):  # 4 seconds — iron sinks slowly through water
        var mask := rb_mgr.compute_obstacle_mask(
            Receptacle.GRID_WIDTH, Receptacle.GRID_HEIGHT, float(Receptacle.CELL_SIZE)
        )
        fluid_solver.upload_obstacle_mask(mask)
        fluid_solver.step(1.0 / 60.0)
        receptacle.sync_from_gpu()
        rb_mgr.apply_liquid_forces(
            fluid_solver, receptacle.liquid_readback,
            Receptacle.GRID_WIDTH, Receptacle.GRID_HEIGHT, float(Receptacle.CELL_SIZE),
        )
        await tree.process_frame

    var bodies := rb_mgr._bodies
    if bodies.size() == 0:
        main.queue_free()
        return {"name": "iron_sinks", "pass": false, "msg": "no body spawned"}
    var block := bodies[0]
    var block_grid_y := block.position.y / float(Receptacle.CELL_SIZE)
    var ok := block_grid_y > 130.0  # near the bottom
    main.queue_free()
    return {
        "name": "iron_sinks",
        "pass": ok,
        "msg": "expected block y > 130 (bottom), got %f" % block_grid_y,
    }
```

- [ ] **Step 3: Register + run**

```bash
godot --path . --headless --script tests/integration/run_integration_tests.gd 2>&1 | tail -20
```

- [ ] **Step 4: Commit**

```bash
git add tests/integration/ data/substances/iron_ingot.tres
git commit -m "test(rigid_body): iron ingot sinks in water"
```

---

## Phase 5 — Drag force

Adds linear velocity damping proportional to submerged cell count so a
floating block doesn't oscillate forever.

### Task 5.1 — Add drag term to `apply_liquid_forces()`

**Files:**
- Modify: `src/simulation/rigid_body_mgr.gd` — extend `apply_liquid_forces()`

**Steps:**

- [ ] **Step 1: Add constant**

```gdscript
## Linear drag coefficient. Force = -DRAG_COEF × velocity × submerged_cell_count
## applied at the centre of mass. Tuned to damp out bobbing within ~2 seconds
## without making the body feel sluggish. Value ~5 works for our cell scale.
const DRAG_COEF: float = 5.0
```

- [ ] **Step 2: Track submerged cell count during the force loop**

Add `var submerged_cells := 0` alongside `total_mass`, increment it
inside the cell loop when `fill > 0.0 && marker > 0`, then after the
buoyancy force is applied:

```gdscript
if submerged_cells > 0:
    var drag_force := -body.linear_velocity * DRAG_COEF * float(submerged_cells) * MASS_SCALE
    body.apply_central_force(drag_force)
```

- [ ] **Step 3: Smoke test**

```bash
godot --path . src/main.tscn --quit-after 60 2>&1 | grep -iE "error" | head -10
```
Expected: no errors.

- [ ] **Step 4: Manual test M5**

Launch the game. Drop a wooden block into water. It should:
- Hit the surface, plunge a bit, overshoot equilibrium.
- Rise, overshoot equilibrium in the upward direction.
- Settle after 2–3 oscillations (compared to M4 without drag, which
  oscillated indefinitely).

If it damps too fast (no bounce at all) → reduce DRAG_COEF to 2–3.
If it doesn't damp at all → raise DRAG_COEF to 8–10.

- [ ] **Step 5: Commit**

```bash
git add src/simulation/rigid_body_mgr.gd
git commit -m "feat(rigid_body): linear drag force damps oscillation"
```

### Task 5.2 — Regression test: block velocity decays

**Files:**
- Create: `tests/integration/test_rb_drag_decay.gd`

**Steps:**

- [ ] **Step 1: Write the test**

Drop a block, push it downward with an artificial initial velocity,
verify that after N seconds the velocity has decayed by a large
fraction.

```gdscript
extends RefCounted

const MainScene := preload("res://src/main.tscn")

static func run_test(tree: SceneTree) -> Dictionary:
    var main := MainScene.instantiate()
    tree.root.add_child(main)
    await tree.process_frame
    await tree.process_frame

    var receptacle: Receptacle = main.receptacle
    var fluid_solver = receptacle.fluid_solver
    var rb_mgr = receptacle.rigid_body_mgr

    # Flood bottom of receptacle.
    var water_id := SubstanceRegistry.find_id_by_name("Water")
    var positions: Array[Vector2] = []
    for y in range(75, 145):
        for x in range(20, 180):
            positions.append(Vector2(x + 0.5, y + 0.5))
    fluid_solver.spawn_particles_batch(positions, water_id)

    var wood_id := SubstanceRegistry.find_id_by_name("Wood")
    rb_mgr.spawn_object(wood_id, Vector2(400, 400) + receptacle.global_position)
    await tree.process_frame

    var block: RigidBody2D = rb_mgr._bodies[0]
    # Give the block a strong downward kick.
    block.linear_velocity = Vector2(0, 500)

    # Step for 3 seconds.
    for i in range(180):
        var mask := rb_mgr.compute_obstacle_mask(
            Receptacle.GRID_WIDTH, Receptacle.GRID_HEIGHT, float(Receptacle.CELL_SIZE)
        )
        fluid_solver.upload_obstacle_mask(mask)
        fluid_solver.step(1.0 / 60.0)
        receptacle.sync_from_gpu()
        rb_mgr.apply_liquid_forces(
            fluid_solver, receptacle.liquid_readback,
            Receptacle.GRID_WIDTH, Receptacle.GRID_HEIGHT, float(Receptacle.CELL_SIZE),
        )
        await tree.process_frame

    var final_speed := block.linear_velocity.length()
    main.queue_free()
    var ok := final_speed < 50.0  # heavily damped
    return {
        "name": "drag_decay",
        "pass": ok,
        "msg": "expected final speed < 50, got %f" % final_speed,
    }
```

- [ ] **Step 2: Register and run**

```bash
godot --path . --headless --script tests/integration/run_integration_tests.gd 2>&1 | tail -20
```

- [ ] **Step 3: Commit**

```bash
git add tests/integration/
git commit -m "test(rigid_body): drag regression test"
```

---

## Phase 6 — Per-substance polygons for existing solids

Add polygons to rock, ice, crystal. Verify behaviour matches density
expectations.

### Task 6.1 — Rock polygon (irregular, dense)

**Files:**
- Modify: `data/substances/rock.tres`

**Steps:**

- [ ] **Step 1: Add polygon to rock.tres**

```
polygon = PackedVector2Array(-12, -14, 6, -16, 18, -6, 16, 10, 2, 18, -16, 14, -18, 2)
```

Irregular 7-vertex shape, ~32×32 pixels.

- [ ] **Step 2: Manual test**

Drop rock in water. It should sink like iron (density 2.6 >> water 1.0).

- [ ] **Step 3: Commit**

```bash
git add data/substances/rock.tres
git commit -m "feat(substance): rock polygon"
```

### Task 6.2 — Ice polygon (nearly water-density)

**Files:**
- Modify: `data/substances/ice.tres`

**Steps:**

- [ ] **Step 1: Add polygon**

```
polygon = PackedVector2Array(-14, -12, 14, -12, 14, 12, -14, 12)
```

- [ ] **Step 2: Manual test**

Drop ice in water. It should bob with ~8% above the surface (density
0.92 → 92% submerged). The crown above the surface is barely visible
— verify by dragging the block down and releasing; it should rise back
quickly.

- [ ] **Step 3: Commit**

```bash
git add data/substances/ice.tres
git commit -m "feat(substance): ice polygon"
```

### Task 6.3 — Crystal polygon

**Files:**
- Modify: `data/substances/crystal.tres`

**Steps:**

- [ ] **Step 1: Add polygon (diamond shape)**

```
polygon = PackedVector2Array(0, -16, 12, 0, 0, 16, -12, 0)
```

- [ ] **Step 2: Manual test**

Drop crystal in water. Behaviour depends on crystal density (check
`crystal.tres`). Likely sinks.

- [ ] **Step 3: Commit**

```bash
git add data/substances/crystal.tres
git commit -m "feat(substance): crystal polygon (diamond)"
```

### Task 6.4 — Manual test M6: substance behaviour matrix

- [ ] **Step 1: Launch game**

- [ ] **Step 2: Drop each solid in a water pool and observe**

| Substance | Density | Expected |
|---|---|---|
| Wood | 0.65 | Float, ~35% above surface |
| Ice | 0.92 | Float, ~8% above surface (tiny crown) |
| Crystal | (check tres) | Usually sinks |
| Rock | 2.6 | Sink fast |
| Iron ingot | 7.87 | Sink very fast |

- [ ] **Step 3: If any substance behaves wrong, document and iterate**

Usually the problem is MASS_SCALE being off — but since it's the same
constant for all substances, mis-tuning affects all densities
proportionally. If wood is slightly wrong but iron is fine, the issue
is elsewhere (polygon area off, etc.).

---

## Phase 7 — CI wiring

Make the unit + integration tests runnable from GitHub Actions so they
gate future PRs.

### Task 7.1 — Add test runner to CI workflow

**Files:**
- Modify: `.github/workflows/build.yml`

**Steps:**

- [ ] **Step 1: Add unit test step**

In the `build-windows` job (or add a new `test` job), add after the
Godot install step:

```yaml
      - name: Run unit tests
        run: |
          ~/godot-bin/godot --path . --headless --script tests/unit/run_unit_tests.gd
```

- [ ] **Step 2: Add integration test step**

```yaml
      - name: Run integration tests
        run: |
          ~/godot-bin/godot --path . --headless --script tests/integration/run_integration_tests.gd
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: run unit and integration tests on push"
```

- [ ] **Step 4: Push and verify CI passes**

```bash
git push origin <branch>
gh run watch
```

Expected: all jobs green.

---

## Done criteria

All phases complete when:

- [ ] All 6 unit tests pass locally and in CI
- [ ] All 4 integration tests pass locally and in CI (obstacle_mask,
      wood_floats, iron_sinks, drag_decay)
- [ ] All 7 manual tests (M1–M7) visibly pass when launching the game
- [ ] `MASS_SCALE` and `DRAG_COEF` values committed and documented in
      the source with their tuning rationale
- [ ] New wood.tres exists and is registered
- [ ] rock.tres, ice.tres, iron_ingot.tres, crystal.tres all have
      polygon fields
- [ ] No regression: existing water/mercury/oil behaviour unchanged
      (quick smoke check by pouring water and mercury before/after)
- [ ] `docs/superpowers/specs/2026-04-08-simulation-interactions-roadmap.md`
      updated to mark Task #1 as Complete and link to the shipped commit
