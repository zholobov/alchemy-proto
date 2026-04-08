class_name MultiLayerRenderer
extends RendererBase
## Multi-layer compositing renderer. Separates substances by phase,
## applies specialized shaders per layer, composites the result.

var grid: ParticleGrid
var cell_size: int = 4
var liquid: LiquidReadback
var vapor: VaporSim

# Per-layer data images
var _powder_image: Image
var _liquid_image: Image
var _gas_image: Image

# Per-layer textures and sprites
var _powder_texture: ImageTexture
var _liquid_texture: ImageTexture
var _gas_texture: ImageTexture
var _powder_sprite: Sprite2D
var _liquid_sprite: Sprite2D
var _gas_sprite: Sprite2D

# Pixel data buffers
var _powder_pixels: PackedByteArray
var _liquid_pixels: PackedByteArray
var _gas_pixels: PackedByteArray

# Noise texture for powder grain
var _noise_texture: NoiseTexture2D

# Color cache
var _color_cache: PackedColorArray
var _phase_cache: PackedInt32Array


func setup(p_grid: ParticleGrid, p_cell_size: int = 4, p_liquid: LiquidReadback = null, p_vapor: VaporSim = null) -> void:
	grid = p_grid
	cell_size = p_cell_size
	liquid = p_liquid
	vapor = p_vapor

	var w := grid.width
	var h := grid.height
	var buf_size := w * h * 4

	_powder_image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	_powder_texture = ImageTexture.create_from_image(_powder_image)
	_liquid_image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	_liquid_texture = ImageTexture.create_from_image(_liquid_image)
	_gas_image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	_gas_texture = ImageTexture.create_from_image(_gas_image)

	_powder_pixels = PackedByteArray()
	_powder_pixels.resize(buf_size)
	_liquid_pixels = PackedByteArray()
	_liquid_pixels.resize(buf_size)
	_gas_pixels = PackedByteArray()
	_gas_pixels.resize(buf_size)

	# Create noise texture for powder grain
	_noise_texture = NoiseTexture2D.new()
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.05
	_noise_texture.noise = noise
	_noise_texture.width = 128
	_noise_texture.height = 128
	_noise_texture.seamless = true

	# Create sprites for each layer with shaders
	_powder_sprite = _create_layer_sprite(_powder_texture, "res://src/rendering/shaders/powder_layer.gdshader")
	if _powder_sprite.material is ShaderMaterial:
		(_powder_sprite.material as ShaderMaterial).set_shader_parameter("noise_texture", _noise_texture)
	add_child(_powder_sprite)

	_liquid_sprite = _create_layer_sprite(_liquid_texture, "res://src/rendering/shaders/liquid_layer.gdshader")
	add_child(_liquid_sprite)

	_gas_sprite = _create_layer_sprite(_gas_texture, "res://src/rendering/shaders/gas_layer.gdshader")
	add_child(_gas_sprite)

	_rebuild_caches()


func _create_layer_sprite(tex: ImageTexture, shader_path: String) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.texture = tex
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sprite.scale = Vector2(cell_size, cell_size)
	sprite.centered = false

	var shader_res := load(shader_path) as Shader
	if shader_res:
		var mat := ShaderMaterial.new()
		mat.shader = shader_res
		sprite.material = mat

	return sprite


func _rebuild_caches() -> void:
	var count := SubstanceRegistry.substances.size()
	_color_cache = PackedColorArray()
	_color_cache.resize(count)
	_phase_cache = PackedInt32Array()
	_phase_cache.resize(count)
	_color_cache[0] = Color.TRANSPARENT
	_phase_cache[0] = -1
	for i in range(1, count):
		var sub := SubstanceRegistry.get_substance(i)
		if sub:
			_color_cache[i] = sub.base_color
			_phase_cache[i] = sub.phase
		else:
			_color_cache[i] = Color.MAGENTA
			_phase_cache[i] = -1


func get_renderer_name() -> String:
	return "Multi-Layer"


func cleanup() -> void:
	for child in get_children():
		child.queue_free()


func render() -> void:
	if not grid:
		return

	_powder_pixels.fill(0)
	_liquid_pixels.fill(0)
	_gas_pixels.fill(0)

	var size := grid.width * grid.height

	for i in range(size):
		if grid.boundary[i] == 0:
			var off := i * 4
			_powder_pixels[off] = 38
			_powder_pixels[off + 1] = 33
			_powder_pixels[off + 2] = 30
			_powder_pixels[off + 3] = 255
			continue

		var substance_id: int = grid.cells[i]
		var fluid_id: int = liquid.markers[i] if liquid else 0

		if fluid_id > 0 and fluid_id < _phase_cache.size():
			var phase: int = _phase_cache[fluid_id]
			var color: Color = _color_cache[fluid_id]
			if phase == SubstanceDef.Phase.LIQUID:
				_write_pixel(_liquid_pixels, i, color)
			elif phase == SubstanceDef.Phase.GAS:
				_write_pixel(_gas_pixels, i, color)

		if substance_id > 0 and substance_id < _phase_cache.size():
			var phase: int = _phase_cache[substance_id]
			var color: Color = _color_cache[substance_id]
			match phase:
				SubstanceDef.Phase.POWDER, SubstanceDef.Phase.SOLID:
					_write_pixel(_powder_pixels, i, color)
				SubstanceDef.Phase.LIQUID:
					_write_pixel(_liquid_pixels, i, color)
				SubstanceDef.Phase.GAS:
					_write_pixel(_gas_pixels, i, color)

		# Vapor (fog/mist/steam) goes into the gas layer too, regardless of
		# what else is in the cell. Translucent so it reads as overlay.
		if vapor:
			var vapor_id: int = vapor.markers[i]
			if vapor_id > 0 and vapor_id < _color_cache.size():
				var vcolor: Color = _color_cache[vapor_id]
				vcolor.a *= 0.5
				_write_pixel(_gas_pixels, i, vcolor)

	var w := grid.width
	var h := grid.height
	_powder_image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, _powder_pixels)
	_powder_texture.update(_powder_image)
	_liquid_image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, _liquid_pixels)
	_liquid_texture.update(_liquid_image)
	_gas_image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, _gas_pixels)
	_gas_texture.update(_gas_image)


func _write_pixel(buffer: PackedByteArray, index: int, color: Color) -> void:
	var off := index * 4
	buffer[off] = int(color.r8)
	buffer[off + 1] = int(color.g8)
	buffer[off + 2] = int(color.b8)
	buffer[off + 3] = int(color.a8)
