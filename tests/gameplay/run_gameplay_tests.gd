extends Node
## Gameplay test runner. Run as a scene (not --script) so autoloads
## (SubstanceRegistry) are initialized by the engine.
##
## Usage:
##   godot --path . tests/gameplay/run_gameplay_tests.tscn
##
## A window appears briefly while the sim runs. Results print to
## stdout. Exits with code 0 (all pass) or 1 (any fail).

const MainScene := preload("res://src/main.tscn")

const TEST_SCRIPTS: Array[String] = [
	"res://tests/gameplay/test_rigid_body_basics.gd",
	"res://tests/gameplay/test_water_basics.gd",
	"res://tests/gameplay/test_buoyancy.gd",
	"res://tests/gameplay/test_ice_floats.gd",
]


func _ready() -> void:
	# Defer to let the scene tree finish initialization.
	await get_tree().process_frame
	await _run_all_tests()


func _run_all_tests() -> void:
	print("\n=== Gameplay Tests ===\n")

	var main := MainScene.instantiate()
	get_tree().root.add_child(main)

	# Let the game fully initialize.
	for i in range(5):
		await get_tree().process_frame

	var total := 0
	var passed := 0
	var failures: Array[String] = []

	for path in TEST_SCRIPTS:
		var script := load(path) as GDScript
		if not script:
			failures.append("%s: failed to load" % path)
			total += 1
			continue

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
