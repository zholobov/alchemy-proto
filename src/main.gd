extends Node2D
## Main scene. Wires together simulation, rendering, and debug overlay.

var receptacle: Receptacle
var perf_monitor: PerfMonitor
var game_log: GameLog
var mediator: Mediator
var temperature_field: TemperatureField
var pressure_field: PressureField
var electric_field: ElectricField
var light_field: LightField
var magnetic_field: MagneticField
var sound_field: SoundField
var field_renderer: FieldRenderer
var renderer_manager: RendererManager

var shelf: Shelf
var drag_drop: DragDrop
var dispenser: Dispenser

var _selected_substance_id: int = 1
var _selected_substance_name: String = ""

const SPAWN_RADIUS := 3


func _ready() -> void:
	# Background color.
	RenderingServer.set_default_clear_color(Color(0.08, 0.06, 0.1))

	# Create receptacle (centered on screen).
	receptacle = Receptacle.new()
	add_child(receptacle)
	var screen_size := get_viewport_rect().size
	var rec_size := receptacle.get_screen_size()
	receptacle.position = Vector2(
		(screen_size.x - rec_size.x) / 2,
		(screen_size.y - rec_size.y + 80) / 2
	)

	# Create renderer manager.
	renderer_manager = RendererManager.new()
	renderer_manager.setup(receptacle, receptacle.grid, Receptacle.CELL_SIZE, receptacle.liquid_readback, receptacle.vapor_sim)
	add_child(renderer_manager)

	# Debug overlay on a CanvasLayer so it's always on top.
	var debug_layer := CanvasLayer.new()
	debug_layer.layer = 100
	add_child(debug_layer)

	var fps := FPSOverlay.new()
	fps.renderer_manager = renderer_manager
	debug_layer.add_child(fps)

	perf_monitor = PerfMonitor.new()
	debug_layer.add_child(perf_monitor)

	game_log = GameLog.new()
	game_log.anchor_right = 1.0
	game_log.position = Vector2(screen_size.x - 420, screen_size.y - 270)
	debug_layer.add_child(game_log)

	receptacle.setup_rigid_bodies()

	# Create shelf.
	var shelf_layer := CanvasLayer.new()
	shelf_layer.layer = 50
	add_child(shelf_layer)

	shelf = Shelf.new()
	shelf.anchor_right = 1.0
	shelf_layer.add_child(shelf)
	shelf.substance_picked.connect(_on_substance_picked)
	shelf.reset_requested.connect(_clear_receptacle)

	# Create drag-drop handler.
	drag_drop = DragDrop.new()
	add_child(drag_drop)
	drag_drop.dropped.connect(_on_substance_dropped)
	drag_drop.pouring.connect(_on_substance_pouring)

	# Create dispenser.
	dispenser = Dispenser.new()
	dispenser.setup(receptacle.grid, receptacle.global_position, Receptacle.CELL_SIZE, receptacle.gpu_sim, receptacle.fluid_solver)
	add_child(dispenser)

	# Create mediator.
	mediator = Mediator.new()
	mediator.setup(receptacle.grid, receptacle.liquid_readback, game_log)
	mediator.rigid_body_mgr = receptacle.rigid_body_mgr
	mediator.particle_fluid_solver = receptacle.fluid_solver
	mediator.vapor_sim = receptacle.vapor_sim

	# Create fields — all share the same boundary.
	var gw := Receptacle.GRID_WIDTH
	var gh := Receptacle.GRID_HEIGHT
	var bound := receptacle.grid.boundary

	temperature_field = TemperatureField.new(gw, gh)
	temperature_field.boundary = bound

	pressure_field = PressureField.new(gw, gh)
	pressure_field.boundary = bound
	pressure_field.calculate_volume()
	pressure_field.containment_failure.connect(_on_containment_failure)

	electric_field = ElectricField.new(gw, gh)
	electric_field.boundary = bound

	light_field = LightField.new(gw, gh)
	light_field.boundary = bound

	magnetic_field = MagneticField.new(gw, gh)
	magnetic_field.boundary = bound

	sound_field = SoundField.new()
	sound_field.setup(self)

	# Wire field references into mediator for reaction outputs.
	mediator.temperature_field = temperature_field
	mediator.electric_field = electric_field
	mediator.light_field = light_field
	mediator.sound_field = sound_field

	# Create field renderer.
	field_renderer = FieldRenderer.new()
	field_renderer.setup(
		receptacle.grid, Receptacle.CELL_SIZE,
		temperature_field, light_field, electric_field, pressure_field
	)
	receptacle.add_child(field_renderer)

	game_log.log_event("Alchemy Prototype started", Color.CYAN)
	game_log.log_event("Click to spawn particles. Keys 1-9 to select substance.", Color.GREEN)
	game_log.log_event("F2 = toggle log, F3 = toggle perf, F4 = perf file logging", Color.GREEN)


