class_name GpuSimulation
extends RefCounted
## Manages GPU compute shaders for the particle grid and field simulation.
## Fluid MAC simulation is handled by a separate FluidSolver class.

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

# Shader and pipeline RIDs — particles
var shader_particle: RID
var pipeline_particle: RID
var uniform_set_particle: RID

# Shader and pipeline RIDs — fields
var shader_fields: RID
var pipeline_fields: RID
var uniform_set_fields: RID

# Fields ping-pong buffer
var buf_temps_out: RID

# Dispatch dimensions
var groups_x: int
var groups_y: int
var groups_margolus_x: int
var groups_margolus_y: int

# CPU-side readback arrays
var _cells_readback: PackedInt32Array
var _temps_readback: PackedFloat32Array

# Frame counter
var _frame_count: int = 0

# Substance table constants
const SUBSTANCE_STRIDE := 12
const MAX_SUBSTANCES := 32


func setup(w: int, h: int, boundary_mask: PackedByteArray) -> void:
	width = w
	height = h
	cell_count = w * h

	rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("Failed to create RenderingDevice")
		return

	# Per-cell dispatch groups (16x16 workgroups)
	groups_x = ceili(float(width) / 16.0)
	groups_y = ceili(float(height) / 16.0)

	# Margolus dispatch: each thread handles a 2x2 block (8x8 workgroups)
	groups_margolus_x = ceili(float(width) / 2.0 / 8.0)
	groups_margolus_y = ceili(float(height) / 2.0 / 8.0)

	_create_buffers(boundary_mask)
	_upload_substance_table()
	_compile_shaders()
	_create_particle_pipeline()
	_create_fields_pipeline()

	print("GPU simulation initialized: %dx%d grid, dispatch %dx%d" % [width, height, groups_margolus_x, groups_margolus_y])


func _create_buffers(boundary_mask: PackedByteArray) -> void:
	# Params buffer
	var params := PackedByteArray()
	params.resize(16)
	buf_params = rd.storage_buffer_create(16, params)

	# Cells buffer
	var cells_data := PackedInt32Array()
	cells_data.resize(cell_count)
	buf_cells = rd.storage_buffer_create(cell_count * 4, cells_data.to_byte_array())

	# Boundary buffer (convert bytes to int32 for shader compatibility)
	var boundary_ints := PackedInt32Array()
	boundary_ints.resize(cell_count)
	for i in range(mini(boundary_mask.size(), cell_count)):
		boundary_ints[i] = boundary_mask[i]
	buf_boundary = rd.storage_buffer_create(cell_count * 4, boundary_ints.to_byte_array())

	# Temperatures buffer
	var temps_data := PackedFloat32Array()
	temps_data.resize(cell_count)
	temps_data.fill(20.0)
	buf_temperatures = rd.storage_buffer_create(cell_count * 4, temps_data.to_byte_array())

	# Temperature output ping-pong buffer
	var temps_out := PackedFloat32Array()
	temps_out.resize(cell_count)
	temps_out.fill(20.0)
	buf_temps_out = rd.storage_buffer_create(cell_count * 4, temps_out.to_byte_array())

	# Substance lookup table
	var table_size := MAX_SUBSTANCES * SUBSTANCE_STRIDE * 4
	var table_data := PackedByteArray()
	table_data.resize(table_size)
	buf_substance_table = rd.storage_buffer_create(table_size, table_data)


func _upload_substance_table() -> void:
	var table := PackedFloat32Array()
	table.resize(MAX_SUBSTANCES * SUBSTANCE_STRIDE)
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

	var fields_file := load("res://src/shaders/fields_update.glsl") as RDShaderFile
	if not fields_file:
		push_error("Failed to load fields_update.glsl")
		return
	var fields_spirv := fields_file.get_spirv()
	shader_fields = rd.shader_create_from_spirv(fields_spirv)
	if not shader_fields.is_valid():
		push_error("Failed to compile fields_update shader")


func _create_particle_pipeline() -> void:
	pipeline_particle = rd.compute_pipeline_create(shader_particle)

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


func _create_fields_pipeline() -> void:
	pipeline_fields = rd.compute_pipeline_create(shader_fields)

	# Bindings: 0=params, 1=cells, 2=boundary, 3=temps_in, 4=temps_out, 5=substances
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

	uniform_set_fields = rd.uniform_set_create(uniforms, shader_fields, 0)


func step(delta: float) -> void:
	## Run one simulation frame on the GPU.
	# Dispatch particle update twice — Margolus pass 0 and pass 1
	for pass_idx in range(2):
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

	# Dispatch fields update (temperature diffusion)
	var fields_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(fields_list, pipeline_fields)
	rd.compute_list_bind_uniform_set(fields_list, uniform_set_fields, 0)
	rd.compute_list_dispatch(fields_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()

	# Swap temperature ping-pong: copy output back to input
	var temp_out_data := rd.buffer_get_data(buf_temps_out)
	rd.buffer_update(buf_temperatures, 0, cell_count * 4, temp_out_data)

	_frame_count += 1
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
	for pos in positions:
		if pos.x < 0 or pos.x >= width or pos.y < 0 or pos.y >= height:
			continue
		var idx := pos.y * width + pos.x
		var bytes := PackedByteArray()
		bytes.resize(4)
		bytes.encode_s32(0, substance_id)
		rd.buffer_update(buf_cells, idx * 4, 4, bytes)


func write_cell(x: int, y: int, substance_id: int) -> void:
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


func upload_cells(data: PackedInt32Array) -> void:
	rd.buffer_update(buf_cells, 0, data.size() * 4, data.to_byte_array())


func upload_temperatures(data: PackedFloat32Array) -> void:
	rd.buffer_update(buf_temperatures, 0, data.size() * 4, data.to_byte_array())


func clear_all() -> void:
	var zeros_int := PackedInt32Array()
	zeros_int.resize(cell_count)
	rd.buffer_update(buf_cells, 0, cell_count * 4, zeros_int.to_byte_array())

	var temps := PackedFloat32Array()
	temps.resize(cell_count)
	temps.fill(20.0)
	rd.buffer_update(buf_temperatures, 0, cell_count * 4, temps.to_byte_array())

	_readback()


func cleanup() -> void:
	if rd:
		rd.free_rid(pipeline_particle)
		rd.free_rid(uniform_set_particle)
		rd.free_rid(shader_particle)
		rd.free_rid(pipeline_fields)
		rd.free_rid(uniform_set_fields)
		rd.free_rid(shader_fields)
		rd.free_rid(buf_params)
		rd.free_rid(buf_cells)
		rd.free_rid(buf_boundary)
		rd.free_rid(buf_temperatures)
		rd.free_rid(buf_temps_out)
		rd.free_rid(buf_substance_table)
		rd.free()
