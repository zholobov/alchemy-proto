extends "res://tests/gameplay/gameplay_test.gd"
## Gameplay test: iron ingot (density 7.87) should float on mercury
## (density 13.5). Iron is denser than water but lighter than mercury.


func run() -> Array[Dictionary]:
	_results.clear()

	# Fill with mercury instead of water.
	print("  Filling mercury pool (rows 70-140)...")
	await fill_liquid("Mercury", 70, 140)
	await wait_frames(120)

	var surface_y := water_surface_y_approx()
	var bottom_y := receptacle_bottom_y()
	print("  Mercury surface ≈ %.0f, bottom ≈ %.0f" % [surface_y, bottom_y])

	# Drop iron ingot above the mercury pool.
	print("  Dropping iron ingot...")
	var drop_pos := Vector2(
		receptacle_center().x,
		_receptacle.global_position.y + 30 * Receptacle.CELL_SIZE,
	)
	await drop_solid("Iron Ingot", drop_pos)

	# Track position.
	var bodies := get_rigid_bodies()
	if bodies.size() < 1:
		assert_test("iron_spawned", false, "no body found")
		return _results
	var iron := bodies[bodies.size() - 1]

	print("  Settling for 300 frames...")
	var y_history: Array[float] = []
	for i in range(300):
		await get_tree().process_frame
		y_history.append(iron.global_position.y)

	var iron_y := iron.global_position.y

	# Iron (7.87) in mercury (13.5) should float at ~58% submerged
	# (7.87/13.5 = 0.583). It must NOT be on the floor.
	print("  Iron Y=%.0f, surface=%.0f, bottom=%.0f" % [iron_y, surface_y, bottom_y])

	assert_test("iron_floats_on_mercury",
		iron_y < bottom_y - 30,
		"iron Y=%.0f, bottom=%.0f — should float, not sink" % [iron_y, bottom_y])

	assert_test("iron_near_mercury_surface",
		absf(iron_y - surface_y) < 100,
		"iron Y=%.0f, surface=%.0f — should be near mercury surface" % [iron_y, surface_y])

	# Stability check.
	var last_60_min := INF
	var last_60_max := -INF
	for i in range(maxi(0, y_history.size() - 60), y_history.size()):
		last_60_min = minf(last_60_min, y_history[i])
		last_60_max = maxf(last_60_max, y_history[i])
	var y_range := last_60_max - last_60_min
	assert_test("iron_stable_on_mercury",
		y_range < 60,
		"Y range = %.0f in last 60 frames" % y_range)

	return _results
