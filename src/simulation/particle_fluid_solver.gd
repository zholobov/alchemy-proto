class_name ParticleFluidSolver
extends RefCounted
## PIC/FLIP particle-based fluid solver.
##
## Particles carry mass and substance ID; the MAC grid is used only for the
## pressure projection step. This eliminates the numerical-diffusion artifact
## of grid-based density advection: water stays as water because each particle
## is a discrete entity that doesn't get bilinear-interpolated into oblivion.
##
## Pipeline per step():
##   1. clear_grid: zero u, v, weights, density, substance buffers
##   2. p2g: scatter particle velocities + density to grid (atomic CompSwap)
##   3. normalize: divide accumulated u/v by weights, convert density to float
##   4. classify: cell type from float density (reuses fluid_classify.glsl)
##   5. wall_zero: zero velocities at wall faces (reuses fluid_wall_zero.glsl)
##   6. save_vel: snapshot u/v as u_old/v_old for FLIP delta
##   7. divergence (reuses fluid_divergence.glsl)
##   8. jacobi (80 iterations, reuses fluid_jacobi.glsl)
##   9. gradient (reuses fluid_gradient.glsl)
##   10. wall_zero
##   11. g2p: gather corrected grid velocity back to particles, FLIP delta
##   12. advect: apply gravity per-particle, move, boundary collision
##
## Note: gravity is applied PER-PARTICLE only (in advect), NOT on the grid.
## In hybrid PIC/FLIP, the FLIP component preserves particle momentum across
## frames; if gravity were also applied to grid velocities and captured in the
## FLIP delta, it would cancel out (saved=after-gravity, current=after-gravity-
## minus-pressure, delta=just pressure). Per-particle gravity is the standard
## approach in FLIP literature.

const MAX_PARTICLES := 262144  # 256k. ~6 MB. Enough to fill 200x150 grid at 8/cell.
const PARTICLE_STRIDE := 24  # bytes: vec2 pos + vec2 vel + int substance + int alive
const MAX_SUBSTANCES := 64   # size of the substance properties table
const SUBSTANCE_PROPS_STRIDE := 16  # bytes per substance: vec4(viscosity, flip_ratio, density, _)
const JACOBI_ITERATIONS := 80

## Fixed internal sub-step dt. The shader constants in pflip_advect.glsl
## (MAX_VELOCITY=100, GRAVITY=60, DRAG_SPEED_FALLOFF=50) and
## pflip_density_correction.glsl (DENSITY_STIFFNESS=500) were tuned assuming
## this per-step dt. step() sub-steps internally so the solver always sees
## this dt regardless of the caller's frame rate. DO NOT change TARGET_DT
## without retuning those shader constants in tandem — CFL violation at
## larger dt causes a particle-ejection cascade that blows the blob apart.
const TARGET_DT := 0.0083   # = 1/120s, matches the "CFL: at 120 FPS" comment in pflip_advect.glsl
const MAX_FRAME_DT := 0.05  # Hard cap on simulated time per step() call. Below ~20 FPS
                            # we stop trying to keep up with wall time and let the sim slow.
const MAX_SUBSTEPS := 8     # Safety cap on sub-step count per frame. Prevents death spiral
                            # if substepping itself drops FPS further.

var rd: RenderingDevice
var width: int
var height: int
var cell_count: int
var u_size: int
var v_size: int

# Particle state (CPU side)
var _particle_count: int = 0  # number of slots used (alive or not, for compaction later)
var _alive_count: int = 0     # number of actually-alive particles

# GPU buffers
var buf_params: RID
var buf_particles: RID
var buf_boundary: RID
var buf_u_vel: RID
var buf_v_vel: RID
var buf_u_weights: RID
var buf_v_weights: RID
var buf_u_old: RID
var buf_v_old: RID
var buf_u_temp: RID  # scratch for viscosity (read u_vel, write u_temp, then copy back)
var buf_v_temp: RID
var buf_density_count: RID  # uint, particle count per cell
var buf_density_float: RID  # float, normalized density (for classify)
var buf_substance: RID
var buf_substance2: RID  # C1: secondary substance per cell for mixing visualization
var buf_substance_props: RID  # per-substance properties (viscosity, ...) indexed by id
var buf_kill_mask: RID  # mediator sets cells to 1 to destroy liquid particles there
var buf_ambient_density: RID  # per-cell ambient density for Archimedes buoyancy in advect
var buf_temperature: RID  # per-cell temperature for thermal buoyancy (convection)
var buf_cell_type: RID
var buf_divergence: RID
var buf_pressure: RID
var buf_pressure_out: RID
var buf_cell_density: RID  # per-cell density (cell_mass / count) for variable-density Poisson
var buf_cell_mass: RID     # sum of per-particle substance densities, atomic-accumulated in p2g

