class_name MagneticField
extends FieldBase
## Magnetic field. Radiates from magnetic substances, influences ferrous particles.

const FIELD_FALLOFF := 0.85
const PROPAGATION_RADIUS := 8


func _init(w: int, h: int) -> void:
	super(w, h)
	update_interval = 4


func update(grid: ParticleGrid, _liquid: LiquidReadback, _delta: float) -> void:
	if not should_update():
		return

	values.fill(0.0)

	for y in range(height):
		for x in range(width):
			if not is_valid(x, y):
				continue
			var i := idx(x, y)
			var substance_id: int = grid.cells[i]
			if substance_id <= 0:
				continue
			var sub := SubstanceRegistry.get_substance(substance_id)
			if not sub or sub.magnetic_permeability < 0.1:
				continue

			var strength := sub.magnetic_permeability

			var charge: float = grid.charges[i]
			if absf(charge) > 0.1:
				strength += absf(charge) * 0.5

			_radiate(x, y, strength)


func _radiate(cx: int, cy: int, strength: float) -> void:
	for dy in range(-PROPAGATION_RADIUS, PROPAGATION_RADIUS + 1):
		for dx in range(-PROPAGATION_RADIUS, PROPAGATION_RADIUS + 1):
			var nx := cx + dx
			var ny := cy + dy
			if not is_valid(nx, ny):
				continue
			var dist := sqrt(float(dx * dx + dy * dy))
			if dist > PROPAGATION_RADIUS:
				continue
			var falloff := strength / maxf(1.0, dist * dist)
			values[idx(nx, ny)] += falloff


func apply_forces(grid: ParticleGrid) -> void:
	for y in range(grid.height - 1, 0, -1):
		for x in range(1, grid.width - 1):
			var substance_id := grid.get_cell(x, y)
			if substance_id <= 0:
				continue
			var sub := SubstanceRegistry.get_substance(substance_id)
			if not sub or sub.magnetic_permeability < 0.1:
				continue

			var best_dx := 0
			var best_dy := 0
			var best_val: float = values[idx(x, y)]

			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					if dx == 0 and dy == 0:
						continue
					var nx: int = x + dx
					var ny: int = y + dy
					if is_valid(nx, ny) and values[idx(nx, ny)] > best_val:
						if grid.get_cell(nx, ny) == 0:
							best_val = values[idx(nx, ny)]
							best_dx = dx
							best_dy = dy

			if best_dx != 0 or best_dy != 0:
				if randf() < 0.3 * sub.magnetic_permeability:
					grid._swap(x, y, x + best_dx, y + best_dy)
