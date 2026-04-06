class_name RendererBase
extends Node2D
## Base class for all substance renderers.
## Subclasses must override setup(), render(), get_renderer_name(), and cleanup().


func setup(p_grid: ParticleGrid, p_cell_size: int, p_fluid: FluidSim) -> void:
	pass


func render() -> void:
	pass


func get_renderer_name() -> String:
	return "Base"


func cleanup() -> void:
	pass
