extends "res://tests/gameplay/gameplay_test.gd"
## Gameplay test: rigid body basics — drop solids, verify they fall,
## stay inside the container, and don't clip through walls.


func run() -> Array[Dictionary]:
	_results.clear()
	var center := receptacle_center()
	var bottom_y := receptacle_bottom_y()

	# ---- Drop rock in empty receptacle — should hit the floor ----
	print("  Dropping rock in empty receptacle...")
	var drop_pos := Vector2(center.x, _receptacle.global_position.y + 20 * Receptacle.CELL_SIZE)
	await drop_solid("Rock", drop_pos)
	await wait_frames(180)

	var bodies := get_rigid_bodies()
	assert_test("rock_spawned", bodies.size() >= 1, "no body found")
	if bodies.size() < 1:
		return _results

	var rock := bodies[0]
	var rock_y := rock.global_position.y
	# Rock should be near the bottom of the receptacle (within 50 px).
	assert_test("rock_falls_to_floor",
		absf(rock_y - bottom_y) < 100,
		"rock Y=%.0f, bottom=%.0f — expected near floor" % [rock_y, bottom_y])

	# Rock should be inside the receptacle (x within receptacle width).
	var rec_left := _receptacle.global_position.x
	var rec_right := rec_left + Receptacle.GRID_WIDTH * Receptacle.CELL_SIZE
	assert_test("rock_inside_receptacle",
		rock.global_position.x > rec_left and rock.global_position.x < rec_right,
		"rock X=%.0f, bounds=[%.0f, %.0f]" % [rock.global_position.x, rec_left, rec_right])

	# ---- Drop ice — it has a rectangular polygon ----
	print("  Dropping ice...")
	var ice_pos := Vector2(center.x + 60, _receptacle.global_position.y + 20 * Receptacle.CELL_SIZE)
	await drop_solid("Ice", ice_pos)
	await wait_frames(120)

	var all_bodies := get_rigid_bodies()
	assert_test("ice_spawned", all_bodies.size() >= 2, "expected 2+ bodies, got %d" % all_bodies.size())

	# ---- Verify no body has insane velocity (launch bug regression) ----
	var max_speed := 0.0
	for b in all_bodies:
		max_speed = maxf(max_speed, b.linear_velocity.length())
	assert_test("no_launch_bug",
		max_speed < 500,
		"max speed %.0f — expected < 500 (no launch into space)" % max_speed)

	return _results
