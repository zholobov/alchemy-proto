class_name DensityFieldRenderer
extends RendererBase
## Density field renderer. Generates per-substance density textures,
## blurs them for smooth organic blobs, composites with material shading.

var grid: ParticleGrid
var cell_size: int = 4
var fluid: FluidSim

var _output_sprite: Sprite2D
var _output_image: Image
var _output_texture: ImageTexture
var _output_pixels: PackedByteArray

# Blur work buffer
var _density_pixels: PackedByteArray
var _blurred_pixels: PackedFloat32Array

# Color cache
var _color_cache: PackedColorArray


func setup(p_grid: ParticleGrid, p_cell_size: int = 4, p_fluid: FluidSim = null) -> void:
	grid = p_grid
	cell_size = p_cell_size
	fluid = p_fluid

	var w := grid.width
	var h := grid.height

	_output_image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	_output_texture = ImageTexture.create_from_image(_output_image)
	_output_pixels = PackedByteArray()
	_output_pixels.resize(w * h * 4)

	_density_pixels = PackedByteArray()
	_density_pixels.resize(w * h)
	_blurred_pixels = PackedFloat32Array()
	_blurred_pixels.resize(w * h)

	_output_sprite = Sprite2D.new()
	_output_sprite.texture = _output_texture
	_output_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_output_sprite.scale = Vector2(cell_size, cell_size)
	_output_sprite.centered = false
	add_child(_output_sprite)

	_rebuild_color_cache()


func _rebuild_color_cache() -> void:
	_color_cache = PackedColorArray()
	_color_cache.resize(SubstanceRegistry.substances.size())
	_color_cache[0] = Color.TRANSPARENT
	for i in range(1, SubstanceRegistry.substances.size()):
		var sub := SubstanceRegistry.get_substance(i)
		if sub:
			_color_cache[i] = sub.base_color
		else:
			_color_cache[i] = Color.MAGENTA


func get_renderer_name() -> String:
	return "Density Field"


func cleanup() -> void:
	for child in get_children():
		child.queue_free()


func render() -> void:
	if not grid:
		return

	var w := grid.width
	var h := grid.height
	var size := w * h

	# Clear output
	_output_pixels.fill(0)

	# Find which substance IDs are present
	var active_substances: Dictionary = {}
	for i in range(size):
		var sid: int = grid.cells[i]
		if sid > 0:
			active_substances[sid] = true
		if fluid:
			var fid: int = fluid.markers[i]
			if fid > 0:
				active_substances[fid] = true

	# Process each active substance: build density, blur, composite
	for sid in active_substances:
		var color: Color = _color_cache[sid] if sid < _color_cache.size() else Color.MAGENTA

		# Build density field for this substance
		_density_pixels.fill(0)
		for i in range(size):
			if grid.cells[i] == sid or (fluid and fluid.markers[i] == sid):
				_density_pixels[i] = 255

		# Box blur the density field (2 passes for smooth result)
		_blur_density(w, h)
		_blur_density(w, h)

		# Composite: where density > threshold, blend substance color
		for i in range(size):
			var density: float = _blurred_pixels[i]
			if density < 0.05:
				continue

			# Smoothstep for soft edges
			var alpha: float = _smoothstep(0.1, 0.6, density)
			alpha *= color.a

			# Blend into output (simple alpha compositing)
			var off := i * 4
			var existing_a: float = float(_output_pixels[off + 3]) / 255.0
			var out_a: float = alpha + existing_a * (1.0 - alpha)
			if out_a > 0.0:
				var inv_blend := existing_a * (1.0 - alpha) / out_a
				_output_pixels[off] = int((color.r * alpha / out_a + float(_output_pixels[off]) / 255.0 * inv_blend) * 255.0)
				_output_pixels[off + 1] = int((color.g * alpha / out_a + float(_output_pixels[off + 1]) / 255.0 * inv_blend) * 255.0)
				_output_pixels[off + 2] = int((color.b * alpha / out_a + float(_output_pixels[off + 2]) / 255.0 * inv_blend) * 255.0)
				_output_pixels[off + 3] = int(out_a * 255.0)

	# Draw boundary walls
	for i in range(size):
		if grid.boundary[i] == 0:
			var off := i * 4
			_output_pixels[off] = 38
			_output_pixels[off + 1] = 33
			_output_pixels[off + 2] = 30
			_output_pixels[off + 3] = 255

	_output_image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, _output_pixels)
	_output_texture.update(_output_image)


func _blur_density(w: int, h: int) -> void:
	## Fast blur using native Image downscale+upscale (C++, not GDScript loops).
	var img := Image.create_from_data(w, h, false, Image.FORMAT_R8, _density_pixels)
	img.resize(maxi(w / 4, 1), maxi(h / 4, 1), Image.INTERPOLATE_BILINEAR)
	img.resize(w, h, Image.INTERPOLATE_BILINEAR)
	var blurred_bytes := img.get_data()
	for i in range(w * h):
		_blurred_pixels[i] = float(blurred_bytes[i]) / 255.0
		_density_pixels[i] = blurred_bytes[i]


func _smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
