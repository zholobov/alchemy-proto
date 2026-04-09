extends "res://tests/gameplay/gameplay_test.gd"
## Gameplay test: kill the bottom half of the pool. Wood was floating
## near the top. With half the water gone, water level drops and the
## wood must fall to the new lower surface — not hang at the old level.


func run() -> Array[Dictionary]:
	_results.clear()

	# Fill water pool.
	print("  Filling water pool (rows 80-130)...")
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

	# Kill bottom half of pool (rows 110-130). The pool was rows 80-130,
	# so this removes ~40% of the water. The water level should drop and
	# the wood should sink to the new, lower surface.
	var wood_gx := int((wood.global_position.x - _receptacle.global_position.x) / Receptacle.CELL_SIZE)
	print("  Killing bottom half of pool (rows 110-140)...")
	for y in range(110, 141):
		for x in range(Receptacle.GRID_WIDTH):
			_receptacle.fluid_solver.mark_cell_for_kill(x, y)

	# Track frame by frame.
	print("  Frame | Y pos  | vel_y  | const_force_y | liquid_nearby")
	for i in range(300):
		await get_tree().process_frame
		if i % 30 == 0:
			var wood_gy := int((wood.global_position.y - _receptacle.global_position.y) / Receptacle.CELL_SIZE)
			var nearby := 0
			for dy in range(-3, 6):
				for dx in range(-5, 6):
					var nx := wood_gx + dx
					var ny := wood_gy + dy
					if nx >= 0 and nx < Receptacle.GRID_WIDTH and ny >= 0 and ny < Receptacle.GRID_HEIGHT:
						var idx := ny * Receptacle.GRID_WIDTH + nx
						if idx < _receptacle.liquid_readback.markers.size() and _receptacle.liquid_readback.markers[idx] > 0:
							nearby += 1
			print("  %5d | %6.0f | %6.1f | %9.0f    | %d" % [
				i, wood.global_position.y, wood.linear_velocity.y,
				wood.constant_force.y, nearby])

	var wood_y_after := wood.global_position.y
	print("  Wood Y after partial drain: %.0f (delta: %.0f)" % [wood_y_after, wood_y_after - wood_y_floating])

	# Wood should have dropped — the water level is lower.
	assert_test("wood_drops_with_water_level",
		wood_y_after > wood_y_floating + 20,
		"wood Y before=%.0f after=%.0f — should have dropped with the water level" % [wood_y_floating, wood_y_after])

	return _results
