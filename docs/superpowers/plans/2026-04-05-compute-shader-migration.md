# Compute Shader Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the simulation from GDScript per-cell loops to GPU compute shaders, achieving 60+ FPS instead of 3 FPS.

**Architecture:** GPU compute shaders process all 30K grid cells in parallel via Godot's RenderingDevice API. Three shader passes (particles, fluid, fields) run per frame. CPU reads back results and runs reaction logic on only occupied cells. Particle grid uses Margolus neighborhood (2x2 blocks) for conflict-free parallel updates.

**Tech Stack:** Godot 4.x RenderingDevice API, GLSL 450 compute shaders, storage buffers (SSBOs)

**Design Spec:** `docs/superpowers/specs/2026-04-05-compute-shader-migration.md`

---

## GPU Algorithm: Margolus Neighborhood

The particle grid shader uses 2x2 block processing to avoid race conditions. Each GPU thread owns a 2x2 block of cells and rearranges them locally (gravity, spreading). Block offset alternates each frame so particles cross block boundaries:

- Even frames: blocks at (0,0), (2,0), (0,2), ...
- Odd frames: blocks at (1,1), (3,1), (1,3), ...

Dispatched twice per frame (both offsets) so particles move 1 cell per frame, matching CPU speed. Dispatch grid: ceil(width/2) x ceil(height/2) threads.

---

### Task 1: GPU Simulation Manager — Minimal Pipeline

**Files:**
- Create: `src/shaders/particle_update.glsl`
- Create: `src/simulation/gpu_simulation.gd`

Prove the GPU compute pipeline works end-to-end: create a buffer, dispatch a trivial shader, read back data.

- [ ] **Step 1: Create shader directory**

```bash
mkdir -p /Users/zholobov/src/gd-alchemy-proto/src/shaders
```

- [ ] **Step 2: Create minimal pass-through compute shader**

Create `src/shaders/particle_update.glsl`:

```glsl
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int frame_count;
} params;

layout(set = 0, binding = 1, std430) restrict buffer CellsBuffer {
    int data[];
} cells;

layout(set = 0, binding = 2, std430) restrict buffer BoundaryBuffer {
    int data[];
} boundary;

layout(set = 0, binding = 3, std430) restrict buffer TempsBuffer {
    float data[];
} temperatures;

layout(set = 0, binding = 4, std430) restrict buffer SubstanceTable {
    float data[];
} substances;

// Substance table layout: STRIDE floats per substance
// [0]=phase, [1]=density, [2]=cond_thermal, [3]=cond_electric,
// [4]=mag_perm, [5]=viscosity, [6]=flash_point, [7]=flammability,
// [8]=color_r, [9]=color_g, [10]=color_b, [11]=color_a
const int STRIDE = 12;
const int PHASE_POWDER = 1;
const int PHASE_LIQUID = 2;
const int PHASE_GAS = 3;

int get_phase(int substance_id) {
    if (substance_id <= 0) return -1;
    return int(substances.data[substance_id * STRIDE]);
}

float get_density(int substance_id) {
    if (substance_id <= 0) return 0.0;
    return substances.data[substance_id * STRIDE + 1];
}

// Simple hash for pseudo-random behavior per cell per frame
uint hash(uint x, uint y, uint frame) {
    uint h = x * 374761393u + y * 668265263u + frame * 1013904223u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return h ^ (h >> 16);
}

void main() {
    // For now: pass-through. No simulation logic yet.
    // Just proves the pipeline works.
}
```

- [ ] **Step 3: Create GPU simulation manager**

Create `src/simulation/gpu_simulation.gd`:

