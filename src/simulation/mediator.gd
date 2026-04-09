class_name Mediator
extends RefCounted
## Cross-system interaction handler. Checks contacts between particles,
## fluids, and rigid bodies. Applies reaction rules and feeds outputs
## back into the appropriate systems.
##
## Performance-critical: three optimizations keep this under 5ms/frame:
##  1. Homogeneous skip: if only one substance exists, skip contact checks
##  2. Boundary-only scanning: only check cells at substance boundaries
##  3. Zero-allocation contacts: inline substance IDs, no Dictionary creation
##     except when a reaction actually fires (rare, <5/frame)

var grid: ParticleGrid
var liquid: LiquidReadback  ## Read-only CPU snapshot of the PIC/FLIP fluid solver.
var particle_fluid_solver: ParticleFluidSolver
var vapor_sim: VaporSim
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
const MAX_SUBSTANCES := 64  ## must match substance registry capacity


func setup(p_grid: ParticleGrid, p_liquid: LiquidReadback, p_log: GameLog) -> void:
	grid = p_grid
	liquid = p_liquid
	game_log = p_log


## Cells at substance boundaries (different neighbor). Used for contact
## checks — interior cells can't react with anything different.
var _boundary_cells: Array[Vector2i] = []
## ALL occupied cells. Used for phase change checks (temperature-driven,
## can happen in the interior of a pool).
var _occupied_cells: Array[Vector2i] = []
## Number of distinct substance IDs seen during the last build pass.
var _unique_substance_count: int = 0
## Tracks which substance IDs were seen (indexed by id, avoids Dictionary).
var _seen_substances: PackedByteArray = PackedByteArray()


func update() -> void:
	reactions_this_frame = 0
	_build_occupied_list()
	if _unique_substance_count > 1:
		_check_sparse_contacts()
	_check_rigid_body_contacts()
	_check_phase_changes_sparse()


func _build_occupied_list() -> void:
	## Scan all cells once. Build two lists:
	## - _occupied_cells: all cells with any substance (for phase changes)
	## - _boundary_cells: cells where a cardinal neighbor has a DIFFERENT
	##   substance (for reaction contact checks)
	## Also counts unique substances for the homogeneous skip.
	_occupied_cells.clear()
	_boundary_cells.clear()

	if _seen_substances.size() < MAX_SUBSTANCES:
		_seen_substances.resize(MAX_SUBSTANCES)
	_seen_substances.fill(0)
	var unique_count := 0

	var w := grid.width
	var h := grid.height
	var cells := grid.cells
	var markers: PackedInt32Array
	if liquid:
		markers = liquid.markers
	else:
		markers = PackedInt32Array()
	var markers_size := markers.size()
	var n := cells.size()

	for i in range(n):
		var g: int = cells[i]
		var l: int = markers[i] if i < markers_size else 0
		if g == 0 and l == 0:
			continue

		var x: int = i % w
		var y: int = i / w
		_occupied_cells.append(Vector2i(x, y))

		# Track unique substances
		if g > 0 and g < MAX_SUBSTANCES and _seen_substances[g] == 0:
			_seen_substances[g] = 1
			unique_count += 1
		if l > 0 and l < MAX_SUBSTANCES and _seen_substances[l] == 0:
			_seen_substances[l] = 1
			unique_count += 1

		# Boundary check: is any cardinal neighbor different from this cell?
		# Cells at grid edges are always boundaries (adjacent to empty/wall).
		var dom: int = g if g > 0 else l
		var at_boundary := (x == 0 or x == w - 1 or y == 0 or y == h - 1)
		if not at_boundary:
			# Inline 4-neighbor check — direct array access, no function calls.
			var li := i - 1
			var ri := i + 1
			var ui := i - w
			var di := i + w
			var l_dom: int = cells[li] if cells[li] > 0 else (markers[li] if li < markers_size else 0)
			var r_dom: int = cells[ri] if cells[ri] > 0 else (markers[ri] if ri < markers_size else 0)
			var u_dom: int = cells[ui] if cells[ui] > 0 else (markers[ui] if ui < markers_size else 0)
			var d_dom: int = cells[di] if cells[di] > 0 else (markers[di] if di < markers_size else 0)
			at_boundary = (l_dom != dom or r_dom != dom or u_dom != dom or d_dom != dom)

		if at_boundary:
			_boundary_cells.append(Vector2i(x, y))

	_unique_substance_count = unique_count


