class_name Mediator
extends RefCounted
## Cross-system interaction handler. Checks contacts between particles,
## fluids, and rigid bodies. Applies reaction rules and feeds outputs
## back into the appropriate systems.

var grid: ParticleGrid
var fluid: FluidSim
var game_log: GameLog
var rigid_body_mgr: RigidBodyMgr

## Field references for feeding reaction outputs into fields.
var temperature_field: FieldBase
var electric_field: FieldBase
var light_field: FieldBase
var sound_field: RefCounted  ## SoundField

## Track reaction count per frame for performance monitoring.
var reactions_this_frame: int = 0

const MAX_REACTIONS_PER_FRAME := 500


func setup(p_grid: ParticleGrid, p_fluid: FluidSim, p_log: GameLog) -> void:
	grid = p_grid
	fluid = p_fluid
	game_log = p_log


var _occupied_cells: Array[Vector2i] = []


func update() -> void:
	reactions_this_frame = 0
	_build_occupied_list()
	_check_sparse_contacts()
	_check_rigid_body_contacts()
	_check_phase_changes_sparse()


func _build_occupied_list() -> void:
	## Scan readback data once to find all occupied cells.
	_occupied_cells.clear()
	for i in range(grid.cells.size()):
		if grid.cells[i] != 0:
			@warning_ignore("integer_division")
			var x: int = i % grid.width
			@warning_ignore("integer_division")
			var y: int = i / grid.width
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


func _check_rigid_body_contacts() -> void:
	## Check if rigid bodies are in contact with reactive grid substances.
	if not rigid_body_mgr:
		return
	for body in rigid_body_mgr._bodies.duplicate():  # duplicate() because we may remove during iteration
		if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
			return
		var body_sub_id: int = body.get_meta("substance_id", 0)
		var body_sub := SubstanceRegistry.get_substance(body_sub_id)
		if not body_sub:
			continue

		# Get grid position of the rigid body center
		var grid_pos := rigid_body_mgr._screen_to_grid(body.global_position)

		# Check a radius around the body for reactive grid substances
		var radius := 5
		var reacted := false
		for dy in range(-radius, radius + 1):
			if reacted:
				break
			for dx in range(-radius, radius + 1):
				if dx * dx + dy * dy > radius * radius:
					continue
				var nx := grid_pos.x + dx
				var ny := grid_pos.y + dy
				var grid_sub_id := grid.get_cell(nx, ny)
				if grid_sub_id <= 0:
					continue

				var grid_sub := SubstanceRegistry.get_substance(grid_sub_id)
				if not grid_sub:
					continue

				var temp: float = grid.temperatures[grid.idx(nx, ny)] if grid.in_bounds(nx, ny) else 20.0

				# Check reaction: grid substance acting on rigid body substance
				var result := ReactionRules.evaluate(grid_sub, body_sub, temp, temp)
				if result.has_reaction() and result.consumed_b:
					# The rigid body dissolves
					rigid_body_mgr.dissolve_body(body)
					_apply_heat(grid_pos.x, grid_pos.y, result.heat_output)
					if result.gas_produced != "":
						_spawn_gas(grid_pos.x, grid_pos.y, result.gas_produced)
					if game_log:
						game_log.log_event(
							"%s dissolves %s!" % [grid_sub.substance_name, body_sub.substance_name],
							Color(1.0, 0.4, 0.1)
						)
					reacted = true
					reactions_this_frame += 1
					break


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


func _apply_reaction(ax: int, ay: int, bx: int, by: int, result: ReactionRules.ReactionResult, sub_a: SubstanceDef, sub_b: SubstanceDef) -> void:
	if result.consumed_a:
		grid.clear_cell(ax, ay)
	if result.consumed_b:
		grid.clear_cell(bx, by)

	if result.spawn_substance != "":
		var new_id := SubstanceRegistry.get_id(result.spawn_substance)
		if new_id > 0:
			if result.consumed_a:
				grid.spawn_particle(ax, ay, new_id)
			elif result.consumed_b:
				grid.spawn_particle(bx, by, new_id)

	if result.heat_output != 0.0:
		_apply_heat(ax, ay, result.heat_output)

	if result.gas_produced != "":
		_spawn_gas(ax, ay, result.gas_produced)

	# Feed light, charge, and sound outputs into fields.
	if result.light_output > 0.0 and light_field:
		light_field.add_value(ax, ay, result.light_output)

	if result.charge_output != 0.0 and electric_field:
		electric_field.add_value(ax, ay, result.charge_output)

	if result.sound_event != "" and sound_field:
		sound_field.trigger(result.sound_event, 1.0)

	if game_log and (result.consumed_a or result.consumed_b):
		game_log.log_event(
			"%s + %s -> reaction" % [sub_a.substance_name, sub_b.substance_name],
			Color(1.0, 0.6, 0.2)
		)


func _apply_reaction_particle_fluid(x: int, y: int, result: ReactionRules.ReactionResult, sub_p: SubstanceDef, sub_f: SubstanceDef) -> void:
	if result.consumed_a:
		grid.clear_cell(x, y)
	if result.consumed_b:
		fluid.clear_cell(x, y)
	if result.heat_output != 0.0:
		_apply_heat(x, y, result.heat_output)
	if result.gas_produced != "":
		_spawn_gas(x, y, result.gas_produced)
	if result.spawn_substance != "":
		var new_id := SubstanceRegistry.get_id(result.spawn_substance)
		if new_id > 0 and result.consumed_a:
			grid.spawn_particle(x, y, new_id)


func _apply_reaction_mixed(px: int, py: int, fx: int, fy: int, result: ReactionRules.ReactionResult, sub_p: SubstanceDef, sub_f: SubstanceDef) -> void:
	if result.consumed_a:
		grid.clear_cell(px, py)
	if result.consumed_b:
		fluid.clear_cell(fx, fy)
	if result.heat_output != 0.0:
		_apply_heat(px, py, result.heat_output)
	if result.gas_produced != "":
		_spawn_gas(px, py, result.gas_produced)


func _apply_heat(x: int, y: int, amount: float) -> void:
	var radius := 3
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var nx := x + dx
			var ny := y + dy
			if grid.in_bounds(nx, ny):
				var dist := sqrt(float(dx * dx + dy * dy))
				var falloff := maxf(0.0, 1.0 - dist / float(radius))
				grid.temperatures[grid.idx(nx, ny)] += amount * falloff


func _spawn_gas(x: int, y: int, gas_name: String) -> void:
	var gas_id := SubstanceRegistry.get_id(gas_name)
	if gas_id <= 0:
		return
	for dy in range(-3, 0):
		var ny := y + dy
		if grid.is_empty(x, ny):
			grid.spawn_particle(x, ny, gas_id)
			return


