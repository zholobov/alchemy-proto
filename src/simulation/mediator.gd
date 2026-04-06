class_name Mediator
extends RefCounted
## Cross-system interaction handler. Checks contacts between particles,
## fluids, and rigid bodies. Applies reaction rules and feeds outputs
## back into the appropriate systems.

var grid: ParticleGrid
var fluid: FluidSim
var game_log: GameLog

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


func update() -> void:
	reactions_this_frame = 0
	_check_particle_contacts()
	_check_particle_fluid_contacts()
	_check_phase_changes()


func _check_particle_contacts() -> void:
	for y in range(grid.height):
		for x in range(grid.width):
			if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
				return

			var id_a := grid.get_cell(x, y)
			if id_a <= 0:
				continue

			var substance_a := SubstanceRegistry.get_substance(id_a)
			if not substance_a:
				continue

			var neighbors := [
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

				var temp_a := grid.temperatures[grid.idx(x, y)]
				var temp_b := grid.temperatures[grid.idx(n.x, n.y)]

				var result := ReactionRules.evaluate(substance_a, substance_b, temp_a, temp_b)
				if result.has_reaction():
					_apply_reaction(x, y, n.x, n.y, result, substance_a, substance_b)
					reactions_this_frame += 1


func _check_particle_fluid_contacts() -> void:
	for y in range(grid.height):
		for x in range(grid.width):
			if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
				return

			var particle_id := grid.get_cell(x, y)
			var fluid_id := fluid.markers[grid.idx(x, y)] if grid.in_bounds(x, y) else 0

			if particle_id > 0 and fluid_id > 0:
				var sub_p := SubstanceRegistry.get_substance(particle_id)
				var sub_f := SubstanceRegistry.get_substance(fluid_id)
				if sub_p and sub_f:
					var temp := grid.temperatures[grid.idx(x, y)]
					var result := ReactionRules.evaluate(sub_p, sub_f, temp, temp)
					if result.has_reaction():
						_apply_reaction_particle_fluid(x, y, result, sub_p, sub_f)
						reactions_this_frame += 1
						continue

			if particle_id > 0:
				var neighbors := [
					Vector2i(x + 1, y), Vector2i(x - 1, y),
					Vector2i(x, y + 1), Vector2i(x, y - 1),
				]
				for n in neighbors:
					if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
						return
					if not grid.in_bounds(n.x, n.y):
						continue
					var adj_fluid := fluid.markers[grid.idx(n.x, n.y)]
					if adj_fluid <= 0:
						continue
					var sub_p := SubstanceRegistry.get_substance(particle_id)
					var sub_f := SubstanceRegistry.get_substance(adj_fluid)
					if sub_p and sub_f:
						var temp := grid.temperatures[grid.idx(x, y)]
						var result := ReactionRules.evaluate(sub_p, sub_f, temp, temp)
						if result.has_reaction():
							_apply_reaction_mixed(x, y, n.x, n.y, result, sub_p, sub_f)
							reactions_this_frame += 1


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


func _check_phase_changes() -> void:
	## Check all particles for temperature-driven phase transitions.
	for y in range(grid.height):
		for x in range(grid.width):
			var i := grid.idx(x, y)
			var substance_id := grid.cells[i]
			if substance_id <= 0:
				continue

			var substance := SubstanceRegistry.get_substance(substance_id)
			if not substance:
				continue

			var temp := grid.temperatures[i]
			var change := ReactionRules.check_phase_change(substance, temp)
			if change.is_empty():
				continue

			var new_id := SubstanceRegistry.get_id(change["target_substance"])
			if new_id <= 0:
				continue

			var new_sub := SubstanceRegistry.get_substance(new_id)
			if not new_sub:
				continue

			# Apply the phase change.
			if new_sub.phase == SubstanceDef.Phase.LIQUID:
				# Particle becomes fluid.
				grid.clear_cell(x, y)
				fluid.spawn_fluid(x, y, new_id)
			elif new_sub.phase == SubstanceDef.Phase.GAS:
				# Particle becomes gas (stays in particle grid, gas phase).
				grid.cells[i] = new_id
			else:
				# Solid/powder transition.
				grid.cells[i] = new_id

			if game_log:
				game_log.log_event(
					"%s -> %s (phase change)" % [substance.substance_name, change["target_substance"]],
					Color(0.5, 0.8, 1.0)
				)
