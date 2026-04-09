class_name ParticleGrid
extends RefCounted
## 2D cellular automata grid for powder and gas particles.
## Uses flat packed arrays for performance. Cell 0 = empty.

var width: int
var height: int
var cells: PackedInt32Array  ## Substance ID per cell. 0 = empty.
var temperatures: PackedFloat32Array  ## Per-cell temperature in degrees.
var charges: PackedFloat32Array  ## Per-cell electrical charge.

## Boundary mask: 1 = inside receptacle, 0 = wall/outside.
var boundary: PackedByteArray

## Use the shared seeded RNG for deterministic simulation.
## SubstanceRegistry.sim_rng is seeded at startup; particle_grid
## accesses it via this alias for convenience.
var _rng: RandomNumberGenerator


func _init(w: int, h: int) -> void:
	_rng = SubstanceRegistry.sim_rng
	width = w
	height = h
	var size := w * h
	cells = PackedInt32Array()
	cells.resize(size)
	temperatures = PackedFloat32Array()
	temperatures.resize(size)
	charges = PackedFloat32Array()
	charges.resize(size)
	boundary = PackedByteArray()
	boundary.resize(size)
	# Default: all cells are valid (open rectangle).
	boundary.fill(1)
	_rng.randomize()
	# Set ambient temperature.
	temperatures.fill(20.0)


func set_boundary_oval(center_x: int, center_y: int, radius_x: int, radius_y: int) -> void:
	## Marks cells inside an oval as valid (1), outside as wall (0).
	## Used to create the mortar/cauldron shape with a rounded bottom.
	boundary.fill(0)
	for y in range(height):
		for x in range(width):
			# Top is open (straight walls), bottom is rounded.
			var wall_margin := 2
			if x < wall_margin or x >= width - wall_margin:
				continue
			# Top half: straight walls.
			if y < center_y:
				boundary[y * width + x] = 1
			else:
				# Bottom half: oval shape.
				var dx := float(x - center_x) / float(radius_x)
				var dy := float(y - center_y) / float(radius_y)
				if dx * dx + dy * dy <= 1.0:
					boundary[y * width + x] = 1


func idx(x: int, y: int) -> int:
	return y * width + x


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height


func is_valid(x: int, y: int) -> bool:
	## Returns true if the cell is inside the receptacle boundary.
	if not in_bounds(x, y):
		return false
	return boundary[idx(x, y)] == 1


func is_empty(x: int, y: int) -> bool:
	return is_valid(x, y) and cells[idx(x, y)] == 0


func get_cell(x: int, y: int) -> int:
	if not in_bounds(x, y):
		return -1
	return cells[idx(x, y)]


func set_cell(x: int, y: int, substance_id: int) -> void:
	if is_valid(x, y):
		cells[idx(x, y)] = substance_id


func spawn_particle(x: int, y: int, substance_id: int) -> bool:
	## Tries to place a particle. Returns true if successful.
	if is_empty(x, y):
		cells[idx(x, y)] = substance_id
		return true
	return false


func clear_cell(x: int, y: int) -> void:
	if in_bounds(x, y):
		cells[idx(x, y)] = 0
		temperatures[idx(x, y)] = 20.0
		charges[idx(x, y)] = 0.0


func count_particles() -> int:
	var count := 0
	for i in range(cells.size()):
		if cells[i] != 0:
			count += 1
	return count


func update() -> void:
	## Disabled — simulation runs on GPU. This class is now a CPU mirror.
	pass


func _update_particle(x: int, y: int) -> void:
	var i := idx(x, y)
	var substance_id: int = cells[i]
	if substance_id == 0:
		return

	var substance := SubstanceRegistry.get_substance(substance_id)
	if not substance:
		return

	match substance.phase:
		SubstanceDef.Phase.POWDER:
			_update_powder(x, y, substance_id, substance)
		SubstanceDef.Phase.GAS:
			_update_gas(x, y, substance_id, substance)
		# LIQUID and SOLID phases are handled by other systems.


func _update_powder(x: int, y: int, _substance_id: int, substance: SubstanceDef) -> void:
	# 1. Try to fall straight down.
	if _try_move(x, y, x, y + 1, substance):
		return

	# 2. Try to fall diagonally (randomize direction to avoid bias).
	var go_left := _rng.randf() > 0.5
	var dx1 := -1 if go_left else 1
	var dx2 := 1 if go_left else -1
	if _try_move(x, y, x + dx1, y + 1, substance):
		return
	if _try_move(x, y, x + dx2, y + 1, substance):
		return


func _update_gas(x: int, y: int, _substance_id: int, substance: SubstanceDef) -> void:
	# Gases rise (try to move up) and drift sideways.
	# 1. Try to rise straight up.
	if _try_move(x, y, x, y - 1, substance):
		return

	# 2. Try to rise diagonally.
	var go_left := _rng.randf() > 0.5
	var dx1 := -1 if go_left else 1
	var dx2 := 1 if go_left else -1
	if _try_move(x, y, x + dx1, y - 1, substance):
		return
	if _try_move(x, y, x + dx2, y - 1, substance):
		return

	# 3. Try to drift sideways.
	if _try_move(x, y, x + dx1, y, substance):
		return
	if _try_move(x, y, x + dx2, y, substance):
		return

	# 4. Gases dissipate over time.
	if _rng.randf() < 0.002:
		# Reached top or stuck — fade out.
		if y <= 2:
			clear_cell(x, y)


func _try_move(from_x: int, from_y: int, to_x: int, to_y: int, substance: SubstanceDef) -> bool:
	## Tries to move a particle to the target cell. Handles density-based displacement.
	if not is_valid(to_x, to_y):
		return false

	var target_id: int = cells[idx(to_x, to_y)]

	# Empty cell — just move.
	if target_id == 0:
		_swap(from_x, from_y, to_x, to_y)
		return true

	# Density displacement: heavy sinks through light.
	var target_substance := SubstanceRegistry.get_substance(target_id)
	if target_substance and substance.density > target_substance.density:
		# Only displace downward movement (sinking).
		if to_y > from_y:
			_swap(from_x, from_y, to_x, to_y)
			return true

	return false


func _swap(x1: int, y1: int, x2: int, y2: int) -> void:
	var i1 := idx(x1, y1)
	var i2 := idx(x2, y2)
	# Swap substance IDs.
	var tmp_cell: int = cells[i1]
	cells[i1] = cells[i2]
	cells[i2] = tmp_cell
	# Swap temperatures.
	var tmp_temp: float = temperatures[i1]
	temperatures[i1] = temperatures[i2]
	temperatures[i2] = tmp_temp
	# Swap charges.
	var tmp_charge: float = charges[i1]
	charges[i1] = charges[i2]
	charges[i2] = tmp_charge
