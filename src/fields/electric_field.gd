class_name ElectricField
extends FieldBase
## Electrical charge propagation through conductive substances.

const DISSIPATION_RATE := 0.05
const PROPAGATION_STRENGTH := 0.3


func _init(w: int, h: int) -> void:
	super(w, h)
	update_interval = 2


func update(grid: ParticleGrid, liquid: LiquidReadback, _delta: float) -> void:
	if not should_update():
		return

	var new_values := values.duplicate()

	for y in range(height):
		for x in range(width):
			if not is_valid(x, y):
				continue

			var i := idx(x, y)
			var charge: float = values[i]
			if absf(charge) < 0.001:
				continue

			var substance_id: int = grid.cells[i]
			var fluid_id: int = liquid.markers[i] if liquid and i < liquid.markers.size() else 0
			var conductivity := 0.0

			if substance_id > 0:
				var sub := SubstanceRegistry.get_substance(substance_id)
				if sub:
					conductivity = sub.conductivity_electric
			elif fluid_id > 0:
				var sub := SubstanceRegistry.get_substance(fluid_id)
				if sub:
					conductivity = sub.conductivity_electric

			if conductivity < 0.01:
				new_values[i] *= (1.0 - DISSIPATION_RATE)
				continue

			var neighbors: Array[Vector2i] = [
				Vector2i(x + 1, y), Vector2i(x - 1, y),
				Vector2i(x, y + 1), Vector2i(x, y - 1),
			]

			for n in neighbors:
				if not is_valid(n.x, n.y):
					continue
				var ni := idx(n.x, n.y)
				var n_sub_id: int = grid.cells[ni]
				var n_fluid_id: int = liquid.markers[ni] if liquid and ni < liquid.markers.size() else 0
				var n_conductivity := 0.0
				if n_sub_id > 0:
					var ns := SubstanceRegistry.get_substance(n_sub_id)
					if ns:
						n_conductivity = ns.conductivity_electric
				elif n_fluid_id > 0:
					var ns := SubstanceRegistry.get_substance(n_fluid_id)
					if ns:
						n_conductivity = ns.conductivity_electric

				if n_conductivity > 0.01:
					var flow := charge * conductivity * n_conductivity * PROPAGATION_STRENGTH * 0.25
					new_values[ni] += flow
					new_values[i] -= flow

			new_values[i] *= (1.0 - DISSIPATION_RATE * (1.0 - conductivity))

	values = new_values

	for i in range(mini(values.size(), grid.charges.size())):
		grid.charges[i] = values[i]
