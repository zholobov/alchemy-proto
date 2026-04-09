extends Node
## Loads and indexes all substance definitions at startup.
## Autoloaded as SubstanceRegistry.
##
## Also provides a seeded RNG for deterministic simulation. ALL code
## that affects simulation state MUST use SubstanceRegistry.sim_rng
## instead of global randf(). The seed can be recorded for replay.

## Hardcoded list of substance resource paths in the order they appear in the
## shelf. We cannot use DirAccess to scan res://data/substances/ at runtime
## because Godot's DirAccess does NOT enumerate files inside the .pck archive
## in exported builds — it only sees real on-disk directories during editor
## runs. When adding a new substance, create its .tres file AND add its path
## to this list.
const SUBSTANCE_PATHS: Array[String] = [
	"res://data/substances/iron_filings.tres",
	"res://data/substances/rock.tres",
	"res://data/substances/sulfur.tres",
	"res://data/substances/iron_ingot.tres",
	"res://data/substances/water.tres",
	"res://data/substances/hot_water.tres",
	"res://data/substances/mercury.tres",
	"res://data/substances/crystal.tres",
	"res://data/substances/ice.tres",
	"res://data/substances/charcoal.tres",
	"res://data/substances/salt.tres",
	"res://data/substances/oil.tres",
	"res://data/substances/acid.tres",
	"res://data/substances/flammable_gas.tres",
	"res://data/substances/steam.tres",
	"res://data/substances/wood.tres",
]

var substances: Array[SubstanceDef] = []
var name_to_id: Dictionary = {}

## Seeded RNG for deterministic simulation. Use sim_rng.randf() instead
## of global randf() in any code that affects simulation outcomes (particle
## jitter, reaction probability, etc.). The seed is set at startup and
## can be overridden for replay.
var sim_rng := RandomNumberGenerator.new()
const DEFAULT_SIM_SEED := 42


func _ready() -> void:
	sim_rng.seed = DEFAULT_SIM_SEED
	_load_substances()


func _load_substances() -> void:
	# Index 0 is reserved for "empty cell"
	substances.append(null)
	for path in SUBSTANCE_PATHS:
		var substance := load(path) as SubstanceDef
		if substance:
			substances.append(substance)
			name_to_id[substance.substance_name] = substances.size() - 1
		else:
			push_warning("Failed to load substance: %s" % path)
	print("Loaded %d substances" % (substances.size() - 1))


func get_substance(id: int) -> SubstanceDef:
	if id <= 0 or id >= substances.size():
		return null
	return substances[id]


func get_id(substance_name: String) -> int:
	return name_to_id.get(substance_name, 0)


func get_count() -> int:
	return substances.size() - 1
