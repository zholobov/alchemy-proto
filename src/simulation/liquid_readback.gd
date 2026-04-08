class_name LiquidReadback
extends RefCounted
## CPU-side snapshot of the PIC/FLIP particle fluid solver's per-cell state.
##
## Populated each frame by Receptacle.sync_from_gpu() from the GPU readback
## buffers (density_float, substance). Consumers — renderers, fields, the
## mediator — read from this class instead of reaching into the solver.
##
## This class is a data container with no simulation of its own. It was
## extracted from the old FluidSim class so that FluidSim can be repurposed
## as VaporSim (gas/fog/steam grid simulator) without fighting with the
## liquid readback path writing to the same arrays.

var width: int
var height: int

## Substance id per cell. 0 = no liquid present in this cell.
## Populated from the GPU substance buffer; cells with density below
## Receptacle.VISIBLE_THRESHOLD are written as 0 here.
var markers: PackedInt32Array

## Normalized density per cell. 0.0 = none, 1.0 = target density
## (PARTICLES_PER_CELL particles occupying one cell). Renderers use this
## to scale alpha so thin liquid regions fade out instead of popping.
var densities: PackedFloat32Array


func _init(w: int, h: int) -> void:
	width = w
	height = h
	markers = PackedInt32Array()
	markers.resize(w * h)
	densities = PackedFloat32Array()
	densities.resize(w * h)


func idx(x: int, y: int) -> int:
	return y * width + x


func clear() -> void:
	## Zero all per-cell state. Called by main.gd on reset / containment failure.
	markers.fill(0)
	densities.fill(0.0)


func count_occupied_cells() -> int:
	## Number of cells with a non-zero substance marker. O(n), called once
	## per frame for the "has fluid?" gate around mediator.update().
	var count := 0
	for i in range(markers.size()):
		if markers[i] != 0:
			count += 1
	return count
