class_name SubstanceRenderer
extends Sprite2D
## Renders the particle grid as a scaled-up pixel image.
## Each grid cell = 1 pixel in the image, scaled by cell_size on screen.

var grid: ParticleGrid
var cell_size: int = 4  ## Screen pixels per grid cell.
var fluid: FluidSim
var _image: Image
var _texture: ImageTexture
var _pixel_data: PackedByteArray

## Cache substance colors to avoid lookups every pixel every frame.
var _color_cache: PackedColorArray


func setup(p_grid: ParticleGrid, p_cell_size: int = 4, p_fluid: FluidSim = null) -> void:
	grid = p_grid
	cell_size = p_cell_size
	fluid = p_fluid

	_image = Image.create(grid.width, grid.height, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	texture = _texture
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	# Scale sprite so each pixel covers cell_size screen pixels.
	scale = Vector2(cell_size, cell_size)

	# Anchor at top-left.
	centered = false

	_pixel_data = PackedByteArray()
	_pixel_data.resize(grid.width * grid.height * 4)

	_rebuild_color_cache()


func _rebuild_color_cache() -> void:
	_color_cache = PackedColorArray()
	_color_cache.resize(SubstanceRegistry.substances.size())
	_color_cache[0] = Color.TRANSPARENT
	for i in range(1, SubstanceRegistry.substances.size()):
		var substance := SubstanceRegistry.get_substance(i)
		if substance:
			_color_cache[i] = substance.base_color
		else:
			_color_cache[i] = Color.MAGENTA  # Error color.


func render() -> void:
	if not grid:
		return

	var size := grid.width * grid.height
	for i in range(size):
		var substance_id := grid.cells[i]
		var color: Color

		if substance_id == 0:
			color = Color.TRANSPARENT
		elif substance_id < _color_cache.size():
			color = _color_cache[substance_id]
		else:
			color = Color.MAGENTA

		# Blend fluid on top if present.
		if fluid and fluid.markers[i] != 0:
			var fluid_id := fluid.markers[i]
			var fluid_color: Color
			if fluid_id < _color_cache.size():
				fluid_color = _color_cache[fluid_id]
			else:
				fluid_color = Color.MAGENTA
			if color.a > 0:
				color = color.lerp(fluid_color, fluid_color.a)
			else:
				color = fluid_color

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