func _input(event: InputEvent) -> void:
	# Number keys 1-9 to select substance.
	if event is InputEventKey and event.pressed:
		var key: int = event.keycode
		if key >= KEY_1 and key <= KEY_9:
			var index: int = key - KEY_1 + 1
			if index <= SubstanceRegistry.get_count():
				_selected_substance_id = index
				var substance := SubstanceRegistry.get_substance(index)
				game_log.log_event("Selected: %s" % substance.substance_name, substance.base_color)
		elif key == KEY_F4:
			perf_monitor._log_enabled = not perf_monitor._log_enabled
			perf_monitor.set_file_logging(perf_monitor._log_enabled)
		elif key == KEY_R:
			# Reset / clear receptacle.
			_clear_receptacle()
		elif key == KEY_D:
			if dispenser.is_active:
				dispenser.deactivate()
			else:
				dispenser.activate(_selected_substance_id)
		elif key == KEY_F5:
			renderer_manager.cycle_renderer()
			game_log.log_event("Renderer: %s" % renderer_manager.get_current_name(), Color.CYAN)
		elif key == KEY_F:
			# Flood fill for stress testing.
			_flood_fill()
		elif key == KEY_F6:
			# Center blob scenario (mirrors tests/pflip_test.gd:186-199).
			_scenario_center_blob()
		elif key == KEY_F7:
			# Top stream scenario (mirrors tests/pflip_test.gd:202-212).
			_scenario_top_stream()
		elif key == KEY_F8:
			# Column scenario (mirrors tests/pflip_test.gd:215-224).
			_scenario_column()
		elif key == KEY_F9:
			# Spawn a Steam blob in the middle of the receptacle for vapor
			# sim debugging. Steam rises (gravity_multiplier < 0).
			_spawn_debug_vapor()


func _process(delta: float) -> void:
	# Poll liquid pouring BEFORE stepping the fluid solver so newly-spawned
	# particles participate in this frame's simulation (matches the test
	# scene's spawn-then-step ordering inside a single _process call).
	# drag_drop's signal path is still used for POWDER.
	if drag_drop.is_dragging and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var active_sub := SubstanceRegistry.get_substance(drag_drop.active_substance_id)
		if active_sub and active_sub.phase == SubstanceDef.Phase.LIQUID:
			_on_substance_pouring(drag_drop.active_substance_id, drag_drop.get_global_mouse_position())

	# --- Simulation (spec order: rigid bodies, fluid, particles) ---
	perf_monitor.begin_timing("GPU Sim")
	receptacle.gpu_sim.step(delta)
	perf_monitor.end_timing("GPU Sim")

	# --- Rigid-body obstacle mask (blocks liquid flow) ---
	var obstacle_mask := receptacle.rigid_body_mgr.compute_obstacle_mask(
		Receptacle.GRID_WIDTH,
		Receptacle.GRID_HEIGHT,
		float(Receptacle.CELL_SIZE),
	)
	receptacle.fluid_solver.upload_obstacle_mask(obstacle_mask)

	# --- GPU MAC Fluid (incompressible liquid simulation) ---
	perf_monitor.begin_timing("Fluid Solver")
	receptacle.fluid_solver.step(delta)
	perf_monitor.end_timing("Fluid Solver")

	# --- CPU Vapor grid (fog, mist, steam) ---
	perf_monitor.begin_timing("Vapor Sim")
	receptacle.vapor_sim.update(delta)
	perf_monitor.end_timing("Vapor Sim")

	# Sync all GPU state (particles + fluid) back to CPU for mediator/rendering.
	receptacle.sync_from_gpu()

	# Compute the shared ambient density field and push it to both solvers.
	# Used on the NEXT frame's step() for per-cell Archimedes buoyancy
	# (inter-liquid, inter-gas, and gas-liquid cross-phase). 1-frame lag
	# is acceptable for visual fluid behavior.
	receptacle.compute_ambient_density()
	receptacle.fluid_solver.upload_ambient_density(receptacle.ambient_density)
	receptacle.vapor_sim.upload_ambient_density(receptacle.ambient_density)

	# Upload temperatures for thermal buoyancy (convection). Same 1-frame lag.
	receptacle.fluid_solver.upload_temperatures(receptacle.grid.temperatures)
	receptacle.vapor_sim.upload_temperatures(receptacle.grid.temperatures)

	# --- CPU Mediator (sparse reactions only, fields run on GPU) ---
	perf_monitor.begin_timing("Mediator")
	var has_substances := receptacle.grid.count_particles() > 0 or receptacle.liquid_readback.count_occupied_cells() > 0
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
	renderer_manager.render()
	field_renderer.update_visuals()
	perf_monitor.end_timing("Render")

	perf_monitor.update_particle_count(
		receptacle.grid.count_particles() + receptacle.liquid_readback.count_occupied_cells()
	)



