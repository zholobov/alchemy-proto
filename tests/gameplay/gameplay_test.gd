extends Node
## GameplayTest — base class for gameplay tests.
## Base class for gameplay tests. Subclass and override run() to define
## a test that emulates user actions and verifies outcomes.
##
## Usage: added as a child of main scene by the runner. The game loop
## (_process) runs normally — obstacle mask, fluid solver, buoyancy,
## rendering, everything. Tests call helper methods to emulate user
## actions (pour liquid, drop solid) and wait for the sim to settle.
##
## All positions are in SCREEN coordinates (pixels from top-left of
## the viewport), matching what a user's mouse would produce.

var _main: Node2D
var _receptacle: Receptacle
var _results: Array[Dictionary] = []


func setup(main: Node2D) -> void:
	_main = main
	_receptacle = main.receptacle


func run() -> Array[Dictionary]:
	## Override in subclass. Return array of {name, pass, msg}.
	push_error("GameplayTest.run() not overridden")
	return []


# ---- Action helpers ----

func pour_liquid(substance_name: String, screen_pos: Vector2, frames: int = 120) -> void:
	## Pour a liquid substance at screen_pos for N frames using the
	## game's own pouring logic. Spawns 8 particles/cell in a radius-2
	## circle each frame, just like the real dispenser.
	var sub_id := SubstanceRegistry.get_id(substance_name)
	if sub_id <= 0:
		push_error("GameplayTest: substance '%s' not found" % substance_name)
		return
	for i in range(frames):
		_main._on_substance_pouring(sub_id, screen_pos)
		await get_tree().process_frame


func drop_solid(substance_name: String, screen_pos: Vector2) -> void:
	## Drop a SOLID substance at screen_pos. Creates a rigid body via
	## the game's own spawn_object path.
	var sub_id := SubstanceRegistry.get_id(substance_name)
	if sub_id <= 0:
		push_error("GameplayTest: substance '%s' not found" % substance_name)
		return
	_receptacle.rigid_body_mgr.spawn_object(sub_id, screen_pos)
	await get_tree().process_frame


func wait_frames(n: int) -> void:
	## Let the game loop run for N frames. All simulation systems
	## (fluid solver, buoyancy, vapor, mediator) update normally.
	for i in range(n):
		await get_tree().process_frame


func get_rigid_bodies() -> Array[RigidBody2D]:
	return _receptacle.rigid_body_mgr._bodies


func receptacle_center() -> Vector2:
	## Screen position at the horizontal center, ~40% down from the top
	## of the receptacle. A good default pour location.
	return _receptacle.global_position + Vector2(
		Receptacle.GRID_WIDTH * Receptacle.CELL_SIZE / 2.0,
		Receptacle.GRID_HEIGHT * Receptacle.CELL_SIZE * 0.4,
	)


func receptacle_bottom_y() -> float:
	## The Y position (screen px) of the bottom of the receptacle's
	## oval interior. The oval center is at 55% of grid height, radius
	## is 45%, so the bottom is at 55% + 45% = 100% of grid height.
	return _receptacle.global_position.y + Receptacle.GRID_HEIGHT * Receptacle.CELL_SIZE


func fill_liquid(substance_name: String, from_row: int, to_row: int) -> void:
	## Directly spawn a dense block of liquid particles across the given
	## grid row range. Much faster than pour_liquid for test setup.
	## Each cell gets 8 jittered particles (full density).
	var sub_id := SubstanceRegistry.get_id(substance_name)
	if sub_id <= 0:
		push_error("GameplayTest: substance '%s' not found" % substance_name)
		return
	var positions: Array[Vector2] = []
	for y in range(from_row, to_row):
		for x in range(5, Receptacle.GRID_WIDTH - 5):
			for i in range(8):
				positions.append(Vector2(
					x + SubstanceRegistry.sim_rng.randf() * 0.8 + 0.1,
					y + SubstanceRegistry.sim_rng.randf() * 0.8 + 0.1,
				))
	_receptacle.fluid_solver.spawn_particles_batch(positions, sub_id)
	await get_tree().process_frame


func water_surface_y_approx() -> float:
	## Rough Y of the water surface based on readback. Scans the center
	## column for the highest row with liquid density > 0.1.
	var cx: int = Receptacle.GRID_WIDTH / 2
	for cy in range(Receptacle.GRID_HEIGHT):
		var idx := cy * Receptacle.GRID_WIDTH + cx
		if _receptacle.liquid_readback.densities[idx] > 0.1:
			return _receptacle.global_position.y + cy * Receptacle.CELL_SIZE
	return receptacle_bottom_y()  # no water found


func assert_test(name: String, condition: bool, msg: String) -> void:
	_results.append({"name": name, "pass": condition, "msg": msg})
	if condition:
		print("  [PASS] %s" % name)
	else:
		print("  [FAIL] %s — %s" % [name, msg])
