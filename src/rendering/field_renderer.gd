class_name FieldRenderer
extends Node2D
## Visualizes field effects on top of the substance renderer.

var grid: ParticleGrid
var temperature_field: TemperatureField
var light_field: LightField
var electric_field: ElectricField
var pressure_field: PressureField
var cell_size: int = 4

var _lights: Array[PointLight2D] = []
var _light_texture: Texture2D


func setup(p_grid: ParticleGrid, p_cell_size: int,
		p_temp: TemperatureField, p_light: LightField,
		p_electric: ElectricField, p_pressure: PressureField) -> void:
	grid = p_grid
	cell_size = p_cell_size
	temperature_field = p_temp
	light_field = p_light
	electric_field = p_electric
	pressure_field = p_pressure

	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in range(64):
		for x in range(64):
			var dx := float(x - 32) / 32.0
			var dy := float(y - 32) / 32.0
			var dist := sqrt(dx * dx + dy * dy)
			var alpha := clampf(1.0 - dist, 0.0, 1.0)
			alpha = alpha * alpha
			img.set_pixel(x, y, Color(1, 1, 1, alpha))
	_light_texture = ImageTexture.create_from_image(img)


func update_visuals() -> void:
	_update_lights()
	queue_redraw()


func _update_lights() -> void:
	var sources := light_field.light_sources

	while _lights.size() < sources.size() and _lights.size() < 20:
		var light := PointLight2D.new()
		light.texture = _light_texture
		light.texture_scale = 2.0
		light.energy = 0.5
		light.blend_mode = Light2D.BLEND_MODE_ADD
		add_child(light)
		_lights.append(light)

	for i in range(_lights.size()):
		if i < sources.size():
			var src := sources[i]
			_lights[i].visible = true
			_lights[i].position = Vector2(src["x"] * cell_size, src["y"] * cell_size)
			_lights[i].color = src["color"]
			_lights[i].energy = clampf(src["intensity"], 0.1, 2.0)
			_lights[i].texture_scale = 1.0 + src["intensity"] * 2.0
		else:
			_lights[i].visible = false


func _draw() -> void:
	if not grid:
		return
	_draw_electric_arcs()
	if pressure_field and pressure_field.pressure_level > 0.3:
		_draw_pressure_warning()


func _draw_electric_arcs() -> void:
	if not electric_field:
		return
	for y in range(0, grid.height, 2):
		for x in range(0, grid.width, 2):
			var charge := electric_field.get_value(x, y)
			if absf(charge) < 0.5:
				continue
			var pos := Vector2(x * cell_size, y * cell_size)
			var spark_color := Color(0.5, 0.7, 1.0, clampf(absf(charge), 0.0, 1.0))
			draw_rect(Rect2(pos, Vector2(cell_size, cell_size)), spark_color)


func _draw_pressure_warning() -> void:
	var intensity := pressure_field.pressure_level
	var border_color := Color(1.0, 0.2, 0.0, clampf(intensity * 0.5, 0.0, 0.8))
	var w := grid.width * cell_size
	var h := grid.height * cell_size
	var thickness := 3.0 + intensity * 5.0
	draw_rect(Rect2(0, 0, w, h), border_color, false, thickness)