# Shaders
var shader_clear_grid: RID
var shader_p2g: RID
var shader_normalize: RID
var shader_save_vel: RID
var shader_g2p: RID
var shader_advect: RID
var shader_classify: RID
var shader_density_correction: RID
var shader_viscosity: RID
var shader_extrapolate: RID
var shader_wall_zero: RID
var shader_divergence: RID
var shader_jacobi: RID
var shader_gradient: RID
var shader_compute_cell_density: RID
var shader_apply_kills: RID

# Pipelines
var pipeline_clear_grid: RID
var pipeline_p2g: RID
var pipeline_normalize: RID
var pipeline_save_vel: RID
var pipeline_g2p: RID
var pipeline_advect: RID
var pipeline_classify: RID
var pipeline_density_correction: RID
var pipeline_viscosity: RID
var pipeline_extrapolate: RID
var pipeline_wall_zero: RID
var pipeline_divergence: RID
var pipeline_jacobi: RID
var pipeline_gradient: RID
var pipeline_compute_cell_density: RID
var pipeline_apply_kills: RID

# Uniform sets
var uset_clear_grid: RID
var uset_p2g: RID
var uset_normalize: RID
var uset_save_vel: RID
var uset_g2p: RID
var uset_advect: RID
var uset_classify: RID
var uset_density_correction: RID
var uset_viscosity: RID
var uset_extrapolate: RID
var uset_wall_zero: RID
var uset_divergence: RID
var uset_jacobi_ab: RID
var uset_jacobi_ba: RID
var uset_gradient: RID
var uset_compute_cell_density: RID
var uset_apply_kills: RID

# CPU-side staging for the mediator's cell kill mask. Mediator calls
# mark_cell_for_kill() which sets bits here; on the next step() we
# upload + dispatch apply_kills + clear the mask.
var _kill_mask_cpu: PackedInt32Array
var _kill_mask_dirty: bool = false

# Dispatch dimensions
var groups_grid_x: int
var groups_grid_y: int
var groups_part: int

# CPU readback
var _density_readback: PackedFloat32Array
var _substance_readback: PackedInt32Array
var _substance2_readback: PackedInt32Array  # C1 secondary substance for mixing


func setup(w: int, h: int, boundary_mask: PackedByteArray = PackedByteArray()) -> void:
	width = w
	height = h
	cell_count = w * h
	u_size = (w + 1) * h
	v_size = w * (h + 1)

	rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("ParticleFluidSolver: failed to create RenderingDevice")
		return

	groups_grid_x = ceili(float(maxi(w + 1, w)) / 16.0)
	groups_grid_y = ceili(float(maxi(h, h + 1)) / 16.0)
	groups_part = ceili(float(MAX_PARTICLES) / 64.0)

	_create_buffers(boundary_mask)
	_compile_shaders()
	_create_pipelines()

	print("ParticleFluidSolver initialized: %dx%d, max %d particles" % [w, h, MAX_PARTICLES])


func step(frame_delta: float) -> void:
	## Advance the simulation by `frame_delta` seconds of wall time.
	## Internally sub-steps so each underlying integration uses a fixed dt
	## of TARGET_DT (matching the FPS the shader constants were tuned for).
	## _readback() runs once at the end — sub-stepping does not increase
	## GPU-to-CPU stall count.
	frame_delta = clampf(frame_delta, 0.0, MAX_FRAME_DT)
	if frame_delta <= 0.0:
		_readback()
		return

	# Mediator-queued kill pass. Runs ONCE per frame (not once per substep),
	# at the top so the remaining substeps act on the culled particle set.
	# No-op on frames when no reactions consumed liquid cells.
	if _kill_mask_dirty:
		_flush_kill_mask()

	var num_substeps := maxi(1, ceili(frame_delta / TARGET_DT))
	num_substeps = mini(num_substeps, MAX_SUBSTEPS)
	var sub_delta := frame_delta / float(num_substeps)

	for i in range(num_substeps):
		_single_step(sub_delta)

	_readback()


func mark_cell_for_kill(x: int, y: int) -> void:
	## Called by the mediator when a reaction consumes a liquid cell. The
	## mark is applied on the next step() call via a GPU dispatch. Multiple
	## calls in the same frame accumulate into the mask without duplication.
	if x < 0 or x >= width or y < 0 or y >= height:
		return
	_kill_mask_cpu[y * width + x] = 1
	_kill_mask_dirty = true


func _flush_kill_mask() -> void:
	## Upload the CPU mask to the GPU, dispatch apply_kills, clear the mask,
	## and drop the dirty flag. Called once at the top of step() when dirty.
	# Need fresh params with particle_count before dispatching.
	_update_params(0.0)
	rd.buffer_update(buf_kill_mask, 0, cell_count * 4, _kill_mask_cpu.to_byte_array())
	_dispatch(pipeline_apply_kills, uset_apply_kills, groups_part, 1)
	_kill_mask_cpu.fill(0)
	_kill_mask_dirty = false


