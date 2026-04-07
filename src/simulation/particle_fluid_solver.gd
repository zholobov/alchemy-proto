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
##   6. body_forces: gravity (reuses fluid_body_forces.glsl) — applied to grid
##   7. wall_zero: again, after gravity
##   8. save_vel: snapshot u/v as u_old/v_old for FLIP delta
##   9. divergence (reuses fluid_divergence.glsl)
##   10. jacobi (200 iterations, reuses fluid_jacobi.glsl)
##   11. gradient (reuses fluid_gradient.glsl)
##   12. wall_zero
##   13. g2p: gather corrected grid velocity back to particles, FLIP delta
##   14. advect: move particles, gravity, boundary collision

const MAX_PARTICLES := 65536
const PARTICLE_STRIDE := 24  # bytes: vec2 pos + vec2 vel + int substance + int alive
const JACOBI_ITERATIONS := 80

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
var buf_density_count: RID  # uint, particle count per cell
var buf_density_float: RID  # float, normalized density (for classify)
var buf_substance: RID
var buf_cell_type: RID
var buf_divergence: RID
var buf_pressure: RID
var buf_pressure_out: RID

# Shaders
var shader_clear_grid: RID
var shader_p2g: RID
var shader_normalize: RID
var shader_save_vel: RID
var shader_g2p: RID
var shader_advect: RID
var shader_classify: RID
var shader_body_forces: RID
var shader_wall_zero: RID
var shader_divergence: RID
var shader_jacobi: RID
var shader_gradient: RID

# Pipelines
var pipeline_clear_grid: RID
var pipeline_p2g: RID
var pipeline_normalize: RID
var pipeline_save_vel: RID
var pipeline_g2p: RID
var pipeline_advect: RID
var pipeline_classify: RID
var pipeline_body_forces: RID
var pipeline_wall_zero: RID
var pipeline_divergence: RID
var pipeline_jacobi: RID
var pipeline_gradient: RID

# Uniform sets
var uset_clear_grid: RID
var uset_p2g: RID
var uset_normalize: RID
var uset_save_vel: RID
var uset_g2p: RID
var uset_advect: RID
var uset_classify: RID
var uset_body_forces: RID
var uset_wall_zero: RID
var uset_divergence: RID
var uset_jacobi_ab: RID
var uset_jacobi_ba: RID
var uset_gradient: RID

# Dispatch dimensions
var groups_grid_x: int
var groups_grid_y: int
var groups_part: int

# CPU readback
var _density_readback: PackedFloat32Array
var _substance_readback: PackedInt32Array


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


