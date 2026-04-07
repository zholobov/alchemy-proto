# GPU MAC Fluid Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a GPU-accelerated Marker-and-Cell (MAC) fluid solver that produces physically-plausible liquid behavior (pressure-driven flow, free surface, density preservation).

**Architecture:** Eight separate compute shaders, one per simulation step (classify, body forces, divergence, Jacobi iteration, pressure gradient, wall zeroing, advection, damping). Ping-pong buffers for parallel Jacobi. Staggered MAC grid with free-surface pressure=0 boundary. Runs at 4x subdivided resolution (800x600).

**Tech Stack:** Godot 4.6, GDScript, GLSL 450 compute shaders, RenderingDevice API

**Design Spec:** `docs/superpowers/specs/2026-04-06-gpu-mac-fluid-design.md`

**Current State:** Liquids use falling-sand rules on the particle grid. The previous GPU MAC attempt failed; its broken shader code is still in `src/shaders/fluid_pressure.glsl` and will be deleted. Old fluid buffers exist in `gpu_simulation.gd` but are not dispatched.

---

## Phase 1: Minimal Test Case (isolated solver, no game integration)

Build the solver in a standalone test harness. Verify mass conservation, convergence, and stability on a simple scenario before connecting to the game.

---

### Task 1: Delete Old Broken Shader

**Files:**
- Delete: `src/shaders/fluid_pressure.glsl`
- Modify: `src/simulation/gpu_simulation.gd`

- [ ] **Step 1: Delete the broken shader file**

```bash
rm /Users/zholobov/src/gd-alchemy-proto/src/shaders/fluid_pressure.glsl
rm /Users/zholobov/src/gd-alchemy-proto/src/shaders/fluid_pressure.glsl.uid
```

- [ ] **Step 2: Remove shader loading from gpu_simulation.gd**

Read `src/simulation/gpu_simulation.gd`. Find the block in `_compile_shaders()` that loads `fluid_pressure.glsl`:

```gdscript
	var fluid_file := load("res://src/shaders/fluid_pressure.glsl") as RDShaderFile
	if not fluid_file:
		push_error("Failed to load fluid_pressure.glsl")
		return
	var fluid_spirv := fluid_file.get_spirv()
	shader_fluid = rd.shader_create_from_spirv(fluid_spirv)
	if not shader_fluid.is_valid():
		push_error("Failed to compile fluid_pressure shader")
```

Delete this block entirely.

- [ ] **Step 3: Remove `_create_fluid_pipeline()` call from setup**

In `setup()`, find and delete this line:
```gdscript
	_create_fluid_pipeline()
```

- [ ] **Step 4: Delete `_create_fluid_pipeline`, `_set_fluid_phase`, `_run_fluid_dispatch`, `_dispatch_fluid` methods**

These entire methods are now dead code. Delete all four methods from `gpu_simulation.gd`.

- [ ] **Step 5: Remove stale fluid buffer fields**

In the class field declarations, remove:
```gdscript
var shader_fluid: RID
var pipeline_fluid: RID
var uniform_set_fluid: RID
var buf_fluid_density: RID
var buf_fluid_density_out: RID
var buf_fluid_substance: RID
var buf_u_velocity: RID
var buf_v_velocity: RID
var buf_pressure: RID
var buf_fluid_boundary: RID
var _fluid_density_readback: PackedFloat32Array
var _fluid_substance_readback: PackedInt32Array
var _fluid_density_grid: PackedFloat32Array
var _fluid_substance_grid: PackedInt32Array
var fluid_scale: int = 4
var fluid_width: int
var fluid_height: int
var fluid_cell_count: int
var _has_fluid: bool = false
const PRESSURE_ITERATIONS := 20
```

- [ ] **Step 6: Remove fluid buffer creation from `_create_buffers()`**

Delete the sections in `_create_buffers()` that create:
- `buf_fluid_density`, `buf_fluid_density_out`
- `buf_fluid_substance`
- `buf_fluid_boundary`
- `buf_u_velocity`, `buf_v_velocity`
- `buf_pressure`

Delete the boundary upscaling loop that writes to `fluid_boundary_data`.

- [ ] **Step 7: Remove fluid readback, downsampling, and getter methods**

In `_readback()`, remove the fluid density/substance reading and downsampling code.

Delete these methods entirely:
- `get_fluid_density()`
- `get_fluid_substance()`
- `spawn_fluid()`

- [ ] **Step 8: Remove fluid buffer freeing from `cleanup()`**

In `cleanup()`, remove the lines freeing:
- `pipeline_fluid`, `uniform_set_fluid`, `shader_fluid`
- `buf_fluid_density`, `buf_fluid_density_out`
- `buf_fluid_substance`
- `buf_fluid_boundary`
- `buf_u_velocity`, `buf_v_velocity`
- `buf_pressure`

- [ ] **Step 9: Remove fluid clearing from `clear_all()`**

In `clear_all()`, remove the code that zeros fluid buffers, u/v velocity, pressure.

- [ ] **Step 10: Remove `setup()` `p_fluid_scale` parameter**

Change the signature from:
```gdscript
func setup(w: int, h: int, boundary_mask: PackedByteArray, p_fluid_scale: int = 4) -> void:
```
to:
```gdscript
func setup(w: int, h: int, boundary_mask: PackedByteArray) -> void:
```

Remove the lines:
```gdscript
	fluid_scale = p_fluid_scale
	fluid_width = w * fluid_scale
	fluid_height = h * fluid_scale
	fluid_cell_count = fluid_width * fluid_height
```

- [ ] **Step 11: Verify receptacle.gd still calls setup correctly**

Read `src/receptacle/receptacle.gd`. The call should already be `gpu_sim.setup(GRID_WIDTH, GRID_HEIGHT, grid.boundary)` (no fluid_scale argument). If not, fix it.

Also in `sync_from_gpu()`, remove the fluid density/substance reading since those methods no longer exist. The CPU `fluid.markers` array should remain but won't be populated (it's not used for rendering anymore since liquids are in the particle grid).

- [ ] **Step 12: Run the game to verify nothing is broken**

```bash
godot --path /Users/zholobov/src/gd-alchemy-proto
```