func _single_step(sub_delta: float) -> void:
	## One full PIC/FLIP pipeline pass at the given dt. Does NOT read back —
	## the outer step() handles that after all sub-steps finish.
	_update_params(sub_delta)

	# Pass 1: clear grid accumulators
	_dispatch(pipeline_clear_grid, uset_clear_grid, groups_grid_x, groups_grid_y)

	# Pass 2: particle-to-grid scatter (velocities + density count)
	_dispatch(pipeline_p2g, uset_p2g, groups_part, 1)

	# Pass 3: normalize accumulated velocities by weights, density count -> float
	_dispatch(pipeline_normalize, uset_normalize, groups_grid_x, groups_grid_y)

	# Pass 4: classify cells (air / fluid / wall) from density
	_dispatch(pipeline_classify, uset_classify, groups_grid_x, groups_grid_y)

	# Pass 5: zero wall-adjacent velocities
	_dispatch(pipeline_wall_zero, uset_wall_zero, groups_grid_x, groups_grid_y)

	# Pass 6: snapshot velocities for FLIP delta (= pressure correction only).
	# Gravity is NOT applied here — it's applied per-particle in advect.
	_dispatch(pipeline_save_vel, uset_save_vel, groups_grid_x, groups_grid_y)

	# Pass 6b: compute per-cell density from substance[] for the variable-
	# density Jacobi + gradient. Runs once per step, reused for all
	# JACOBI_ITERATIONS of the pressure solve.
	_dispatch(pipeline_compute_cell_density, uset_compute_cell_density, groups_grid_x, groups_grid_y)

	# Pass 7: compute divergence
	_dispatch(pipeline_divergence, uset_divergence, groups_grid_x, groups_grid_y)

	# Pass 7b: PIC/FLIP density correction. Adds a negative term to the divergence
	# at over-packed cells so the pressure solve creates outward force.
	_dispatch(pipeline_density_correction, uset_density_correction, groups_grid_x, groups_grid_y)

	# Pass 10: Jacobi pressure projection (batched in one compute list)
	rd.buffer_copy(buf_pressure, buf_pressure_out, 0, 0, cell_count * 4)
	var compute_list := rd.compute_list_begin()
	for i in range(JACOBI_ITERATIONS):
		if i % 2 == 0:
			rd.compute_list_bind_compute_pipeline(compute_list, pipeline_jacobi)
			rd.compute_list_bind_uniform_set(compute_list, uset_jacobi_ab, 0)
		else:
			rd.compute_list_bind_compute_pipeline(compute_list, pipeline_jacobi)
			rd.compute_list_bind_uniform_set(compute_list, uset_jacobi_ba, 0)
		rd.compute_list_dispatch(compute_list, groups_grid_x, groups_grid_y, 1)
		rd.compute_list_add_barrier(compute_list)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	if JACOBI_ITERATIONS % 2 == 1:
		rd.buffer_copy(buf_pressure_out, buf_pressure, 0, 0, cell_count * 4)

	# Pass 11: apply pressure gradient to velocities
	_dispatch(pipeline_gradient, uset_gradient, groups_grid_x, groups_grid_y)

	# Pass 11b: extrapolate fluid velocities into adjacent air cells. Each pass
	# extends the valid velocity field by 1 cell. This gives particles near the
	# fluid surface valid grid velocities to gather from in g2p, smoothing out
	# the boundary discontinuity. Run twice for a 2-cell extrapolation layer.
	for i in range(2):
		_dispatch(pipeline_extrapolate, uset_extrapolate, groups_grid_x, groups_grid_y)
		rd.buffer_copy(buf_u_temp, buf_u_vel, 0, 0, u_size * 4)
		rd.buffer_copy(buf_v_temp, buf_v_vel, 0, 0, v_size * 4)

	# Pass 11c: per-substance viscosity. Reads u_vel/v_vel, writes u_temp/v_temp,
	# then we copy temp back. Runs after gradient and extrapolation so the
	# viscosity correction is part of the (current - saved) FLIP delta.
	_dispatch(pipeline_viscosity, uset_viscosity, groups_grid_x, groups_grid_y)
	rd.buffer_copy(buf_u_temp, buf_u_vel, 0, 0, u_size * 4)
	rd.buffer_copy(buf_v_temp, buf_v_vel, 0, 0, v_size * 4)

	# Pass 12: zero wall velocities (post-gradient + post-viscosity)
	_dispatch(pipeline_wall_zero, uset_wall_zero, groups_grid_x, groups_grid_y)

	# Pass 13: gather corrected grid velocities back to particles (FLIP)
	_dispatch(pipeline_g2p, uset_g2p, groups_part, 1)

	# Pass 14: move particles + boundary collision
	_dispatch(pipeline_advect, uset_advect, groups_part, 1)


