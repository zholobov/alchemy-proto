class_name MarchingSquaresRenderer
extends RendererBase
## Marching squares renderer. Extracts smooth contour polygons from grid data,
## fills with substance colors, draws anti-aliased outlines.

var grid: ParticleGrid
var cell_size: int = 4
var liquid: LiquidReadback

var _density: PackedFloat32Array
var _color_cache: PackedColorArray

const THRESHOLD := 0.3
const OUTLINE_COLOR := Color(0.2, 0.18, 0.15, 0.6)
const OUTLINE_WIDTH := 1.5


func setup(p_grid: ParticleGrid, p_cell_size: int = 4, p_liquid: LiquidReadback = null) -> void:
	grid = p_grid
	cell_size = p_cell_size
	liquid = p_liquid
	_density = PackedFloat32Array()
	_density.resize(grid.width * grid.height)

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
	return "Marching Squares"


func cleanup() -> void:
	pass


func render() -> void:
	if not grid:
		return
	queue_redraw()


func _draw() -> void:
	if not grid:
		return

	var w := grid.width
	var h := grid.height
	var size := w * h
	var cs := float(cell_size)

	# Draw boundary walls first
	for y in range(h):
		for x in range(w):
			if grid.boundary[y * w + x] == 0:
				draw_rect(Rect2(Vector2(x, y) * cs, Vector2(cs, cs)),
					Color(0.15, 0.13, 0.12, 1.0))

	# Find active substances
	var active_substances: Dictionary = {}
	for i in range(size):
		var sid: int = grid.cells[i]
		if sid > 0:
			active_substances[sid] = true
		if liquid and liquid.markers[i] > 0:
			var fid: int = liquid.markers[i]
			active_substances[fid] = true

	# Process each substance
	for sid in active_substances:
		var color: Color = _color_cache[sid] if sid < _color_cache.size() else Color.MAGENTA

		# Build density field
		_density.fill(0.0)
		for i in range(size):
			if grid.cells[i] == sid or (liquid and liquid.markers[i] == sid):
				_density[i] = 1.0

		# Simple blur (1 pass) for smoother contours
		var blurred := PackedFloat32Array()
		blurred.resize(size)
		for y in range(h):
			for x in range(w):
				var sum := 0.0
				var count := 0.0
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						var nx := x + dx
						var ny := y + dy
						if nx >= 0 and nx < w and ny >= 0 and ny < h:
							sum += _density[ny * w + nx]
							count += 1.0
				blurred[y * w + x] = sum / count

		# Draw filled cells
		for y in range(h):
			for x in range(w):
				if blurred[y * w + x] >= THRESHOLD:
					var pos := Vector2(float(x) * cs, float(y) * cs)
					draw_rect(Rect2(pos, Vector2(cs, cs)), color)

		# Extract and draw contour outlines
		var segments := MarchingSquares.extract_contour_segments(blurred, w, h, THRESHOLD)
		for i in range(0, segments.size() - 1, 2):
			var p1 := segments[i] * cs
			var p2 := segments[i + 1] * cs
			draw_line(p1, p2, OUTLINE_COLOR, OUTLINE_WIDTH, true)
