extends "res://tests/gameplay/gameplay_test.gd"
## Gameplay test: iron should float at the water-mercury interface.
## Mercury (13.5) at the bottom, water (1.0) on top. Iron (7.87) is
## denser than water but lighter than mercury — it should settle at
## the interface, not sink to the floor.


func run() -> Array[Dictionary]:
	_results.clear()

	# Fill mercury at the bottom, water on top.
	print("  Filling mercury (rows 100-140)...")
	await fill_liquid("Mercury", 100, 140)
	await wait_frames(60)
	print("  Filling water on top (rows 60-100)...")
	await fill_liquid("Water", 60, 100)
	await wait_frames(120)

	var bottom_y := receptacle_bottom_y()

	# Drop iron ingot from above.
	print("  Dropping iron ingot...")
	var drop_pos := Vector2(
		receptacle_center().x,
		_receptacle.global_position.y + 30 * Receptacle.CELL_SIZE,
	)
	await drop_solid("Iron Ingot", drop_pos)

	print("  Settling for 300 frames...")
	var y_history: Array[float] = []
	var bodies := get_rigid_bodies()
	if bodies.size() < 1:
		assert_test("iron_spawned", false, "no body found")
		return _results
	var iron := bodies[bodies.size() - 1]

	for i in range(300):
		await get_tree().process_frame
		y_history.append(iron.global_position.y)

	var iron_y := iron.global_position.y
	# Mercury starts at row 100 → Y ≈ receptacle.y + 100*4 = receptacle.y + 400
	var mercury_top_y := _receptacle.global_position.y + 100 * Receptacle.CELL_SIZE
	print("  Iron Y=%.0f, mercury_top=%.0f, bottom=%.0f" % [iron_y, mercury_top_y, bottom_y])

	# Iron should be near the mercury surface (row ~100), NOT at the bottom.
	assert_test("iron_not_on_floor",
		iron_y < bottom_y - 50,
		"iron Y=%.0f, bottom=%.0f — should float on mercury, not sink" % [iron_y, bottom_y])

	assert_test("iron_near_mercury_interface",
		absf(iron_y - mercury_top_y) < 80,
		"iron Y=%.0f, mercury_top=%.0f — should settle near interface" % [iron_y, mercury_top_y])

	return _results