func spawn_particle(pos_x: float, pos_y: float, substance_id: int = 1) -> bool:
	## Append a single particle to the buffer. Returns false if buffer is full.
	if _particle_count >= MAX_PARTICLES:
		return false
	var bytes := PackedByteArray()
	bytes.resize(PARTICLE_STRIDE)
	bytes.encode_float(0, pos_x)
	bytes.encode_float(4, pos_y)
	bytes.encode_float(8, 0.0)  # vel.x
	bytes.encode_float(12, 0.0)  # vel.y
	bytes.encode_s32(16, substance_id)
	bytes.encode_s32(20, 1)  # alive
	rd.buffer_update(buf_particles, _particle_count * PARTICLE_STRIDE, PARTICLE_STRIDE, bytes)
	_particle_count += 1
	_alive_count += 1
	return true


func spawn_particles_batch(positions: Array[Vector2], substance_id: int = 1) -> int:
	## Spawn multiple particles in one buffer_update for efficiency. Returns count spawned.
	var spawn_count: int = mini(positions.size(), MAX_PARTICLES - _particle_count)
	if spawn_count <= 0:
		return 0
	var bytes := PackedByteArray()
	bytes.resize(spawn_count * PARTICLE_STRIDE)
	for i in range(spawn_count):
		var off := i * PARTICLE_STRIDE
		bytes.encode_float(off, positions[i].x)
		bytes.encode_float(off + 4, positions[i].y)
		bytes.encode_float(off + 8, 0.0)
		bytes.encode_float(off + 12, 0.0)
		bytes.encode_s32(off + 16, substance_id)
		bytes.encode_s32(off + 20, 1)
	rd.buffer_update(buf_particles, _particle_count * PARTICLE_STRIDE, spawn_count * PARTICLE_STRIDE, bytes)
	_particle_count += spawn_count
	_alive_count += spawn_count
	return spawn_count


func clear() -> void:
	# Zero the particle buffer (all become alive=0).
	var zeros := PackedByteArray()
	zeros.resize(MAX_PARTICLES * PARTICLE_STRIDE)
	rd.buffer_update(buf_particles, 0, MAX_PARTICLES * PARTICLE_STRIDE, zeros)
	_particle_count = 0
	_alive_count = 0
	# Drop any pending mediator kills — there's nothing left to kill.
	_kill_mask_cpu.fill(0)
	_kill_mask_dirty = false


func upload_ambient_density(data: PackedFloat32Array) -> void:
	## Called by Receptacle each frame after sync_from_gpu. Copies the
	## host-computed ambient density field to the GPU for the advect
	## shader to sample. Size must equal cell_count; caller is responsible
	## for that invariant.
	if data.size() < cell_count:
		return
	rd.buffer_update(buf_ambient_density, 0, cell_count * 4, data.to_byte_array())


func upload_temperatures(data: PackedFloat32Array) -> void:
	## Upload grid.temperatures to the GPU for thermal buoyancy. advect
	## samples per-cell temperature to modulate self_density (hot fluid
	## becomes effectively lighter and rises via Archimedes).
	if data.size() < cell_count:
		return
	rd.buffer_update(buf_temperature, 0, cell_count * 4, data.to_byte_array())


func upload_substance_properties() -> void:
	## Populate the substance properties buffer from SubstanceRegistry.
	## Layout: vec4 per substance — .x = viscosity, .y = flip_ratio,
	## .z = density, .w = reserved. VaporSim uses the same layout so both
	## sims can share a single encoding pattern. Call after setup() and
	## whenever registry entries change.
	var bytes := PackedByteArray()
	bytes.resize(MAX_SUBSTANCES * SUBSTANCE_PROPS_STRIDE)
	# Index 0 reserved (no substance) — leave as zeros.
	for i in range(1, MAX_SUBSTANCES):
		var sub := SubstanceRegistry.get_substance(i)
		if sub:
			var off: int = i * SUBSTANCE_PROPS_STRIDE
			bytes.encode_float(off + 0, sub.viscosity)
			bytes.encode_float(off + 4, sub.flip_ratio)
			bytes.encode_float(off + 8, sub.density)
			bytes.encode_float(off + 12, 0.0)
	rd.buffer_update(buf_substance_props, 0, MAX_SUBSTANCES * SUBSTANCE_PROPS_STRIDE, bytes)


func get_density_readback() -> PackedFloat32Array:
	return _density_readback


func get_substance_readback() -> PackedInt32Array:
	return _substance_readback


func get_particle_count() -> int:
	return _particle_count


