extends "res://tests/gameplay/gameplay_test.gd"
## Gameplay test: when water under a floating wood block is killed
## locally, the block must fall — not hang in the air.


func run() -> Array[Dictionary]:
	_results.clear()

	# Fill a SMALL water pool (just enough to float the block).
	# Small pool = water can't refill from the sides easily.
	print("  Filling small water pool (rows 80-130)...")
	await fill_liquid("Water", 80, 130)
	await wait_frames(120)

	print("  Dropping wood...")
	var center := receptacle_center()
	await drop_solid("Wood", Vector2(center.x, _receptacle.global_position.y + 50 * Receptacle.CELL_SIZE))
	await wait_frames(180)

	var bodies := get_rigid_bodies()
	if bodies.size() < 1:
		assert_test("wood_spawned", false, "no body")
		return _results
	var wood := bodies[bodies.size() - 1]
	var wood_y_floating := wood.global_position.y
	var bottom_y := receptacle_bottom_y()
	print("  Wood floating at Y=%.0f (bottom=%.0f)" % [wood_y_floating, bottom_y])

	assert_test("wood_initially_floats",
		wood_y_floating < bottom_y - 50,
		"wood Y=%.0f, bottom=%.0f — should be floating" % [wood_y_floating, bottom_y])

	# Kill ALL water in a single batch — drain the entire pool.
	print("  Killing ALL water particles...")
	for y in range(Receptacle.GRID_HEIGHT):
		for x in range(Receptacle.GRID_WIDTH):
			_receptacle.fluid_solver.mark_cell_for_kill(x, y)

	# Track frame by frame to see HOW FAST the block responds.
	print("  Tracking wood position for 300 frames after drain...")
	print("  Frame | Y pos  | vel_y  | const_force_y | lin_damp | has_fluid_nearby")

	_receptacle.rigid_body_mgr.debug_buoyancy = true
	var y_history: Array[float] = []
	for i in range(300):
		await get_tree().process_frame
		y_history.append(wood.global_position.y)
		if i % 20 == 0:
			# Check if liquid_readback has any markers near the block
			var wood_gx := int((wood.global_position.x - _receptacle.global_position.x) / Receptacle.CELL_SIZE)
			var wood_gy := int((wood.global_position.y - _receptacle.global_position.y) / Receptacle.CELL_SIZE)
			var nearby_liquid := 0
			for dy in range(-5, 10):
				for dx in range(-10, 11):
					var nx := wood_gx + dx
					var ny := wood_gy + dy
					if nx >= 0 and nx < Receptacle.GRID_WIDTH and ny >= 0 and ny < Receptacle.GRID_HEIGHT:
						var idx := ny * Receptacle.GRID_WIDTH + nx
						if idx < _receptacle.liquid_readback.markers.size() and _receptacle.liquid_readback.markers[idx] > 0:
							nearby_liquid += 1
			print("  %5d | %6.0f | %6.1f | %9.0f    | %5.1f | liquid_nearby=%d" % [
				i, wood.global_position.y, wood.linear_velocity.y,
				wood.constant_force.y, wood.linear_damp, nearby_liquid])

	_receptacle.rigid_body_mgr.debug_buoyancy = false

	var wood_y_after := wood.global_position.y
	print("  Wood Y after drain: %.0f (delta: %.0f)" % [wood_y_after, wood_y_after - wood_y_floating])

	assert_test("wood_falls_after_drain",
		wood_y_after > wood_y_floating + 100,
		"wood Y before=%.0f after=%.0f — should have fallen significantly" % [wood_y_floating, wood_y_after])

	return _results
