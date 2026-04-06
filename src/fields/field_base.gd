class_name FieldBase
extends RefCounted
## Base class for all simulation fields. A field is a continuous property
## that propagates across the simulation space and feeds back into reactions.

var width: int
var height: int
var values: PackedFloat32Array
var boundary: PackedByteArray

## Whether this field should update every frame or every N frames.
var update_interval: int = 1
var _frame_counter: int = 0


func _init(w: int, h: int) -> void:
	width = w
	height = h
	values = PackedFloat32Array()
	values.resize(w * h)
	boundary = PackedByteArray()
	boundary.resize(w * h)
	boundary.fill(1)


func idx(x: int, y: int) -> int:
	return y * width + x


func is_valid(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height and boundary[idx(x, y)] == 1


func get_value(x: int, y: int) -> float:
	if not is_valid(x, y):
		return 0.0
	return values[idx(x, y)]


func set_value(x: int, y: int, val: float) -> void:
	if is_valid(x, y):
		values[idx(x, y)] = val


func add_value(x: int, y: int, amount: float) -> void:
	if is_valid(x, y):
		values[idx(x, y)] += amount


func should_update() -> bool:
	_frame_counter += 1
	if _frame_counter >= update_interval:
		_frame_counter = 0
		return true
	return false


func update(_grid: ParticleGrid, _fluid: FluidSim, _delta: float) -> void:
	## Override in subclasses.
	pass