func get_alive_count() -> int:
	return _alive_count


func get_stats() -> Dictionary:
	return {
		"particle_count": _particle_count,
		"alive_count": _alive_count,
		"max_particles": MAX_PARTICLES,
	}


func cleanup() -> void:
	if not rd:
		return

	# Free pipelines
	for p in [pipeline_clear_grid, pipeline_p2g, pipeline_normalize, pipeline_save_vel,
			  pipeline_g2p, pipeline_advect, pipeline_classify, pipeline_density_correction,
			  pipeline_viscosity, pipeline_extrapolate, pipeline_wall_zero,
			  pipeline_divergence, pipeline_jacobi, pipeline_gradient,
			  pipeline_compute_cell_density, pipeline_apply_kills]:
		if p.is_valid():
			rd.free_rid(p)

	# Free shaders
	for s in [shader_clear_grid, shader_p2g, shader_normalize, shader_save_vel,
			  shader_g2p, shader_advect, shader_classify, shader_density_correction,
			  shader_viscosity, shader_extrapolate, shader_wall_zero, shader_divergence,
			  shader_jacobi, shader_gradient, shader_compute_cell_density,
			  shader_apply_kills]:
		if s.is_valid():
			rd.free_rid(s)

	# Free buffers
	for b in [buf_params, buf_particles, buf_boundary, buf_u_vel, buf_v_vel,
			  buf_u_weights, buf_v_weights, buf_u_old, buf_v_old, buf_u_temp, buf_v_temp,
			  buf_density_count, buf_density_float, buf_substance, buf_substance2,
			  buf_substance_props, buf_cell_type, buf_divergence, buf_pressure, buf_pressure_out,
			  buf_cell_density, buf_cell_mass, buf_kill_mask, buf_ambient_density, buf_temperature]:
		if b.is_valid():
			rd.free_rid(b)

	rd.free()


func _create_buffers(boundary_mask: PackedByteArray) -> void:
	# Params buffer
	var params := PackedByteArray()
	params.resize(16)
	buf_params = rd.storage_buffer_create(16, params)

	# Particle buffer (max capacity)
	var part_zeros := PackedByteArray()
	part_zeros.resize(MAX_PARTICLES * PARTICLE_STRIDE)
	buf_particles = rd.storage_buffer_create(MAX_PARTICLES * PARTICLE_STRIDE, part_zeros)

	# Boundary buffer
	var boundary_data := PackedInt32Array()
	boundary_data.resize(cell_count)
	if boundary_mask.size() >= cell_count:
		for i in range(cell_count):
			boundary_data[i] = boundary_mask[i]
	else:
		for y in range(height):
			for x in range(width):
				var is_wall: bool = (x == 0 or x == width - 1 or y == height - 1)
				boundary_data[y * width + x] = 0 if is_wall else 1
	buf_boundary = rd.storage_buffer_create(cell_count * 4, boundary_data.to_byte_array())

	# Velocity buffers (treated as uint[] in p2g for atomic ops, float[] elsewhere)
	var u_zeros := PackedFloat32Array()
	u_zeros.resize(u_size)
	buf_u_vel = rd.storage_buffer_create(u_size * 4, u_zeros.to_byte_array())
	buf_u_weights = rd.storage_buffer_create(u_size * 4, u_zeros.to_byte_array())
	buf_u_old = rd.storage_buffer_create(u_size * 4, u_zeros.to_byte_array())
	buf_u_temp = rd.storage_buffer_create(u_size * 4, u_zeros.to_byte_array())

	var v_zeros := PackedFloat32Array()
	v_zeros.resize(v_size)
	buf_v_vel = rd.storage_buffer_create(v_size * 4, v_zeros.to_byte_array())
	buf_v_weights = rd.storage_buffer_create(v_size * 4, v_zeros.to_byte_array())
	buf_v_old = rd.storage_buffer_create(v_size * 4, v_zeros.to_byte_array())
	buf_v_temp = rd.storage_buffer_create(v_size * 4, v_zeros.to_byte_array())

	# Substance properties table. Laid out as vec2[MAX_SUBSTANCES] — each entry
	# is (viscosity, flip_ratio). Defaults to zeros; upload_substance_properties()
	# populates it from the SubstanceRegistry.
	var sub_props_zeros := PackedByteArray()
	sub_props_zeros.resize(MAX_SUBSTANCES * SUBSTANCE_PROPS_STRIDE)
	buf_substance_props = rd.storage_buffer_create(MAX_SUBSTANCES * SUBSTANCE_PROPS_STRIDE, sub_props_zeros)

	# Density buffers (count as uint, float as float)
	var cell_zeros_i := PackedInt32Array()
	cell_zeros_i.resize(cell_count)
	buf_density_count = rd.storage_buffer_create(cell_count * 4, cell_zeros_i.to_byte_array())
	buf_substance = rd.storage_buffer_create(cell_count * 4, cell_zeros_i.to_byte_array())
	buf_substance2 = rd.storage_buffer_create(cell_count * 4, cell_zeros_i.to_byte_array())
	buf_cell_type = rd.storage_buffer_create(cell_count * 4, cell_zeros_i.to_byte_array())
	buf_kill_mask = rd.storage_buffer_create(cell_count * 4, cell_zeros_i.to_byte_array())

	# Ambient density buffer (float per cell). Host uploads each frame via
	# upload_ambient_density(). Initialized to near-zero; the first real
	# upload happens on the first sync_from_gpu → compute_ambient_density.
	var ambient_zeros := PackedFloat32Array()
	ambient_zeros.resize(cell_count)
	buf_ambient_density = rd.storage_buffer_create(cell_count * 4, ambient_zeros.to_byte_array())

	# Temperature buffer (float per cell, °C). Host uploads grid.temperatures
	# each frame. Used by advect for thermal buoyancy — hot fluid rises.
	var temp_init := PackedFloat32Array()
	temp_init.resize(cell_count)
	temp_init.fill(20.0)  # room temp
	buf_temperature = rd.storage_buffer_create(cell_count * 4, temp_init.to_byte_array())

	# Preallocate the CPU kill-mask staging array so mark_cell_for_kill()
	# doesn't reallocate on first hit.
	_kill_mask_cpu = PackedInt32Array()
	_kill_mask_cpu.resize(cell_count)

	var cell_zeros_f := PackedFloat32Array()
	cell_zeros_f.resize(cell_count)
	buf_density_float = rd.storage_buffer_create(cell_count * 4, cell_zeros_f.to_byte_array())
	buf_divergence = rd.storage_buffer_create(cell_count * 4, cell_zeros_f.to_byte_array())
	buf_pressure = rd.storage_buffer_create(cell_count * 4, cell_zeros_f.to_byte_array())
	buf_pressure_out = rd.storage_buffer_create(cell_count * 4, cell_zeros_f.to_byte_array())
	buf_cell_density = rd.storage_buffer_create(cell_count * 4, cell_zeros_f.to_byte_array())
	buf_cell_mass = rd.storage_buffer_create(cell_count * 4, cell_zeros_f.to_byte_array())


