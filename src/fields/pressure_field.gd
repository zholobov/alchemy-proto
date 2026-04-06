class_name PressureField
extends FieldBase
## Pressure field. Tracks gas accumulation in the receptacle.
## When pressure exceeds the containment threshold, triggers explosion.

var gas_count: int = 0
var receptacle_volume: int = 0
var pressure_level: float = 0.0
var containment_threshold: float = 100.0
var _has_exploded: bool = false

signal containment_failure


func calculate_volume() -> void:
	receptacle_volume = 0
	for i in range(boundary.size()):
		if boundary[i] == 1:
			receptacle_volume += 1


func update(grid: ParticleGrid, _fluid: FluidSim, _delta: float) -> void:
	if not should_update():
		return

	gas_count = 0
	for i in range(grid.cells.size()):
		if grid.cells[i] <= 0:
			continue
		var sub := SubstanceRegistry.get_substance(grid.cells[i])
		if sub and sub.phase == SubstanceDef.Phase.GAS:
			gas_count += 1

	if receptacle_volume > 0:
		pressure_level = float(gas_count) / float(receptacle_volume) * 10.0
	else:
		pressure_level = 0.0

	values.fill(pressure_level)

	if pressure_level >= 1.0 and not _has_exploded:
		_has_exploded = true
		containment_failure.emit()


func reset() -> void:
	_has_exploded = false
	pressure_level = 0.0
	gas_count = 0