func _on_substance_picked(substance_id: int, phase: SubstanceDef.Phase) -> void:
	if substance_id == -1:
		# Toggle dispenser with last selected substance.
		if dispenser.is_active:
			dispenser.deactivate()
		else:
			dispenser.activate(_selected_substance_id)
			game_log.log_event("Dispenser activated", Color.CYAN)
		return

	_selected_substance_id = substance_id
	dispenser.deactivate()
	drag_drop.start_drag(substance_id, phase)
	var substance := SubstanceRegistry.get_substance(substance_id)
	if substance:
		_selected_substance_name = substance.substance_name
		game_log.log_event("Picked up: %s" % substance.substance_name, substance.base_color)


func _on_substance_dropped(substance_id: int, phase: SubstanceDef.Phase, pos: Vector2) -> void:
	if phase == SubstanceDef.Phase.SOLID:
		receptacle.rigid_body_mgr.spawn_object(substance_id, pos)


func _on_substance_pouring(substance_id: int, pos: Vector2) -> void:
	var substance := SubstanceRegistry.get_substance(substance_id)
	if not substance:
		return

	if substance.phase == SubstanceDef.Phase.LIQUID:
		# Liquids spawn into the PIC/FLIP particle fluid solver. Mirrors the
		# test scene (tests/pflip_test.gd): fractional cursor coordinates,
		# 8 jittered particles per cell in a radius-2 circle, jitter 0.1-0.9
		# to keep particles away from cell corners.
		var local := pos - receptacle.global_position
		var gx := local.x / float(Receptacle.CELL_SIZE)
		var gy := local.y / float(Receptacle.CELL_SIZE)
		if gx < 0 or gx >= Receptacle.GRID_WIDTH or gy < 0 or gy >= Receptacle.GRID_HEIGHT:
			return
		var particle_positions: Array[Vector2] = []
		var radius := 2
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if dx * dx + dy * dy > radius * radius:
					continue
				for i in range(8):
					var jx := randf() * 0.8 + 0.1
					var jy := randf() * 0.8 + 0.1
					particle_positions.append(Vector2(gx + dx + jx, gy + dy + jy))
		receptacle.fluid_solver.spawn_particles_batch(particle_positions, substance_id)
	else:
		# Powders and other phases use the integer-grid particle system.
		var grid_pos := receptacle.screen_to_grid(pos)
		var positions: Array[Vector2i] = []
		var radius := 2
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if dx * dx + dy * dy <= radius * radius:
					positions.append(Vector2i(grid_pos.x + dx, grid_pos.y + dy))
		receptacle.gpu_sim.spawn_cells(positions, substance_id)


func _clear_receptacle() -> void:
	receptacle.gpu_sim.clear_all()
	receptacle.fluid_solver.clear()
	receptacle.vapor_sim.clear_all()
	receptacle.sync_from_gpu()
	# Clear rigid bodies.
	for body in receptacle.rigid_body_mgr._bodies.duplicate():
		body.queue_free()
	receptacle.rigid_body_mgr._bodies.clear()
	# Reset fields.
	temperature_field.values.fill(20.0)
	pressure_field.reset()
	electric_field.values.fill(0.0)
	light_field.values.fill(0.0)
	light_field.light_sources.clear()
	magnetic_field.values.fill(0.0)
	game_log.log_event("Receptacle cleared — all systems reset", Color.YELLOW)


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
		# Fill every interior cell with a full density of particles (8 per cell)
		var particle_positions: Array[Vector2] = []
		for p in positions:
			for i in range(8):
				var jx := randf() * 0.8 + 0.1
				var jy := randf() * 0.8 + 0.1
				particle_positions.append(Vector2(float(p.x) + jx, float(p.y) + jy))
		receptacle.fluid_solver.spawn_particles_batch(particle_positions, _selected_substance_id)
	else:
		receptacle.gpu_sim.spawn_cells(positions, _selected_substance_id)
	game_log.log_event("Flood filled %d cells with %s" % [positions.size(), _selected_substance_name], Color.ORANGE)


