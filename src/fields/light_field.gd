class_name LightField
extends FieldBase
## Tracks light emission across the simulation.

const GLOW_TEMP_THRESHOLD := 300.0
const TEMP_GLOW_FACTOR := 0.002

var light_sources: Array[Dictionary] = []
const MAX_LIGHTS := 20


func _init(w: int, h: int) -> void:
	super(w, h)
	update_interval = 3


func update(grid: ParticleGrid, fluid: FluidSim, _delta: float) -> void:
	if not should_update():
		return

	light_sources.clear()
	values.fill(0.0)

	for y in range(height):
		for x in range(width):
			if not is_valid(x, y):
				continue
			var i := idx(x, y)
			var substance_id: int = grid.cells[i]
			var fluid_id: int = fluid.markers[i] if i < fluid.markers.size() else 0
			var sub: SubstanceDef = null

			if substance_id > 0:
				sub = SubstanceRegistry.get_substance(substance_id)
			elif fluid_id > 0:
				sub = SubstanceRegistry.get_substance(fluid_id)

			if not sub:
				continue

			var intensity := 0.0
			var color := sub.luminosity_color

			if sub.luminosity > 0.0:
				intensity += sub.luminosity

			var temp: float = grid.temperatures[i]
			if temp > GLOW_TEMP_THRESHOLD:
				intensity += (temp - GLOW_TEMP_THRESHOLD) * TEMP_GLOW_FACTOR
				var heat_ratio := clampf((temp - GLOW_TEMP_THRESHOLD) / 1000.0, 0.0, 1.0)
				color = Color.RED.lerp(Color.WHITE, heat_ratio)

			var charge: float = grid.charges[i]
			if absf(charge) > 0.1:
				intensity += absf(charge) * 0.3
				color = color.lerp(Color(0.5, 0.7, 1.0), 0.5)

			if intensity > 0.1:
				values[i] = intensity
				if light_sources.size() < MAX_LIGHTS:
					light_sources.append({
						"x": x, "y": y,
						"intensity": intensity,
						"color": color,
					})
