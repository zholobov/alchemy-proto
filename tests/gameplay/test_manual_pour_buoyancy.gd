extends "res://tests/gameplay/gameplay_test.gd"
## Gameplay test: replicate the EXACT manual game flow.
## Uses pour_liquid (the game's _on_substance_pouring path) instead
## of fill_liquid (direct particle batch spawn) to match what the user
## does when they hold the mouse button.


func run() -> Array[Dictionary]:
	_results.clear()
	var center := receptacle_center()

	# ---- Step 1: Pour water using the game's pouring API ----
	# This calls main._on_substance_pouring each frame, same as holding
	# the mouse button on a liquid substance.
	print("  Pouring water via game API for 180 frames (~3 sec)...")
	await pour_liquid("Water", center, 300)  # more frames for accumulator-based sim
	print("  Letting water settle for 120 frames...")
	await wait_frames(120)

	var surface_y := water_surface_y_approx()
	var bottom_y := receptacle_bottom_y()
	print("  Surface ≈ %.0f, bottom ≈ %.0f" % [surface_y, bottom_y])

	# Check if there's actually a pool.
	assert_test("pool_formed",
		surface_y < bottom_y - 30,
		"surface=%.0f bottom=%.0f — pool too shallow" % [surface_y, bottom_y])

	# ---- Step 2: Drop wood ----
	print("  Dropping wood...")
	var drop_pos := Vector2(center.x, _receptacle.global_position.y + 30 * Receptacle.CELL_SIZE)
	await drop_solid("Wood", drop_pos)

	# Track for 300 frames.
	var bodies := get_rigid_bodies()
	if bodies.size() < 1:
		assert_test("wood_spawned", false, "no body")
		return _results
	var wood := bodies[bodies.size() - 1]

	# Enable debug logging to see what's happening.
	_receptacle.rigid_body_mgr.debug_buoyancy = true

	print("  Tracking wood for 300 frames...")
	var y_history: Array[float] = []
	for i in range(300):
		await get_tree().process_frame
		y_history.append(wood.global_position.y)

	# Print trajectory summary.
	print("  Frame | Y pos | vel_y  | const_force_y | lin_damp")
	for i in range(0, y_history.size(), 30):
		print("  %5d | %5.0f | %6.1f | %9.0f    | %.1f" % [
			i, y_history[i], wood.linear_velocity.y,
			wood.constant_force.y, wood.linear_damp])

	var wood_y := wood.global_position.y

	assert_test("wood_floats",
		wood_y < bottom_y - 20,
		"wood Y=%.0f, bottom=%.0f — should be above floor" % [wood_y, bottom_y])

	assert_test("wood_near_surface",
		absf(wood_y - surface_y) < 100,
		"wood Y=%.0f, surface=%.0f" % [wood_y, surface_y])

	_receptacle.rigid_body_mgr.debug_buoyancy = false
	return _results