Expected: Game runs. Pour water — it still behaves like falling sand (that's the current state). No shader compilation errors.

- [ ] **Step 13: Commit**

```bash
git add src/shaders/ src/simulation/gpu_simulation.gd src/receptacle/receptacle.gd
git commit -m "chore: remove broken GPU MAC fluid code — clean slate for rewrite"
```

---

### Task 2: Create Test Harness Scene

A standalone Godot scene that runs the MAC solver on a 64x64 grid with a fluid blob. No integration with the alchemy game — just a visual test of the solver.

**Files:**
- Create: `tests/fluid_test.tscn`
- Create: `tests/fluid_test.gd`

- [ ] **Step 1: Create test directory**

```bash
mkdir -p /Users/zholobov/src/gd-alchemy-proto/tests
```

- [ ] **Step 2: Create the test scene root script**

Create `tests/fluid_test.gd`:

```gdscript
extends Node2D
## Standalone test harness for the GPU MAC fluid solver.
## Displays a 64x64 fluid simulation with a blob that should fall and pool.
## Press R to reset, SPACE to pause, 1-4 to change fluid scenarios.

const GRID_W := 64
const GRID_H := 64
const CELL_SIZE := 8

var solver: FluidSolver
var _image: Image
var _texture: ImageTexture
var _sprite: Sprite2D
var _pixels: PackedByteArray
var _paused: bool = false

# Debug labels
var _fps_label: Label
var _stats_label: Label


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.05, 0.05, 0.1))

	# Create solver
	solver = FluidSolver.new()
	solver.setup(GRID_W, GRID_H)

	# Create display sprite
	_image = Image.create(GRID_W, GRID_H, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	_sprite = Sprite2D.new()
	_sprite.texture = _texture
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sprite.scale = Vector2(CELL_SIZE, CELL_SIZE)
	_sprite.centered = false
	_sprite.position = Vector2(50, 50)
	add_child(_sprite)

	_pixels = PackedByteArray()
	_pixels.resize(GRID_W * GRID_H * 4)

	# FPS label
	_fps_label = Label.new()
	_fps_label.position = Vector2(10, 10)
	_fps_label.add_theme_font_size_override("font_size", 14)
	_fps_label.add_theme_color_override("font_color", Color.YELLOW)
	add_child(_fps_label)

	# Stats label (mass, max velocity, divergence)
	_stats_label = Label.new()
	_stats_label.position = Vector2(10, 30)
	_stats_label.add_theme_font_size_override("font_size", 12)
	_stats_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(_stats_label)

	# Instructions label
	var help := Label.new()
	help.position = Vector2(600, 10)
	help.add_theme_font_size_override("font_size", 12)
	help.add_theme_color_override("font_color", Color.GRAY)
	help.text = "R=reset  SPACE=pause  1=center blob  2=top blob  3=two blobs  4=column"
	add_child(help)

	_scenario_center_blob()


func _process(delta: float) -> void:
	if not _paused:
		solver.step(delta)

	var stats := solver.get_stats()
	_fps_label.text = "%d FPS %s" % [Engine.get_frames_per_second(), " [PAUSED]" if _paused else ""]
	_stats_label.text = "Mass: %.1f  MaxVel: %.2f  MaxDiv: %.4f  FluidCells: %d" % [
		stats["total_mass"], stats["max_velocity"], stats["max_divergence"], stats["fluid_cells"]
	]

	_render_density()


func _render_density() -> void:
	var density := solver.get_density_readback()
	for i in range(GRID_W * GRID_H):
		var d: float = density[i]
		var off := i * 4
		if d > 0.01:
			_pixels[off] = 50       # R
			_pixels[off + 1] = 100  # G
			_pixels[off + 2] = int(clampf(d, 0.0, 1.0) * 255)  # B proportional to density
			_pixels[off + 3] = 255
		else:
			_pixels[off] = 10
			_pixels[off + 1] = 10
			_pixels[off + 2] = 15
			_pixels[off + 3] = 255
	_image = Image.create_from_data(GRID_W, GRID_H, false, Image.FORMAT_RGBA8, _pixels)
	_texture.update(_image)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_R:
				solver.clear()
				_scenario_center_blob()
			KEY_SPACE:
				_paused = not _paused
			KEY_1:
				solver.clear()
				_scenario_center_blob()
			KEY_2:
				solver.clear()
				_scenario_top_blob()
			KEY_3:
				solver.clear()
				_scenario_two_blobs()
			KEY_4:
				solver.clear()
				_scenario_column()


func _scenario_center_blob() -> void:
	var cx := GRID_W / 2
	var cy := GRID_H / 2
	for dy in range(-5, 6):
		for dx in range(-5, 6):
			if dx * dx + dy * dy <= 25:
				solver.spawn_fluid(cx + dx, cy + dy, 1.0)


func _scenario_top_blob() -> void:
	var cx := GRID_W / 2
	var cy := 10
	for dy in range(-4, 5):
		for dx in range(-4, 5):
			if dx * dx + dy * dy <= 16:
				solver.spawn_fluid(cx + dx, cy + dy, 1.0)


func _scenario_two_blobs() -> void:
	for dy in range(-3, 4):
		for dx in range(-3, 4):
			if dx * dx + dy * dy <= 9:
				solver.spawn_fluid(16 + dx, 16 + dy, 1.0)
				solver.spawn_fluid(48 + dx, 16 + dy, 1.0)


func _scenario_column() -> void:
	for y in range(5, 30):
		for x in range(30, 34):
			solver.spawn_fluid(x, y, 1.0)
```

- [ ] **Step 3: Create the test scene file**

Create `tests/fluid_test.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/fluid_test.gd" id="1"]

[node name="FluidTest" type="Node2D"]
script = ExtResource("1")
```

- [ ] **Step 4: Commit**

```bash
git add tests/
git commit -m "test: fluid test harness scene skeleton"
```

Note: At this point, the scene won't load yet because `FluidSolver` doesn't exist. That's fine — we create it in Task 3.

---

### Task 3: Create FluidSolver Skeleton

The central class that owns all GPU resources and orchestrates the simulation.

**Files:**
- Create: `src/simulation/fluid_solver.gd`

- [ ] **Step 1: Create the skeleton with all buffer declarations**

Create `src/simulation/fluid_solver.gd`:

```gdscript
class_name FluidSolver
extends RefCounted
## GPU MAC fluid solver.
## Manages buffers, compiles shaders, dispatches 8 passes per simulation step.

var rd: RenderingDevice
var width: int
var height: int
var cell_count: int

# Cell type constants
const CELL_AIR := 0
const CELL_FLUID := 1
const CELL_WALL := 2

# Pressure solver iteration count
const JACOBI_ITERATIONS := 40

# Buffers
var buf_params: RID
var buf_density: RID
var buf_density_out: RID
var buf_substance: RID
var buf_substance_out: RID
var buf_u_vel: RID
var buf_v_vel: RID
var buf_cell_type: RID
var buf_boundary: RID
var buf_divergence: RID
var buf_pressure: RID
var buf_pressure_out: RID

# Shaders and pipelines
var shader_classify: RID
var shader_body_forces: RID
var shader_divergence: RID
var shader_jacobi: RID
var shader_gradient: RID
var shader_wall_zero: RID
var shader_advect: RID
var shader_damping: RID

var pipeline_classify: RID
var pipeline_body_forces: RID
var pipeline_divergence: RID
var pipeline_jacobi: RID
var pipeline_gradient: RID
var pipeline_wall_zero: RID
var pipeline_advect: RID
var pipeline_damping: RID

# Uniform sets for each shader
var uniform_set_classify: RID
var uniform_set_body_forces: RID
var uniform_set_divergence: RID
var uniform_set_jacobi_ab: RID  # pressure_in=A, pressure_out=B
var uniform_set_jacobi_ba: RID  # pressure_in=B, pressure_out=A
var uniform_set_gradient: RID
var uniform_set_wall_zero: RID
var uniform_set_advect: RID
var uniform_set_damping: RID

# Readback data
var _density_readback: PackedFloat32Array

# Dispatch groups
var groups_x: int
var groups_y: int


func setup(w: int, h: int, boundary_mask: PackedByteArray = PackedByteArray()) -> void:
	width = w
	height = h
	cell_count = w * h

	rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("FluidSolver: failed to create RenderingDevice")
		return

	groups_x = ceili(float(w) / 16.0)
	groups_y = ceili(float(h) / 16.0)

	_create_buffers(boundary_mask)
	_compile_shaders()
	_create_pipelines()

	print("FluidSolver initialized: %dx%d" % [w, h])


func step(delta: float) -> void:
	# Placeholder — filled in Task 5
	pass


func clear() -> void:
	# Zero all dynamic buffers
	var zeros_f := PackedFloat32Array()
	zeros_f.resize(cell_count)
	rd.buffer_update(buf_density, 0, cell_count * 4, zeros_f.to_byte_array())
	rd.buffer_update(buf_density_out, 0, cell_count * 4, zeros_f.to_byte_array())
	rd.buffer_update(buf_divergence, 0, cell_count * 4, zeros_f.to_byte_array())
	rd.buffer_update(buf_pressure, 0, cell_count * 4, zeros_f.to_byte_array())
	rd.buffer_update(buf_pressure_out, 0, cell_count * 4, zeros_f.to_byte_array())

	var zeros_i := PackedInt32Array()
	zeros_i.resize(cell_count)
	rd.buffer_update(buf_substance, 0, cell_count * 4, zeros_i.to_byte_array())
	rd.buffer_update(buf_substance_out, 0, cell_count * 4, zeros_i.to_byte_array())
	rd.buffer_update(buf_cell_type, 0, cell_count * 4, zeros_i.to_byte_array())

	var u_size: int = (width + 1) * height
	var u_zeros := PackedFloat32Array()
	u_zeros.resize(u_size)
	rd.buffer_update(buf_u_vel, 0, u_size * 4, u_zeros.to_byte_array())

	var v_size: int = width * (height + 1)
	var v_zeros := PackedFloat32Array()
	v_zeros.resize(v_size)
	rd.buffer_update(buf_v_vel, 0, v_size * 4, v_zeros.to_byte_array())


func spawn_fluid(x: int, y: int, density: float = 1.0) -> void:
	if x < 0 or x >= width or y < 0 or y >= height:
		return
	var idx := y * width + x
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0, density)
	rd.buffer_update(buf_density, idx * 4, 4, bytes)


func get_density_readback() -> PackedFloat32Array:
	return _density_readback


func get_stats() -> Dictionary:
	# Placeholder — filled in Task 5
	return {
		"total_mass": 0.0,
		"max_velocity": 0.0,
		"max_divergence": 0.0,
		"fluid_cells": 0,
	}


func cleanup() -> void:
	if not rd:
		return
	# Placeholder — filled in Task 10
	rd.free()


func _create_buffers(boundary_mask: PackedByteArray) -> void:
	# Params buffer: width, height, delta_time, extra
	var params := PackedByteArray()
	params.resize(16)
	buf_params = rd.storage_buffer_create(16, params)

	# Density buffers (ping-pong)
	var density_data := PackedFloat32Array()
	density_data.resize(cell_count)
	buf_density = rd.storage_buffer_create(cell_count * 4, density_data.to_byte_array())
	buf_density_out = rd.storage_buffer_create(cell_count * 4, density_data.to_byte_array())

	# Substance ID buffers (ping-pong)
	var sub_data := PackedInt32Array()
	sub_data.resize(cell_count)
	buf_substance = rd.storage_buffer_create(cell_count * 4, sub_data.to_byte_array())
	buf_substance_out = rd.storage_buffer_create(cell_count * 4, sub_data.to_byte_array())

	# Velocity buffers (staggered MAC layout)
	var u_size: int = (width + 1) * height
	var u_data := PackedFloat32Array()
	u_data.resize(u_size)
	buf_u_vel = rd.storage_buffer_create(u_size * 4, u_data.to_byte_array())

	var v_size: int = width * (height + 1)
	var v_data := PackedFloat32Array()
	v_data.resize(v_size)
	buf_v_vel = rd.storage_buffer_create(v_size * 4, v_data.to_byte_array())

	# Cell type buffer (recomputed each frame)
	var cell_type_data := PackedInt32Array()
	cell_type_data.resize(cell_count)
	buf_cell_type = rd.storage_buffer_create(cell_count * 4, cell_type_data.to_byte_array())

	# Boundary mask (uploaded once, never changes)
	var boundary_data := PackedInt32Array()
	boundary_data.resize(cell_count)
	if boundary_mask.size() >= cell_count:
		for i in range(cell_count):
			boundary_data[i] = boundary_mask[i]
	else:
		# Default: all valid (rectangular box open on top)
		for y in range(height):
			for x in range(width):
				var is_wall: bool = (x == 0 or x == width - 1 or y == height - 1)
				boundary_data[y * width + x] = 0 if is_wall else 1
	buf_boundary = rd.storage_buffer_create(cell_count * 4, boundary_data.to_byte_array())

	# Divergence buffer
	var div_data := PackedFloat32Array()
	div_data.resize(cell_count)
	buf_divergence = rd.storage_buffer_create(cell_count * 4, div_data.to_byte_array())

	# Pressure buffers (ping-pong)
	var press_data := PackedFloat32Array()
	press_data.resize(cell_count)
	buf_pressure = rd.storage_buffer_create(cell_count * 4, press_data.to_byte_array())
	buf_pressure_out = rd.storage_buffer_create(cell_count * 4, press_data.to_byte_array())


func _compile_shaders() -> void:
	# Placeholder — filled in Task 4
	pass


func _create_pipelines() -> void:
	# Placeholder — filled in Task 4
	pass
```

- [ ] **Step 2: Update fluid_test.gd to use default boundary**

The FluidSolver.setup signature already accepts an optional boundary_mask. The test harness calls `solver.setup(GRID_W, GRID_H)` which will use the default box boundary. No changes needed.

- [ ] **Step 3: Run the test scene to verify the skeleton loads**

```bash
godot --path /Users/zholobov/src/gd-alchemy-proto tests/fluid_test.tscn
```

Expected: Scene opens, shows a dark background, prints "FluidSolver initialized: 64x64". The solver does nothing yet (no shaders compiled), but the class should instantiate without errors.

Press R to call `_scenario_center_blob()` — should write density to the buffer (no visible effect yet since advection isn't running).

Close the window.

- [ ] **Step 4: Commit**

```bash
git add src/simulation/fluid_solver.gd
git commit -m "feat: FluidSolver skeleton with buffer allocation and test harness"
```

---

### Task 4: Create Pass 1 — Cell Classification

The simplest shader. Classifies each cell as AIR, FLUID, or WALL based on boundary and density.

**Files:**
- Create: `src/shaders/fluid_classify.glsl`
- Modify: `src/simulation/fluid_solver.gd`

- [ ] **Step 1: Create the classify shader**

Create `src/shaders/fluid_classify.glsl`:

```glsl
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int extra;
} params;

layout(set = 0, binding = 1, std430) restrict buffer DensityBuffer {
    float data[];
} density;

layout(set = 0, binding = 2, std430) restrict buffer BoundaryBuffer {
    int data[];
} boundary;

layout(set = 0, binding = 3, std430) restrict buffer CellTypeBuffer {
    int data[];
} cell_type;

const int CELL_AIR = 0;
const int CELL_FLUID = 1;
const int CELL_WALL = 2;
const float FLUID_THRESHOLD = 0.05;

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= w || y >= h) return;

    int idx = y * w + x;

    if (boundary.data[idx] == 0) {
        cell_type.data[idx] = CELL_WALL;
    } else if (density.data[idx] > FLUID_THRESHOLD) {
        cell_type.data[idx] = CELL_FLUID;
    } else {
        cell_type.data[idx] = CELL_AIR;
    }
}
```

- [ ] **Step 2: Implement `_compile_shaders()` for the classify shader**

In `src/simulation/fluid_solver.gd`, replace the `_compile_shaders()` stub:

```gdscript
func _compile_shaders() -> void:
	shader_classify = _load_shader("res://src/shaders/fluid_classify.glsl")


func _load_shader(path: String) -> RID:
	var file := load(path) as RDShaderFile
	if not file:
		push_error("FluidSolver: failed to load %s" % path)
		return RID()
	var spirv := file.get_spirv()
	var shader := rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		push_error("FluidSolver: failed to compile %s" % path)
	return shader
```

- [ ] **Step 3: Implement `_create_pipelines()` for the classify pipeline**

Replace the `_create_pipelines()` stub:

```gdscript
func _create_pipelines() -> void:
	pipeline_classify = rd.compute_pipeline_create(shader_classify)
	uniform_set_classify = _build_uniform_set(shader_classify, [
		[0, buf_params],
		[1, buf_density],
		[2, buf_boundary],
		[3, buf_cell_type],
	])


func _build_uniform_set(shader: RID, bindings: Array) -> RID:
	## Helper: builds a uniform set from [binding_index, buffer_rid] pairs.
	var uniforms: Array[RDUniform] = []
	for b in bindings:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = b[0]
		u.add_id(b[1])
		uniforms.append(u)
	return rd.uniform_set_create(uniforms, shader, 0)
```

- [ ] **Step 4: Add helper to update params buffer**

Add this method to `fluid_solver.gd`:

```gdscript
func _update_params(delta: float) -> void:
	var bytes := PackedByteArray()
	bytes.resize(16)
	bytes.encode_s32(0, width)
	bytes.encode_s32(4, height)
	bytes.encode_float(8, delta)
	bytes.encode_s32(12, 0)
	rd.buffer_update(buf_params, 0, 16, bytes)
```

- [ ] **Step 5: Add helper to dispatch a single shader pass**

Add this method:

```gdscript
func _dispatch(pipeline: RID, uniform_set: RID) -> void:
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
```

- [ ] **Step 6: Wire classify into `step()`**

Replace the `step()` stub:

```gdscript
func step(delta: float) -> void:
	_update_params(delta)
	_dispatch(pipeline_classify, uniform_set_classify)
	_readback_density()


func _readback_density() -> void:
	var bytes := rd.buffer_get_data(buf_density)
	_density_readback = bytes.to_float32_array()
```

- [ ] **Step 7: Run the test scene**

```bash
godot --path /Users/zholobov/src/gd-alchemy-proto tests/fluid_test.tscn
```

Expected: Scene loads. Prints "FluidSolver initialized". Press 1 to spawn center blob. The density rendering should show the spawned blob as dark blue pixels. The cells themselves won't move (no gravity/advection yet) but classification runs each frame.

- [ ] **Step 8: Commit**

```bash
git add src/shaders/fluid_classify.glsl src/simulation/fluid_solver.gd
git commit -m "feat: fluid classify shader — AIR/FLUID/WALL cell types"
```

---

### Task 5: Create Pass 2 — Body Forces (Gravity)

**Files:**
- Create: `src/shaders/fluid_body_forces.glsl`
- Modify: `src/simulation/fluid_solver.gd`

- [ ] **Step 1: Create the body forces shader**

Create `src/shaders/fluid_body_forces.glsl`:

```glsl
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int extra;
} params;

layout(set = 0, binding = 1, std430) restrict buffer CellTypeBuffer {
    int data[];
} cell_type;

layout(set = 0, binding = 2, std430) restrict buffer VVelocity {
    float data[];
} v_vel;

const int CELL_FLUID = 1;
const float GRAVITY = 20.0;  // cells per second squared


int v_idx(int x, int y, int w) {
    return y * w + x;
}

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= w || y >= h) return;

    int idx = y * w + x;
    if (cell_type.data[idx] != CELL_FLUID) return;

    // Apply gravity to the v-velocity at the bottom face of this fluid cell.
    if (y + 1 <= h) {
        int vi = v_idx(x, y + 1, w);
        v_vel.data[vi] += GRAVITY * params.delta_time;
    }
}
```

- [ ] **Step 2: Compile and create pipeline**

In `fluid_solver.gd`, update `_compile_shaders()`:

```gdscript
func _compile_shaders() -> void:
	shader_classify = _load_shader("res://src/shaders/fluid_classify.glsl")
	shader_body_forces = _load_shader("res://src/shaders/fluid_body_forces.glsl")
```

Update `_create_pipelines()`:

```gdscript
func _create_pipelines() -> void:
	pipeline_classify = rd.compute_pipeline_create(shader_classify)
	uniform_set_classify = _build_uniform_set(shader_classify, [
		[0, buf_params],
		[1, buf_density],
		[2, buf_boundary],
		[3, buf_cell_type],
	])

	pipeline_body_forces = rd.compute_pipeline_create(shader_body_forces)
	uniform_set_body_forces = _build_uniform_set(shader_body_forces, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_v_vel],
	])
```

- [ ] **Step 3: Wire body forces into `step()`**

```gdscript
func step(delta: float) -> void:
	_update_params(delta)
	_dispatch(pipeline_classify, uniform_set_classify)
	_dispatch(pipeline_body_forces, uniform_set_body_forces)
	_readback_density()
```

- [ ] **Step 4: Run the test scene**

Press 1 to spawn blob. Observe: velocities are being added but density doesn't move yet (no advection). If you could visualize velocities, they'd show downward accumulation.

- [ ] **Step 5: Commit**

```bash
git add src/shaders/fluid_body_forces.glsl src/simulation/fluid_solver.gd
git commit -m "feat: body forces shader — apply gravity to fluid cells"
```

---

### Task 6: Create Pass 3 — Divergence, Pass 4 — Jacobi Pressure, Pass 5 — Pressure Gradient

These three shaders implement the pressure projection. They must be created together because they share the pressure-velocity coupling.

**Files:**
- Create: `src/shaders/fluid_divergence.glsl`
- Create: `src/shaders/fluid_jacobi.glsl`
- Create: `src/shaders/fluid_gradient.glsl`
- Modify: `src/simulation/fluid_solver.gd`

- [ ] **Step 1: Create the divergence shader**

Create `src/shaders/fluid_divergence.glsl`:

```glsl
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int extra;
} params;

layout(set = 0, binding = 1, std430) restrict buffer CellTypeBuffer {
    int data[];
} cell_type;

layout(set = 0, binding = 2, std430) restrict buffer UVelocity {
    float data[];
} u_vel;

layout(set = 0, binding = 3, std430) restrict buffer VVelocity {
    float data[];
} v_vel;

layout(set = 0, binding = 4, std430) restrict buffer DivergenceBuffer {
    float data[];
} divergence;

const int CELL_FLUID = 1;

int u_idx(int x, int y, int w) {
    return y * (w + 1) + x;
}

int v_idx(int x, int y, int w) {
    return y * w + x;
}

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= w || y >= h) return;

    int idx = y * w + x;
    if (cell_type.data[idx] != CELL_FLUID) {
        divergence.data[idx] = 0.0;
        return;
    }

    // Divergence = net outflow. Positive = more flowing out than in.
    float u_left   = u_vel.data[u_idx(x, y, w)];
    float u_right  = u_vel.data[u_idx(x + 1, y, w)];
    float v_top    = v_vel.data[v_idx(x, y, w)];
    float v_bottom = v_vel.data[v_idx(x, y + 1, w)];

    divergence.data[idx] = (u_right - u_left) + (v_bottom - v_top);
}
```

- [ ] **Step 2: Create the Jacobi shader**

Create `src/shaders/fluid_jacobi.glsl`:

```glsl
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int extra;
} params;

layout(set = 0, binding = 1, std430) restrict buffer CellTypeBuffer {
    int data[];
} cell_type;

layout(set = 0, binding = 2, std430) restrict buffer DivergenceBuffer {
    float data[];
} divergence;

layout(set = 0, binding = 3, std430) restrict buffer PressureIn {
    float data[];
} pressure_in;

layout(set = 0, binding = 4, std430) restrict buffer PressureOut {
    float data[];
} pressure_out;

const int CELL_AIR = 0;
const int CELL_FLUID = 1;
const int CELL_WALL = 2;

float pressure_at(int x, int y, int w, int h, float current_pressure) {
    if (x < 0 || x >= w || y < 0 || y >= h) return current_pressure;
    int idx = y * w + x;
    int ct = cell_type.data[idx];
    if (ct == CELL_AIR) return 0.0;      // Free surface: atmospheric pressure.
    if (ct == CELL_WALL) return current_pressure;  // Wall: zero gradient.
    return pressure_in.data[idx];  // Fluid: use current iteration value.
}

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= w || y >= h) return;

    int idx = y * w + x;
    if (cell_type.data[idx] != CELL_FLUID) {
        pressure_out.data[idx] = 0.0;
        return;
    }

    float current = pressure_in.data[idx];
    float p_left   = pressure_at(x - 1, y, w, h, current);
    float p_right  = pressure_at(x + 1, y, w, h, current);
    float p_top    = pressure_at(x, y - 1, w, h, current);
    float p_bottom = pressure_at(x, y + 1, w, h, current);

    float div = divergence.data[idx];
    pressure_out.data[idx] = (p_left + p_right + p_top + p_bottom - div) * 0.25;
}
```

- [ ] **Step 3: Create the pressure gradient shader**

Create `src/shaders/fluid_gradient.glsl`:

```glsl
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int extra;
} params;

layout(set = 0, binding = 1, std430) restrict buffer CellTypeBuffer {
    int data[];
} cell_type;

layout(set = 0, binding = 2, std430) restrict buffer PressureBuffer {
    float data[];
} pressure;

layout(set = 0, binding = 3, std430) restrict buffer UVelocity {
    float data[];
} u_vel;

layout(set = 0, binding = 4, std430) restrict buffer VVelocity {
    float data[];
} v_vel;

const int CELL_FLUID = 1;
const int CELL_WALL = 2;

float pressure_at(int x, int y, int w, int h) {
    if (x < 0 || x >= w || y < 0 || y >= h) return 0.0;
    int idx = y * w + x;
    int ct = cell_type.data[idx];
    if (ct == CELL_WALL) return 0.0;
    return pressure.data[idx];
}

int u_idx(int x, int y, int w) {
    return y * (w + 1) + x;
}

int v_idx(int x, int y, int w) {
    return y * w + x;
}

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= w || y >= h) return;

    int idx = y * w + x;
    if (cell_type.data[idx] != CELL_FLUID) return;

    float p_here = pressure.data[idx];

    // Subtract pressure gradient from velocities at this cell's faces.
    // Left face (u at x, y): affected by pressure difference (p[x] - p[x-1]).
    // Right face (u at x+1, y): affected by (p[x+1] - p[x]).
    // Top face (v at x, y): affected by (p[y] - p[y-1]).
    // Bottom face (v at x, y+1): affected by (p[y+1] - p[y]).

    // Only update velocities where both sides are fluid (avoid touching walls/air edges).
    if (x > 0 && cell_type.data[idx - 1] == CELL_FLUID) {
        float p_left = pressure_at(x - 1, y, w, h);
        u_vel.data[u_idx(x, y, w)] -= (p_here - p_left);
    }
    if (x < w - 1 && cell_type.data[idx + 1] == CELL_FLUID) {
        float p_right = pressure_at(x + 1, y, w, h);
        u_vel.data[u_idx(x + 1, y, w)] -= (p_right - p_here);
    }
    if (y > 0 && cell_type.data[idx - w] == CELL_FLUID) {
        float p_top = pressure_at(x, y - 1, w, h);
        v_vel.data[v_idx(x, y, w)] -= (p_here - p_top);
    }
    if (y < h - 1 && cell_type.data[idx + w] == CELL_FLUID) {
        float p_bottom = pressure_at(x, y + 1, w, h);
        v_vel.data[v_idx(x, y + 1, w)] -= (p_bottom - p_here);
    }
}
```

- [ ] **Step 4: Load shaders and create pipelines**

In `fluid_solver.gd`, update `_compile_shaders()`:

```gdscript
func _compile_shaders() -> void:
	shader_classify = _load_shader("res://src/shaders/fluid_classify.glsl")
	shader_body_forces = _load_shader("res://src/shaders/fluid_body_forces.glsl")
	shader_divergence = _load_shader("res://src/shaders/fluid_divergence.glsl")
	shader_jacobi = _load_shader("res://src/shaders/fluid_jacobi.glsl")
	shader_gradient = _load_shader("res://src/shaders/fluid_gradient.glsl")
```

Update `_create_pipelines()` to add divergence, jacobi (with TWO uniform sets for ping-pong), and gradient:

```gdscript
func _create_pipelines() -> void:
	pipeline_classify = rd.compute_pipeline_create(shader_classify)
	uniform_set_classify = _build_uniform_set(shader_classify, [
		[0, buf_params],
		[1, buf_density],
		[2, buf_boundary],
		[3, buf_cell_type],
	])

	pipeline_body_forces = rd.compute_pipeline_create(shader_body_forces)
	uniform_set_body_forces = _build_uniform_set(shader_body_forces, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_v_vel],
	])

	pipeline_divergence = rd.compute_pipeline_create(shader_divergence)
	uniform_set_divergence = _build_uniform_set(shader_divergence, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_u_vel],
		[3, buf_v_vel],
		[4, buf_divergence],
	])

	pipeline_jacobi = rd.compute_pipeline_create(shader_jacobi)
	# Two uniform sets for ping-pong: A→B and B→A.
	uniform_set_jacobi_ab = _build_uniform_set(shader_jacobi, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_divergence],
		[3, buf_pressure],      # in
		[4, buf_pressure_out],  # out
	])
	uniform_set_jacobi_ba = _build_uniform_set(shader_jacobi, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_divergence],
		[3, buf_pressure_out],  # in
		[4, buf_pressure],      # out
	])

	pipeline_gradient = rd.compute_pipeline_create(shader_gradient)
	uniform_set_gradient = _build_uniform_set(shader_gradient, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_pressure],  # whichever buffer has final pressure after Jacobi
		[3, buf_u_vel],
		[4, buf_v_vel],
	])
```

- [ ] **Step 5: Wire divergence, Jacobi, and gradient into `step()`**

Update `step()`:

```gdscript
func step(delta: float) -> void:
	_update_params(delta)

	# Pass 1: Classify cells
	_dispatch(pipeline_classify, uniform_set_classify)

	# Pass 2: Apply gravity
	_dispatch(pipeline_body_forces, uniform_set_body_forces)

	# Pass 3: Compute divergence
	_dispatch(pipeline_divergence, uniform_set_divergence)

	# Reset pressure to 0 before starting Jacobi
	var zeros := PackedFloat32Array()
	zeros.resize(cell_count)
	rd.buffer_update(buf_pressure, 0, cell_count * 4, zeros.to_byte_array())
	rd.buffer_update(buf_pressure_out, 0, cell_count * 4, zeros.to_byte_array())

	# Pass 4: Jacobi pressure iterations (ping-pong)
	for i in range(JACOBI_ITERATIONS):
		if i % 2 == 0:
			_dispatch(pipeline_jacobi, uniform_set_jacobi_ab)  # pressure → pressure_out
		else:
			_dispatch(pipeline_jacobi, uniform_set_jacobi_ba)  # pressure_out → pressure

	# After even iterations, final pressure is in buf_pressure.
	# After odd iterations, final pressure is in buf_pressure_out — copy it back.
	if JACOBI_ITERATIONS % 2 == 1:
		var out_data := rd.buffer_get_data(buf_pressure_out)
		rd.buffer_update(buf_pressure, 0, cell_count * 4, out_data)

	# Pass 5: Subtract pressure gradient from velocities
	_dispatch(pipeline_gradient, uniform_set_gradient)

	_readback_density()
```

- [ ] **Step 6: Run the test scene**

Press 1 to spawn blob. The velocity field should now be divergence-free. No visible fluid motion yet (still no advection), but the pressure solver is running.

- [ ] **Step 7: Commit**

```bash
git add src/shaders/fluid_divergence.glsl src/shaders/fluid_jacobi.glsl src/shaders/fluid_gradient.glsl src/simulation/fluid_solver.gd
git commit -m "feat: pressure projection — divergence, Jacobi, gradient shaders"
```

---

### Task 7: Create Pass 6 — Wall Zero, Pass 7 — Advection, Pass 8 — Damping

**Files:**
- Create: `src/shaders/fluid_wall_zero.glsl`
- Create: `src/shaders/fluid_advect.glsl`
- Create: `src/shaders/fluid_damping.glsl`
- Modify: `src/simulation/fluid_solver.gd`

- [ ] **Step 1: Create wall velocity zeroing shader**

Create `src/shaders/fluid_wall_zero.glsl`:

```glsl
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int extra;
} params;

layout(set = 0, binding = 1, std430) restrict buffer CellTypeBuffer {
    int data[];
} cell_type;

layout(set = 0, binding = 2, std430) restrict buffer UVelocity {
    float data[];
} u_vel;

layout(set = 0, binding = 3, std430) restrict buffer VVelocity {
    float data[];
} v_vel;

const int CELL_WALL = 2;

int u_idx(int x, int y, int w) {
    return y * (w + 1) + x;
}

int v_idx(int x, int y, int w) {
    return y * w + x;
}

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= w || y >= h) return;

    int idx = y * w + x;
    if (cell_type.data[idx] != CELL_WALL) return;

    // Zero all four faces of this wall cell.
    u_vel.data[u_idx(x, y, w)] = 0.0;
    u_vel.data[u_idx(x + 1, y, w)] = 0.0;
    v_vel.data[v_idx(x, y, w)] = 0.0;
    v_vel.data[v_idx(x, y + 1, w)] = 0.0;
}
```

- [ ] **Step 2: Create advection shader**

Create `src/shaders/fluid_advect.glsl`:

```glsl
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int extra;
} params;

layout(set = 0, binding = 1, std430) restrict buffer CellTypeBuffer {
    int data[];
} cell_type;

layout(set = 0, binding = 2, std430) restrict buffer DensityIn {
    float data[];
} density_in;

layout(set = 0, binding = 3, std430) restrict buffer DensityOut {
    float data[];
} density_out;

layout(set = 0, binding = 4, std430) restrict buffer SubstanceIn {
    int data[];
} substance_in;

layout(set = 0, binding = 5, std430) restrict buffer SubstanceOut {
    int data[];
} substance_out;

layout(set = 0, binding = 6, std430) restrict buffer UVelocity {
    float data[];
} u_vel;

layout(set = 0, binding = 7, std430) restrict buffer VVelocity {
    float data[];
} v_vel;

const int CELL_AIR = 0;
const int CELL_FLUID = 1;
const int CELL_WALL = 2;

int u_idx(int x, int y, int w) {
    return y * (w + 1) + x;
}

int v_idx(int x, int y, int w) {
    return y * w + x;
}

// Bilinear density sample at fractional grid position, skipping wall cells.
float sample_density(float fx, float fy, int w, int h) {
    fx = clamp(fx, 0.0, float(w - 1));
    fy = clamp(fy, 0.0, float(h - 1));

    int x0 = int(floor(fx));
    int y0 = int(floor(fy));
    int x1 = min(x0 + 1, w - 1);
    int y1 = min(y0 + 1, h - 1);

    float sx = fx - float(x0);
    float sy = fy - float(y0);

    float w00 = (1.0 - sx) * (1.0 - sy);
    float w10 = sx * (1.0 - sy);
    float w01 = (1.0 - sx) * sy;
    float w11 = sx * sy;

    bool v00 = cell_type.data[y0 * w + x0] != CELL_WALL;
    bool v10 = cell_type.data[y0 * w + x1] != CELL_WALL;
    bool v01 = cell_type.data[y1 * w + x0] != CELL_WALL;
    bool v11 = cell_type.data[y1 * w + x1] != CELL_WALL;

    if (!v00) w00 = 0.0;
    if (!v10) w10 = 0.0;
    if (!v01) w01 = 0.0;
    if (!v11) w11 = 0.0;

    float total_w = w00 + w10 + w01 + w11;
    if (total_w <= 0.0) return 0.0;

    float inv = 1.0 / total_w;
    w00 *= inv; w10 *= inv; w01 *= inv; w11 *= inv;

    float d00 = v00 ? density_in.data[y0 * w + x0] : 0.0;
    float d10 = v10 ? density_in.data[y0 * w + x1] : 0.0;
    float d01 = v01 ? density_in.data[y1 * w + x0] : 0.0;
    float d11 = v11 ? density_in.data[y1 * w + x1] : 0.0;

    return d00 * w00 + d10 * w10 + d01 * w01 + d11 * w11;
}

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= w || y >= h) return;

    int idx = y * w + x;

    if (cell_type.data[idx] == CELL_WALL) {
        density_out.data[idx] = 0.0;
        substance_out.data[idx] = 0;
        return;
    }

    // Velocity at cell center (average of face velocities).
    float vx = (u_vel.data[u_idx(x, y, w)] + u_vel.data[u_idx(x + 1, y, w)]) * 0.5;
    float vy = (v_vel.data[v_idx(x, y, w)] + v_vel.data[v_idx(x, y + 1, w)]) * 0.5;

    // Backward trace.
    float src_x = float(x) - vx * params.delta_time;
    float src_y = float(y) - vy * params.delta_time;

    density_out.data[idx] = sample_density(src_x, src_y, w, h);

    // Nearest-neighbor substance sample.
    int sx = clamp(int(round(src_x)), 0, w - 1);
    int sy = clamp(int(round(src_y)), 0, h - 1);
    substance_out.data[idx] = substance_in.data[sy * w + sx];
}
```

- [ ] **Step 3: Create damping shader**

Create `src/shaders/fluid_damping.glsl`:

```glsl
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int extra;
} params;

layout(set = 0, binding = 1, std430) restrict buffer UVelocity {
    float data[];
} u_vel;

layout(set = 0, binding = 2, std430) restrict buffer VVelocity {
    float data[];
} v_vel;

const float DAMPING = 0.995;  // 0.5% velocity loss per frame

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    // Damp u velocity (width+1 × height)
    if (x <= w && y < h) {
        int ui = y * (w + 1) + x;
        u_vel.data[ui] *= DAMPING;
    }

    // Damp v velocity (width × height+1)
    if (x < w && y <= h) {
        int vi = y * w + x;
        v_vel.data[vi] *= DAMPING;
    }
}
```

- [ ] **Step 4: Load shaders, create pipelines, wire into step()**

In `fluid_solver.gd`, update `_compile_shaders()`:

```gdscript
func _compile_shaders() -> void:
	shader_classify = _load_shader("res://src/shaders/fluid_classify.glsl")
	shader_body_forces = _load_shader("res://src/shaders/fluid_body_forces.glsl")
	shader_divergence = _load_shader("res://src/shaders/fluid_divergence.glsl")
	shader_jacobi = _load_shader("res://src/shaders/fluid_jacobi.glsl")
	shader_gradient = _load_shader("res://src/shaders/fluid_gradient.glsl")
	shader_wall_zero = _load_shader("res://src/shaders/fluid_wall_zero.glsl")
	shader_advect = _load_shader("res://src/shaders/fluid_advect.glsl")
	shader_damping = _load_shader("res://src/shaders/fluid_damping.glsl")
```

Update `_create_pipelines()` to add the three new pipelines (append to existing code):

```gdscript
	pipeline_wall_zero = rd.compute_pipeline_create(shader_wall_zero)
	uniform_set_wall_zero = _build_uniform_set(shader_wall_zero, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_u_vel],
		[3, buf_v_vel],
	])

	pipeline_advect = rd.compute_pipeline_create(shader_advect)
	uniform_set_advect = _build_uniform_set(shader_advect, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_density],
		[3, buf_density_out],
		[4, buf_substance],
		[5, buf_substance_out],
		[6, buf_u_vel],
		[7, buf_v_vel],
	])

	pipeline_damping = rd.compute_pipeline_create(shader_damping)
	uniform_set_damping = _build_uniform_set(shader_damping, [
		[0, buf_params],
		[1, buf_u_vel],
		[2, buf_v_vel],
	])
```

Update `step()` to include all 8 passes:

```gdscript
func step(delta: float) -> void:
	_update_params(delta)

	# Pass 1: Classify cells
	_dispatch(pipeline_classify, uniform_set_classify)

	# Pass 2: Apply gravity
	_dispatch(pipeline_body_forces, uniform_set_body_forces)

	# Pass 3: Compute divergence
	_dispatch(pipeline_divergence, uniform_set_divergence)

	# Reset pressure to 0 before Jacobi
	var zeros := PackedFloat32Array()
	zeros.resize(cell_count)
	rd.buffer_update(buf_pressure, 0, cell_count * 4, zeros.to_byte_array())
	rd.buffer_update(buf_pressure_out, 0, cell_count * 4, zeros.to_byte_array())

	# Pass 4: Jacobi pressure iterations (ping-pong)
	for i in range(JACOBI_ITERATIONS):
		if i % 2 == 0:
			_dispatch(pipeline_jacobi, uniform_set_jacobi_ab)
		else:
			_dispatch(pipeline_jacobi, uniform_set_jacobi_ba)

	# Ensure final pressure is in buf_pressure.
	if JACOBI_ITERATIONS % 2 == 1:
		var out_data := rd.buffer_get_data(buf_pressure_out)
		rd.buffer_update(buf_pressure, 0, cell_count * 4, out_data)

	# Pass 5: Subtract pressure gradient
	_dispatch(pipeline_gradient, uniform_set_gradient)

	# Pass 6: Zero wall velocities
	_dispatch(pipeline_wall_zero, uniform_set_wall_zero)

	# Pass 7: Advect density and substance
	_dispatch(pipeline_advect, uniform_set_advect)

	# Swap density/substance buffers (copy _out → in)
	var new_density := rd.buffer_get_data(buf_density_out)
	rd.buffer_update(buf_density, 0, cell_count * 4, new_density)
	var new_substance := rd.buffer_get_data(buf_substance_out)
	rd.buffer_update(buf_substance, 0, cell_count * 4, new_substance)

	# Pass 8: Velocity damping
	_dispatch(pipeline_damping, uniform_set_damping)

	_readback_density()
```

- [ ] **Step 5: Run the test scene**

```bash
godot --path /Users/zholobov/src/gd-alchemy-proto tests/fluid_test.tscn
```

Expected:
- Press 1 → center blob appears
- Blob should fall under gravity and pool at the bottom of the container
- Mass should remain stable (not rapidly decrease)
- No fluid should leak through walls

If fluid falls and pools without losing mass, the solver is working. If mass decreases visibly or fluid scatters, there's still a bug — go to Task 8 to add diagnostic stats.

- [ ] **Step 6: Commit**

```bash
git add src/shaders/fluid_wall_zero.glsl src/shaders/fluid_advect.glsl src/shaders/fluid_damping.glsl src/simulation/fluid_solver.gd
git commit -m "feat: complete MAC pipeline — wall zero, advection, damping"
```

---

### Task 8: Add Diagnostic Stats

Implement `get_stats()` properly so the test harness can display mass, max velocity, and max divergence. This is critical for detecting regressions.

**Files:**
- Modify: `src/simulation/fluid_solver.gd`

- [ ] **Step 1: Add velocity and divergence readback**

Add these fields to the class:

```gdscript
var _u_readback: PackedFloat32Array
var _v_readback: PackedFloat32Array
var _divergence_readback: PackedFloat32Array
```

Update `_readback_density()` to also read the others:

```gdscript
func _readback_density() -> void:
	var d_bytes := rd.buffer_get_data(buf_density)
	_density_readback = d_bytes.to_float32_array()

	var u_bytes := rd.buffer_get_data(buf_u_vel)
	_u_readback = u_bytes.to_float32_array()

	var v_bytes := rd.buffer_get_data(buf_v_vel)
	_v_readback = v_bytes.to_float32_array()

	var div_bytes := rd.buffer_get_data(buf_divergence)
	_divergence_readback = div_bytes.to_float32_array()
```

- [ ] **Step 2: Implement `get_stats()`**

Replace the stub:

```gdscript
func get_stats() -> Dictionary:
	var total_mass := 0.0
	var fluid_cells := 0
	for d in _density_readback:
		total_mass += d
		if d > 0.05:
			fluid_cells += 1

	var max_vel := 0.0
	for u in _u_readback:
		if absf(u) > max_vel:
			max_vel = absf(u)
	for v in _v_readback:
		if absf(v) > max_vel:
			max_vel = absf(v)

	var max_div := 0.0
	for d in _divergence_readback:
		if absf(d) > max_div:
			max_div = absf(d)

	return {
		"total_mass": total_mass,
		"max_velocity": max_vel,
		"max_divergence": max_div,
		"fluid_cells": fluid_cells,
	}
```

- [ ] **Step 3: Run the test scene and observe stats**

Press 1 (center blob). Watch the stats label:
- `Mass` should stay roughly constant (small diffusion is OK)
- `MaxVel` should rise initially then stabilize
- `MaxDiv` should be near 0 after Jacobi converges (good) or large (bad — increase iterations)
- `FluidCells` should be roughly constant

Record the initial and final values. If mass drops by more than 10% over 5 seconds, there's a bug.

- [ ] **Step 4: Commit**

```bash
git add src/simulation/fluid_solver.gd
git commit -m "feat: fluid solver diagnostic stats — mass, velocity, divergence"
```

---

### Task 9: Verify All Test Scenarios

Run each test scenario and document the behavior. This catches regressions in later phases.

- [ ] **Step 1: Run scenario 1 — center blob**

```bash
godot --path /Users/zholobov/src/gd-alchemy-proto tests/fluid_test.tscn
```

Press 1. Expected: blob falls and forms a flat puddle at the bottom.

- [ ] **Step 2: Run scenario 2 — top blob**

Press 2. Expected: blob falls from the top and splats at the bottom, possibly with some spreading.

- [ ] **Step 3: Run scenario 3 — two blobs**

Press 3. Expected: both blobs fall independently, combine into a single pool at the bottom.

- [ ] **Step 4: Run scenario 4 — column**

Press 4. Expected: tall thin column falls and spreads into a short wide puddle.

- [ ] **Step 5: Document results**

If any scenario fails (fluid disappears, scatters, or leaks), debug before proceeding. Check:
- Stats for mass loss or divergence spikes
- Whether the pressure is converging (MaxDiv should stabilize near 0)
- Whether JACOBI_ITERATIONS needs to be increased

- [ ] **Step 6: Commit any tuning changes**

If you adjusted `JACOBI_ITERATIONS`, `GRAVITY`, or `DAMPING`:

```bash
git add src/shaders/ src/simulation/fluid_solver.gd
git commit -m "tune: fluid solver parameters for stability"
```

---

### Task 10: Implement Proper Cleanup

**Files:**
- Modify: `src/simulation/fluid_solver.gd`

- [ ] **Step 1: Fill in the cleanup() method**

Replace the `cleanup()` stub:

```gdscript
func cleanup() -> void:
	if not rd:
		return

	# Free pipelines
	rd.free_rid(pipeline_classify)
	rd.free_rid(pipeline_body_forces)
	rd.free_rid(pipeline_divergence)
	rd.free_rid(pipeline_jacobi)
	rd.free_rid(pipeline_gradient)
	rd.free_rid(pipeline_wall_zero)
	rd.free_rid(pipeline_advect)
	rd.free_rid(pipeline_damping)

	# Free shaders
	rd.free_rid(shader_classify)
	rd.free_rid(shader_body_forces)
	rd.free_rid(shader_divergence)
	rd.free_rid(shader_jacobi)
	rd.free_rid(shader_gradient)
	rd.free_rid(shader_wall_zero)
	rd.free_rid(shader_advect)
	rd.free_rid(shader_damping)

	# Free buffers
	rd.free_rid(buf_params)
	rd.free_rid(buf_density)
	rd.free_rid(buf_density_out)
	rd.free_rid(buf_substance)
	rd.free_rid(buf_substance_out)
	rd.free_rid(buf_u_vel)
	rd.free_rid(buf_v_vel)
	rd.free_rid(buf_cell_type)
	rd.free_rid(buf_boundary)
	rd.free_rid(buf_divergence)
	rd.free_rid(buf_pressure)
	rd.free_rid(buf_pressure_out)

	rd.free()
```

- [ ] **Step 2: Commit**

```bash
git add src/simulation/fluid_solver.gd
git commit -m "feat: FluidSolver cleanup frees all GPU resources"
```

---

## Phase 2: Integration with Alchemy Game

Now that the solver works in isolation, integrate it into the main game.

---

### Task 11: Upscale Solver Grid to Match Receptacle Subdivision

The receptacle is 200x150. For fluid, we want 4x subdivision = 800x600. The solver already supports arbitrary dimensions — just needs the correct setup call.

**Files:**
- Modify: `src/receptacle/receptacle.gd`

- [ ] **Step 1: Add FluidSolver to receptacle**

Read `src/receptacle/receptacle.gd`. Add a new field:

```gdscript
var fluid_solver: FluidSolver
```

- [ ] **Step 2: Create FluidSolver in _ready() after gpu_sim**

Add after the `gpu_sim.setup(...)` line:

```gdscript
	# Create GPU MAC fluid solver at 4x subdivided resolution.
	var fluid_w: int = GRID_WIDTH * 4
	var fluid_h: int = GRID_HEIGHT * 4
	# Upscale the grid boundary to fluid resolution.
	var fluid_boundary := PackedByteArray()
	fluid_boundary.resize(fluid_w * fluid_h)
	for gy in range(GRID_HEIGHT):
		for gx in range(GRID_WIDTH):
			var val: int = grid.boundary[gy * GRID_WIDTH + gx]
			for fy in range(4):
				for fx in range(4):
					fluid_boundary[(gy * 4 + fy) * fluid_w + gx * 4 + fx] = val
	fluid_solver = FluidSolver.new()
	fluid_solver.setup(fluid_w, fluid_h, fluid_boundary)
```

- [ ] **Step 3: Update _exit_tree() to clean up the solver**

Replace the existing `_exit_tree()`:

```gdscript
func _exit_tree() -> void:
	if gpu_sim:
		gpu_sim.cleanup()
	if fluid_solver:
		fluid_solver.cleanup()
```

- [ ] **Step 4: Run the game**

```bash
godot --path /Users/zholobov/src/gd-alchemy-proto
```

Expected: game runs normally. FluidSolver prints "FluidSolver initialized: 800x600" but isn't actually invoked yet.

- [ ] **Step 5: Commit**

```bash
git add src/receptacle/receptacle.gd
git commit -m "feat: instantiate FluidSolver in Receptacle at 4x resolution"
```

---

### Task 12: Call fluid_solver.step() Each Frame

**Files:**
- Modify: `src/main.gd`

- [ ] **Step 1: Add fluid_solver.step() to the game loop**

Read `src/main.gd`. Find the GPU Sim section in `_process()`. Add a call to the fluid solver right after it:

```gdscript
	perf_monitor.begin_timing("GPU Sim")
	receptacle.gpu_sim.step(delta)
	receptacle.sync_from_gpu()
	perf_monitor.end_timing("GPU Sim")

	perf_monitor.begin_timing("Fluid Sim")
	receptacle.fluid_solver.step(delta)
	perf_monitor.end_timing("Fluid Sim")
```

- [ ] **Step 2: Run the game**

Expected: game runs. Perf monitor (F3) shows "Fluid Sim" timing. No visible fluid yet (nothing is spawned into the solver).

- [ ] **Step 3: Commit**

```bash
git add src/main.gd
git commit -m "feat: dispatch fluid solver each frame in main loop"
```

---

### Task 13: Route Liquid Spawns to FluidSolver

When the player pours a liquid, it should go to the fluid solver instead of the particle grid.

**Files:**
- Modify: `src/main.gd`
- Modify: `src/simulation/fluid_solver.gd`

- [ ] **Step 1: Add a batch spawn method to FluidSolver**

Add to `fluid_solver.gd`:

```gdscript
func spawn_fluid_block(grid_x: int, grid_y: int, block_size: int, substance_id: int) -> void:
	## Spawn a block_size × block_size block of fluid at a grid position.
	## Used when the solver resolution is higher than the source grid.
	var density_byte := PackedByteArray()
	density_byte.resize(4)
	density_byte.encode_float(0, 1.0)
	var sub_byte := PackedByteArray()
	sub_byte.resize(4)
	sub_byte.encode_s32(0, substance_id)

	for fy in range(block_size):
		for fx in range(block_size):
			var x: int = grid_x * block_size + fx
			var y: int = grid_y * block_size + fy
			if x < 0 or x >= width or y < 0 or y >= height:
				continue
			var idx: int = y * width + x
			rd.buffer_update(buf_density, idx * 4, 4, density_byte)
			rd.buffer_update(buf_substance, idx * 4, 4, sub_byte)
```

- [ ] **Step 2: Update `_on_substance_pouring()` in main.gd to route liquids**

Read `src/main.gd`. Find `_on_substance_pouring()`. Replace the spawn logic:

```gdscript
func _on_substance_pouring(substance_id: int, pos: Vector2) -> void:
	var grid_pos := receptacle.screen_to_grid(pos)
	var substance := SubstanceRegistry.get_substance(substance_id)
	if not substance:
		return

	var positions: Array[Vector2i] = []
	var radius := 2
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx * dx + dy * dy <= radius * radius:
				positions.append(Vector2i(grid_pos.x + dx, grid_pos.y + dy))

	if substance.phase == SubstanceDef.Phase.LIQUID:
		# Liquids go to the MAC fluid solver at 4x resolution.
		for p in positions:
			receptacle.fluid_solver.spawn_fluid_block(p.x, p.y, 4, substance_id)
	else:
		receptacle.gpu_sim.spawn_cells(positions, substance_id)
```

- [ ] **Step 3: Run the game**

Pour water. The particle grid renderer won't show it (the water is now in the fluid solver buffers, not the particle grid). We need a way to render it — Task 14.

For now, just verify:
- Game runs without errors
- Perf monitor shows "Fluid Sim" with nonzero time when pouring (~3-5ms)

- [ ] **Step 4: Commit**

```bash
git add src/main.gd src/simulation/fluid_solver.gd
git commit -m "feat: route liquid spawns to FluidSolver at 4x resolution"
```

---

### Task 14: Render Fluid Density in the Existing Renderers

The four renderers currently read `fluid.markers` (CPU int array). We need to populate that from the fluid solver's density readback, downsampled from 800x600 to 200x150.

**Files:**
- Modify: `src/simulation/fluid_solver.gd`
- Modify: `src/receptacle/receptacle.gd`

- [ ] **Step 1: Add downsampling to FluidSolver**

Add method to `fluid_solver.gd`:

```gdscript
func downsample_to_grid(target_width: int, target_height: int, scale: int) -> Dictionary:
	## Downsample the fluid density and substance to a coarser grid.
	## Returns { density: PackedFloat32Array, substance: PackedInt32Array }
	var grid_density := PackedFloat32Array()
	grid_density.resize(target_width * target_height)
	var grid_substance := PackedInt32Array()
	grid_substance.resize(target_width * target_height)

	var sub_bytes := rd.buffer_get_data(buf_substance)
	var substance_readback := sub_bytes.to_int32_array()

	var inv_scale_sq := 1.0 / float(scale * scale)
	for gy in range(target_height):
		for gx in range(target_width):
			var sum := 0.0
			var best_dens := 0.0
			var best_sub := 0
			for fy in range(scale):
				for fx in range(scale):
					var fi: int = (gy * scale + fy) * width + gx * scale + fx
					var d: float = _density_readback[fi]
					sum += d
					if d > best_dens:
						best_dens = d
						best_sub = substance_readback[fi]
			var avg := sum * inv_scale_sq
			var gi: int = gy * target_width + gx
			grid_density[gi] = avg
			grid_substance[gi] = best_sub if avg > 0.05 else 0

	return {"density": grid_density, "substance": grid_substance}
```

- [ ] **Step 2: Sync fluid data in receptacle**

In `src/receptacle/receptacle.gd`, update `sync_from_gpu()`:

```gdscript
func sync_from_gpu() -> void:
	var cells_data := gpu_sim.get_cells()
	var temps_data := gpu_sim.get_temperatures()
	for i in range(mini(cells_data.size(), grid.cells.size())):
		grid.cells[i] = cells_data[i]
	for i in range(mini(temps_data.size(), grid.temperatures.size())):
		grid.temperatures[i] = temps_data[i]

	# Downsample fluid solver to grid resolution and populate fluid.markers.
	var downsampled := fluid_solver.downsample_to_grid(GRID_WIDTH, GRID_HEIGHT, 4)
	var sub_data: PackedInt32Array = downsampled["substance"]
	for i in range(mini(sub_data.size(), fluid.markers.size())):
		fluid.markers[i] = sub_data[i]
```

- [ ] **Step 3: Run the game**

Pour water. The renderers read `fluid.markers` so the water should now be visible. Expected behavior: water falls and pools realistically at the bottom.

If the water disappears or scatters, return to Task 8 and check stats in the test harness — the standalone solver should still work, the issue would be in the integration.

- [ ] **Step 4: Commit**

```bash
git add src/simulation/fluid_solver.gd src/receptacle/receptacle.gd
git commit -m "feat: downsample fluid solver density to grid mirror for rendering"
```

---

### Task 15: Route Clear and Flood Fill

**Files:**
- Modify: `src/main.gd`

- [ ] **Step 1: Update _clear_receptacle() to also clear fluid**

Read `src/main.gd`. In `_clear_receptacle()`, add a call to clear the fluid solver:

```gdscript
func _clear_receptacle() -> void:
	receptacle.gpu_sim.clear_all()
	receptacle.fluid_solver.clear()
	receptacle.sync_from_gpu()
	# ... rest of the method (rigid body clearing, field resets)
```

- [ ] **Step 2: Update _flood_fill() to route liquids**

Replace `_flood_fill()`:

```gdscript
func _flood_fill() -> void:
	var substance := SubstanceRegistry.get_substance(_selected_substance_id)
	if not substance:
		return

	var positions: Array[Vector2i] = []
	for i in range(receptacle.grid.cells.size()):
		if receptacle.grid.boundary[i] == 1 and receptacle.grid.cells[i] == 0:
			var x: int = i % receptacle.grid.width
			var y: int = floori(float(i) / float(receptacle.grid.width))
			positions.append(Vector2i(x, y))

	if substance.phase == SubstanceDef.Phase.LIQUID:
		for p in positions:
			receptacle.fluid_solver.spawn_fluid_block(p.x, p.y, 4, _selected_substance_id)
	else:
		receptacle.gpu_sim.spawn_cells(positions, _selected_substance_id)

	game_log.log_event("Flood filled %d cells with %s" % [positions.size(), _selected_substance_name], Color.ORANGE)
```

- [ ] **Step 3: Update dispenser routing**

In `src/interaction/dispenser.gd`, check how liquids are currently spawned. They currently go to `_gpu_sim.spawn_cells()`. Update to route liquids to the fluid solver.

Add a setter for fluid_solver in the dispenser:

```gdscript
var _fluid_solver: FluidSolver
```

Update the setup signature:

```gdscript
func setup(grid: ParticleGrid, fluid: FluidSim, receptacle_pos: Vector2, cell_size: int, gpu_sim: GpuSimulation = null, fluid_solver: FluidSolver = null) -> void:
	_grid = grid
	_fluid = fluid
	_gpu_sim = gpu_sim
	_fluid_solver = fluid_solver
	# ... rest unchanged
```

Update `_emit_particle()` to route liquids:

```gdscript
func _emit_particle(screen_pos: Vector2) -> void:
	var local := screen_pos - _receptacle_pos
	var gx: int = floori(local.x / float(_cell_size))
	var gy: int = floori(local.y / float(_cell_size))

	var sub := SubstanceRegistry.get_substance(substance_id)
	if not sub:
		return

	if _fluid_solver and sub.phase == SubstanceDef.Phase.LIQUID:
		_fluid_solver.spawn_fluid_block(gx, gy, 4, substance_id)
	elif _gpu_sim:
		_gpu_sim.spawn_cells([Vector2i(gx, gy)], substance_id)
```

- [ ] **Step 4: Pass fluid_solver to dispenser in main.gd**

In `_ready()`:

```gdscript
	dispenser.setup(receptacle.grid, receptacle.fluid, receptacle.global_position, Receptacle.CELL_SIZE, receptacle.gpu_sim, receptacle.fluid_solver)
```

- [ ] **Step 5: Run the game**

Test all liquid spawn methods:
- Pour from drag-drop
- Dispenser
- Flood fill (F key)
- Reset (R key)

Verify fluid behavior is consistent and clears work correctly.

- [ ] **Step 6: Commit**

```bash
git add src/main.gd src/interaction/dispenser.gd
git commit -m "feat: route clear, flood fill, and dispenser to fluid solver"
```

---

### Task 16: Final Integration Test and Perf Check

- [ ] **Step 1: Run comprehensive tests**

```bash
godot --path /Users/zholobov/src/gd-alchemy-proto
```

Test each:
1. Pour water → should fall, pool, and spread realistically
2. Pour oil → same behavior
3. Pour water, then acid → both should coexist without destroying each other (simple mixing)
4. Drop iron ingot in water → ingot should sit in the water
5. Pour acid on iron filings → should trigger reaction
6. Reset → everything clears
7. Switch renderers with F5 → fluid should be visible in all four
8. F3 perf monitor → Fluid Sim should be <10ms, total frame <16ms (60 FPS)

- [ ] **Step 2: Document results**

If any test fails, file it as a follow-up issue and move on. Primary goal: fluid behaves physically plausibly at 60 FPS.

- [ ] **Step 3: Commit documentation**

Update `CLAUDE.md` with a note about the new fluid system:

```markdown
## Fluid Simulation

Liquids use a GPU MAC fluid solver at 4x subdivided resolution (800x600). See `src/simulation/fluid_solver.gd` and `src/shaders/fluid_*.glsl`. Design spec: `docs/superpowers/specs/2026-04-06-gpu-mac-fluid-design.md`.
```

```bash
git add CLAUDE.md
git commit -m "docs: note fluid solver in CLAUDE.md"
```
