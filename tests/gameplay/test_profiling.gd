extends "res://tests/gameplay/gameplay_test.gd"
## Profiling test: measures per-phase timing to identify CPU bottlenecks.
## Not a pass/fail test — just prints timing data.


func run() -> Array[Dictionary]:
	_results.clear()

	print("  Filling water for profiling...")
	await fill_liquid("Water", 50, 140)
	await wait_frames(60)

	# Measure each phase manually for 60 frames.
	print("  Profiling 60 frames under load...\n")
	var totals: Dictionary = {}
	for i in range(60):
		var t0 := Time.get_ticks_usec()
		await get_tree().process_frame
		var frame_us := Time.get_ticks_usec() - t0
		if i == 30:  # print one sample at mid-point
			print("  Sample frame %d: %.1f ms total" % [i, frame_us / 1000.0])

	# Read accumulated timings from the perf monitor labels.
	# The perf_monitor updates labels each frame, so the last values
	# are the most recent frame's timings.
	var main_node := _main
	var pm = main_node.perf_monitor
	print("\n  === Per-phase timing (last frame) ===")
	for system_name in pm._timings:
		print("  %s: timing started but check labels" % system_name)

	# Alternative: print ALL label texts.
	for key in pm._labels:
		print("  %s" % pm._labels[key].text)

	# Just pass — this test is for data collection, not assertions.
	assert_test("profiling_complete", true, "see console output above")
	return _results
