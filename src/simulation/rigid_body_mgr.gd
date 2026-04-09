class_name RigidBodyMgr
extends Node2D
## Manages solid objects (RigidBody2D) inside the receptacle.
## Handles creation, displacement of grid cells, and dissolution.

## Converts polygon-area × density (pixel² × relative-density) into a
## RigidBody2D mass value that feels reasonable at the simulation scale.
## Buoyancy uses the same constant so that displaced-liquid force and body
## weight are in the same unit system. Adjust this single knob to tune
## float depth: higher → heavier bodies + stronger buoyancy (ratio stays).
const MASS_SCALE: float = 0.01

## Gravitational acceleration for buoyancy force — must match the gravity
## that Godot's physics engine applies to rigid bodies (default 980 px/s²).
## NOT the fluid sim's internal GRAVITY constant (60 cells/s²) — those are
## different unit systems. The body falls under Godot physics gravity, so
## the buoyancy force must use the same g to balance correctly.
var BUOYANCY_G: float = ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)

## Safety cap: buoyancy force on a body is clamped to this multiple of its
## weight. Prevents numerical blow-up when a body overlaps many dense cells.
const MAX_BUOYANCY_FACTOR: float = 8.0

## Linear drag coefficient. F_drag = -DRAG_COEF × velocity × submerged_cells.
## Damps oscillation of floating bodies using stationary-fluid approximation.
const DRAG_COEF: float = 5.0

var grid: ParticleGrid
var _bodies: Array[RigidBody2D] = []

## Reusable obstacle mask buffer — avoids re-allocation every frame.
var _obstacle_mask_cpu: PackedInt32Array = PackedInt32Array()
var _mask_width: int = 0
var _mask_height: int = 0

## Reference to receptacle for coordinate conversion.
var receptacle_position: Vector2
var cell_size: int


func setup(p_grid: ParticleGrid, p_receptacle_pos: Vector2, p_cell_size: int) -> void:
	grid = p_grid
	receptacle_position = p_receptacle_pos
	cell_size = p_cell_size


func spawn_object(substance_id: int, screen_pos: Vector2) -> void:
	## Creates a RigidBody2D for a solid substance at the given screen position.
	var substance := SubstanceRegistry.get_substance(substance_id)
	if not substance or substance.phase != SubstanceDef.Phase.SOLID:
		return

	# Determine polygon vertices: use substance polygon if available,
	# otherwise fall back to the legacy 30×24 rectangle.
	var verts: PackedVector2Array
	if substance.polygon.size() >= 3:
		verts = substance.polygon
	else:
		verts = PackedVector2Array([
			Vector2(-15, -12),
			Vector2( 15, -12),
			Vector2( 15,  12),
			Vector2(-15,  12),
		])

	var body := RigidBody2D.new()
	body.mass = _polygon_area(verts) * substance.density * MASS_SCALE
	body.gravity_scale = 1.0
	body.position = screen_pos - receptacle_position

	var collision := CollisionPolygon2D.new()
	collision.polygon = verts
	body.add_child(collision)

	var visual := Polygon2D.new()
	visual.polygon = verts
	visual.color = substance.base_color
	body.add_child(visual)

	body.set_meta("substance_id", substance_id)
	body.set_meta("substance_name", substance.substance_name)

	add_child(body)
	_bodies.append(body)


static func _polygon_area(verts: PackedVector2Array) -> float:
	## Returns the unsigned area of a simple polygon using the shoelace formula.
	var n := verts.size()
	if n < 3:
		return 0.0
	var area := 0.0
	for i in n:
		var j := (i + 1) % n
		area += verts[i].x * verts[j].y
		area -= verts[j].x * verts[i].y
	return absf(area) * 0.5


func get_body_count() -> int:
	return _bodies.size()


func dissolve_body(body: RigidBody2D) -> void:
	## Remove a rigid body and spawn particles/fluid in its place.
	var substance_id: int = body.get_meta("substance_id", 0)
	var substance := SubstanceRegistry.get_substance(substance_id)

	if substance:
		var grid_pos := _screen_to_grid(body.global_position)
		var radius := 4
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if dx * dx + dy * dy <= radius * radius:
					grid.spawn_particle(grid_pos.x + dx, grid_pos.y + dy, substance_id)

	_bodies.erase(body)
	body.queue_free()


func _screen_to_grid(screen_pos: Vector2) -> Vector2i:
	var local := screen_pos - receptacle_position
	var gx: int = floori(local.x / float(cell_size))
	var gy: int = floori(local.y / float(cell_size))
	return Vector2i(gx, gy)


func compute_obstacle_mask(grid_width: int, grid_height: int, cell_size_px: float) -> PackedInt32Array:
	## Rasterize every active rigid body into a flat obstacle mask.
	## Returns a PackedInt32Array of size grid_width * grid_height where
	## cells inside any body's polygon are set to 1.
	var n := grid_width * grid_height
	if _mask_width != grid_width or _mask_height != grid_height:
		_obstacle_mask_cpu.resize(n)
		_mask_width = grid_width
		_mask_height = grid_height
	_obstacle_mask_cpu.fill(0)

	for body in _bodies:
		if not is_instance_valid(body):
			continue
		var sub_id: int = body.get_meta("substance_id", 0)
		var sub := SubstanceRegistry.get_substance(sub_id)
		if not sub:
			continue
		var polygon: PackedVector2Array = sub.polygon
		if polygon.size() < 3:
			# Fallback rectangle matching spawn_object fallback.
			polygon = PackedVector2Array([
				Vector2(-15, -12), Vector2(15, -12),
				Vector2(15, 12), Vector2(-15, 12),
			])
		PolygonRasterizer.rasterize(
			polygon,
			body.position,
			body.rotation,
			grid_width,
			grid_height,
			cell_size_px,
			_obstacle_mask_cpu,
		)

	return _obstacle_mask_cpu