func _on_containment_failure() -> void:
	game_log.log_event("CONTAINMENT FAILURE — EXPLOSION!", Color.RED)
	var grid := receptacle.grid
	for y in range(grid.height):
		for x in range(grid.width):
			if grid.get_cell(x, y) > 0:
				if randf() < 0.7:
					grid.clear_cell(x, y)
	receptacle.liquid_readback.clear()
	receptacle.vapor_sim.clear_all()
	pressure_field.reset()


# --- Test scene parity scenarios (for A/B behavior comparison) ---
# These mirror tests/pflip_test.gd:186-224 exactly so the game and test
# scene can be compared from identical initial conditions. Reset first,
# then spawn into receptacle.fluid_solver using the same loops and jitter.

func _scenario_center_blob() -> void:
	_clear_receptacle()
	var water_id := SubstanceRegistry.get_id("Water")
	if water_id <= 0:
		return
	@warning_ignore("integer_division")
	var cx: int = Receptacle.GRID_WIDTH / 2
	@warning_ignore("integer_division")
	var cy: int = Receptacle.GRID_HEIGHT / 3
	var positions: Array[Vector2] = []
	for dy in range(-6, 7):
		for dx in range(-6, 7):
			if dx * dx + dy * dy > 36:
				continue
			for ii in range(8):
				var jx := randf() * 0.8 + 0.1
				var jy := randf() * 0.8 + 0.1
				positions.append(Vector2(cx + dx + jx, cy + dy + jy))
	receptacle.fluid_solver.spawn_particles_batch(positions, water_id)
	game_log.log_event("Center blob scenario (%d particles)" % positions.size(), Color.CYAN)


func _scenario_top_stream() -> void:
	_clear_receptacle()
	var water_id := SubstanceRegistry.get_id("Water")
	if water_id <= 0:
		return
	@warning_ignore("integer_division")
	var cx: int = Receptacle.GRID_WIDTH / 2
	var cy := 5
	var positions: Array[Vector2] = []
	for dy in range(0, 8):
		for dx in range(-2, 3):
			for ii in range(8):
				var jx := randf() * 0.8 + 0.1
				var jy := randf() * 0.8 + 0.1
				positions.append(Vector2(cx + dx + jx, cy + dy + jy))
	receptacle.fluid_solver.spawn_particles_batch(positions, water_id)
	game_log.log_event("Top stream scenario (%d particles)" % positions.size(), Color.CYAN)


func _scenario_column() -> void:
	_clear_receptacle()
	var water_id := SubstanceRegistry.get_id("Water")
	if water_id <= 0:
		return
	@warning_ignore("integer_division")
	var cx: int = Receptacle.GRID_WIDTH / 2
	var positions: Array[Vector2] = []
	for y in range(5, 60):
		for dx in range(-2, 3):
			for ii in range(8):
				var jx := randf() * 0.8 + 0.1
				var jy := randf() * 0.8 + 0.1
				positions.append(Vector2(cx + dx + jx, y + jy))
	receptacle.fluid_solver.spawn_particles_batch(positions, water_id)
	game_log.log_event("Column scenario (%d particles)" % positions.size(), Color.CYAN)


func _spawn_debug_vapor() -> void:
	## F9 debug: spawn a Steam blob in the middle of the receptacle so the
	## VaporSim can be visually tested without needing a reaction.
	var steam_id := SubstanceRegistry.get_id("Steam")
	if steam_id <= 0:
		game_log.log_event("No Steam substance registered", Color.RED)
		return
	@warning_ignore("integer_division")
	var cx: int = Receptacle.GRID_WIDTH / 2
	@warning_ignore("integer_division")
	var cy: int = Receptacle.GRID_HEIGHT * 2 / 3
	var count := 0
	for dy in range(-4, 5):
		for dx in range(-4, 5):
			if dx * dx + dy * dy > 16:
				continue
			if receptacle.vapor_sim.spawn(cx + dx, cy + dy, steam_id):
				count += 1
	game_log.log_event("Debug vapor spawn: %d cells of Steam" % count, Color.CYAN)