```gdscript
class_name GpuSimulation
extends RefCounted
## Manages GPU compute shaders for the alchemy simulation.
## Creates buffers, compiles shaders, dispatches compute passes, handles readback.

var rd: RenderingDevice
var width: int
var height: int
var cell_count: int

# GPU buffer RIDs
var buf_params: RID
var buf_cells: RID
var buf_boundary: RID
var buf_temperatures: RID
var buf_substance_table: RID

# Shader and pipeline RIDs
var shader_particle: RID
var pipeline_particle: RID
var uniform_set_particle: RID

# Dispatch dimensions
var groups_x: int
var groups_y: int

# CPU-side readback arrays
var _cells_readback: PackedInt32Array
var _temps_readback: PackedFloat32Array

# Frame counter for alternating Margolus offsets
var _frame_count: int = 0

# Substance table constants
const SUBSTANCE_STRIDE := 12
const MAX_SUBSTANCES := 16


func setup(w: int, h: int, boundary_mask: PackedByteArray) -> void:
	width = w
	height = h
	cell_count = w * h

	rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("Failed to create RenderingDevice")
		return

	# Calculate dispatch groups (for per-cell shaders)
	groups_x = ceili(float(width) / 16.0)
	groups_y = ceili(float(height) / 16.0)

	_create_buffers(boundary_mask)
	_upload_substance_table()
	_compile_shaders()
	_create_pipelines()

	print("GPU simulation initialized: %dx%d grid, %d groups" % [width, height, groups_x * groups_y])


func _create_buffers(boundary_mask: PackedByteArray) -> void:
	# Params buffer (16 bytes: width, height, delta, frame_count)
	var params := PackedByteArray()
	params.resize(16)
	buf_params = rd.storage_buffer_create(16, params)

	# Cells buffer (int32 per cell)
	var cells_data := PackedInt32Array()
	cells_data.resize(cell_count)
	buf_cells = rd.storage_buffer_create(cell_count * 4, cells_data.to_byte_array())

	# Boundary buffer (int32 per cell, converted from bytes)
	var boundary_ints := PackedInt32Array()
	boundary_ints.resize(cell_count)
	for i in range(mini(boundary_mask.size(), cell_count)):
		boundary_ints[i] = boundary_mask[i]
	buf_boundary = rd.storage_buffer_create(cell_count * 4, boundary_ints.to_byte_array())

	# Temperatures buffer (float32 per cell)
	var temps_data := PackedFloat32Array()
	temps_data.resize(cell_count)
	temps_data.fill(20.0)
	buf_temperatures = rd.storage_buffer_create(cell_count * 4, temps_data.to_byte_array())

	# Substance lookup table
	var table_size := MAX_SUBSTANCES * SUBSTANCE_STRIDE * 4
	var table_data := PackedByteArray()
	table_data.resize(table_size)
	buf_substance_table = rd.storage_buffer_create(table_size, table_data)


func _upload_substance_table() -> void:
	var table := PackedFloat32Array()
	table.resize(MAX_SUBSTANCES * SUBSTANCE_STRIDE)
	# Index 0 = empty (all zeros, already default)
	for i in range(1, SubstanceRegistry.substances.size()):
		var sub := SubstanceRegistry.get_substance(i)
		if not sub:
			continue
		var offset := i * SUBSTANCE_STRIDE
		table[offset + 0] = float(sub.phase)
		table[offset + 1] = sub.density
		table[offset + 2] = sub.conductivity_thermal
		table[offset + 3] = sub.conductivity_electric
		table[offset + 4] = sub.magnetic_permeability
		table[offset + 5] = sub.viscosity
		table[offset + 6] = sub.flash_point
		table[offset + 7] = sub.flammability
		table[offset + 8] = sub.base_color.r
		table[offset + 9] = sub.base_color.g
		table[offset + 10] = sub.base_color.b
		table[offset + 11] = sub.base_color.a
	rd.buffer_update(buf_substance_table, 0, table.size() * 4, table.to_byte_array())


func _compile_shaders() -> void:
	var shader_file := load("res://src/shaders/particle_update.glsl") as RDShaderFile
	if not shader_file:
		push_error("Failed to load particle_update.glsl")
		return
	var spirv := shader_file.get_spirv()
	shader_particle = rd.shader_create_from_spirv(spirv)
	if not shader_particle.is_valid():
		push_error("Failed to compile particle_update shader")


func _create_pipelines() -> void:
	pipeline_particle = rd.compute_pipeline_create(shader_particle)

	# Create uniform set: bindings must match shader layout
	var uniforms: Array[RDUniform] = []

	var u_params := RDUniform.new()
	u_params.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_params.binding = 0
	u_params.add_id(buf_params)
	uniforms.append(u_params)

	var u_cells := RDUniform.new()
	u_cells.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_cells.binding = 1
	u_cells.add_id(buf_cells)
	uniforms.append(u_cells)

	var u_boundary := RDUniform.new()
	u_boundary.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_boundary.binding = 2
	u_boundary.add_id(buf_boundary)
	uniforms.append(u_boundary)

	var u_temps := RDUniform.new()
	u_temps.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_temps.binding = 3
	u_temps.add_id(buf_temperatures)
	uniforms.append(u_temps)

	var u_substances := RDUniform.new()
	u_substances.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_substances.binding = 4
	u_substances.add_id(buf_substance_table)
	uniforms.append(u_substances)

	uniform_set_particle = rd.uniform_set_create(uniforms, shader_particle, 0)


func _update_params(delta: float) -> void:
	var params := PackedInt32Array()
	params.resize(4)
	params[0] = width
	params[1] = height
	# Pack float delta as int bits
	params[2] = 0  # We'll pass delta differently
	params[3] = _frame_count

	# Use byte-level packing for mixed int/float params
	var bytes := PackedByteArray()
	bytes.resize(16)
	bytes.encode_s32(0, width)
	bytes.encode_s32(4, height)
	bytes.encode_float(8, delta)
	bytes.encode_s32(12, _frame_count)
	rd.buffer_update(buf_params, 0, 16, bytes)


func step(delta: float) -> void:
	## Run one simulation frame on the GPU.
	_frame_count += 1
	_update_params(delta)

	# Dispatch particle update shader
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline_particle)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set_particle, 0)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	rd.submit()
	rd.sync()

	# Read back results
	_readback()


func _readback() -> void:
	var cells_bytes := rd.buffer_get_data(buf_cells)
	_cells_readback = cells_bytes.to_int32_array()

	var temps_bytes := rd.buffer_get_data(buf_temperatures)
	_temps_readback = temps_bytes.to_float32_array()


func get_cells() -> PackedInt32Array:
	return _cells_readback


func get_temperatures() -> PackedFloat32Array:
	return _temps_readback


func spawn_cells(positions: Array[Vector2i], substance_id: int) -> void:
	## Write particles into the cells buffer at given positions.
	for pos in positions:
		if pos.x < 0 or pos.x >= width or pos.y < 0 or pos.y >= height:
			continue
		var idx := pos.y * width + pos.x
		var bytes := PackedByteArray()
		bytes.resize(4)
		bytes.encode_s32(0, substance_id)
		rd.buffer_update(buf_cells, idx * 4, 4, bytes)


func write_cell(x: int, y: int, substance_id: int) -> void:
	## Write a single cell. Used by mediator for reaction outputs.
	if x < 0 or x >= width or y < 0 or y >= height:
		return
	var idx := y * width + x
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_s32(0, substance_id)
	rd.buffer_update(buf_cells, idx * 4, 4, bytes)


func write_temperature(x: int, y: int, value: float) -> void:
	if x < 0 or x >= width or y < 0 or y >= height:
		return
	var idx := y * width + x
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0, value)
	rd.buffer_update(buf_temperatures, idx * 4, 4, bytes)


func clear_all() -> void:
	## Zero out all simulation buffers.
	var zeros_int := PackedInt32Array()
	zeros_int.resize(cell_count)
	rd.buffer_update(buf_cells, 0, cell_count * 4, zeros_int.to_byte_array())

	var temps := PackedFloat32Array()
	temps.resize(cell_count)
	temps.fill(20.0)
	rd.buffer_update(buf_temperatures, 0, cell_count * 4, temps.to_byte_array())

	_readback()


func cleanup() -> void:
	## Free all GPU resources.
	if rd:
		rd.free_rid(pipeline_particle)
		rd.free_rid(uniform_set_particle)
		rd.free_rid(shader_particle)
		rd.free_rid(buf_params)
		rd.free_rid(buf_cells)
		rd.free_rid(buf_boundary)
		rd.free_rid(buf_temperatures)
		rd.free_rid(buf_substance_table)
		rd.free()
```

- [ ] **Step 4: Commit**

```bash
git add src/shaders/particle_update.glsl src/simulation/gpu_simulation.gd
git commit -m "feat: GPU simulation manager skeleton with RenderingDevice pipeline"
```

---

### Task 2: Particle Update Shader — Margolus Gravity

**Files:**
- Modify: `src/shaders/particle_update.glsl`

Implement actual particle simulation in the compute shader using Margolus 2x2 block neighborhood.

- [ ] **Step 1: Replace particle_update.glsl with full Margolus implementation**

Replace `src/shaders/particle_update.glsl`:

