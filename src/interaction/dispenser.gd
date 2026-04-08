class_name Dispenser
extends Node2D
## Precision dispenser for fine particle streams.

var substance_id: int = 0
var flow_rate: float = 1.0
var is_active: bool = false

var _emit_timer: float = 0.0
var _grid: ParticleGrid
var _fluid: FluidSim
var _gpu_sim: GpuSimulation
var _fluid_solver: ParticleFluidSolver
var _receptacle_pos: Vector2
var _cell_size: int

var _cursor_indicator: ColorRect


func setup(grid: ParticleGrid, fluid: FluidSim, receptacle_pos: Vector2, cell_size: int, gpu_sim: GpuSimulation = null, fluid_solver: ParticleFluidSolver = null) -> void:
	_grid = grid
	_fluid = fluid
	_gpu_sim = gpu_sim
	_fluid_solver = fluid_solver
	_receptacle_pos = receptacle_pos
	_cell_size = cell_size

	_cursor_indicator = ColorRect.new()
	_cursor_indicator.size = Vector2(8, 8)
	_cursor_indicator.color = Color(1, 1, 1, 0.5)
	_cursor_indicator.visible = false
	add_child(_cursor_indicator)


func activate(p_substance_id: int) -> void:
	substance_id = p_substance_id
	is_active = true
	_cursor_indicator.visible = true
	var sub := SubstanceRegistry.get_substance(substance_id)
	if sub:
		_cursor_indicator.color = sub.base_color
		_cursor_indicator.color.a = 0.7


func deactivate() -> void:
	is_active = false
	substance_id = 0
	_cursor_indicator.visible = false


func _process(delta: float) -> void:
	if not is_active:
		return

	var mouse_pos := get_global_mouse_position()
	_cursor_indicator.global_position = mouse_pos - _cursor_indicator.size / 2

	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_emit_timer -= delta
		if _emit_timer <= 0.0:
			_emit_timer = 0.02 / flow_rate
			_emit_particle(mouse_pos)


func _emit_particle(screen_pos: Vector2) -> void:
	var local := screen_pos - _receptacle_pos
	var gx: int = floori(local.x / float(_cell_size))
	var gy: int = floori(local.y / float(_cell_size))

	var sub := SubstanceRegistry.get_substance(substance_id)
	if not sub:
		return

	var pos := Vector2i(gx, gy)
	if sub.phase == SubstanceDef.Phase.LIQUID and _fluid_solver:
		# Liquids spawn into the PIC/FLIP particle solver. Spawn 4 jittered
		# particles for the single dispenser cell to build up density over
		# multiple frames of continuous dispensing.
		var particle_positions: Array[Vector2] = []
		for i in range(4):
			particle_positions.append(Vector2(float(gx) + randf(), float(gy) + randf()))
		_fluid_solver.spawn_particles_batch(particle_positions, substance_id)
	elif _gpu_sim:
		_gpu_sim.spawn_cells([pos], substance_id)
	else:
		if sub.phase == SubstanceDef.Phase.LIQUID:
			_fluid.spawn_fluid(gx, gy, substance_id)
		else:
			_grid.spawn_particle(gx, gy, substance_id)


func _input(event: InputEvent) -> void:
	if not is_active:
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			flow_rate = clampf(flow_rate + 0.2, 0.1, 3.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			flow_rate = clampf(flow_rate - 0.2, 0.1, 3.0)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			deactivate()
