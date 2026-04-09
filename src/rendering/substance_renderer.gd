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

	# Cache array refs outside the loop to avoid per-iteration property lookups.
	var cells := grid.cells
	var boundary := grid.boundary
	var size := cells.size()
	var cache := _color_cache
	var cache_size := cache.size()
	var has_liquid := liquid != null
	var liq_markers: PackedInt32Array
	var liq_densities: PackedFloat32Array
	var liq_secondary: PackedInt32Array
	if has_liquid:
		liq_markers = liquid.markers
		liq_densities = liquid.densities
		liq_secondary = liquid.secondary_markers
	var has_vapor := vapor != null
	var vap_markers: PackedInt32Array
	if has_vapor:
		vap_markers = vapor.markers
	var pd := _pixel_data

	for i in range(size):
		var substance_id: int = cells[i]
		var color: Color

		if substance_id == 0:
			color = Color.TRANSPARENT
		elif substance_id < cache_size:
			color = cache[substance_id]
		else:
			color = Color.MAGENTA

		if has_liquid and liq_markers[i] != 0:
			var liquid_id: int = liq_markers[i]
			var liquid_color: Color = cache[liquid_id] if liquid_id < cache_size else Color.MAGENTA
			var secondary_id: int = liq_secondary[i]
			if secondary_id > 0 and secondary_id < cache_size:
				liquid_color = liquid_color.lerp(cache[secondary_id], 0.5)
			var density_factor: float = sqrt(clampf(liq_densities[i], 0.0, 1.0))
			liquid_color.a *= density_factor
			if color.a > 0:
				color = color.lerp(liquid_color, liquid_color.a)
			else:
				color = liquid_color

		if has_vapor and vap_markers[i] != 0:
			var vapor_id: int = vap_markers[i]
			var vapor_color: Color = cache[vapor_id] if vapor_id < cache_size else Color.MAGENTA
			vapor_color.a *= VAPOR_ALPHA_SCALE
			if color.a > 0:
				color = color.lerp(vapor_color, vapor_color.a)
			else:
				color = vapor_color

		if boundary[i] == 0:
			color = Color(0.15, 0.13, 0.12, 1.0)

		var offset := i * 4
		pd[offset] = color.r8
		pd[offset + 1] = color.g8
		pd[offset + 2] = color.b8
		pd[offset + 3] = color.a8

	# Reuse the existing Image instead of reallocating every frame.
	# set_data() updates pixel data in-place (no new allocation).
	_image.set_data(grid.width, grid.height, false, Image.FORMAT_RGBA8, _pixel_data)
	_texture.update(_image)