```glsl
#[compute]
#version 450

// Each thread processes one 2x2 block.
// Dispatch: ceil(width/2/8) x ceil(height/2/8) workgroups.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int frame_count;
} params;

layout(set = 0, binding = 1, std430) restrict buffer CellsBuffer {
    int data[];
} cells;

layout(set = 0, binding = 2, std430) restrict buffer BoundaryBuffer {
    int data[];
} boundary;

layout(set = 0, binding = 3, std430) restrict buffer TempsBuffer {
    float data[];
} temperatures;

layout(set = 0, binding = 4, std430) restrict buffer SubstanceTable {
    float data[];
} substances;

const int STRIDE = 12;
const int PHASE_SOLID = 0;
const int PHASE_POWDER = 1;
const int PHASE_LIQUID = 2;
const int PHASE_GAS = 3;

int get_phase(int sub_id) {
    if (sub_id <= 0) return -1;
    return int(substances.data[sub_id * STRIDE]);
}

float get_density(int sub_id) {
    if (sub_id <= 0) return 0.0;
    return substances.data[sub_id * STRIDE + 1];
}

uint hash_cell(uint x, uint y, uint frame) {
    uint h = x * 374761393u + y * 668265263u + frame * 1013904223u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return h ^ (h >> 16);
}

bool is_movable(int phase) {
    return phase == PHASE_POWDER || phase == PHASE_LIQUID || phase == PHASE_GAS;
}

bool falls(int phase) {
    return phase == PHASE_POWDER || phase == PHASE_LIQUID;
}

bool rises(int phase) {
    return phase == PHASE_GAS;
}

void swap_cells(uint i1, uint i2) {
    int tmp = cells.data[i1];
    cells.data[i1] = cells.data[i2];
    cells.data[i2] = tmp;
    float tt = temperatures.data[i1];
    temperatures.data[i1] = temperatures.data[i2];
    temperatures.data[i2] = tt;
}

void main() {
    uint bx = gl_GlobalInvocationID.x;
    uint by = gl_GlobalInvocationID.y;

    // Margolus offset: alternates between (0,0) and (1,1) based on pass.
    // frame_count encodes both: bit 0 = current pass (0 or 1).
    uint offset = uint(params.frame_count) & 1u;

    uint x0 = bx * 2u + offset;
    uint y0 = by * 2u + offset;
    uint x1 = x0 + 1u;
    uint y1 = y0 + 1u;

    // Bounds check: both corners must be in grid
    if (x1 >= uint(params.grid_width) || y1 >= uint(params.grid_height)) return;

    // Cell indices
    uint i00 = y0 * uint(params.grid_width) + x0;  // top-left
    uint i10 = y0 * uint(params.grid_width) + x1;  // top-right
    uint i01 = y1 * uint(params.grid_width) + x0;  // bottom-left
    uint i11 = y1 * uint(params.grid_width) + x1;  // bottom-right

    // Check boundary validity
    bool b00 = boundary.data[i00] == 1;
    bool b10 = boundary.data[i10] == 1;
    bool b01 = boundary.data[i01] == 1;
    bool b11 = boundary.data[i11] == 1;

    // Read cells
    int c00 = cells.data[i00];
    int c10 = cells.data[i10];
    int c01 = cells.data[i01];
    int c11 = cells.data[i11];

    // Read temperatures
    float t00 = temperatures.data[i00];
    float t10 = temperatures.data[i10];
    float t01 = temperatures.data[i01];
    float t11 = temperatures.data[i11];

    // Pseudo-random for this block
    uint rng = hash_cell(x0, y0, uint(params.frame_count));
    bool prefer_left = (rng & 1u) == 0u;

    // === GRAVITY: top cells fall to bottom cells ===

    // Top-left falls to bottom-left
    if (c00 != 0 && c01 == 0 && b00 && b01 && falls(get_phase(c00))) {
        // Density check: don't fall through heavier substance
        if (c01 == 0 || get_density(c00) > get_density(c01)) {
            c01 = c00; c00 = 0;
            float tmp = t01; t01 = t00; t00 = tmp;
        }
    }

    // Top-right falls to bottom-right
    if (c10 != 0 && c11 == 0 && b10 && b11 && falls(get_phase(c10))) {
        if (c11 == 0 || get_density(c10) > get_density(c11)) {
            c11 = c10; c10 = 0;
            float tmp = t11; t11 = t10; t10 = tmp;
        }
    }

    // === DIAGONAL FALLS ===
    // Top-left falls diagonally to bottom-right (if can't go straight down)
    if (c00 != 0 && c11 == 0 && b00 && b11 && falls(get_phase(c00))) {
        if (c01 != 0 && prefer_left) {  // blocked below, try diagonal
            c11 = c00; c00 = 0;
            float tmp = t11; t11 = t00; t00 = tmp;
        }
    }

    // Top-right falls diagonally to bottom-left
    if (c10 != 0 && c01 == 0 && b10 && b01 && falls(get_phase(c10))) {
        if (c11 != 0 && !prefer_left) {
            c01 = c10; c10 = 0;
            float tmp = t01; t01 = t10; t10 = tmp;
        }
    }

    // === LIQUID SPREADING: bottom cells spread sideways ===
    if (c01 != 0 && c11 == 0 && b01 && b11 && get_phase(c01) == PHASE_LIQUID && prefer_left) {
        c11 = c01; c01 = 0;
        float tmp = t11; t11 = t01; t01 = tmp;
    }
    if (c11 != 0 && c01 == 0 && b11 && b01 && get_phase(c11) == PHASE_LIQUID && !prefer_left) {
        c01 = c11; c11 = 0;
        float tmp = t01; t01 = t11; t11 = tmp;
    }

    // === GAS RISING: bottom cells rise to top cells ===
    if (c01 != 0 && c00 == 0 && b01 && b00 && rises(get_phase(c01))) {
        c00 = c01; c01 = 0;
        float tmp = t00; t00 = t01; t01 = tmp;
    }
    if (c11 != 0 && c10 == 0 && b11 && b10 && rises(get_phase(c11))) {
        c10 = c11; c11 = 0;
        float tmp = t10; t10 = t11; t11 = tmp;
    }

    // === GAS SIDEWAYS DRIFT ===
    if (c00 != 0 && c10 == 0 && b00 && b10 && rises(get_phase(c00)) && prefer_left) {
        c10 = c00; c00 = 0;
    }
    if (c10 != 0 && c00 == 0 && b10 && b00 && rises(get_phase(c10)) && !prefer_left) {
        c00 = c10; c10 = 0;
    }

    // === DENSITY DISPLACEMENT: heavy sinks through light ===
    // Top-left vs bottom-left
    if (c00 != 0 && c01 != 0 && b00 && b01) {
        if (falls(get_phase(c00)) && get_density(c00) > get_density(c01) * 1.5) {
            int tmp_c = c01; c01 = c00; c00 = tmp_c;
            float tmp_t = t01; t01 = t00; t00 = tmp_t;
        }
    }
    // Top-right vs bottom-right
    if (c10 != 0 && c11 != 0 && b10 && b11) {
        if (falls(get_phase(c10)) && get_density(c10) > get_density(c11) * 1.5) {
            int tmp_c = c11; c11 = c10; c10 = tmp_c;
            float tmp_t = t11; t11 = t10; t10 = tmp_t;
        }
    }

    // === GAS DISSIPATION at top ===
    if (y0 <= 2u) {
        if (rises(get_phase(c00)) && (rng & 255u) < 2u) { c00 = 0; t00 = 20.0; }
        if (rises(get_phase(c10)) && ((rng >> 8) & 255u) < 2u) { c10 = 0; t10 = 20.0; }
    }

    // Write back all 4 cells
    cells.data[i00] = c00;
    cells.data[i10] = c10;
    cells.data[i01] = c01;
    cells.data[i11] = c11;

    temperatures.data[i00] = t00;
    temperatures.data[i10] = t10;
    temperatures.data[i01] = t01;
    temperatures.data[i11] = t11;
}
```

- [ ] **Step 2: Update gpu_simulation.gd dispatch for Margolus**

