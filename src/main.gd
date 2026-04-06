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

var shelf: Shelf
var drag_drop: DragDrop
var dispenser: Dispenser

var _selected_substance_id: int = 1
var _selected_substance_name: String = ""

## Spawn rate when holding mouse button.
const SPAWN_RADIUS := 3
const SPAWN_INTERVAL := 0.01  ## Seconds between spawn bursts.
var _spawn_timer: float = 0.0


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
		screen_size.y - rec_size.y - 60
	)

	# Debug overlay on a CanvasLayer so it's always on top.
	var debug_layer := CanvasLayer.new()
	debug_layer.layer = 100
	add_child(debug_layer)

	var fps := FPSOverlay.new()
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
	dispenser.setup(receptacle.grid, receptacle.fluid, receptacle.global_position, Receptacle.CELL_SIZE)
	add_child(dispenser)

	# Create mediator.
	mediator = Mediator.new()
	mediator.setup(receptacle.grid, receptacle.fluid, game_log)

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
		var key := event.keycode
		if key >= KEY_1 and key <= KEY_9:
			var index := key - KEY_1 + 1
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
		elif key == KEY_F:
			# Flood fill for stress testing.
			_flood_fill()


func _process(delta: float) -> void:
	# --- Simulation (spec order: rigid bodies, fluid, particles) ---
	perf_monitor.begin_timing("Fluid Sim")
	receptacle.fluid.update(delta)
	perf_monitor.end_timing("Fluid Sim")

	perf_monitor.begin_timing("Particle Grid")
	receptacle.grid.update()
	perf_monitor.end_timing("Particle Grid")

	# --- Mediator + Fields feedback loop (up to 3 passes) ---
	perf_monitor.begin_timing("Mediator+Fields")
	for _pass in range(3):
		mediator.update()

		temperature_field.update(receptacle.grid, receptacle.fluid, delta)
		pressure_field.update(receptacle.grid, receptacle.fluid, delta)
		electric_field.update(receptacle.grid, receptacle.fluid, delta)
		light_field.update(receptacle.grid, receptacle.fluid, delta)
		magnetic_field.update(receptacle.grid, receptacle.fluid, delta)
		magnetic_field.apply_forces(receptacle.grid)

		# Break early if no reactions occurred this pass (nothing to cascade).
		if mediator.reactions_this_frame == 0:
			break
	sound_field.flush()
	perf_monitor.end_timing("Mediator+Fields")

	# --- Rendering ---
	perf_monitor.begin_timing("Render")
	receptacle.renderer.render()
	field_renderer.update_visuals()
	perf_monitor.end_timing("Render")

	perf_monitor.update_particle_count(
		receptacle.grid.count_particles() + receptacle.fluid.count_fluid_cells()
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
	var grid_pos := receptacle.screen_to_grid(pos)
	var substance := SubstanceRegistry.get_substance(substance_id)
	if not substance:
		return

	var radius := 2
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx * dx + dy * dy <= radius * radius:
				var px := grid_pos.x + dx
				var py := grid_pos.y + dy
				if substance.phase == SubstanceDef.Phase.LIQUID:
					receptacle.fluid.spawn_fluid(px, py, substance_id)
				else:
					receptacle.grid.spawn_particle(px, py, substance_id)


func _clear_receptacle() -> void:
	# Clear particle grid.
	for i in range(receptacle.grid.cells.size()):
		receptacle.grid.cells[i] = 0
		receptacle.grid.temperatures[i] = 20.0
		receptacle.grid.charges[i] = 0.0
	# Clear fluid.
	receptacle.fluid.markers.fill(0)
	receptacle.fluid.u.fill(0.0)
	receptacle.fluid.v.fill(0.0)
	receptacle.fluid.pressure.fill(0.0)
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
	var is_liquid := substance.phase == SubstanceDef.Phase.LIQUID
	var count := 0
	for i in range(receptacle.grid.cells.size()):
		if receptacle.grid.boundary[i] == 1:
			if is_liquid:
				if receptacle.fluid.markers[i] == 0 and receptacle.grid.cells[i] == 0:
					receptacle.fluid.markers[i] = _selected_substance_id
					count += 1
			else:
				if receptacle.grid.cells[i] == 0 and receptacle.fluid.markers[i] == 0:
					receptacle.grid.cells[i] = _selected_substance_id
					count += 1
	game_log.log_event("Flood filled %d cells with %s" % [count, _selected_substance_name], Color.ORANGE)


func _on_containment_failure() -> void:
	game_log.log_event("CONTAINMENT FAILURE — EXPLOSION!", Color.RED)
	var grid := receptacle.grid
	for y in range(grid.height):
		for x in range(grid.width):
			if grid.get_cell(x, y) > 0:
				if randf() < 0.7:
					grid.clear_cell(x, y)
	receptacle.fluid.markers.fill(0)
	pressure_field.reset()
