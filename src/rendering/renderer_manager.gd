class_name RendererManager
extends Node
## Manages swappable rendering backends.
## F5 cycles between registered renderers. Only one is active at a time.

var _renderer_classes: Array[GDScript] = []
var _renderer_names: Array[String] = []
var _current_index: int = 0
var _active_renderer: RendererBase

var _grid: ParticleGrid
var _cell_size: int
var _liquid: LiquidReadback
var _vapor: VaporSim
var _parent_node: Node2D  ## Receptacle — renderers are added as children of this.


func setup(parent: Node2D, grid: ParticleGrid, cell_size: int, liquid: LiquidReadback, vapor: VaporSim = null) -> void:
	_parent_node = parent
	_grid = grid
	_cell_size = cell_size
	_liquid = liquid
	_vapor = vapor

	# Register available renderers.
	_register(SubstanceRenderer, "Debug Pixel")
	_register(MultiLayerRenderer, "Multi-Layer")
	_register(DensityFieldRenderer, "Density Field")
	_register(MarchingSquaresRenderer, "Marching Squares")

	# Activate the first renderer.
	_activate(0)


func _register(renderer_class: GDScript, display_name: String) -> void:
	_renderer_classes.append(renderer_class)
	_renderer_names.append(display_name)


func _activate(index: int) -> void:
	# Clean up current renderer.
	if _active_renderer:
		_active_renderer.cleanup()
		_parent_node.remove_child(_active_renderer)
		_active_renderer.queue_free()
		_active_renderer = null

	# Create new renderer.
	_current_index = index
	_active_renderer = _renderer_classes[index].new() as RendererBase
	_parent_node.add_child(_active_renderer)
	# Move to index 0 so it renders below field_renderer and other children.
	_parent_node.move_child(_active_renderer, 0)
	_active_renderer.setup(_grid, _cell_size, _liquid, _vapor)

	print("Renderer switched to: %s" % _renderer_names[index])


func cycle_renderer() -> void:
	var next_index := (_current_index + 1) % _renderer_classes.size()
	_activate(next_index)


func render() -> void:
	if _active_renderer:
		_active_renderer.render()


func get_current_name() -> String:
	if _current_index < _renderer_names.size():
		return _renderer_names[_current_index]
	return "Unknown"