func _compile_shaders() -> void:
	shader_clear_grid = _load("res://src/shaders/pflip_clear_grid.glsl")
	shader_p2g = _load("res://src/shaders/pflip_p2g.glsl")
	shader_normalize = _load("res://src/shaders/pflip_normalize.glsl")
	shader_save_vel = _load("res://src/shaders/pflip_save_vel.glsl")
	shader_g2p = _load("res://src/shaders/pflip_g2p.glsl")
	shader_advect = _load("res://src/shaders/pflip_advect.glsl")
	shader_density_correction = _load("res://src/shaders/pflip_density_correction.glsl")
	shader_viscosity = _load("res://src/shaders/pflip_viscosity.glsl")
	shader_extrapolate = _load("res://src/shaders/pflip_extrapolate.glsl")
	shader_apply_kills = _load("res://src/shaders/pflip_apply_kills.glsl")
	# pflip_classify uses a higher density threshold than the grid solver's
	# fluid_classify (sparse cells become AIR so falling streams aren't
	# pressure-corrected).
	shader_classify = _load("res://src/shaders/pflip_classify.glsl")
	# Reused from the grid solver:
	shader_wall_zero = _load("res://src/shaders/fluid_wall_zero.glsl")
	shader_divergence = _load("res://src/shaders/fluid_divergence.glsl")
	# PIC/FLIP-specific variable-density pressure projection. Solves the
	# weighted Poisson equation ∇·((1/ρ)∇p) = ∇·u/dt so multi-substance
	# mixes sort by density (mercury sinks through water, oil rises, etc.).
	# VaporSim still uses the uniform-density fluid_jacobi / fluid_gradient
	# because gases all have similar densities in our normalized scale.
	shader_compute_cell_density = _load("res://src/shaders/pflip_compute_cell_density.glsl")
	shader_jacobi = _load("res://src/shaders/pflip_jacobi.glsl")
	shader_gradient = _load("res://src/shaders/pflip_gradient.glsl")


func _load(path: String) -> RID:
	var file := load(path) as RDShaderFile
	if not file:
		push_error("ParticleFluidSolver: failed to load %s" % path)
		return RID()
	var spirv := file.get_spirv()
	var shader := rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		push_error("ParticleFluidSolver: failed to compile %s" % path)
	return shader


