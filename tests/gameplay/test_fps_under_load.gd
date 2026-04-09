extends "res://tests/gameplay/gameplay_test.gd"
## Gameplay test: FPS must stay above MIN_FPS when the receptacle is
## half-full of water. This catches GPU sync stall regressions.

const MIN_FPS := 18.0  # fail if average FPS drops below this
const WARMUP_FRAMES := 60  # let the sim warm up before measuring
const MEASURE_FRAMES := 180  # measure over 3 seconds


func run() -> Array[Dictionary]:
	_results.clear()

	# Fill the bottom half with water — the heavy-load scenario.
	print("  Filling water (rows 50-140) for FPS test...")
	await fill_liquid("Water", 50, 140)
	await wait_frames(WARMUP_FRAMES)

	# Measure FPS over MEASURE_FRAMES.
	print("  Measuring FPS over %d frames..." % MEASURE_FRAMES)
	var frame_times: Array[float] = []
	for i in range(MEASURE_FRAMES):
		var t0 := Time.get_ticks_usec()
		await get_tree().process_frame
		var t1 := Time.get_ticks_usec()
		frame_times.append(float(t1 - t0))

	# Compute stats.
	var total_us := 0.0
	var max_us := 0.0
	for t in frame_times:
		total_us += t
		if t > max_us:
			max_us = t
	var avg_us := total_us / float(MEASURE_FRAMES)
	var avg_fps := 1000000.0 / avg_us
	var worst_fps := 1000000.0 / max_us

	print("  Average: %.1f FPS (%.1f ms/frame)" % [avg_fps, avg_us / 1000.0])
	print("  Worst:   %.1f FPS (%.1f ms/frame)" % [worst_fps, max_us / 1000.0])

	assert_test("avg_fps_above_minimum",
		avg_fps >= MIN_FPS,
		"avg %.1f FPS < minimum %.0f FPS (%.1f ms/frame)" % [avg_fps, MIN_FPS, avg_us / 1000.0])

	# Also drop a wood block to test buoyancy under load.
	print("  Dropping wood under load...")
	var center := receptacle_center()
	await drop_solid("Wood", Vector2(center.x, _receptacle.global_position.y + 30 * Receptacle.CELL_SIZE))
	await wait_frames(180)

	var bodies := get_rigid_bodies()
	if bodies.size() >= 1:
		var wood_y := bodies[bodies.size() - 1].global_position.y
		var surface_y := water_surface_y_approx()
		assert_test("wood_floats_under_load",
			absf(wood_y - surface_y) < 100,
			"wood Y=%.0f, surface=%.0f — buoyancy should work under load" % [wood_y, surface_y])

	return _results
