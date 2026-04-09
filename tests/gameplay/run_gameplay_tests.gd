extends Node
## Gameplay test runner. Run as a scene (not --script) so autoloads
## (SubstanceRegistry) are initialized by the engine.
##
## Usage:
##   godot --path . tests/gameplay/run_gameplay_tests.tscn          # run all
##   godot --path . tests/gameplay/run_gameplay_tests.tscn -- buoyancy  # run matching
##
## A window appears briefly while the sim runs. Results print to
## stdout. Exits with code 0 (all pass) or 1 (any fail).

const MainScene := preload("res://src/main.tscn")

const TEST_SCRIPTS: Array[String] = [
	"res://tests/gameplay/test_rigid_body_basics.gd",
	"res://tests/gameplay/test_water_basics.gd",
	"res://tests/gameplay/test_buoyancy.gd",
	"res://tests/gameplay/test_ice_floats.gd",
	"res://tests/gameplay/test_manual_pour_buoyancy.gd",
	"res://tests/gameplay/test_iron_in_mercury.gd",
	"res://tests/gameplay/test_iron_in_layered_pool.gd",
	"res://tests/gameplay/test_mercury_on_wood.gd",
	"res://tests/gameplay/test_fps_under_load.gd",
	"res://tests/gameplay/test_profiling.gd",
]


func _ready() -> void:
	# Defer to let the scene tree finish initialization.
	await get_tree().process_frame
	await _run_all_tests()


func _run_all_tests() -> void:
	print("\n=== Gameplay Tests ===\n")

	# Single scene instance — GPU resources are expensive to recreate.
	# Between tests, call _clear_receptacle() which resets all sim
	# systems, rigid bodies, and fields to a clean initial state.
	var main := MainScene.instantiate()
	get_tree().root.add_child(main)
	for i in range(5):
		await get_tree().process_frame

	var total := 0
	var passed := 0
	var failures: Array[String] = []

	# Filter: if a command-line arg is given after --, only run tests
	# whose filename contains it. E.g. "-- buoyancy" runs test_buoyancy.
	var filter := ""
	var user_args := OS.get_cmdline_user_args()
	if user_args.size() > 0:
		filter = user_args[0]
		print("Filter: '%s'\n" % filter)

	for path in TEST_SCRIPTS:
		if filter != "" and path.find(filter) == -1:
			continue

		var script := load(path) as GDScript
		if not script:
			failures.append("%s: failed to load" % path)
			total += 1
			continue

		# Reset to clean state before each test.
		main._clear_receptacle()
		for i in range(3):
			await get_tree().process_frame

		print("Running: %s" % path.get_file())
		var test_node = script.new()
		if not test_node or not test_node.has_method("run"):
			failures.append("%s: missing run() method" % path)
			total += 1
			continue

		main.add_child(test_node)
		test_node.setup(main)
		var results: Array = await test_node.run()
		test_node.queue_free()

		for r in results:
			total += 1
			if r.get("pass", false):
				passed += 1
			else:
				failures.append("%s::%s — %s" % [path.get_file(), r["name"], r.get("msg", "")])

	main.queue_free()

	print("\n=== Gameplay Tests: %d/%d passed ===" % [passed, total])
	if failures.size() > 0:
		print("Failures:")
		for f in failures:
			print("  " + f)
		get_tree().quit(1)
	else:
		get_tree().quit(0)
