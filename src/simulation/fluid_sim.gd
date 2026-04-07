class_name FluidSim
extends RefCounted
## Marker-and-Cell (MAC) grid fluid simulation for liquids.
## Velocity stored at cell faces, pressure at cell centers.

var width: int
var height: int

## Velocity field: u (horizontal) at left cell face, v (vertical) at top cell face.
var u: PackedFloat32Array  ## (width+1) * height
var v: PackedFloat32Array  ## width * (height+1)

## Pressure field.
var pressure: PackedFloat32Array  ## width * height

## Fluid markers: substance ID per cell. 0 = no fluid.
var markers: PackedInt32Array  ## width * height

## Per-cell density (populated from GPU MAC fluid solver each frame).
## Used by renderers to scale alpha by density (thinner = more translucent).
var densities: PackedFloat32Array  ## width * height

## Boundary mask — shared with particle grid.
var boundary: PackedByteArray

const GRAVITY := 200.0  ## Pixels/s^2 in grid units.
const PRESSURE_ITERATIONS := 20
const OVERRELAX := 1.9  ## SOR overrelaxation factor.


func _init(w: int, h: int) -> void:
	width = w
	height = h
	u = PackedFloat32Array()
	u.resize((w + 1) * h)
	v = PackedFloat32Array()
	v.resize(w * (h + 1))
	pressure = PackedFloat32Array()
	pressure.resize(w * h)
	markers = PackedInt32Array()
	markers.resize(w * h)
	densities = PackedFloat32Array()
	densities.resize(w * h)
	boundary = PackedByteArray()
	boundary.resize(w * h)
	boundary.fill(1)


func idx(x: int, y: int) -> int:
	return y * width + x


func is_valid(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height and boundary[idx(x, y)] == 1


func is_fluid(x: int, y: int) -> bool:
	return is_valid(x, y) and markers[idx(x, y)] != 0


func u_idx(x: int, y: int) -> int:
	## u velocity is stored at left face of cell, grid is (width+1)*height.
	return y * (width + 1) + x


func v_idx(x: int, y: int) -> int:
	## v velocity is stored at top face of cell, grid is width*(height+1).
	return y * width + x


func spawn_fluid(x: int, y: int, substance_id: int) -> bool:
	if is_valid(x, y) and markers[idx(x, y)] == 0:
		markers[idx(x, y)] = substance_id
		return true
	return false


func clear_cell(x: int, y: int) -> void:
	if x >= 0 and x < width and y >= 0 and y < height:
		markers[idx(x, y)] = 0


func count_fluid_cells() -> int:
	var count := 0
	for i in range(markers.size()):
		if markers[i] != 0:
			count += 1
	return count


func update(delta: float) -> void:
	## Full fluid simulation step. Skip if no fluid present.
	if count_fluid_cells() == 0:
		return
	_apply_gravity(delta)
	_project()
	_advect_markers(delta)


func _apply_gravity(delta: float) -> void:
	## Apply gravity to vertical velocity of fluid cells.
	for y in range(height):
		for x in range(width):
			if not is_fluid(x, y):
				continue
			# Add gravity to v at bottom face of this cell.
			v[v_idx(x, y + 1)] += GRAVITY * delta


func _project() -> void:
	## Pressure projection: make velocity field divergence-free.
	## Uses Gauss-Seidel with SOR (successive over-relaxation).
	pressure.fill(0.0)

	for _iter in range(PRESSURE_ITERATIONS):
		for y in range(height):
			for x in range(width):
				if not is_fluid(x, y):
					continue

				# Count open neighbors (not wall).
				var s_left := 1.0 if is_valid(x - 1, y) else 0.0
				var s_right := 1.0 if is_valid(x + 1, y) else 0.0
				var s_top := 1.0 if is_valid(x, y - 1) else 0.0
				var s_bottom := 1.0 if is_valid(x, y + 1) else 0.0
				var s_total := s_left + s_right + s_top + s_bottom
				if s_total == 0.0:
					continue

				# Divergence at this cell.
				var div: float = u[u_idx(x + 1, y)] - u[u_idx(x, y)] + v[v_idx(x, y + 1)] - v[v_idx(x, y)]

				# Pressure correction.
				var p := -div / s_total * OVERRELAX
				pressure[idx(x, y)] += p

				# Apply to velocities.
				u[u_idx(x, y)] -= s_left * p
				u[u_idx(x + 1, y)] += s_right * p
				v[v_idx(x, y)] -= s_top * p
				v[v_idx(x, y + 1)] += s_bottom * p

	# Zero out velocities at boundary walls.
	for y in range(height):
		for x in range(width):
			if not is_valid(x, y):
				# Zero all adjacent velocities.
				u[u_idx(x, y)] = 0.0
				u[u_idx(x + 1, y)] = 0.0
				v[v_idx(x, y)] = 0.0
				v[v_idx(x, y + 1)] = 0.0


func _advect_markers(delta: float) -> void:
	## Move fluid markers through the velocity field using semi-Lagrangian advection.
	var new_markers := PackedInt32Array()
	new_markers.resize(width * height)

	for y in range(height):
		for x in range(width):
			if not is_fluid(x, y):
				continue

			var substance_id: int = markers[idx(x, y)]

			# Get velocity at cell center (average of face velocities).
			var vx: float = (u[u_idx(x, y)] + u[u_idx(x + 1, y)]) * 0.5
			var vy: float = (v[v_idx(x, y)] + v[v_idx(x, y + 1)]) * 0.5

			# Target position (where this fluid moves to).
			var tx := int(roundf(float(x) + vx * delta))
			var ty := int(roundf(float(y) + vy * delta))

			# Clamp to grid.
			tx = clampi(tx, 0, width - 1)
			ty = clampi(ty, 0, height - 1)

			if is_valid(tx, ty) and new_markers[idx(tx, ty)] == 0:
				new_markers[idx(tx, ty)] = substance_id
			elif is_valid(x, y) and new_markers[idx(x, y)] == 0:
				# Can't move — stay in place.
				new_markers[idx(x, y)] = substance_id

	markers = new_markers
