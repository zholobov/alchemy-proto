extends SceneTree
## Integration-test runner.
## Usage: godot --path . --headless --script tests/integration/run_integration_tests.gd
## Note: GPU-dependent tests will be skipped in --headless mode since there is
## no rendering device. Remove --headless to run the full suite with GPU.
##
## Each test script must expose:
##   static func run_test(tree: SceneTree) -> Dictionary
## where the returned Dictionary has keys: name, pass, msg.
## Tests may use `await` internally (the runner awaits each one).

const TEST_SCRIPTS: Array[String] = [
	"res://tests/integration/test_rb_obstacle_mask.gd",
]


var _started := false


func _init() -> void:
	# Defer to _process so the scene tree is fully initialised and autoloads
	# (SubstanceRegistry) have had their _ready() called.
	pass


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	# Run once, then the coroutine will call quit() when done.
	_run_all_tests()
	return false


func _run_all_tests() -> void:
	var total := 0
	var passed := 0
	var failed := 0
	var results: Array[Dictionary] = []

	for path in TEST_SCRIPTS:
		var script := load(path)
		if not script:
			results.append({
				"name": path,
				"pass": false,
				"msg": "could not load script",
			})
			continue
		if not script.has_method("run_test"):
			results.append({
				"name": path,
				"pass": false,
				"msg": "missing static run_test(tree) method",
			})
			continue
		var result: Dictionary = await script.run_test(self)
		results.append(result)

	print("")
	print("=== Integration Test Results ===")
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