In `src/simulation/gpu_simulation.gd`, update `setup()` to calculate Margolus dispatch groups:

Add new field:
```gdscript
var groups_margolus_x: int
var groups_margolus_y: int
```

In `setup()`, after calculating `groups_x`/`groups_y`:
```gdscript
	# Margolus dispatch: each thread handles a 2x2 block
	groups_margolus_x = ceili(float(width) / 2.0 / 8.0)
	groups_margolus_y = ceili(float(height) / 2.0 / 8.0)
```

Update `step()` to dispatch twice (both Margolus offsets):

```gdscript
func step(delta: float) -> void:
	_update_params(delta)

	# Dispatch particle update twice — Margolus pass 0 and pass 1
	for pass_idx in range(2):
		# Update frame_count so shader sees the current pass
		var bytes := PackedByteArray()
		bytes.resize(16)
		bytes.encode_s32(0, width)
		bytes.encode_s32(4, height)
		bytes.encode_float(8, delta)
		bytes.encode_s32(12, _frame_count * 2 + pass_idx)
		rd.buffer_update(buf_params, 0, 16, bytes)

		var compute_list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline_particle)
		rd.compute_list_bind_uniform_set(compute_list, uniform_set_particle, 0)
		rd.compute_list_dispatch(compute_list, groups_margolus_x, groups_margolus_y, 1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()

	_frame_count += 1
	_readback()
```

- [ ] **Step 3: Commit**

```bash
git add src/shaders/particle_update.glsl src/simulation/gpu_simulation.gd
git commit -m "feat: Margolus particle update compute shader with gravity, gas, liquid"
```

---

### Task 3: Wire Particle Grid to GPU

**Files:**
- Modify: `src/receptacle/receptacle.gd`
- Modify: `src/main.gd`
- Modify: `src/simulation/particle_grid.gd`

Replace CPU particle grid update with GPU dispatch. ParticleGrid becomes a CPU mirror populated from readback.

- [ ] **Step 1: Add GpuSimulation to receptacle**

Read `src/receptacle/receptacle.gd`. Add field:

```gdscript
var gpu_sim: GpuSimulation
```

In `_ready()`, after creating the particle grid and setting boundary, add:

```gdscript
	# Create GPU simulation.
	gpu_sim = GpuSimulation.new()
	gpu_sim.setup(GRID_WIDTH, GRID_HEIGHT, grid.boundary)
```

- [ ] **Step 2: Add method to sync GPU readback to CPU mirror**

Add to `src/receptacle/receptacle.gd`:

```gdscript
func sync_from_gpu() -> void:
	## Copy GPU readback data into the CPU-side ParticleGrid mirror.
	var cells_data := gpu_sim.get_cells()
	var temps_data := gpu_sim.get_temperatures()
	for i in range(mini(cells_data.size(), grid.cells.size())):
		grid.cells[i] = cells_data[i]
	for i in range(mini(temps_data.size(), grid.temperatures.size())):
		grid.temperatures[i] = temps_data[i]
```

- [ ] **Step 3: Update main.gd to use GPU simulation**

Read `src/main.gd`. In `_process()`, replace the particle grid and fluid sim sections:

Replace:
```gdscript
	perf_monitor.begin_timing("Fluid Sim")
	receptacle.fluid.update(delta)
	perf_monitor.end_timing("Fluid Sim")

	perf_monitor.begin_timing("Particle Grid")
	receptacle.grid.update()
	perf_monitor.end_timing("Particle Grid")
```

With:
```gdscript
	perf_monitor.begin_timing("GPU Sim")
	receptacle.gpu_sim.step(delta)
	receptacle.sync_from_gpu()
	perf_monitor.end_timing("GPU Sim")
```

Update the spawn handlers to write to GPU. In `_on_substance_pouring()`, replace grid/fluid spawn calls with GPU buffer writes:

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

	receptacle.gpu_sim.spawn_cells(positions, substance_id)
```

Update `_clear_receptacle()` to clear GPU:
```gdscript
	receptacle.gpu_sim.clear_all()
	receptacle.sync_from_gpu()
```

- [ ] **Step 4: Disable CPU particle grid update**

In `src/simulation/particle_grid.gd`, add a guard to `update()` to make it a no-op (keep the method for API compatibility):

Read the file first, then add at the top of `update()`:
```gdscript
func update() -> void:
	## Disabled — simulation runs on GPU. This class is now a CPU mirror.
	pass
```

Replace the entire method body with just `pass`.

- [ ] **Step 5: Run and verify**

```bash
godot --path /Users/zholobov/src/gd-alchemy-proto
```

Expected: Window opens, FPS should be much higher (30-60+). Click to spawn particles — they should fall and stack. Press F3 to check "GPU Sim" timing (should be <5ms).

If particles don't appear: check Godot output panel for shader compilation errors.

- [ ] **Step 6: Commit**

```bash
git add src/receptacle/receptacle.gd src/main.gd src/simulation/particle_grid.gd
git commit -m "feat: wire particle grid to GPU compute — CPU becomes mirror"
```

---

### Task 4: Fields on GPU

**Files:**
- Create: `src/shaders/fields_update.glsl`
- Modify: `src/simulation/gpu_simulation.gd`

Move temperature diffusion, electric propagation, and pressure counting to GPU. Skip magnetic for now (runs every 4th frame, less critical). Fluid MAC shader deferred to Task 5.

- [ ] **Step 1: Create fields compute shader**

Create `src/shaders/fields_update.glsl`:

```glsl
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int frame_count;
} params;

layout(set = 0, binding = 1, std430) restrict buffer CellsBuffer {
    int data[];
} cells;

layout(set = 0, binding = 2, std430) restrict buffer BoundaryBuffer {
    int data[];
} boundary;

layout(set = 0, binding = 3, std430) restrict buffer TempsIn {
    float data[];
} temps_in;

layout(set = 0, binding = 4, std430) restrict buffer TempsOut {
    float data[];
} temps_out;

layout(set = 0, binding = 5, std430) restrict buffer SubstanceTable {
    float data[];
} substances;

layout(set = 0, binding = 6, std430) restrict buffer ElectricIn {
    float data[];
} electric_in;

layout(set = 0, binding = 7, std430) restrict buffer ElectricOut {
    float data[];
} electric_out;

const int STRIDE = 12;
const float AMBIENT_TEMP = 20.0;
const float AMBIENT_COOLING_RATE = 0.05;
const float CONDUCTION_RATE = 0.1;
const float RADIATION_RATE = 0.01;
const float ELEC_DISSIPATION = 0.05;
const float ELEC_PROPAGATION = 0.3;

float get_thermal_conductivity(int sub_id) {
    if (sub_id <= 0) return 0.0;
    return substances.data[sub_id * STRIDE + 2];
}

float get_electric_conductivity(int sub_id) {
    if (sub_id <= 0) return 0.0;
    return substances.data[sub_id * STRIDE + 3];
}