func _check_sparse_contacts() -> void:
	## Check reactions at boundary cells only. Inline substance ID reads —
	## zero Dictionary allocations per cell. Dicts are only created when a
	## reaction actually fires (rare, <5 per frame).
	for pos in _boundary_cells:
		if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
			return

		var x := pos.x
		var y := pos.y
		var i := grid.idx(x, y)

		# Read substance IDs directly — no allocation
		var g: int = grid.cells[i]
		var l: int = 0
		var l2: int = 0
		if liquid and i < liquid.markers.size():
			l = liquid.markers[i]
			l2 = liquid.secondary_markers[i]
		# Deduplicate
		if l == g: l = 0
		if l2 == g or l2 == l: l2 = 0

		# Same-cell pairs (up to 3 combos, no allocation)
		if g > 0 and l > 0:
			_try_react_inline(g, &"grid", l, &"liquid", x, y, x, y)
		if g > 0 and l2 > 0:
			_try_react_inline(g, &"grid", l2, &"liquid", x, y, x, y)
		if l > 0 and l2 > 0:
			_try_react_inline(l, &"liquid", l2, &"liquid", x, y, x, y)

		# Neighbor reactions — inline all 4 directions
		_check_neighbor_inline(g, l, l2, x, y, x + 1, y)
		_check_neighbor_inline(g, l, l2, x, y, x - 1, y)
		_check_neighbor_inline(g, l, l2, x, y, x, y + 1)
		_check_neighbor_inline(g, l, l2, x, y, x, y - 1)


func _check_neighbor_inline(g_here: int, l_here: int, l2_here: int,
		hx: int, hy: int, nx: int, ny: int) -> void:
	if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
		return
	if not grid.in_bounds(nx, ny):
		return
	var ni := grid.idx(nx, ny)
	var gn: int = grid.cells[ni]
	var ln: int = 0
	var ln2: int = 0
	if liquid and ni < liquid.markers.size():
		ln = liquid.markers[ni]
		ln2 = liquid.secondary_markers[ni]
	if ln == gn: ln = 0
	if ln2 == gn or ln2 == ln: ln2 = 0

	# All cross-cell pairs (skip same-substance). Inlined to avoid
	# Array allocation — just enumerate the up-to-9 combos directly.
	if g_here > 0:
		if gn > 0 and gn != g_here: _try_react_inline(g_here, &"grid", gn, &"grid", hx, hy, nx, ny)
		if ln > 0 and ln != g_here: _try_react_inline(g_here, &"grid", ln, &"liquid", hx, hy, nx, ny)
		if ln2 > 0 and ln2 != g_here: _try_react_inline(g_here, &"grid", ln2, &"liquid", hx, hy, nx, ny)
	if l_here > 0:
		if gn > 0 and gn != l_here: _try_react_inline(l_here, &"liquid", gn, &"grid", hx, hy, nx, ny)
		if ln > 0 and ln != l_here: _try_react_inline(l_here, &"liquid", ln, &"liquid", hx, hy, nx, ny)
		if ln2 > 0 and ln2 != l_here: _try_react_inline(l_here, &"liquid", ln2, &"liquid", hx, hy, nx, ny)
	if l2_here > 0:
		if gn > 0 and gn != l2_here: _try_react_inline(l2_here, &"liquid", gn, &"grid", hx, hy, nx, ny)
		if ln > 0 and ln != l2_here: _try_react_inline(l2_here, &"liquid", ln, &"liquid", hx, hy, nx, ny)
		if ln2 > 0 and ln2 != l2_here: _try_react_inline(l2_here, &"liquid", ln2, &"liquid", hx, hy, nx, ny)


