extends SceneTree
## Headless unit-test runner.
## Usage: godot --path . --headless --script tests/unit/run_unit_tests.gd


func _init() -> void:
	var total := 0
	var passed := 0
	var failed := 0
	var results: Array[Dictionary] = []

	# Discover and run all test_*.gd files in res://tests/unit/.
	var dir := DirAccess.open("res://tests/unit/")
	if not dir:
		print("ERROR: cannot open res://tests/unit/")
		quit(1)
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.begins_with("test_") and file_name.ends_with(".gd"):
			var path := "res://tests/unit/" + file_name
			var script := load(path)
			if script and script.has_method("run_tests"):
				var suite_results: Array = script.run_tests()
				for r in suite_results:
					results.append(r)
		file_name = dir.get_next()
	dir.list_dir_end()

	# Print results.
	print("")
	print("=== Unit Test Results ===")
	print("")
	for r in results:
		total += 1
		var status: String
		if r["pass"]:
			passed += 1
			status = "PASS"
		else:
			failed += 1
			status = "FAIL"
		print("  [%s] %s — %s" % [status, r["name"], r["msg"]])

	print("")
	print("Total: %d  Passed: %d  Failed: %d" % [total, passed, failed])
	print("")

	quit(0 if failed == 0 else 1)