int get_phase(int sub_id) {
    if (sub_id <= 0) return -1;
    return int(substances.data[sub_id * STRIDE]);
}

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= uint(w) || y >= uint(h)) return;

    uint idx = y * uint(w) + x;
    if (boundary.data[idx] != 1) return;

    int sub_id = cells.data[idx];
    float temp = temps_in.data[idx];
    bool has_substance = sub_id > 0;

    // === TEMPERATURE DIFFUSION ===
    float conductivity = RADIATION_RATE;
    if (has_substance) {
        conductivity = get_thermal_conductivity(sub_id) * CONDUCTION_RATE;
    }

    float new_temp = temp;
    // 4-neighbor heat diffusion
    int neighbors_checked = 0;
    float heat_sum = 0.0;

    if (x > 0u && boundary.data[idx - 1u] == 1) {
        heat_sum += (temps_in.data[idx - 1u] - temp) * conductivity;
        neighbors_checked++;
    }
    if (x < uint(w - 1) && boundary.data[idx + 1u] == 1) {
        heat_sum += (temps_in.data[idx + 1u] - temp) * conductivity;
        neighbors_checked++;
    }
    if (y > 0u && boundary.data[idx - uint(w)] == 1) {
        heat_sum += (temps_in.data[idx - uint(w)] - temp) * conductivity;
        neighbors_checked++;
    }
    if (y < uint(h - 1) && boundary.data[idx + uint(w)] == 1) {
        heat_sum += (temps_in.data[idx + uint(w)] - temp) * conductivity;
        neighbors_checked++;
    }

    if (neighbors_checked > 0) {
        new_temp += heat_sum * 0.25;
    }

    // Ambient cooling
    if (has_substance) {
        new_temp = mix(new_temp, AMBIENT_TEMP, AMBIENT_COOLING_RATE * 0.1);
    } else {
        new_temp = mix(new_temp, AMBIENT_TEMP, AMBIENT_COOLING_RATE);
    }

    temps_out.data[idx] = new_temp;

    // === ELECTRIC FIELD (every 2nd frame) ===
    if ((params.frame_count & 1) == 0) {
        float charge = electric_in.data[idx];
        float new_charge = charge;
        float e_cond = has_substance ? get_electric_conductivity(sub_id) : 0.0;

        if (abs(charge) > 0.001 && e_cond > 0.01) {
            // Propagate to conductive neighbors
            if (x > 0u && boundary.data[idx - 1u] == 1) {
                int n_sub = cells.data[idx - 1u];
                float nc = n_sub > 0 ? get_electric_conductivity(n_sub) : 0.0;
                if (nc > 0.01) {
                    float flow = charge * e_cond * nc * ELEC_PROPAGATION * 0.25;
                    electric_out.data[idx - 1u] += flow;
                    new_charge -= flow;
                }
            }
            if (x < uint(w - 1) && boundary.data[idx + 1u] == 1) {
                int n_sub = cells.data[idx + 1u];
                float nc = n_sub > 0 ? get_electric_conductivity(n_sub) : 0.0;
                if (nc > 0.01) {
                    float flow = charge * e_cond * nc * ELEC_PROPAGATION * 0.25;
                    electric_out.data[idx + 1u] += flow;
                    new_charge -= flow;
                }
            }
            if (y > 0u && boundary.data[idx - uint(w)] == 1) {
                int n_sub = cells.data[idx - uint(w)];
                float nc = n_sub > 0 ? get_electric_conductivity(n_sub) : 0.0;
                if (nc > 0.01) {
                    float flow = charge * e_cond * nc * ELEC_PROPAGATION * 0.25;
                    electric_out.data[idx - uint(w)] += flow;
                    new_charge -= flow;
                }
            }
            if (y < uint(h - 1) && boundary.data[idx + uint(w)] == 1) {
                int n_sub = cells.data[idx + uint(w)];
                float nc = n_sub > 0 ? get_electric_conductivity(n_sub) : 0.0;
                if (nc > 0.01) {
                    float flow = charge * e_cond * nc * ELEC_PROPAGATION * 0.25;
                    electric_out.data[idx + uint(w)] += flow;
                    new_charge -= flow;
                }
            }
            new_charge *= (1.0 - ELEC_DISSIPATION * (1.0 - e_cond));
        } else {
            new_charge *= (1.0 - ELEC_DISSIPATION);
        }

        electric_out.data[idx] = new_charge;
    }
}
```

- [ ] **Step 2: Add fields buffers and shader to gpu_simulation.gd**

Read `src/simulation/gpu_simulation.gd`. Add new buffer and shader fields:

```gdscript
# Field buffers
var buf_temps_out: RID
var buf_electric_in: RID
var buf_electric_out: RID

# Fields shader
var shader_fields: RID
var pipeline_fields: RID
var uniform_set_fields: RID
```

In `_create_buffers()`, add:

```gdscript
	# Temperature output (ping-pong)
	var temps_out := PackedFloat32Array()
	temps_out.resize(cell_count)
	temps_out.fill(20.0)
	buf_temps_out = rd.storage_buffer_create(cell_count * 4, temps_out.to_byte_array())

	# Electric field buffers
	var elec_data := PackedFloat32Array()
	elec_data.resize(cell_count)
	buf_electric_in = rd.storage_buffer_create(cell_count * 4, elec_data.to_byte_array())
	buf_electric_out = rd.storage_buffer_create(cell_count * 4, elec_data.to_byte_array())
```

In `_compile_shaders()`, add:

```gdscript
	var fields_file := load("res://src/shaders/fields_update.glsl") as RDShaderFile
	if fields_file:
		var fields_spirv := fields_file.get_spirv()
		shader_fields = rd.shader_create_from_spirv(fields_spirv)
```

In `_create_pipelines()`, add a new method `_create_fields_pipeline()` and call it:

```gdscript
func _create_fields_pipeline() -> void:
	pipeline_fields = rd.compute_pipeline_create(shader_fields)

	var uniforms: Array[RDUniform] = []

	var u_params := RDUniform.new()
	u_params.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_params.binding = 0
	u_params.add_id(buf_params)
	uniforms.append(u_params)

	var u_cells := RDUniform.new()
	u_cells.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_cells.binding = 1
	u_cells.add_id(buf_cells)
	uniforms.append(u_cells)

	var u_boundary := RDUniform.new()
	u_boundary.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_boundary.binding = 2
	u_boundary.add_id(buf_boundary)
	uniforms.append(u_boundary)

	var u_temps_in := RDUniform.new()
	u_temps_in.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_temps_in.binding = 3
	u_temps_in.add_id(buf_temperatures)
	uniforms.append(u_temps_in)

	var u_temps_out := RDUniform.new()
	u_temps_out.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_temps_out.binding = 4
	u_temps_out.add_id(buf_temps_out)
	uniforms.append(u_temps_out)

	var u_substances := RDUniform.new()
	u_substances.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_substances.binding = 5
	u_substances.add_id(buf_substance_table)
	uniforms.append(u_substances)

	var u_elec_in := RDUniform.new()
	u_elec_in.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_elec_in.binding = 6
	u_elec_in.add_id(buf_electric_in)
	uniforms.append(u_elec_in)

	var u_elec_out := RDUniform.new()
	u_elec_out.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_elec_out.binding = 7
	u_elec_out.add_id(buf_electric_out)
	uniforms.append(u_elec_out)

	uniform_set_fields = rd.uniform_set_create(uniforms, shader_fields, 0)
