class_name PolygonRasterizer
extends RefCounted
## Pure CPU utility for rasterizing convex/concave polygons onto a cell grid.
## Used by RigidBodyMgr to build occupancy masks for rigid bodies.


static func rasterize(
	polygon_local: PackedVector2Array,
	body_pos: Vector2,
	body_rotation: float,
	grid_width: int,
	grid_height: int,
	cell_size_px: float,
	out_mask: PackedInt32Array,
	value: int = 1,
) -> void:
	## Rasterize a polygon into a cell occupancy mask.
	## polygon_local: vertices in body-local coordinates.
	## body_pos/body_rotation: transform from local to world space.
	## out_mask: flat array of size grid_width*grid_height; cells inside the
	##           polygon are set to `value` (default 1). Pass a substance_id
	##           to store which body occupies each cell.
	if polygon_local.size() < 3:
		return

	# --- Transform vertices from body-local to world coordinates ---
	var cos_r := cos(body_rotation)
	var sin_r := sin(body_rotation)
	var world_verts := PackedVector2Array()
	world_verts.resize(polygon_local.size())
	for i in polygon_local.size():
		var v := polygon_local[i]
		world_verts[i] = Vector2(
			v.x * cos_r - v.y * sin_r + body_pos.x,
			v.x * sin_r + v.y * cos_r + body_pos.y,
		)

	# --- Compute axis-aligned bounding box of transformed polygon ---
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

	# --- Clamp bbox to grid bounds (in cell coordinates) ---
	var cx_min := maxi(floori(min_x / cell_size_px), 0)
	var cx_max := mini(floori(max_x / cell_size_px), grid_width - 1)
	var cy_min := maxi(floori(min_y / cell_size_px), 0)
	var cy_max := mini(floori(max_y / cell_size_px), grid_height - 1)

	# --- Test each cell center against the polygon ---
	for cy in range(cy_min, cy_max + 1):
		var row_offset := cy * grid_width
		for cx in range(cx_min, cx_max + 1):
			var px := (cx + 0.5) * cell_size_px
			var py := (cy + 0.5) * cell_size_px
			if _point_in_polygon(px, py, world_verts):
				out_mask[row_offset + cx] = value


static func _point_in_polygon(px: float, py: float, verts: PackedVector2Array) -> bool:
	## Even-odd rule: cast a ray from (px,py) toward +x infinity,
	## count edge crossings to determine inside/outside.
	var n := verts.size()
	var inside := false
	var j := n - 1
	for i in n:
		var yi := verts[i].y
		var yj := verts[j].y
		if (yi > py) != (yj > py):
			var xi := verts[i].x
			var xj := verts[j].x
			var x_intersect := xi + (py - yi) / (yj - yi) * (xj - xi)
			if px < x_intersect:
				inside = !inside
		j = i
	return inside


static func polygon_area(verts: PackedVector2Array) -> float:
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