func _try_react_inline(id_a: int, layer_a: StringName, id_b: int, layer_b: StringName,
		ax: int, ay: int, bx: int, by: int) -> void:
	## Evaluate reaction rules between two substance IDs. Only creates
	## Dictionary entries if a reaction actually fires (rare).
	if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
		return
	var sub_a := SubstanceRegistry.get_substance(id_a)
	var sub_b := SubstanceRegistry.get_substance(id_b)
	if not sub_a or not sub_b:
		return
	var temp_a: float = grid.temperatures[grid.idx(ax, ay)]
	var temp_b: float = grid.temperatures[grid.idx(bx, by)]
	var result := ReactionRules.evaluate(sub_a, sub_b, temp_a, temp_b)
	if not result.has_reaction():
		return
	# Only allocate Dictionaries when a reaction fires (rare, <5/frame).
	var a := {"id": id_a, "layer": layer_a, "x": ax, "y": ay}
	var b := {"id": id_b, "layer": layer_b, "x": bx, "y": by}
	_apply_layered_reaction(a, b, result, sub_a, sub_b)
	reactions_this_frame += 1


func _check_rigid_body_contacts() -> void:
	if not rigid_body_mgr:
		return
	for body in rigid_body_mgr._bodies.duplicate():
		if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
			return
		var body_sub_id: int = body.get_meta("substance_id", 0)
		var body_sub := SubstanceRegistry.get_substance(body_sub_id)
		if not body_sub:
			continue

		var grid_pos := rigid_body_mgr._screen_to_grid(body.global_position)
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

				var grid_sub_id: int = grid.cells[grid.idx(nx, ny)]
				if grid_sub_id > 0:
					var grid_sub := SubstanceRegistry.get_substance(grid_sub_id)
					if grid_sub:
						var r := ReactionRules.evaluate(grid_sub, body_sub, temp, temp)
						if r.has_reaction() and r.consumed_b:
							_dissolve_body_via(grid_sub, body, grid_pos, r, "grid", nx, ny)
							reacted = true
							break

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
	for pos in _occupied_cells:
		var x := pos.x
		var y := pos.y
		var i := grid.idx(x, y)
		var temp: float = grid.temperatures[i]

		var grid_id: int = grid.cells[i]
		if grid_id > 0:
			var gs := SubstanceRegistry.get_substance(grid_id)
			if gs:
				_apply_phase_change_if_any(gs, temp, x, y, "grid")

		if liquid and i < liquid.markers.size():
			var liq_id: int = liquid.markers[i]
			if liq_id > 0:
				var ls := SubstanceRegistry.get_substance(liq_id)
				if ls:
					_apply_phase_change_if_any(ls, temp, x, y, "liquid")


func _apply_phase_change_if_any(
	source: SubstanceDef, temperature: float, x: int, y: int, source_layer: String
) -> void:
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
	if layer == "grid":
		grid.clear_cell(x, y)
	elif layer == "liquid" and particle_fluid_solver:
		particle_fluid_solver.mark_cell_for_kill(x, y)


func _spawn_reaction_product(sub: SubstanceDef, id: int, x: int, y: int) -> void:
	match sub.phase:
		SubstanceDef.Phase.LIQUID:
			if particle_fluid_solver:
				var positions: Array[Vector2] = []
				for j in range(8):
					var jx := SubstanceRegistry.sim_rng.randf() * 0.8 + 0.1
					var jy := SubstanceRegistry.sim_rng.randf() * 0.8 + 0.1
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
	var gas_id := SubstanceRegistry.get_id(gas_name)
	if gas_id <= 0 or not vapor_sim:
		return
	for dy in range(-3, 0):
		var ny := y + dy
		if vapor_sim.spawn(x, ny, gas_id):
			return
	vapor_sim.spawn(x, y, gas_id)
