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
var _paused: bool = false
var _spawning: bool = false

var _fps_label: Label
var _stats_label: Label
var _help_label: Label


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.05, 0.05, 0.1))

	# Build same oval boundary as the main game's Receptacle
	var boundary := PackedByteArray()
	boundary.resize(GRID_W * GRID_H)
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
				boundary[y * GRID_W + x] = 1
			else:
				var dx := float(x - cx_g) / float(rx_g)
				var dy := float(y - cy_g) / float(ry_g)
				if dx * dx + dy * dy <= 1.0:
					boundary[y * GRID_W + x] = 1

	solver = ParticleFluidSolver.new()
	solver.setup(GRID_W, GRID_H, boundary)

	_image = Image.create(GRID_W, GRID_H, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	_sprite = Sprite2D.new()
	_sprite.texture = _texture
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sprite.scale = Vector2(CELL_SIZE, CELL_SIZE)
	_sprite.centered = false
	_sprite.position = Vector2(50, 80)
	add_child(_sprite)

	# Draw the oval boundary in a darker color so the user can see it
	for y in range(GRID_H):
		for x in range(GRID_W):
			var off := (y * GRID_W + x) * 4
			if boundary[y * GRID_W + x] == 0:
				_pixels.append(40)
				_pixels.append(35)
				_pixels.append(30)
				_pixels.append(255)
			else:
				_pixels.append(15)
				_pixels.append(15)
				_pixels.append(20)
				_pixels.append(255)

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
	var density := solver.get_density_readback()
	for y in range(GRID_H):
		for x in range(GRID_W):
			var i := y * GRID_W + x
			var off := i * 4
			var d: float = density[i] if i < density.size() else 0.0
			if d > 0.001:
				# Water blue, alpha scaled by density (sqrt for visibility).
				var alpha: float = sqrt(clampf(d, 0.0, 1.0))
				_pixels[off] = int(50 * alpha + 15 * (1.0 - alpha))
				_pixels[off + 1] = int(120 * alpha + 15 * (1.0 - alpha))
				_pixels[off + 2] = int(220 * alpha + 20 * (1.0 - alpha))
				_pixels[off + 3] = 255
			# else leave the boundary background pixel from setup
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
			for ii in range(4):
				var jx := randf() * 0.8 + 0.1
				var jy := randf() * 0.8 + 0.1
				positions.append(Vector2(gx + dx + jx, gy + dy + jy))
	solver.spawn_particles_batch(positions, 1)


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
			for ii in range(4):
				var jx := randf() * 0.8 + 0.1
				var jy := randf() * 0.8 + 0.1
				positions.append(Vector2(cx + dx + jx, cy + dy + jy))
	solver.spawn_particles_batch(positions, 1)


func _scenario_top_stream() -> void:
	var cx := GRID_W / 2
	var cy := 5
	var positions: Array[Vector2] = []
	for dy in range(0, 8):
		for dx in range(-2, 3):
			for ii in range(4):
				var jx := randf() * 0.8 + 0.1
				var jy := randf() * 0.8 + 0.1
				positions.append(Vector2(cx + dx + jx, cy + dy + jy))
	solver.spawn_particles_batch(positions, 1)


func _scenario_column() -> void:
	var cx := GRID_W / 2
	var positions: Array[Vector2] = []
	for y in range(5, 60):
		for dx in range(-2, 3):
			for ii in range(4):
				var jx := randf() * 0.8 + 0.1
				var jy := randf() * 0.8 + 0.1
				positions.append(Vector2(cx + dx + jx, y + jy))
	solver.spawn_particles_batch(positions, 1)


func _exit_tree() -> void:
	if solver:
		solver.cleanup()
