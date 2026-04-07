extends Node2D
## Standalone test harness for the GPU MAC fluid solver.
## Displays a 64x64 fluid simulation with a blob that should fall and pool.
## Press R to reset, SPACE to pause, 1-4 to change fluid scenarios.

const GRID_W := 64
const GRID_H := 64
const CELL_SIZE := 8

var solver: FluidSolver
var _image: Image
var _texture: ImageTexture
var _sprite: Sprite2D
var _pixels: PackedByteArray
var _paused: bool = false

var _fps_label: Label
var _stats_label: Label


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.05, 0.05, 0.1))

	solver = FluidSolver.new()
	solver.setup(GRID_W, GRID_H)

	_image = Image.create(GRID_W, GRID_H, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	_sprite = Sprite2D.new()
	_sprite.texture = _texture
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sprite.scale = Vector2(CELL_SIZE, CELL_SIZE)
	_sprite.centered = false
	_sprite.position = Vector2(50, 50)
	add_child(_sprite)

	_pixels = PackedByteArray()
	_pixels.resize(GRID_W * GRID_H * 4)

	_fps_label = Label.new()
	_fps_label.position = Vector2(10, 10)
	_fps_label.add_theme_font_size_override("font_size", 14)
	_fps_label.add_theme_color_override("font_color", Color.YELLOW)
	add_child(_fps_label)

	_stats_label = Label.new()
	_stats_label.position = Vector2(10, 30)
	_stats_label.add_theme_font_size_override("font_size", 12)
	_stats_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(_stats_label)

	var help := Label.new()
	help.position = Vector2(600, 10)
	help.add_theme_font_size_override("font_size", 12)
	help.add_theme_color_override("font_color", Color.GRAY)
	help.text = "R=reset  SPACE=pause  1=center blob  2=top blob  3=two blobs  4=column"
	add_child(help)

	_scenario_center_blob()


func _process(_delta: float) -> void:
	if not _paused:
		solver.step(_delta)

	var stats := solver.get_stats()
	_fps_label.text = "%d FPS %s" % [Engine.get_frames_per_second(), " [PAUSED]" if _paused else ""]
	_stats_label.text = "Mass: %.1f  MaxVel: %.2f  MaxDiv: %.4f  FluidCells: %d" % [
		stats["total_mass"], stats["max_velocity"], stats["max_divergence"], stats["fluid_cells"]
	]

	_render_density()


func _render_density() -> void:
	var density := solver.get_density_readback()
	for i in range(GRID_W * GRID_H):
		var d: float = density[i] if i < density.size() else 0.0
		var off := i * 4
		if d > 0.01:
			_pixels[off] = 50
			_pixels[off + 1] = 100
			_pixels[off + 2] = int(clampf(d, 0.0, 1.0) * 255)
			_pixels[off + 3] = 255
		else:
			_pixels[off] = 10
			_pixels[off + 1] = 10
			_pixels[off + 2] = 15
			_pixels[off + 3] = 255
	_image = Image.create_from_data(GRID_W, GRID_H, false, Image.FORMAT_RGBA8, _pixels)
	_texture.update(_image)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_R:
				solver.clear()
				_scenario_center_blob()
			KEY_SPACE:
				_paused = not _paused
			KEY_1:
				solver.clear()
				_scenario_center_blob()
			KEY_2:
				solver.clear()
				_scenario_top_blob()
			KEY_3:
				solver.clear()
				_scenario_two_blobs()
			KEY_4:
				solver.clear()
				_scenario_column()


func _scenario_center_blob() -> void:
	var cx: int = GRID_W / 2
	var cy: int = GRID_H / 2
	for dy in range(-5, 6):
		for dx in range(-5, 6):
			if dx * dx + dy * dy <= 25:
				solver.spawn_fluid(cx + dx, cy + dy, 1.0)


func _scenario_top_blob() -> void:
	var cx: int = GRID_W / 2
	var cy: int = 10
	for dy in range(-4, 5):
		for dx in range(-4, 5):
			if dx * dx + dy * dy <= 16:
				solver.spawn_fluid(cx + dx, cy + dy, 1.0)


func _scenario_two_blobs() -> void:
	for dy in range(-3, 4):
		for dx in range(-3, 4):
			if dx * dx + dy * dy <= 9:
				solver.spawn_fluid(16 + dx, 16 + dy, 1.0)
				solver.spawn_fluid(48 + dx, 16 + dy, 1.0)


func _scenario_column() -> void:
	for y in range(5, 30):
		for x in range(30, 34):
			solver.spawn_fluid(x, y, 1.0)