func step(delta: float) -> void:
	# Clamp dt to prevent scene-load spikes from causing instability.
	delta = clampf(delta, 0.0, 0.033)
	_update_params(delta)

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

	# Pass 6: apply gravity to grid v-velocity (body forces)
	_dispatch(pipeline_body_forces, uset_body_forces, groups_grid_x, groups_grid_y)

	# Pass 7: zero walls again after gravity
	_dispatch(pipeline_wall_zero, uset_wall_zero, groups_grid_x, groups_grid_y)

	# Pass 8: snapshot velocities for FLIP delta computation
	_dispatch(pipeline_save_vel, uset_save_vel, groups_grid_x, groups_grid_y)

	# Pass 9: compute divergence
	_dispatch(pipeline_divergence, uset_divergence, groups_grid_x, groups_grid_y)

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

	# Pass 12: zero wall velocities (post-gradient)
	_dispatch(pipeline_wall_zero, uset_wall_zero, groups_grid_x, groups_grid_y)

	# Pass 13: gather corrected grid velocities back to particles (FLIP)
	_dispatch(pipeline_g2p, uset_g2p, groups_part, 1)

	# Pass 14: move particles + boundary collision
	_dispatch(pipeline_advect, uset_advect, groups_part, 1)

	_readback()


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
			  pipeline_g2p, pipeline_advect, pipeline_classify, pipeline_body_forces,
			  pipeline_wall_zero, pipeline_divergence, pipeline_jacobi, pipeline_gradient]:
		if p.is_valid():
			rd.free_rid(p)

	# Free shaders
	for s in [shader_clear_grid, shader_p2g, shader_normalize, shader_save_vel,
			  shader_g2p, shader_advect, shader_classify, shader_body_forces,
			  shader_wall_zero, shader_divergence, shader_jacobi, shader_gradient]:
		if s.is_valid():
			rd.free_rid(s)

	# Free buffers
	for b in [buf_params, buf_particles, buf_boundary, buf_u_vel, buf_v_vel,
			  buf_u_weights, buf_v_weights, buf_u_old, buf_v_old, buf_density_count,
			  buf_density_float, buf_substance, buf_cell_type, buf_divergence,
			  buf_pressure, buf_pressure_out]:
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

	var v_zeros := PackedFloat32Array()
	v_zeros.resize(v_size)
	buf_v_vel = rd.storage_buffer_create(v_size * 4, v_zeros.to_byte_array())
	buf_v_weights = rd.storage_buffer_create(v_size * 4, v_zeros.to_byte_array())
	buf_v_old = rd.storage_buffer_create(v_size * 4, v_zeros.to_byte_array())

	# Density buffers (count as uint, float as float)
	var cell_zeros_i := PackedInt32Array()
	cell_zeros_i.resize(cell_count)
	buf_density_count = rd.storage_buffer_create(cell_count * 4, cell_zeros_i.to_byte_array())
	buf_substance = rd.storage_buffer_create(cell_count * 4, cell_zeros_i.to_byte_array())
	buf_cell_type = rd.storage_buffer_create(cell_count * 4, cell_zeros_i.to_byte_array())

	var cell_zeros_f := PackedFloat32Array()
	cell_zeros_f.resize(cell_count)
	buf_density_float = rd.storage_buffer_create(cell_count * 4, cell_zeros_f.to_byte_array())
	buf_divergence = rd.storage_buffer_create(cell_count * 4, cell_zeros_f.to_byte_array())
	buf_pressure = rd.storage_buffer_create(cell_count * 4, cell_zeros_f.to_byte_array())
	buf_pressure_out = rd.storage_buffer_create(cell_count * 4, cell_zeros_f.to_byte_array())


func _compile_shaders() -> void:
	shader_clear_grid = _load("res://src/shaders/pflip_clear_grid.glsl")
	shader_p2g = _load("res://src/shaders/pflip_p2g.glsl")
	shader_normalize = _load("res://src/shaders/pflip_normalize.glsl")
	shader_save_vel = _load("res://src/shaders/pflip_save_vel.glsl")
	shader_g2p = _load("res://src/shaders/pflip_g2p.glsl")
	shader_advect = _load("res://src/shaders/pflip_advect.glsl")
	# Reused from the grid solver:
	shader_classify = _load("res://src/shaders/fluid_classify.glsl")
	shader_body_forces = _load("res://src/shaders/fluid_body_forces.glsl")
	shader_wall_zero = _load("res://src/shaders/fluid_wall_zero.glsl")
	shader_divergence = _load("res://src/shaders/fluid_divergence.glsl")
	shader_jacobi = _load("res://src/shaders/fluid_jacobi.glsl")
	shader_gradient = _load("res://src/shaders/fluid_gradient.glsl")


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
	])

	# p2g
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
	])

	# advect
	pipeline_advect = rd.compute_pipeline_create(shader_advect)
	uset_advect = _build_uset(shader_advect, [
		[0, buf_params],
		[1, buf_particles],
		[2, buf_boundary],
	])

	# classify (reuses fluid_classify.glsl)
	pipeline_classify = rd.compute_pipeline_create(shader_classify)
	uset_classify = _build_uset(shader_classify, [
		[0, buf_params],
		[1, buf_density_float],
		[2, buf_boundary],
		[3, buf_cell_type],
	])

	# body_forces
	pipeline_body_forces = rd.compute_pipeline_create(shader_body_forces)
	uset_body_forces = _build_uset(shader_body_forces, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_v_vel],
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

	# jacobi (ping-pong)
	pipeline_jacobi = rd.compute_pipeline_create(shader_jacobi)
	uset_jacobi_ab = _build_uset(shader_jacobi, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_divergence],
		[3, buf_pressure],
		[4, buf_pressure_out],
	])
	uset_jacobi_ba = _build_uset(shader_jacobi, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_divergence],
		[3, buf_pressure_out],
		[4, buf_pressure],
	])

	# gradient
	pipeline_gradient = rd.compute_pipeline_create(shader_gradient)
	uset_gradient = _build_uset(shader_gradient, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_pressure],
		[3, buf_u_vel],
		[4, buf_v_vel],
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
	var in_air := 0
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
