class_name LiquidReadback
extends RefCounted
## CPU-side snapshot of the PIC/FLIP particle fluid solver's per-cell state.
##
## Populated each frame by Receptacle.sync_from_gpu() from the GPU readback
## buffers (density_float, substance). Consumers — renderers, fields, the
## mediator — read from this class instead of reaching into the solver.
##
## This class is a data container with no simulation of its own. It lives
## separately from VaporSim (which holds gas state) because the two sims
## need independent per-cell arrays — when both a liquid and a gas coexist
## in the same cell they don't overwrite each other's state.

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

## Secondary substance id per cell for mixing visualization. 0 = cell is
## homogeneous (all particles share one substance), >0 = cell holds a
## second substance alongside `markers[i]` and renderers should blend
## the two colors. Populated by pflip_p2g when a cell sees particles of
## different substance ids in the same frame. See C1 in the PIC/FLIP
## work notes for the design tradeoffs.
var secondary_markers: PackedInt32Array


func _init(w: int, h: int) -> void:
	width = w
	height = h
	markers = PackedInt32Array()
	markers.resize(w * h)
	densities = PackedFloat32Array()
	densities.resize(w * h)
	secondary_markers = PackedInt32Array()
	secondary_markers.resize(w * h)


func idx(x: int, y: int) -> int:
	return y * width + x


func clear() -> void:
	## Zero all per-cell state. Called by main.gd on reset / containment failure.
	markers.fill(0)
	densities.fill(0.0)
	secondary_markers.fill(0)


func count_occupied_cells() -> int:
	## Number of cells with a non-zero substance marker. O(n), called once
	## per frame for the "has fluid?" gate around mediator.update().
	var count := 0
	for i in range(markers.size()):
		if markers[i] != 0:
			count += 1
	return count
