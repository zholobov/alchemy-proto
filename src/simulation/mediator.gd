class_name Mediator
extends RefCounted
## Cross-system interaction handler. Checks contacts between particles,
## fluids, and rigid bodies. Applies reaction rules and feeds outputs
## back into the appropriate systems.

var grid: ParticleGrid
var liquid: LiquidReadback  ## Read-only CPU snapshot of the PIC/FLIP fluid solver.
var particle_fluid_solver: ParticleFluidSolver  # for creating liquid particles on phase change
var vapor_sim: VaporSim  ## Grid MAC solver for gases — written to when reactions produce vapor.
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


func setup(p_grid: ParticleGrid, p_liquid: LiquidReadback, p_log: GameLog) -> void:
	grid = p_grid
	liquid = p_liquid
	game_log = p_log


var _occupied_cells: Array[Vector2i] = []


func update() -> void:
	reactions_this_frame = 0
	_build_occupied_list()
	_check_sparse_contacts()
	_check_rigid_body_contacts()
	_check_phase_changes_sparse()


func _build_occupied_list() -> void:
	## Scan readback data once to find all occupied cells (particles + liquid).
	_occupied_cells.clear()
	for i in range(grid.cells.size()):
		var has_particle := grid.cells[i] != 0
		var has_liquid := liquid and i < liquid.markers.size() and liquid.markers[i] != 0
		if has_particle or has_liquid:
			var x: int = i % grid.width
			var y: int = floori(float(i) / float(grid.width))
			_occupied_cells.append(Vector2i(x, y))


## Small struct passed around _check_sparse_contacts. Layer is "grid" or
## "liquid" — tells _destroy_at how to remove the substance.
## Kept as untyped Dictionary for GDScript simplicity; fields are {id, layer, x, y}.

func _substances_at(x: int, y: int) -> Array:
	## Return all substances present at a cell across grid + liquid + liquid
	## secondary (C1). Up to 3 entries per cell. Skips duplicates so a cell
	## with only one substance returns one entry.
	var result: Array = []
	if not grid.in_bounds(x, y):
		return result
	var i := grid.idx(x, y)
	var g: int = grid.cells[i]
	if g > 0:
		result.append({"id": g, "layer": "grid", "x": x, "y": y})
	if liquid and i < liquid.markers.size():
		var l: int = liquid.markers[i]
		if l > 0 and l != g:
			result.append({"id": l, "layer": "liquid", "x": x, "y": y})
		var l2: int = liquid.secondary_markers[i]
		if l2 > 0 and l2 != g and l2 != l:
			result.append({"id": l2, "layer": "liquid", "x": x, "y": y})
	return result


func _check_sparse_contacts() -> void:
	## Check reactions at occupied cells and their 4 neighbors. A cell can
	## host up to 3 substances (grid + liquid + liquid secondary), each pair
	## across the local + neighbor sets is evaluated once. Same-substance
	## pairs skip. Reactions use the layer tag to decide whether to clear a
	## grid cell or mark a liquid cell for kill.
	for pos in _occupied_cells:
		if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
			return

		var x := pos.x
		var y := pos.y
		var subs_here := _substances_at(x, y)
		if subs_here.is_empty():
			continue

		# Same-cell reactions: grid+liquid coexistence, liquid primary+secondary
		# mixing. These don't have a neighbor — both a and b are at (x, y).
		for a_i in range(subs_here.size()):
			for b_i in range(a_i + 1, subs_here.size()):
				if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
					return
				_try_react(subs_here[a_i], subs_here[b_i])

		# Neighbor reactions.
		var neighbors: Array[Vector2i] = [
			Vector2i(x + 1, y), Vector2i(x - 1, y),
			Vector2i(x, y + 1), Vector2i(x, y - 1),
		]
		for n in neighbors:
			if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
				return
			var subs_there := _substances_at(n.x, n.y)
			if subs_there.is_empty():
				continue
			for a in subs_here:
				for b in subs_there:
					if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
						return
					if a["id"] == b["id"]:
						continue
					_try_react(a, b)


