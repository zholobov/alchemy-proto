class_name TemperatureField
extends FieldBase
## Temperature field. Heat conducts through substances based on thermal
## conductivity, radiates through air slowly, and cools toward ambient.

const AMBIENT_TEMP := 20.0
const AMBIENT_COOLING_RATE := 0.05
const CONDUCTION_RATE := 0.1
const RADIATION_RATE := 0.01


func update(grid: ParticleGrid, fluid: FluidSim, _delta: float) -> void:
	if not should_update():
		return

	# Merge any heat the mediator wrote directly to grid.temperatures.
	for i in range(mini(values.size(), grid.temperatures.size())):
		if grid.temperatures[i] != values[i]:
			values[i] = grid.temperatures[i]

	var new_values := values.duplicate()

	for y in range(height):
		for x in range(width):
			if not is_valid(x, y):
				continue

			var i := idx(x, y)
			var temp := values[i]
			var substance_id := grid.cells[i]
			var fluid_id := fluid.markers[i] if i < fluid.markers.size() else 0
			var has_substance := substance_id > 0 or fluid_id > 0

			var conductivity := RADIATION_RATE
			if substance_id > 0:
				var sub := SubstanceRegistry.get_substance(substance_id)
				if sub:
					conductivity = sub.conductivity_thermal * CONDUCTION_RATE
			elif fluid_id > 0:
				var sub := SubstanceRegistry.get_substance(fluid_id)
				if sub:
					conductivity = sub.conductivity_thermal * CONDUCTION_RATE

			var neighbors := [
				Vector2i(x + 1, y), Vector2i(x - 1, y),
				Vector2i(x, y + 1), Vector2i(x, y - 1),
			]

			for n in neighbors:
				if not is_valid(n.x, n.y):
					continue
				var ni := idx(n.x, n.y)
				var neighbor_temp := values[ni]
				var diff := neighbor_temp - temp
				var flow := diff * conductivity
				new_values[i] += flow * 0.25

			if has_substance:
				new_values[i] = lerpf(new_values[i], AMBIENT_TEMP, AMBIENT_COOLING_RATE * 0.1)
			else:
				new_values[i] = lerpf(new_values[i], AMBIENT_TEMP, AMBIENT_COOLING_RATE)

	values = new_values

	for i in range(mini(values.size(), grid.temperatures.size())):
		grid.temperatures[i] = values[i]
