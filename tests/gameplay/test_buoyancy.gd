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

	# ---- Step 2: Drop wood with per-frame tracking ----
	print("  Dropping wood...")
	var wood_drop_pos := Vector2(center.x - 40, _receptacle.global_position.y + 30 * Receptacle.CELL_SIZE)
	await drop_solid("Wood", wood_drop_pos)

	var bodies := get_rigid_bodies()
	if bodies.size() < 1:
		assert_test("wood_spawned", false, "no rigid body found after drop")
		return _results
	var wood := bodies[bodies.size() - 1]

	# Track wood position every frame to detect oscillation.
	var y_history: Array[float] = []
	var vel_history: Array[float] = []
	var force_history: Array[float] = []
	print("  Tracking wood for 300 frames...")
	for i in range(300):
		await get_tree().process_frame
		y_history.append(wood.global_position.y)
		vel_history.append(wood.linear_velocity.y)
		force_history.append(wood.constant_force.y)

	# Print trajectory summary (every 10 frames).
	print("  Frame | Y pos | vel_y  | force_y")
	for i in range(0, y_history.size(), 10):
		print("  %5d | %5.0f | %6.1f | %7.0f" % [i, y_history[i], vel_history[i], force_history[i]])

	# Detect LARGE oscillation — small jitter from fluid interaction is
	# normal and physically realistic. We care about:
	# (a) Y-range in the final second: body should have settled
	# (b) no sign changes where velocity is large on both sides (big swings)
	var last_60_min := INF
	var last_60_max := -INF
	for i in range(maxi(0, y_history.size() - 60), y_history.size()):
		last_60_min = minf(last_60_min, y_history[i])
		last_60_max = maxf(last_60_max, y_history[i])
	var y_range := last_60_max - last_60_min

	var big_swings := 0
	for i in range(1, vel_history.size()):
		if vel_history[i] * vel_history[i - 1] < 0:
			if absf(vel_history[i]) > 30.0 and absf(vel_history[i - 1]) > 30.0:
				big_swings += 1

	print("  Final 60-frame Y range: %.0f px, big velocity swings: %d" % [y_range, big_swings])
	assert_test("wood_settled",
		y_range < 60.0,
		"Y range in final second: %.0f px — expected < 60 (body still swinging)" % y_range)
	assert_test("wood_no_big_swings",
		big_swings <= 2,
		"%d big velocity reversals (|v|>30 on both sides) — body is bouncing" % big_swings)

	# Final position checks.
	var wood_y := wood.global_position.y
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
	# Tolerance 100px — with MAX_SUBSTEPS=3, sim time is slower than
	# real time at low FPS, so iron takes longer to reach the floor.
	var iron_sank := iron_y > bottom_y - 100
	assert_test("iron_sinks_to_bottom",
		iron_sank,
		"iron Y=%.0f, bottom=%.0f — expected iron near floor (within 100px)" % [iron_y, bottom_y])

	# ---- Step 4: Relative check ----
	# Wood should be above iron (wood floats, iron sinks).
	assert_test("wood_above_iron",
		wood_y < iron_y - 20,
		"wood Y=%.0f, iron Y=%.0f — expected wood significantly above iron" % [wood_y, iron_y])

	return _results