func _try_react(a: Dictionary, b: Dictionary) -> void:
	## Evaluate reaction rules between two substance entries and apply
	## the result if a reaction fires. Entries are {id, layer, x, y}
	## dicts from _substances_at().
	var sub_a: SubstanceDef = SubstanceRegistry.get_substance(a["id"])
	var sub_b: SubstanceDef = SubstanceRegistry.get_substance(b["id"])
	if not sub_a or not sub_b:
		return
	var ax: int = a["x"]
	var ay: int = a["y"]
	var bx: int = b["x"]
	var by: int = b["y"]
	var temp_a: float = grid.temperatures[grid.idx(ax, ay)]
	var temp_b: float = grid.temperatures[grid.idx(bx, by)]
	var result := ReactionRules.evaluate(sub_a, sub_b, temp_a, temp_b)
	if not result.has_reaction():
		return
	_apply_layered_reaction(a, b, result, sub_a, sub_b)
	reactions_this_frame += 1


func _check_rigid_body_contacts() -> void:
	## Check if rigid bodies are in contact with reactive grid or liquid
	## substances. For each cell in a small disc around the body's center,
	## try reactions against both grid.cells[i] and liquid.markers[i].
	## On a reaction that consumes the body, dissolve it and stop scanning
	## this body. Liquids consumed alongside the body are marked for kill.
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

		# Check a radius around the body for reactive substances.
		var radius := 5
		var reacted := false
		for dy in range(-radius, radius + 1):
			if reacted:
				break
			for dx in range(-radius, radius + 1):
				if dx * dx + dy * dy > radius * radius:
					continue
				var nx: int = grid_pos.x + dx
				var ny: int = grid_pos.y + dy
				if not grid.in_bounds(nx, ny):
					continue

				var temp: float = grid.temperatures[grid.idx(nx, ny)]

				# Try grid substance vs body.
				var grid_sub_id: int = grid.cells[grid.idx(nx, ny)]
				if grid_sub_id > 0:
					var grid_sub := SubstanceRegistry.get_substance(grid_sub_id)
					if grid_sub:
						var r := ReactionRules.evaluate(grid_sub, body_sub, temp, temp)
						if r.has_reaction() and r.consumed_b:
							_dissolve_body_via(grid_sub, body, grid_pos, r, "grid", nx, ny)
							reacted = true
							break

				# Try liquid substance vs body.
				var ni := grid.idx(nx, ny)
				if liquid and ni < liquid.markers.size():
					var liq_sub_id: int = liquid.markers[ni]
					if liq_sub_id > 0:
						var liq_sub := SubstanceRegistry.get_substance(liq_sub_id)
						if liq_sub:
							var rl := ReactionRules.evaluate(liq_sub, body_sub, temp, temp)
							if rl.has_reaction() and rl.consumed_b:
								_dissolve_body_via(liq_sub, body, grid_pos, rl, "liquid", nx, ny)
								reacted = true
								break


func _dissolve_body_via(
	attacker_sub: SubstanceDef,
	body: RigidBody2D,
	body_grid_pos: Vector2i,
	result: ReactionRules.ReactionResult,
	attacker_layer: String,
	attacker_x: int,
	attacker_y: int
) -> void:
	## Common path for "substance dissolves a rigid body". Removes the body,
	## applies heat/gas side effects at the body's grid cell, and — if the
	## reaction consumed the attacker too — removes it from its sim.
	var body_sub_id: int = body.get_meta("substance_id", 0)
	var body_sub := SubstanceRegistry.get_substance(body_sub_id)
	rigid_body_mgr.dissolve_body(body)
	if result.consumed_a:
		_destroy_at(attacker_x, attacker_y, attacker_layer)
	_apply_heat(body_grid_pos.x, body_grid_pos.y, result.heat_output)
	if result.gas_produced != "":
		_spawn_gas(body_grid_pos.x, body_grid_pos.y, result.gas_produced)
	if game_log and body_sub:
		game_log.log_event(
			"%s dissolves %s!" % [attacker_sub.substance_name, body_sub.substance_name],
			Color(1.0, 0.4, 0.1)
		)
	reactions_this_frame += 1


func _check_phase_changes_sparse() -> void:
	## Check phase changes for all occupied cells in both grid and liquid
	## layers. Each cell may transition based on its temperature — water
	## boils into steam above 100C, ice melts into water above 0C, etc.
	## The source substance is destroyed from its home sim and the target
	## is spawned in the sim appropriate for its phase.
	for pos in _occupied_cells:
		var x := pos.x
		var y := pos.y
		var i := grid.idx(x, y)
		var temp: float = grid.temperatures[i]

		# Grid substance phase check.
		var grid_id: int = grid.cells[i]
		if grid_id > 0:
			var gs := SubstanceRegistry.get_substance(grid_id)
			if gs:
				_apply_phase_change_if_any(gs, temp, x, y, "grid")

		# Liquid substance phase check (C1: also covers secondary mixed cells).
		if liquid and i < liquid.markers.size():
			var liq_id: int = liquid.markers[i]
			if liq_id > 0:
				var ls := SubstanceRegistry.get_substance(liq_id)
				if ls:
					_apply_phase_change_if_any(ls, temp, x, y, "liquid")