```

Update `step()` to dispatch the fields shader after particle update, then swap ping-pong buffers:

```gdscript
	# Dispatch fields update
	var fields_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(fields_list, pipeline_fields)
	rd.compute_list_bind_uniform_set(fields_list, uniform_set_fields, 0)
	rd.compute_list_dispatch(fields_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()

	# Swap temperature ping-pong: copy output back to input
	var temp_data := rd.buffer_get_data(buf_temps_out)
	rd.buffer_update(buf_temperatures, 0, cell_count * 4, temp_data)

	# Swap electric ping-pong
	if _frame_count % 2 == 0:
		var elec_data := rd.buffer_get_data(buf_electric_out)
		rd.buffer_update(buf_electric_in, 0, cell_count * 4, elec_data)
```

- [ ] **Step 3: Update main.gd to skip CPU field updates**

In `src/main.gd`, in the `_process()` function, replace the Mediator+Fields section. The fields now run on GPU as part of `gpu_sim.step()`. The mediator still runs on CPU but only for reactions:

```gdscript
	# --- CPU Mediator (reactions only, on readback data) ---
	perf_monitor.begin_timing("Mediator")
	var has_substances := receptacle.grid.count_particles() > 0
	if has_substances:
		mediator.update()
	sound_field.flush()
	perf_monitor.end_timing("Mediator")
```

Remove the old fields update calls (temperature_field.update, pressure_field.update, etc.) from `_process()`.

- [ ] **Step 4: Commit**

```bash
git add src/shaders/fields_update.glsl src/simulation/gpu_simulation.gd src/main.gd
git commit -m "feat: temperature and electric fields on GPU compute shader"
```

---

### Task 5: Sparse Mediator

**Files:**
- Modify: `src/simulation/mediator.gd`

The mediator currently iterates all 30K cells to find occupied ones. With GPU readback, we scan the readback array once to build a sparse list, then only process those cells.

- [ ] **Step 1: Add sparse iteration to mediator**

Read `src/simulation/mediator.gd`. Replace `_check_particle_contacts()` with a sparse version:

```gdscript
var _occupied_cells: Array[Vector2i] = []


func update() -> void:
	reactions_this_frame = 0
	_build_occupied_list()
	_check_sparse_contacts()
	_check_phase_changes_sparse()


func _build_occupied_list() -> void:
	## Scan readback data once to find all occupied cells.
	_occupied_cells.clear()
	for y in range(grid.height):
		for x in range(grid.width):
			var i: int = y * grid.width + x
			if grid.cells[i] != 0 or (fluid and fluid.markers[i] != 0):
				_occupied_cells.append(Vector2i(x, y))


func _check_sparse_contacts() -> void:
	## Only check reactions at occupied cells and their neighbors.
	for pos in _occupied_cells:
		if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
			return

		var x := pos.x
		var y := pos.y
		var id_a := grid.get_cell(x, y)
		if id_a <= 0:
			continue

		var substance_a := SubstanceRegistry.get_substance(id_a)
		if not substance_a:
			continue

		# Check 4 neighbors
		var neighbors: Array[Vector2i] = [
			Vector2i(x + 1, y), Vector2i(x - 1, y),
			Vector2i(x, y + 1), Vector2i(x, y - 1),
		]

		for n in neighbors:
			if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
				return
			var id_b := grid.get_cell(n.x, n.y)
			if id_b <= 0 or id_b == id_a:
				continue

			var substance_b := SubstanceRegistry.get_substance(id_b)
			if not substance_b:
				continue

			var temp_a: float = grid.temperatures[grid.idx(x, y)]
			var temp_b: float = grid.temperatures[grid.idx(n.x, n.y)]

			var result := ReactionRules.evaluate(substance_a, substance_b, temp_a, temp_b)
			if result.has_reaction():
				_apply_reaction(x, y, n.x, n.y, result, substance_a, substance_b)
				reactions_this_frame += 1


func _check_phase_changes_sparse() -> void:
	## Only check phase changes for occupied cells.
	for pos in _occupied_cells:
		var x := pos.x
		var y := pos.y
		var i := grid.idx(x, y)
		var substance_id: int = grid.cells[i]
		if substance_id <= 0:
			continue

		var substance := SubstanceRegistry.get_substance(substance_id)
		if not substance:
			continue

		var temp: float = grid.temperatures[i]
		var change := ReactionRules.check_phase_change(substance, temp)
		if change.is_empty():
			continue

		var new_id := SubstanceRegistry.get_id(change["target_substance"])
		if new_id <= 0:
			continue

		var new_sub := SubstanceRegistry.get_substance(new_id)
		if not new_sub:
			continue

		# Apply phase change — write to GPU via receptacle
		if new_sub.phase == SubstanceDef.Phase.LIQUID:
			grid.clear_cell(x, y)
			fluid.spawn_fluid(x, y, new_id)
		elif new_sub.phase == SubstanceDef.Phase.GAS:
			grid.cells[i] = new_id
		else:
			grid.cells[i] = new_id

		if game_log:
			game_log.log_event(
				"%s -> %s (phase change)" % [substance.substance_name, change["target_substance"]],
				Color(0.5, 0.8, 1.0)
			)
```

Remove the old `_check_particle_contacts()`, `_check_particle_fluid_contacts()`, and `_check_phase_changes()` methods.

- [ ] **Step 2: Write mediator reaction outputs back to GPU**

The mediator modifies `grid.cells` and `grid.temperatures` on the CPU mirror. These changes need to be pushed back to the GPU buffers. Add to `src/main.gd` after the mediator runs:

```gdscript
	# Push mediator changes back to GPU
	if has_substances and mediator.reactions_this_frame > 0:
		# Sync entire cells and temps arrays back (simple approach)
		receptacle.gpu_sim.upload_cells(receptacle.grid.cells)
		receptacle.gpu_sim.upload_temperatures(receptacle.grid.temperatures)
```

Add these methods to `src/simulation/gpu_simulation.gd`:

```gdscript
func upload_cells(data: PackedInt32Array) -> void:
	rd.buffer_update(buf_cells, 0, data.size() * 4, data.to_byte_array())


func upload_temperatures(data: PackedFloat32Array) -> void:
	rd.buffer_update(buf_temperatures, 0, data.size() * 4, data.to_byte_array())
```

- [ ] **Step 3: Commit**

```bash
git add src/simulation/mediator.gd src/simulation/gpu_simulation.gd src/main.gd
git commit -m "feat: sparse mediator — iterate only occupied cells from GPU readback"
```

---

### Task 6: Fluid MAC Shader

**Files:**
- Create: `src/shaders/fluid_pressure.glsl`
- Modify: `src/simulation/gpu_simulation.gd`

Port the MAC fluid simulation to GPU. The Jacobi pressure solver is dispatched N times from CPU with barriers between iterations.

- [ ] **Step 1: Create fluid pressure compute shader**

Create `src/shaders/fluid_pressure.glsl`:

```glsl
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int phase;  // 0=gravity, 1=pressure_jacobi, 2=advect
} params;

