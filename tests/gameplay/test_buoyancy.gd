extends "res://tests/gameplay/gameplay_test.gd"
## Gameplay test: buoyancy behavior for rigid bodies in liquid.
##
## Emulates user actions:
##   1. Pour water to fill ~half the receptacle
##   2. Drop a wood block → should float
##   3. Drop an iron ingot → should sink
##
## Verifies positions after settling to confirm buoyancy works.


func run() -> Array[Dictionary]:
	_results.clear()
	var center := receptacle_center()

	# ---- Step 1: Fill the receptacle with a deep water pool ----
	# Use direct batch spawn (fast) instead of pour (slow). Fill rows
	# 50–140 (out of 150) — a deep pool leaving ~50 rows of air above.
	print("  Filling water pool (rows 50-140)...")
	await fill_liquid("Water", 50, 140)
	await wait_frames(120)  # let water settle

	var surface_y := water_surface_y_approx()
	var bottom_y := receptacle_bottom_y()
	print("  Water surface ≈ %.0f, bottom ≈ %.0f" % [surface_y, bottom_y])

	# ---- Step 2: Drop wood ----
	print("  Dropping wood...")
	var wood_drop_pos := Vector2(center.x - 40, _receptacle.global_position.y + 30 * Receptacle.CELL_SIZE)  # well above water
	await drop_solid("Wood", wood_drop_pos)
	await wait_frames(180)  # 3 seconds to settle

	var bodies := get_rigid_bodies()
	if bodies.size() < 1:
		assert_test("wood_spawned", false, "no rigid body found after drop")
		return _results

	var wood := bodies[bodies.size() - 1]
	var wood_y := wood.global_position.y
	# Wood (density 0.65) should float: its center should be ABOVE the
	# bottom of the receptacle and NEAR the water surface (not on the floor).
	var wood_above_floor := wood_y < bottom_y - 20
	assert_test("wood_floats_above_floor",
		wood_above_floor,
		"wood Y=%.0f, bottom=%.0f — expected wood well above floor" % [wood_y, bottom_y])

	var wood_near_surface := absf(wood_y - surface_y) < 80
	assert_test("wood_near_surface",
		wood_near_surface,
		"wood Y=%.0f, surface=%.0f — expected within 80px of surface" % [wood_y, surface_y])

	# ---- Step 3: Drop iron ----
	print("  Dropping iron ingot...")
	var iron_drop_pos := Vector2(center.x + 40, _receptacle.global_position.y + 30 * Receptacle.CELL_SIZE)
	await drop_solid("Iron Ingot", iron_drop_pos)
	await wait_frames(240)  # 4 seconds — iron is heavy, sinks fast

	var iron: RigidBody2D = null
	for b in get_rigid_bodies():
		if b.get_meta("substance_name", "") == "Iron Ingot":
			iron = b
			break
	if not iron:
		assert_test("iron_spawned", false, "Iron Ingot rigid body not found")
		return _results

	var iron_y := iron.global_position.y
	# Iron (density 7.87) should sink: Y should be near the bottom.
	var iron_sank := iron_y > bottom_y - 40
	assert_test("iron_sinks_to_bottom",
		iron_sank,
		"iron Y=%.0f, bottom=%.0f — expected iron near floor" % [iron_y, bottom_y])

	# ---- Step 4: Relative check ----
	# Wood should be above iron (wood floats, iron sinks).
	assert_test("wood_above_iron",
		wood_y < iron_y - 20,
		"wood Y=%.0f, iron Y=%.0f — expected wood significantly above iron" % [wood_y, iron_y])

	return _results