func _apply_phase_change_if_any(
	source: SubstanceDef, temperature: float, x: int, y: int, source_layer: String
) -> void:
	## Evaluate and apply a phase change on a single cell. Splits the
	## change into destroy-source + spawn-target, using the layer tag for
	## destruction and the target substance's phase to decide where to
	## spawn it (particle fluid for LIQUID, vapor sim for GAS, grid for
	## POWDER/SOLID).
	var change := ReactionRules.check_phase_change(source, temperature)
	if change.is_empty():
		return
	var new_id := SubstanceRegistry.get_id(change["target_substance"])
	if new_id <= 0:
		return
	var new_sub := SubstanceRegistry.get_substance(new_id)
	if not new_sub:
		return

	_destroy_at(x, y, source_layer)
	_spawn_reaction_product(new_sub, new_id, x, y)

	if game_log:
		game_log.log_event(
			"%s -> %s (phase change)" % [source.substance_name, change["target_substance"]],
			Color(0.5, 0.8, 1.0)
		)


func _destroy_at(x: int, y: int, layer: String) -> void:
	## Remove a substance from its home sim, respecting the layer tag.
	## Grid substances get cleared directly on the CPU array; liquid cells
	## are marked for GPU kill on the next fluid_solver.step().
	if layer == "grid":
		grid.clear_cell(x, y)
	elif layer == "liquid" and particle_fluid_solver:
		particle_fluid_solver.mark_cell_for_kill(x, y)


func _spawn_reaction_product(sub: SubstanceDef, id: int, x: int, y: int) -> void:
	## Spawn the reaction's output substance in the appropriate sim based
	## on its phase: liquids go to the PIC/FLIP particle solver, gases to
	## the vapor sim, everything else (powder/solid) lands in the grid.
	match sub.phase:
		SubstanceDef.Phase.LIQUID:
			if particle_fluid_solver:
				var positions: Array[Vector2] = []
				for j in range(8):
					var jx := randf() * 0.8 + 0.1
					var jy := randf() * 0.8 + 0.1
					positions.append(Vector2(float(x) + jx, float(y) + jy))
				particle_fluid_solver.spawn_particles_batch(positions, id)
		SubstanceDef.Phase.GAS:
			if vapor_sim:
				vapor_sim.spawn(x, y, id)
		_:
			grid.spawn_particle(x, y, id)


func _apply_layered_reaction(
	a: Dictionary, b: Dictionary,
	result: ReactionRules.ReactionResult,
	sub_a: SubstanceDef, sub_b: SubstanceDef
) -> void:
	## Apply a reaction result when a and b are layer-tagged entries. Uses
	## _destroy_at / _spawn_reaction_product so the correct backing sim is
	## touched for each substance. Field outputs, log, and heat are applied
	## at the A side (arbitrary but consistent — reactions write to A's cell).
	var ax: int = a["x"]
	var ay: int = a["y"]
	var bx: int = b["x"]
	var by: int = b["y"]

	if result.consumed_a:
		_destroy_at(ax, ay, a["layer"])
	if result.consumed_b:
		_destroy_at(bx, by, b["layer"])

	if result.spawn_substance != "":
		var new_id := SubstanceRegistry.get_id(result.spawn_substance)
		if new_id > 0:
			var new_sub := SubstanceRegistry.get_substance(new_id)
			if new_sub:
				if result.consumed_a:
					_spawn_reaction_product(new_sub, new_id, ax, ay)
				elif result.consumed_b:
					_spawn_reaction_product(new_sub, new_id, bx, by)

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
	## Emit gas from a reaction site into VaporSim. Tries cells above the
	## reaction point first so the gas visibly emerges upward; falls back
	## to the reaction cell itself if all three cells above are occupied.
	var gas_id := SubstanceRegistry.get_id(gas_name)
	if gas_id <= 0 or not vapor_sim:
		return
	for dy in range(-3, 0):
		var ny := y + dy
		if vapor_sim.spawn(x, ny, gas_id):
			return
	# All three cells above are occupied or walls — fall back to spawning
	# at the reaction site itself if possible.
	vapor_sim.spawn(x, y, gas_id)


