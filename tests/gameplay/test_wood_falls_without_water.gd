extends "res://tests/gameplay/gameplay_test.gd"
## Gameplay test: when water is drained (cleared), a floating wood
## block must fall to the floor — not hang in the air.


func run() -> Array[Dictionary]:
	_results.clear()

	# Fill water pool and drop wood.
	print("  Filling water pool...")
	await fill_liquid("Water", 50, 140)
	await wait_frames(120)

	print("  Dropping wood...")
	var center := receptacle_center()
	await drop_solid("Wood", Vector2(center.x, _receptacle.global_position.y + 30 * Receptacle.CELL_SIZE))
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

	# DRAIN: clear all liquid from the fluid solver.
	print("  Draining all water...")
	_receptacle.fluid_solver.clear()
	# Run sync so liquid_readback reflects the empty state.
	await wait_frames(60)
	_receptacle.sync_from_gpu()
	await wait_frames(180)

	var wood_y_after := wood.global_position.y
	print("  Wood Y after drain: %.0f (delta: %.0f)" % [wood_y_after, wood_y_after - wood_y_floating])

	# Wood should have fallen to near the floor (no water = no buoyancy).
	assert_test("wood_falls_after_drain",
		wood_y_after > bottom_y - 80,
		"wood Y=%.0f, bottom=%.0f — should have fallen near floor after water drained" % [wood_y_after, bottom_y])

	assert_test("wood_lower_than_before",
		wood_y_after > wood_y_floating + 30,
		"wood Y before=%.0f after=%.0f — should have dropped significantly" % [wood_y_floating, wood_y_after])

	return _results
