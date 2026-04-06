extends Node
## Loads and indexes all substance definitions at startup.
## Autoloaded as SubstanceRegistry.

var substances: Array[Resource] = []
var name_to_id: Dictionary = {}


func _ready() -> void:
	_load_substances()


func _load_substances() -> void:
	# Index 0 is reserved for "empty cell"
	substances.append(null)
	var dir := DirAccess.open("res://data/substances/")
	if not dir:
		push_warning("No substances directory found")
		return
	dir.list_dir_begin()
	var filename := dir.get_next()
	while filename != "":
		if filename.ends_with(".tres"):
			var substance := load("res://data/substances/" + filename)
			if substance:
				substances.append(substance)
				name_to_id[substance.substance_name] = substances.size() - 1
		filename = dir.get_next()
	print("Loaded %d substances" % (substances.size() - 1))


func get_substance(id: int) -> Resource:
	if id <= 0 or id >= substances.size():
		return null
	return substances[id]


func get_id(substance_name: String) -> int:
	return name_to_id.get(substance_name, 0)


func get_count() -> int:
	return substances.size() - 1
