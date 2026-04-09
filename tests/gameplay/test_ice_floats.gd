extends "res://tests/gameplay/gameplay_test.gd"
## Gameplay test: ice (density 0.92) should float with ~8% above surface.
## Tighter tolerance than wood (0.65) because ice is barely buoyant —
## sensitive to MASS_SCALE tuning.


func run() -> Array[Dictionary]:
	_results.clear()

	# Fill a deep pool.
	print("  Filling water pool...")
	await fill_liquid("Water", 50, 140)
	await wait_frames(120)

	var surface_y := water_surface_y_approx()
	print("  Surface ≈ %.0f" % surface_y)

	# Drop ice above the pool.
	print("  Dropping ice...")
	var drop_pos := Vector2(
		receptacle_center().x,
		_receptacle.global_position.y + 30 * Receptacle.CELL_SIZE,
	)
	await drop_solid("Ice", drop_pos)

	# Track settling.
	var bodies := get_rigid_bodies()
	if bodies.size() < 1:
		assert_test("ice_spawned", false, "no body found")
		return _results
	var ice := bodies[bodies.size() - 1]

	print("  Settling ice for 300 frames...")
	var y_history: Array[float] = []
	for i in range(300):
		await get_tree().process_frame
		y_history.append(ice.global_position.y)

	var ice_y := ice.global_position.y

	# Ice center should be near the surface (within 50px).
	# density 0.92 → 92% submerged → center is slightly below surface.
	assert_test("ice_near_surface",
		absf(ice_y - surface_y) < 50,
		"ice Y=%.0f, surface=%.0f — expected within 50px" % [ice_y, surface_y])

	# Ice should be above the floor.
	assert_test("ice_not_on_floor",
		ice_y < receptacle_bottom_y() - 30,
		"ice Y=%.0f, bottom=%.0f — expected above floor" % [ice_y, receptacle_bottom_y()])

	# Final stability: Y range in last 60 frames should be small.
	var last_60_min := INF
	var last_60_max := -INF
	for i in range(maxi(0, y_history.size() - 60), y_history.size()):
		last_60_min = minf(last_60_min, y_history[i])
		last_60_max = maxf(last_60_max, y_history[i])
	var y_range := last_60_max - last_60_min
	assert_test("ice_stable",
		y_range < 60,
		"Y range = %.0f in last 60 frames — expected < 60" % y_range)

	return _results
