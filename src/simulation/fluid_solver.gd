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

# Uniform sets
var uniform_set_classify: RID
var uniform_set_body_forces: RID
var uniform_set_divergence: RID
var uniform_set_jacobi_ab: RID  # pressure_in=A, pressure_out=B
var uniform_set_jacobi_ba: RID  # pressure_in=B, pressure_out=A
var uniform_set_gradient: RID
var uniform_set_wall_zero: RID
var uniform_set_advect: RID
var uniform_set_damping: RID

# Readback
var _density_readback: PackedFloat32Array
var _u_readback: PackedFloat32Array
var _v_readback: PackedFloat32Array
var _divergence_readback: PackedFloat32Array
var _pressure_readback: PackedFloat32Array

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
	_update_params(delta)

	# Pass 1: Classify cells
	_dispatch(pipeline_classify, uniform_set_classify)

	# Pass 2: Apply gravity
	_dispatch(pipeline_body_forces, uniform_set_body_forces)

	# Pass 3: Compute divergence
	_dispatch(pipeline_divergence, uniform_set_divergence)

	# Reset pressure to 0 before Jacobi.
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

	# Ensure final pressure is in buf_pressure (gradient shader reads from there).
	if JACOBI_ITERATIONS % 2 == 1:
		var out_data := rd.buffer_get_data(buf_pressure_out)
		rd.buffer_update(buf_pressure, 0, cell_count * 4, out_data)

	# Pass 5: Subtract pressure gradient from velocities.
	_dispatch(pipeline_gradient, uniform_set_gradient)

	# Pass 6: Zero wall velocities.
	_dispatch(pipeline_wall_zero, uniform_set_wall_zero)

	# Pass 7: Advect density and substance.
	_dispatch(pipeline_advect, uniform_set_advect)

	# Swap density/substance: copy _out → in for next frame.
	var new_density := rd.buffer_get_data(buf_density_out)
	rd.buffer_update(buf_density, 0, cell_count * 4, new_density)
	var new_substance := rd.buffer_get_data(buf_substance_out)
	rd.buffer_update(buf_substance, 0, cell_count * 4, new_substance)

	# Pass 8: Velocity damping.
	_dispatch(pipeline_damping, uniform_set_damping)

	_readback_density()


func clear() -> void:
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
	var total_mass := 0.0
	var fluid_cells := 0
	for d in _density_readback:
		total_mass += d
		if d > 0.001:
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

	var max_pressure := 0.0
	var min_pressure := 0.0
	for p in _pressure_readback:
		if p > max_pressure:
			max_pressure = p
		if p < min_pressure:
			min_pressure = p

	return {
		"total_mass": total_mass,
		"max_velocity": max_vel,
		"max_divergence": max_div,
		"fluid_cells": fluid_cells,
		"max_pressure": max_pressure,
		"min_pressure": min_pressure,
	}


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
		# Default: rectangular box, walls on left/right/bottom, open top.
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
	shader_classify = _load_shader("res://src/shaders/fluid_classify.glsl")
	shader_body_forces = _load_shader("res://src/shaders/fluid_body_forces.glsl")
	shader_divergence = _load_shader("res://src/shaders/fluid_divergence.glsl")
	shader_jacobi = _load_shader("res://src/shaders/fluid_jacobi.glsl")
	shader_gradient = _load_shader("res://src/shaders/fluid_gradient.glsl")
	shader_wall_zero = _load_shader("res://src/shaders/fluid_wall_zero.glsl")
	shader_advect = _load_shader("res://src/shaders/fluid_advect.glsl")
	shader_damping = _load_shader("res://src/shaders/fluid_damping.glsl")


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
		[3, buf_pressure],
		[4, buf_pressure_out],
	])
	uniform_set_jacobi_ba = _build_uniform_set(shader_jacobi, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_divergence],
		[3, buf_pressure_out],
		[4, buf_pressure],
	])

	pipeline_gradient = rd.compute_pipeline_create(shader_gradient)
	uniform_set_gradient = _build_uniform_set(shader_gradient, [
		[0, buf_params],
		[1, buf_cell_type],
		[2, buf_pressure],
		[3, buf_u_vel],
		[4, buf_v_vel],
	])

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


func _update_params(delta: float) -> void:
	var bytes := PackedByteArray()
	bytes.resize(16)
	bytes.encode_s32(0, width)
	bytes.encode_s32(4, height)
	bytes.encode_float(8, delta)
	bytes.encode_s32(12, 0)
	rd.buffer_update(buf_params, 0, 16, bytes)


func _dispatch(pipeline: RID, uniform_set: RID) -> void:
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()


func _readback_density() -> void:
	var d_bytes := rd.buffer_get_data(buf_density)
	_density_readback = d_bytes.to_float32_array()

	var u_bytes := rd.buffer_get_data(buf_u_vel)
	_u_readback = u_bytes.to_float32_array()

	var v_bytes := rd.buffer_get_data(buf_v_vel)
	_v_readback = v_bytes.to_float32_array()

	var div_bytes := rd.buffer_get_data(buf_divergence)
	_divergence_readback = div_bytes.to_float32_array()

	var press_bytes := rd.buffer_get_data(buf_pressure)
	_pressure_readback = press_bytes.to_float32_array()
