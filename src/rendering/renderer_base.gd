class_name RendererBase
extends Node2D
## Base class for all substance renderers.
## Subclasses must override setup(), render(), get_renderer_name(), and cleanup().


func setup(_p_grid: ParticleGrid, _p_cell_size: int, _p_liquid: LiquidReadback) -> void:
	pass


func render() -> void:
	pass


func get_renderer_name() -> String:
	return "Base"


func cleanup() -> void:
	pass