layout(set = 0, binding = 1, std430) restrict buffer BoundaryBuffer {
    int data[];
} boundary;

layout(set = 0, binding = 2, std430) restrict buffer MarkersBuffer {
    int data[];
} markers;

layout(set = 0, binding = 3, std430) restrict buffer MarkersOutBuffer {
    int data[];
} markers_out;

layout(set = 0, binding = 4, std430) restrict buffer UVelocity {
    float data[];
} u_vel;

layout(set = 0, binding = 5, std430) restrict buffer VVelocity {
    float data[];
} v_vel;

layout(set = 0, binding = 6, std430) restrict buffer PressureBuffer {
    float data[];
} pressure;

const float GRAVITY = 200.0;
const float OVERRELAX = 1.9;

bool is_valid(int x, int y) {
    if (x < 0 || x >= params.grid_width || y < 0 || y >= params.grid_height) return false;
    return boundary.data[y * params.grid_width + x] == 1;
}

bool is_fluid(int x, int y) {
    if (!is_valid(x, y)) return false;
    return markers.data[y * params.grid_width + x] != 0;
}

int u_idx(int x, int y) {
    return y * (params.grid_width + 1) + x;
}

int v_idx(int x, int y) {
    return y * params.grid_width + x;
}

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= w || y >= h) return;

    int idx = y * w + x;

    if (params.phase == 0) {
        // === GRAVITY ===
        if (!is_fluid(x, y)) return;
        v_vel.data[v_idx(x, y + 1)] += GRAVITY * params.delta_time;
    }
    else if (params.phase == 1) {
        // === JACOBI PRESSURE ITERATION ===
        if (!is_fluid(x, y)) return;

        float s_left = is_valid(x - 1, y) ? 1.0 : 0.0;
        float s_right = is_valid(x + 1, y) ? 1.0 : 0.0;
        float s_top = is_valid(x, y - 1) ? 1.0 : 0.0;
        float s_bottom = is_valid(x, y + 1) ? 1.0 : 0.0;
        float s_total = s_left + s_right + s_top + s_bottom;
        if (s_total == 0.0) return;

        float div = u_vel.data[u_idx(x + 1, y)] - u_vel.data[u_idx(x, y)]
                   + v_vel.data[v_idx(x, y + 1)] - v_vel.data[v_idx(x, y)];

        float p = -div / s_total * OVERRELAX;
        pressure.data[idx] += p;

        u_vel.data[u_idx(x, y)] -= s_left * p;
        u_vel.data[u_idx(x + 1, y)] += s_right * p;
        v_vel.data[v_idx(x, y)] -= s_top * p;
        v_vel.data[v_idx(x, y + 1)] += s_bottom * p;
    }
    else if (params.phase == 2) {
        // === ADVECT MARKERS ===
        if (!is_fluid(x, y)) return;

        int sub_id = markers.data[idx];

        float vx = (u_vel.data[u_idx(x, y)] + u_vel.data[u_idx(x + 1, y)]) * 0.5;
        float vy = (v_vel.data[v_idx(x, y)] + v_vel.data[v_idx(x, y + 1)]) * 0.5;

        int tx = clamp(int(round(float(x) + vx * params.delta_time)), 0, w - 1);
        int ty = clamp(int(round(float(y) + vy * params.delta_time)), 0, h - 1);

        int t_idx = ty * w + tx;
        if (is_valid(tx, ty) && markers_out.data[t_idx] == 0) {
            markers_out.data[t_idx] = sub_id;
        } else if (markers_out.data[idx] == 0) {
            markers_out.data[idx] = sub_id;
        }
    }
    else if (params.phase == 3) {
        // === ZERO WALL VELOCITIES ===
        if (is_valid(x, y)) return;  // Only process wall cells
        u_vel.data[u_idx(x, y)] = 0.0;
        u_vel.data[u_idx(x + 1, y)] = 0.0;
        v_vel.data[v_idx(x, y)] = 0.0;
        v_vel.data[v_idx(x, y + 1)] = 0.0;
    }
}
```

- [ ] **Step 2: Add fluid buffers and shader to gpu_simulation.gd**

Read `src/simulation/gpu_simulation.gd`. Add fluid buffer fields:

```gdscript
# Fluid buffers
var buf_fluid_markers: RID
var buf_fluid_markers_out: RID
var buf_u_velocity: RID
var buf_v_velocity: RID
var buf_pressure: RID

# Fluid shader
var shader_fluid: RID
var pipeline_fluid: RID
var uniform_set_fluid: RID

# Fluid readback
var _fluid_readback: PackedInt32Array
var _has_fluid: bool = false

const PRESSURE_ITERATIONS := 40
```

In `_create_buffers()`, add:

```gdscript
	# Fluid markers
	var fluid_data := PackedInt32Array()
	fluid_data.resize(cell_count)
	buf_fluid_markers = rd.storage_buffer_create(cell_count * 4, fluid_data.to_byte_array())
	buf_fluid_markers_out = rd.storage_buffer_create(cell_count * 4, fluid_data.to_byte_array())

	# Velocity fields
	var u_size := (width + 1) * height
	var u_data := PackedFloat32Array()
	u_data.resize(u_size)
	buf_u_velocity = rd.storage_buffer_create(u_size * 4, u_data.to_byte_array())

	var v_size := width * (height + 1)
	var v_data := PackedFloat32Array()
	v_data.resize(v_size)
	buf_v_velocity = rd.storage_buffer_create(v_size * 4, v_data.to_byte_array())

	# Pressure
	var press_data := PackedFloat32Array()
	press_data.resize(cell_count)
	buf_pressure = rd.storage_buffer_create(cell_count * 4, press_data.to_byte_array())
```

Compile the fluid shader and create its pipeline (similar pattern to fields — create uniform set with all fluid buffers bound to the shader's bindings).

Update `step()` to dispatch the fluid shader with multiple phases:

```gdscript
	# Dispatch fluid sim (if fluid exists)
	if _has_fluid:
		_dispatch_fluid(delta)

	# ... after readback:
	_fluid_readback = rd.buffer_get_data(buf_fluid_markers).to_int32_array()
	_has_fluid = false
	for i in range(_fluid_readback.size()):
		if _fluid_readback[i] != 0:
			_has_fluid = true
			break