func _create_pipelines() -> void:
	# clear_grid
	pipeline_clear_grid = rd.compute_pipeline_create(shader_clear_grid)
	uset_clear_grid = _build_uset(shader_clear_grid, [
		[0, buf_params],
		[1, buf_u_vel],
		[2, buf_v_vel],
		[3, buf_u_weights],
		[4, buf_v_weights],
		[5, buf_density_count],
		[6, buf_substance],
		[7, buf_substance2],
		[8, buf_cell_mass],
	])

	# p2g — bindings 9/10 feed the cell_mass accumulator (substance_props
	# gives per-particle density, which gets atomicAdd'd into cell_mass).
	pipeline_p2g = rd.compute_pipeline_create(shader_p2g)
	uset_p2g = _build_uset(shader_p2g, [
		[0, buf_params],
		[1, buf_particles],
		[2, buf_u_vel],
		[3, buf_v_vel],
		[4, buf_u_weights],
		[5, buf_v_weights],
		[6, buf_density_count],
		[7, buf_substance],
		[8, buf_substance2],
		[9, buf_substance_props],
		[10, buf_cell_mass],
	])

	# normalize
	pipeline_normalize = rd.compute_pipeline_create(shader_normalize)
	uset_normalize = _build_uset(shader_normalize, [
		[0, buf_params],
		[1, buf_u_vel],
		[2, buf_v_vel],
		[3, buf_u_weights],
		[4, buf_v_weights],
		[5, buf_density_count],
		[6, buf_density_float],
	])

	# save_vel
	pipeline_save_vel = rd.compute_pipeline_create(shader_save_vel)
	uset_save_vel = _build_uset(shader_save_vel, [
		[0, buf_params],
		[1, buf_u_vel],
		[2, buf_v_vel],
		[3, buf_u_old],
		[4, buf_v_old],
	])

	# g2p
	pipeline_g2p = rd.compute_pipeline_create(shader_g2p)
	uset_g2p = _build_uset(shader_g2p, [
		[0, buf_params],
		[1, buf_particles],
		[2, buf_u_vel],
		[3, buf_v_vel],
		[4, buf_u_old],
		[5, buf_v_old],
		[6, buf_cell_type],
		[7, buf_substance_props],
	])

	# advect
	pipeline_advect = rd.compute_pipeline_create(shader_advect)
	uset_advect = _build_uset(shader_advect, [
		[0, buf_params],
		[1, buf_particles],
		[2, buf_boundary],
		[3, buf_substance_props],
		[4, buf_density_float],
		[5, buf_ambient_density],
		[6, buf_temperature],
	])

	# classify (reuses fluid_classify.glsl)
	pipeline_classify = rd.compute_pipeline_create(shader_classify)
	uset_classify = _build_uset(shader_classify, [
		[0, buf_params],
		[1, buf_density_float],
		[2, buf_boundary],
		[3, buf_cell_type],
	])

	# wall_zero
	pipeline_wall_zero = rd.compute_pipeline_create(shader_wall_zero)
	uset_wall_zero = _build_uset(shader_wall_zero, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_u_vel],
		[3, buf_v_vel],
	])

	# divergence
	pipeline_divergence = rd.compute_pipeline_create(shader_divergence)
	uset_divergence = _build_uset(shader_divergence, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_u_vel],
		[3, buf_v_vel],
		[4, buf_divergence],
	])

	# density_correction (PIC/FLIP only — modifies divergence to push particles apart)
	pipeline_density_correction = rd.compute_pipeline_create(shader_density_correction)
	uset_density_correction = _build_uset(shader_density_correction, [
		[0, buf_params],
		[1, buf_density_float],
		[2, buf_cell_type],
		[3, buf_divergence],
	])

	# viscosity (PIC/FLIP only — per-substance Laplacian smoothing of grid velocities)
	pipeline_viscosity = rd.compute_pipeline_create(shader_viscosity)
	uset_viscosity = _build_uset(shader_viscosity, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_substance],
		[3, buf_substance_props],
		[4, buf_u_vel],
		[5, buf_v_vel],
		[6, buf_u_temp],
		[7, buf_v_temp],
	])

	# extrapolate (PIC/FLIP only — extends fluid velocities into air cells)
	pipeline_extrapolate = rd.compute_pipeline_create(shader_extrapolate)
	uset_extrapolate = _build_uset(shader_extrapolate, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_u_vel],
		[3, buf_v_vel],
		[4, buf_u_temp],
		[5, buf_v_temp],
	])

	# apply_kills: mediator-driven cell-level kill pass for liquid reactions.
	# Reads the kill_mask and zeroes `alive` on any particle whose current
	# cell is marked. Dispatched at the top of step() before substeps when
	# _kill_mask_dirty is true.
	pipeline_apply_kills = rd.compute_pipeline_create(shader_apply_kills)
	uset_apply_kills = _build_uset(shader_apply_kills, [
		[0, buf_params],
		[1, buf_particles],
		[2, buf_kill_mask],
	])

	# compute_cell_density — divides cell_mass by particle count to get a
	# mass-weighted average cell density. Must run before divergence so the
	# pressure solve has a fresh density field. Uses cell_mass/count rather
	# than the racy substance buffer so isolated particles don't flicker the
	# cell density between substances and jitter the pressure.
	pipeline_compute_cell_density = rd.compute_pipeline_create(shader_compute_cell_density)
	uset_compute_cell_density = _build_uset(shader_compute_cell_density, [
		[0, buf_params],
		[1, buf_cell_mass],
		[2, buf_density_count],
		[3, buf_cell_density],
	])

	# jacobi (ping-pong) — variable-density pflip_jacobi reads cell_density
	# at binding 5 on top of the standard uset layout.
	pipeline_jacobi = rd.compute_pipeline_create(shader_jacobi)
	uset_jacobi_ab = _build_uset(shader_jacobi, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_divergence],
		[3, buf_pressure],
		[4, buf_pressure_out],
		[5, buf_cell_density],
	])
	uset_jacobi_ba = _build_uset(shader_jacobi, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_divergence],
		[3, buf_pressure_out],
		[4, buf_pressure],
		[5, buf_cell_density],
	])

	# gradient — variable-density pflip_gradient, same binding 5 extension.
	pipeline_gradient = rd.compute_pipeline_create(shader_gradient)
	uset_gradient = _build_uset(shader_gradient, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_pressure],
		[3, buf_u_vel],
		[4, buf_v_vel],
		[5, buf_cell_density],
	])


