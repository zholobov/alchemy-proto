extends "res://tests/gameplay/gameplay_test.gd"
## Gameplay test: when water under a floating wood block is killed
## locally (a big chunk removed, not the whole pool), the block must
## fall — not hang in the air.


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

	# Kill a big chunk of water around and below the wood block.
	# Use mark_cell_for_kill on a wide area under the block.
	var wood_gx := int((wood.global_position.x - _receptacle.global_position.x) / Receptacle.CELL_SIZE)
	var wood_gy := int((wood.global_position.y - _receptacle.global_position.y) / Receptacle.CELL_SIZE)
	print("  Killing water in 30×30 area around wood (grid %d,%d)..." % [wood_gx, wood_gy])
	var killed := 0
	for dy in range(-5, 25):
		for dx in range(-15, 16):
			var kx := wood_gx + dx
			var ky := wood_gy + dy
			if kx >= 0 and kx < Receptacle.GRID_WIDTH and ky >= 0 and ky < Receptacle.GRID_HEIGHT:
				_receptacle.fluid_solver.mark_cell_for_kill(kx, ky)
				killed += 1
	print("  Marked %d cells for kill" % killed)

	# Keep killing for many frames — the incompressible solver refills
	# voids within one step, so a single kill batch gets undone immediately.
	# Continuous killing simulates water draining away persistently.
	for frame in range(120):
		for dy in range(-5, 25):
			for dx in range(-15, 16):
				var kx := wood_gx + dx
				var ky := wood_gy + dy
				if kx >= 0 and kx < Receptacle.GRID_WIDTH and ky >= 0 and ky < Receptacle.GRID_HEIGHT:
					_receptacle.fluid_solver.mark_cell_for_kill(kx, ky)
		await get_tree().process_frame

	# Let the body settle after killing stops.
	await wait_frames(60)

	var wood_y_after := wood.global_position.y
	print("  Wood Y after local drain: %.0f (delta: %.0f)" % [wood_y_after, wood_y_after - wood_y_floating])

	# Wood should have fallen significantly — the water under it is gone.
	assert_test("wood_drops_after_local_drain",
		wood_y_after > wood_y_floating + 20,
		"wood Y before=%.0f after=%.0f — should have dropped after water removed underneath" % [wood_y_floating, wood_y_after])

	return _results
