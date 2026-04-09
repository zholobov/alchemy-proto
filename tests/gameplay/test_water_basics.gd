extends "res://tests/gameplay/gameplay_test.gd"
## Gameplay test: water pours, pools at bottom, and basic fluid behavior.


func run() -> Array[Dictionary]:
	_results.clear()

	# ---- Pour water and verify it pools ----
	print("  Filling water (rows 60-140)...")
	await fill_liquid("Water", 60, 140)
	await wait_frames(120)

	var surface_y := water_surface_y_approx()
	var bottom_y := receptacle_bottom_y()
	print("  Surface ≈ %.0f, bottom ≈ %.0f" % [surface_y, bottom_y])

	assert_test("water_has_surface",
		surface_y < bottom_y - 50,
		"surface=%.0f bottom=%.0f — pool should have depth" % [surface_y, bottom_y])

	# ---- Verify water doesn't leak through walls ----
	# Sample some cells outside the interior — they should have 0 density.
	var lr := _receptacle.liquid_readback
	var corner_density: float = 0.0
	for y in range(0, 5):
		for x in range(0, 5):
			corner_density += lr.densities[y * Receptacle.GRID_WIDTH + x]
	assert_test("no_leak_through_walls",
		corner_density < 0.01,
		"density in corner cells = %.3f — should be 0" % corner_density)

	# ---- Pour mercury and verify it sinks below water ----
	print("  Pouring mercury...")
	await pour_liquid("Mercury", receptacle_center(), 60)
	await wait_frames(180)

	# Mercury (density 13.5) should be at the bottom. Sample the bottom
	# rows for mercury markers.
	var mercury_id := SubstanceRegistry.get_id("Mercury")
	var mercury_at_bottom := 0
	var mercury_at_top := 0
	for x in range(30, Receptacle.GRID_WIDTH - 30):
		# Bottom 10 rows
		for y in range(Receptacle.GRID_HEIGHT - 15, Receptacle.GRID_HEIGHT - 5):
			if lr.markers[y * Receptacle.GRID_WIDTH + x] == mercury_id:
				mercury_at_bottom += 1
		# Top 10 rows of pool
		for y in range(60, 70):
			if lr.markers[y * Receptacle.GRID_WIDTH + x] == mercury_id:
				mercury_at_top += 1

	print("  Mercury cells: bottom=%d, top=%d" % [mercury_at_bottom, mercury_at_top])
	assert_test("mercury_sinks_below_water",
		mercury_at_bottom > mercury_at_top,
		"bottom=%d top=%d — mercury should be mostly at bottom" % [mercury_at_bottom, mercury_at_top])

	return _results