func _build_uset(shader: RID, bindings: Array) -> RID:
	var uniforms: Array[RDUniform] = []
	for b in bindings:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = b[0]
		u.add_id(b[1])
		uniforms.append(u)
	return rd.uniform_set_create(uniforms, shader, 0)


func _update_params(delta: float) -> void:
	var bytes := PackedByteArray()
	bytes.resize(16)
	bytes.encode_s32(0, width)
	bytes.encode_s32(4, height)
	bytes.encode_float(8, delta)
	bytes.encode_s32(12, _particle_count)
	rd.buffer_update(buf_params, 0, 16, bytes)


func _dispatch(pipeline: RID, uniform_set: RID, gx: int, gy: int) -> void:
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, gx, gy, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()


func _readback() -> void:
	var d_bytes := rd.buffer_get_data(buf_density_float)
	_density_readback = d_bytes.to_float32_array()
	var s_bytes := rd.buffer_get_data(buf_substance)
	_substance_readback = s_bytes.to_int32_array()
	var s2_bytes := rd.buffer_get_data(buf_substance2)
	_substance2_readback = s2_bytes.to_int32_array()


func get_secondary_substance_readback() -> PackedInt32Array:
	return _substance2_readback


func debug_first_particle() -> Dictionary:
	## Read back the first particle's data for debugging.
	var p_bytes := rd.buffer_get_data(buf_particles, 0, PARTICLE_STRIDE)
	return {
		"pos_x": p_bytes.decode_float(0),
		"pos_y": p_bytes.decode_float(4),
		"vel_x": p_bytes.decode_float(8),
		"vel_y": p_bytes.decode_float(12),
		"substance": p_bytes.decode_s32(16),
		"alive": p_bytes.decode_s32(20),
	}


func debug_particle_locations(boundary: PackedByteArray) -> Dictionary:
	## Read back ALL particle positions and count how many are in wall cells.
	var p_bytes := rd.buffer_get_data(buf_particles, 0, _particle_count * PARTICLE_STRIDE)
	var in_wall := 0
	var _in_air := 0
	var in_interior := 0
	var dead := 0
	var x_min: float = 1e9
	var x_max: float = -1e9
	var y_min: float = 1e9
	var y_max: float = -1e9
	for pi in range(_particle_count):
		var off := pi * PARTICLE_STRIDE
		var alive: int = p_bytes.decode_s32(off + 20)
		if alive == 0:
			dead += 1
			continue
		var px: float = p_bytes.decode_float(off)
		var py: float = p_bytes.decode_float(off + 4)
		if px < x_min: x_min = px
		if px > x_max: x_max = px
		if py < y_min: y_min = py
		if py > y_max: y_max = py
		var cx: int = clampi(int(floor(px)), 0, width - 1)
		var cy: int = clampi(int(floor(py)), 0, height - 1)
		if boundary[cy * width + cx] == 0:
			in_wall += 1
		else:
			in_interior += 1
	return {
		"in_wall": in_wall,
		"in_interior": in_interior,
		"dead": dead,
		"x_range": Vector2(x_min, x_max),
		"y_range": Vector2(y_min, y_max),
	}
