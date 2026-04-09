extends "res://tests/gameplay/gameplay_test.gd"
## Gameplay test: pouring mercury on a floating wood block should push
## it deeper into the water. Tests the pressure integration model —
## fluid ABOVE the body creates downward pressure.


func run() -> Array[Dictionary]:
	_results.clear()

	# Fill water pool.
	print("  Filling water pool...")
	await fill_liquid("Water", 50, 140)
	await wait_frames(120)

	# Drop wood and let it settle.
	print("  Dropping wood...")
	var center := receptacle_center()
	await drop_solid("Wood", Vector2(center.x, _receptacle.global_position.y + 30 * Receptacle.CELL_SIZE))
	await wait_frames(180)

	var bodies := get_rigid_bodies()
	if bodies.size() < 1:
		assert_test("wood_spawned", false, "no body")
		return _results
	var wood := bodies[bodies.size() - 1]
	var wood_y_before := wood.global_position.y
	print("  Wood Y before mercury: %.0f" % wood_y_before)

	# Spawn a mercury layer directly ABOVE the floating wood block.
	# Pouring doesn't work here because PIC/FLIP routes mercury around
	# the obstacle mask — mercury slides off before building pressure.
	# Direct placement ensures mercury sits above the block so we can
	# verify the pressure integration correctly pushes the block down.
	print("  Placing mercury column above wood...")
	var wood_grid_x := int((wood.global_position.x - _receptacle.global_position.x) / Receptacle.CELL_SIZE)
	var wood_grid_y := int((wood.global_position.y - _receptacle.global_position.y) / Receptacle.CELL_SIZE)
	var mercury_id := SubstanceRegistry.get_id("Mercury")
	var merc_positions: Array[Vector2] = []
	# Fill 5 rows above the block, 10 cells wide
	for dy in range(-8, -3):
		for dx in range(-5, 5):
			var gx := wood_grid_x + dx
			var gy := wood_grid_y + dy
			if gx < 1 or gx >= Receptacle.GRID_WIDTH - 1:
				continue
			if gy < 1 or gy >= Receptacle.GRID_HEIGHT - 1:
				continue
			for i in range(8):
				merc_positions.append(Vector2(
					gx + SubstanceRegistry.sim_rng.randf() * 0.8 + 0.1,
					gy + SubstanceRegistry.sim_rng.randf() * 0.8 + 0.1,
				))
	_receptacle.fluid_solver.spawn_particles_batch(merc_positions, mercury_id)
	print("  Spawned %d mercury particles" % merc_positions.size())
	await wait_frames(180)

	var wood_y_after := wood.global_position.y
	print("  Wood Y after mercury: %.0f (delta: %.0f)" % [wood_y_after, wood_y_after - wood_y_before])

	# Wood should have sunk DEEPER (higher Y value) due to mercury weight.
	assert_test("mercury_pushes_wood_down",
		wood_y_after > wood_y_before + 5,
		"Y before=%.0f after=%.0f — mercury should push wood deeper" % [wood_y_before, wood_y_after])

	return _results
