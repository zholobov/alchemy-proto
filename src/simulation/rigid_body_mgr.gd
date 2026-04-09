class_name RigidBodyMgr
extends Node2D
## Manages solid objects (RigidBody2D) inside the receptacle.
## Handles creation, displacement of grid cells, and dissolution.

## Converts polygon-area × density (pixel² × relative-density) into a
## RigidBody2D mass value that feels reasonable at the simulation scale.
const MASS_SCALE: float = 0.01

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
