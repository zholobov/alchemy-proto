class_name SubstanceRenderer
extends RendererBase
## Debug pixel renderer. Renders the particle grid as a scaled-up pixel image.
## Each grid cell = 1 pixel in the image, scaled by cell_size on screen.

var grid: ParticleGrid
var cell_size: int = 4
var liquid: LiquidReadback
var vapor: VaporSim
var _image: Image
var _texture: ImageTexture
var _pixel_data: PackedByteArray
var _sprite: Sprite2D

## Cache substance colors to avoid lookups every pixel every frame.
var _color_cache: PackedColorArray

## Vapor alpha multiplier. Vapor is always translucent regardless of
## substance base_color alpha so it reads as fog/mist overlay rather
## than solid fill.
const VAPOR_ALPHA_SCALE := 0.5


func setup(p_grid: ParticleGrid, p_cell_size: int = 4, p_liquid: LiquidReadback = null, p_vapor: VaporSim = null) -> void:
	grid = p_grid
	cell_size = p_cell_size
	liquid = p_liquid
	vapor = p_vapor

	_image = Image.create(grid.width, grid.height, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)

	_sprite = Sprite2D.new()
	_sprite.texture = _texture
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sprite.scale = Vector2(cell_size, cell_size)
	_sprite.centered = false
	add_child(_sprite)

	_pixel_data = PackedByteArray()
	_pixel_data.resize(grid.width * grid.height * 4)

	_rebuild_color_cache()


func get_renderer_name() -> String:
	return "Debug Pixel"


func cleanup() -> void:
	if _sprite:
		_sprite.queue_free()
		_sprite = null


func _rebuild_color_cache() -> void:
	_color_cache = PackedColorArray()
	_color_cache.resize(SubstanceRegistry.substances.size())
	_color_cache[0] = Color.TRANSPARENT
	for i in range(1, SubstanceRegistry.substances.size()):
		var substance := SubstanceRegistry.get_substance(i)
		if substance:
			_color_cache[i] = substance.base_color
		else:
			_color_cache[i] = Color.MAGENTA


func render() -> void:
	if not grid:
		return

	var size := grid.width * grid.height
	for i in range(size):
		var substance_id: int = grid.cells[i]
		var color: Color

		if substance_id == 0:
			color = Color.TRANSPARENT
		elif substance_id < _color_cache.size():
			color = _color_cache[substance_id]
		else:
			color = Color.MAGENTA

		# Blend liquid on top if present. Scale liquid alpha by density so thin
		# cells are translucent and dense cells are opaque. This makes
		# sparse surface cells fade out gracefully instead of being rendered
		# as solid color.
		if liquid and liquid.markers[i] != 0:
			var liquid_id: int = liquid.markers[i]
			var liquid_color: Color
			if liquid_id < _color_cache.size():
				liquid_color = _color_cache[liquid_id]
			else:
				liquid_color = Color.MAGENTA
			# Scale by density (clamped 0..1). Use sqrt to make low-density
			# cells more visible than linear scaling would (sqrt(0.1)=0.32 vs 0.1).
			var density_factor: float = sqrt(clampf(liquid.densities[i], 0.0, 1.0))
			liquid_color.a *= density_factor
			if color.a > 0:
				color = color.lerp(liquid_color, liquid_color.a)
			else:
				color = liquid_color

		# Blend vapor on top of everything except walls. Vapor uses the
		# substance's base color scaled down to VAPOR_ALPHA_SCALE so it
		# reads as fog rather than solid fill.
		if vapor and vapor.markers[i] != 0:
			var vapor_id: int = vapor.markers[i]
			var vapor_color: Color
			if vapor_id < _color_cache.size():
				vapor_color = _color_cache[vapor_id]
			else:
				vapor_color = Color.MAGENTA
			vapor_color.a *= VAPOR_ALPHA_SCALE
			if color.a > 0:
				color = color.lerp(vapor_color, vapor_color.a)
			else:
				color = vapor_color

		# Boundary walls.
		if grid.boundary[i] == 0:
			color = Color(0.15, 0.13, 0.12, 1.0)

		var offset := i * 4
		_pixel_data[offset] = int(color.r8)
		_pixel_data[offset + 1] = int(color.g8)
		_pixel_data[offset + 2] = int(color.b8)
		_pixel_data[offset + 3] = int(color.a8)

	_image = Image.create_from_data(grid.width, grid.height, false, Image.FORMAT_RGBA8, _pixel_data)
	_texture.update(_image)