func _dispatch_fluid(delta: float) -> void:
	# Phase 0: Apply gravity
	_set_fluid_phase(0, delta)
	_run_fluid_dispatch()

	# Phase 1: Jacobi pressure iterations
	for iter in range(PRESSURE_ITERATIONS):
		_set_fluid_phase(1, delta)
		_run_fluid_dispatch()

	# Phase 3: Zero wall velocities
	_set_fluid_phase(3, delta)
	_run_fluid_dispatch()

	# Phase 2: Advect markers
	# First clear markers_out
	var zeros := PackedInt32Array()
	zeros.resize(cell_count)
	rd.buffer_update(buf_fluid_markers_out, 0, cell_count * 4, zeros.to_byte_array())

	_set_fluid_phase(2, delta)
	_run_fluid_dispatch()

	# Copy markers_out to markers_in for next frame
	var new_markers := rd.buffer_get_data(buf_fluid_markers_out)
	rd.buffer_update(buf_fluid_markers, 0, cell_count * 4, new_markers)

	# Reset pressure
	var zeros_f := PackedFloat32Array()
	zeros_f.resize(cell_count)
	rd.buffer_update(buf_pressure, 0, cell_count * 4, zeros_f.to_byte_array())


func _set_fluid_phase(phase: int, delta: float) -> void:
	var bytes := PackedByteArray()
	bytes.resize(16)
	bytes.encode_s32(0, width)
	bytes.encode_s32(4, height)
	bytes.encode_float(8, delta)
	bytes.encode_s32(12, phase)
	rd.buffer_update(buf_params, 0, 16, bytes)


func _run_fluid_dispatch() -> void:
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline_fluid)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set_fluid, 0)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
```

Add fluid readback and spawn methods:

```gdscript
func get_fluid_markers() -> PackedInt32Array:
	return _fluid_readback


func spawn_fluid(positions: Array[Vector2i], substance_id: int) -> void:
	for pos in positions:
		if pos.x < 0 or pos.x >= width or pos.y < 0 or pos.y >= height:
			continue
		var idx := pos.y * width + pos.x
		var bytes := PackedByteArray()
		bytes.resize(4)
		bytes.encode_s32(0, substance_id)
		rd.buffer_update(buf_fluid_markers, idx * 4, 4, bytes)
	_has_fluid = true
```

- [ ] **Step 3: Wire fluid into main.gd**

Update `_on_substance_pouring()` to route liquids to GPU fluid:

```gdscript
	if substance.phase == SubstanceDef.Phase.LIQUID:
		receptacle.gpu_sim.spawn_fluid(positions, substance_id)
	else:
		receptacle.gpu_sim.spawn_cells(positions, substance_id)
```

Update `receptacle.sync_from_gpu()` to also sync fluid markers:

```gdscript
func sync_from_gpu() -> void:
	var cells_data := gpu_sim.get_cells()
	var temps_data := gpu_sim.get_temperatures()
	var fluid_data := gpu_sim.get_fluid_markers()
	for i in range(mini(cells_data.size(), grid.cells.size())):
		grid.cells[i] = cells_data[i]
	for i in range(mini(temps_data.size(), grid.temperatures.size())):
		grid.temperatures[i] = temps_data[i]
	for i in range(mini(fluid_data.size(), fluid.markers.size())):
		fluid.markers[i] = fluid_data[i]
```

- [ ] **Step 4: Disable CPU fluid sim**

In `src/simulation/fluid_sim.gd`, replace `update()` body with:

```gdscript
func update(delta: float) -> void:
	## Disabled — simulation runs on GPU. This class is now a CPU mirror.
	pass
```

- [ ] **Step 5: Commit**

```bash
git add src/shaders/fluid_pressure.glsl src/simulation/gpu_simulation.gd src/main.gd src/receptacle/receptacle.gd src/simulation/fluid_sim.gd
git commit -m "feat: MAC fluid pressure solver on GPU — Jacobi iterations + marker advection"
```

---

### Task 7: Integration, Cleanup & Benchmark

**Files:**
- Modify: `src/main.gd`
- Modify: `src/simulation/gpu_simulation.gd`

Final wiring, cleanup dead code paths, and benchmark.

- [ ] **Step 1: Clean up main.gd _process()**

Read `src/main.gd`. The final `_process()` should be:

```gdscript
func _process(delta: float) -> void:
	# --- GPU Simulation ---
	perf_monitor.begin_timing("GPU Sim")
	receptacle.gpu_sim.step(delta)
	receptacle.sync_from_gpu()
	perf_monitor.end_timing("GPU Sim")

	# --- CPU Mediator (reactions only) ---
	perf_monitor.begin_timing("Mediator")
	var has_substances := receptacle.grid.count_particles() > 0 or receptacle.fluid.count_fluid_cells() > 0
	if has_substances:
		mediator.update()
		# Push reaction changes back to GPU
		if mediator.reactions_this_frame > 0:
			receptacle.gpu_sim.upload_cells(receptacle.grid.cells)
			receptacle.gpu_sim.upload_temperatures(receptacle.grid.temperatures)
	sound_field.flush()
	perf_monitor.end_timing("Mediator")

	# --- Rendering ---
	perf_monitor.begin_timing("Render")
	receptacle.renderer.render()
	field_renderer.update_visuals()
	perf_monitor.end_timing("Render")

	perf_monitor.update_particle_count(
		receptacle.grid.count_particles() + receptacle.fluid.count_fluid_cells()
	)
```

Remove any remaining CPU field update calls (temperature_field.update, electric_field.update, etc.) from `_process()` — these now run on GPU.

- [ ] **Step 2: Add cleanup to receptacle**

In `src/receptacle/receptacle.gd`, add:

```gdscript
func _exit_tree() -> void:
	if gpu_sim:
		gpu_sim.cleanup()
```

- [ ] **Step 3: Update _clear_receptacle()**

```gdscript
func _clear_receptacle() -> void:
	receptacle.gpu_sim.clear_all()
	receptacle.sync_from_gpu()
	# Clear rigid bodies
	for body in receptacle.rigid_body_mgr._bodies.duplicate():
		body.queue_free()
	receptacle.rigid_body_mgr._bodies.clear()
	# Reset CPU-side field state
	pressure_field.reset()
	light_field.light_sources.clear()
	game_log.log_event("Receptacle cleared — all systems reset", Color.YELLOW)
```

- [ ] **Step 4: Run and benchmark**

```bash
godot --path /Users/zholobov/src/gd-alchemy-proto
```

Test with F3 enabled:

| Test | Expected GPU Sim | Expected Mediator | Expected FPS |
|------|-----------------|-------------------|-------------|
| Empty receptacle | <1ms | 0ms | 60+ |
| 100 powder particles | <2ms | <1ms | 60+ |
| 1000 particles | <2ms | <2ms | 60+ |
| Flood fill (30K) | <3ms | ~5ms | 40-60 |
| Fluid (water) | <5ms | <1ms | 60+ |
| Mixed powder + fluid | <5ms | <3ms | 50-60 |

- [ ] **Step 5: Commit**

```bash
git add src/main.gd src/receptacle/receptacle.gd src/simulation/gpu_simulation.gd
git commit -m "feat: full GPU simulation integration — particles, fluid, fields on compute shaders"
```