func apply_liquid_forces(
	fluid_solver,
	liquid_readback: LiquidReadback,
	ambient: PackedFloat32Array,
	grid_width: int,
	grid_height: int,
	cell_size_px: float,
) -> void:
	## Compute Archimedes buoyancy on each rigid body from displaced liquid.
	## Body cells are WALL (obstacle mask), so liquid_readback.densities is
	## zero inside the body. Instead, we sample the AMBIENT density of each
	## body cell's cardinal neighbors to determine if the cell is submerged.
	## If any neighbor has ambient > 0.01, the cell counts as submerged at
	## the max neighbor density.
	const SUBMERSION_THRESHOLD := 0.01
	for body in _bodies:
		if not is_instance_valid(body):
			continue

		# --- Get substance polygon (with fallback rectangle) ---
		var sub_id: int = body.get_meta("substance_id", 0)
		var sub := SubstanceRegistry.get_substance(sub_id)
		if not sub:
			continue
		var polygon: PackedVector2Array = sub.polygon
		if polygon.size() < 3:
			polygon = PackedVector2Array([
				Vector2(-15, -12), Vector2(15, -12),
				Vector2(15, 12), Vector2(-15, 12),
			])

		# --- Transform polygon vertices to world space ---
		var cos_r := cos(body.rotation)
		var sin_r := sin(body.rotation)
		var world_verts := PackedVector2Array()
		world_verts.resize(polygon.size())
		for i in polygon.size():
			var v := polygon[i]
			world_verts[i] = Vector2(
				v.x * cos_r - v.y * sin_r + body.position.x,
				v.x * sin_r + v.y * cos_r + body.position.y,
			)

		# --- Compute axis-aligned bounding box, clamp to grid ---
		var min_x := world_verts[0].x
		var max_x := world_verts[0].x
		var min_y := world_verts[0].y
		var max_y := world_verts[0].y
		for i in range(1, world_verts.size()):
			var v := world_verts[i]
			if v.x < min_x: min_x = v.x
			if v.x > max_x: max_x = v.x
			if v.y < min_y: min_y = v.y
			if v.y > max_y: max_y = v.y

		var cx_min := maxi(floori(min_x / cell_size_px), 0)
		var cx_max := mini(floori(max_x / cell_size_px), grid_width - 1)
		var cy_min := maxi(floori(min_y / cell_size_px), 0)
		var cy_max := mini(floori(max_y / cell_size_px), grid_height - 1)

		# --- Accumulate displaced liquid mass ---
		var total_mass := 0.0
		var sum_x := 0.0
		var sum_y := 0.0
		var submerged_cells := 0

		for cy in range(cy_min, cy_max + 1):
			var row_offset := cy * grid_width
			for cx in range(cx_min, cx_max + 1):
				var px := (cx + 0.5) * cell_size_px
				var py := (cy + 0.5) * cell_size_px
				if not PolygonRasterizer._point_in_polygon(px, py, world_verts):
					continue
				# Body cells are WALL — no particles inside. Determine
				# submersion by checking cardinal neighbors' ambient density.
				var max_neighbor_density := 0.0
				if cx > 0:
					max_neighbor_density = maxf(max_neighbor_density, ambient[row_offset + cx - 1])
				if cx < grid_width - 1:
					max_neighbor_density = maxf(max_neighbor_density, ambient[row_offset + cx + 1])
				if cy > 0:
					max_neighbor_density = maxf(max_neighbor_density, ambient[(cy - 1) * grid_width + cx])
				if cy < grid_height - 1:
					max_neighbor_density = maxf(max_neighbor_density, ambient[(cy + 1) * grid_width + cx])
				if max_neighbor_density <= SUBMERSION_THRESHOLD:
					continue
				submerged_cells += 1
				var cell_mass: float = max_neighbor_density * cell_size_px * cell_size_px
				total_mass += cell_mass
				sum_x += px * cell_mass
				sum_y += py * cell_mass

		# --- Apply upward buoyancy force at center of buoyant mass ---
		if total_mass > 0.0:
			var center := Vector2(sum_x / total_mass, sum_y / total_mass)
			var force_mag: float = total_mass * BUOYANCY_G * MASS_SCALE
			# Safety clamp to prevent blow-up.
			var max_force: float = MAX_BUOYANCY_FACTOR * body.mass * BUOYANCY_G
			force_mag = minf(force_mag, max_force)
			body.apply_force(Vector2(0, -force_mag), center - body.position)

		# --- Apply linear drag force to damp oscillation ---
		if submerged_cells > 0:
			var drag_force := -body.linear_velocity * DRAG_COEF * float(submerged_cells) * MASS_SCALE
			body.apply_central_force(drag_force)
