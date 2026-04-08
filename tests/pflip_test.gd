extends Node2D
## Standalone test for the PIC/FLIP particle fluid solver.
##
## Controls:
##   - LMB drag: spawn water particles at the cursor
##   - R: clear and respawn a center blob
##   - SPACE: pause / resume
##   - 1: center blob
##   - 2: top column (continuous-pour-like)
##   - 3: tall column

const GRID_W := 200
const GRID_H := 150
const CELL_SIZE := 4

var solver: ParticleFluidSolver
var _image: Image
var _texture: ImageTexture
var _sprite: Sprite2D
var _pixels: PackedByteArray
var _boundary: PackedByteArray  # cached for renderer to restore background each frame
var _water_id: int = 1           # SubstanceRegistry id for "Water"; resolved in _ready()
var _paused: bool = false
var _spawning: bool = false

var _fps_label: Label
var _stats_label: Label
var _help_label: Label


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.05, 0.05, 0.1))

	# Build same oval boundary as the main game's Receptacle
	_boundary = PackedByteArray()
	_boundary.resize(GRID_W * GRID_H)
	var cx_g := GRID_W / 2
	var cy_g := int(float(GRID_H) * 0.55)
	var rx_g := int(float(GRID_W) / 2.0) - 2
	var ry_g := int(float(GRID_H) * 0.45)
	for y in range(GRID_H):
		for x in range(GRID_W):
			var wall_margin := 2
			if x < wall_margin or x >= GRID_W - wall_margin:
				continue
			if y < cy_g:
				_boundary[y * GRID_W + x] = 1
			else:
				var dx := float(x - cx_g) / float(rx_g)
				var dy := float(y - cy_g) / float(ry_g)
				if dx * dx + dy * dy <= 1.0:
					_boundary[y * GRID_W + x] = 1

	solver = ParticleFluidSolver.new()
	solver.setup(GRID_W, GRID_H, _boundary)
	solver.upload_substance_properties()

	# Resolve Water's substance id from the registry so the spawned particles
	# pick up water's viscosity (0.3 in data/substances/water.tres).
	var water_lookup := SubstanceRegistry.get_id("Water")
	if water_lookup > 0:
		_water_id = water_lookup

	_image = Image.create(GRID_W, GRID_H, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	_sprite = Sprite2D.new()
	_sprite.texture = _texture
	# LINEAR filtering smooths the cell-grid → screen upscaling, which combined
	# with the box-filter density smoothing in _render() gives a soft fluid surface.
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_sprite.scale = Vector2(CELL_SIZE, CELL_SIZE)
	_sprite.centered = false
	_sprite.position = Vector2(50, 80)
	add_child(_sprite)

	# Allocate the pixel buffer; actual pixels are written each frame in _render().
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

	_help_label = Label.new()
	_help_label.position = Vector2(10, 50)
	_help_label.add_theme_font_size_override("font_size", 11)
	_help_label.add_theme_color_override("font_color", Color.GRAY)
	_help_label.text = "LMB drag = pour water  |  R = reset  |  SPACE = pause  |  1 = blob  2 = top stream  3 = column"
	add_child(_help_label)

	_scenario_center_blob()


func _process(_delta: float) -> void:
	if _spawning:
		_spawn_at_mouse()

	if not _paused:
		solver.step(_delta)

	var stats := solver.get_stats()
	_fps_label.text = "%d FPS %s" % [Engine.get_frames_per_second(), " [PAUSED]" if _paused else ""]
	_stats_label.text = "Particles: %d / %d alive" % [stats["particle_count"], stats["max_particles"]]

	_render()


func _render() -> void:
	# Smooth density rendering: each cell's display density is the average of
	# itself and its 8 neighbors (3x3 box filter). This eliminates the
	# stippled "salt-and-pepper" look caused by per-cell particle count
	# fluctuation. Combined with TEXTURE_FILTER_LINEAR on the sprite, the
	# result is a smooth fluid surface instead of pixelated dithering.
	var density := solver.get_density_readback()
	for y in range(GRID_H):
		for x in range(GRID_W):
			var i := y * GRID_W + x
			var off := i * 4
			var is_wall: bool = _boundary[i] == 0

			# Box-filter the density over 3x3 neighborhood. Out-of-bounds
			# samples are treated as 0 (no contribution).
			var sum_d: float = 0.0
			var count: int = 0
			for dy in range(-1, 2):
				var ny := y + dy
				if ny < 0 or ny >= GRID_H:
					continue
				for dx in range(-1, 2):
					var nx := x + dx
					if nx < 0 or nx >= GRID_W:
						continue
					sum_d += density[ny * GRID_W + nx]
					count += 1
			var d: float = sum_d / float(count)

			if d > 0.005:
				# sqrt curve so low-density cells are still visible
				var alpha: float = sqrt(clampf(d, 0.0, 1.0))
				_pixels[off] = int(50 * alpha + 15 * (1.0 - alpha))
				_pixels[off + 1] = int(120 * alpha + 15 * (1.0 - alpha))
				_pixels[off + 2] = int(220 * alpha + 20 * (1.0 - alpha))
				_pixels[off + 3] = 255
			elif is_wall:
				_pixels[off] = 40
				_pixels[off + 1] = 35
				_pixels[off + 2] = 30
				_pixels[off + 3] = 255
			else:
				_pixels[off] = 15
				_pixels[off + 1] = 15
				_pixels[off + 2] = 20
				_pixels[off + 3] = 255
	_image = Image.create_from_data(GRID_W, GRID_H, false, Image.FORMAT_RGBA8, _pixels)
	_texture.update(_image)


func _spawn_at_mouse() -> void:
	var local := get_global_mouse_position() - _sprite.position
	var gx := local.x / float(CELL_SIZE)
	var gy := local.y / float(CELL_SIZE)
	if gx < 0 or gx >= GRID_W or gy < 0 or gy >= GRID_H:
		return
	# Spawn 4 particles per cell in a 2x2 sub-cell pattern around the cursor
	var positions: Array[Vector2] = []
	var radius := 2
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx * dx + dy * dy > radius * radius:
				continue
			# 4 jittered particles per cell
			for ii in range(8):
				var jx := randf() * 0.8 + 0.1
				var jy := randf() * 0.8 + 0.1
				positions.append(Vector2(gx + dx + jx, gy + dy + jy))
	solver.spawn_particles_batch(positions, _water_id)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_spawning = event.pressed
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
				_scenario_top_stream()
			KEY_3:
				solver.clear()
				_scenario_column()


func _scenario_center_blob() -> void:
	var cx := GRID_W / 2
	var cy := GRID_H / 3
	var positions: Array[Vector2] = []
	for dy in range(-6, 7):
		for dx in range(-6, 7):
			if dx * dx + dy * dy > 36:
				continue
			# 4 particles per cell
			for ii in range(8):
				var jx := randf() * 0.8 + 0.1
				var jy := randf() * 0.8 + 0.1
				positions.append(Vector2(cx + dx + jx, cy + dy + jy))
	solver.spawn_particles_batch(positions, _water_id)


func _scenario_top_stream() -> void:
	var cx := GRID_W / 2
	var cy := 5
	var positions: Array[Vector2] = []
	for dy in range(0, 8):
		for dx in range(-2, 3):
			for ii in range(8):
				var jx := randf() * 0.8 + 0.1
				var jy := randf() * 0.8 + 0.1
				positions.append(Vector2(cx + dx + jx, cy + dy + jy))
	solver.spawn_particles_batch(positions, _water_id)


func _scenario_column() -> void:
	var cx := GRID_W / 2
	var positions: Array[Vector2] = []
	for y in range(5, 60):
		for dx in range(-2, 3):
			for ii in range(8):
				var jx := randf() * 0.8 + 0.1
				var jy := randf() * 0.8 + 0.1
				positions.append(Vector2(cx + dx + jx, y + jy))
	solver.spawn_particles_batch(positions, _water_id)


func _exit_tree() -> void:
	if solver:
		solver.cleanup()
