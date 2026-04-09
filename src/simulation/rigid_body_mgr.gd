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
## Tuned for near-critical damping so floating bodies settle without
## oscillating. The system is spring-like (buoyancy ∝ depth), and
## critical damping requires c ≈ 2√(k·m) ≈ 75 for a wood block.
## Effective c = DRAG_COEF × submerged_cells × MASS_SCALE ≈ 150×45×0.01 = 67.
## Slightly underdamped → body settles with ≤1 gentle overshoot.
## Reduced from 300 to 60 so marginally buoyant objects (ice, density
## 0.92 = 8% excess) rise at visible speed. Terminal velocities:
##   Ice:  85.7 / 4.1 = 21 px/s (reaches surface in ~10s)
##   Wood: 343  / 5.5 = 62 px/s (reaches surface in ~1s)
## Wood oscillation is now controlled by torque smoothing + angular
## damping, not by extreme linear drag.
const DRAG_COEF: float = 60.0

## Drag scales up with buoyancy margin: |1 - ρ_body/ρ_fluid|.
## Wood (margin 0.35): damp_scale = 1 + 0.35×10 = 4.5 → effective high
## Ice  (margin 0.08): damp_scale = 1 + 0.08×10 = 1.8 → effective low
## This lets ice rise visibly while wood settles without bouncing.
## Raised from 10 to 40 so heavy bodies in dense fluids (iron in
## mercury: mass=35, only 28 submerged cells) get enough damping.
## The effective damp = DRAG_COEF × (1 + margin × SCALE) × cells ×
## MASS_SCALE / mass. Heavy-small-polygon bodies need a large SCALE
## to compensate for the mass/area ratio.
const DRAG_BUOYANCY_SCALE: float = 40.0

## Torque from asymmetric submersion is scaled down by this factor.
## Raw torque is very strong (offset_px × net_force); 0.02 makes it a
## gentle righting hint that takes ~1 second to correct a 30° tilt.
const TORQUE_SCALE: float = 0.02

## Lerp factor for smoothing torque between frames. Low values (0.05–0.1)
## act as a low-pass filter that kills jitter from the discretized
## submerged-cell set changing frame to frame. Higher = more responsive
## but more jittery.
const TORQUE_SMOOTHING: float = 0.08

var grid: ParticleGrid
var _bodies: Array[RigidBody2D] = []
## Set to true to print per-frame buoyancy diagnostics to stdout.
## Toggle via the B-key scenario in main.gd.
var debug_buoyancy: bool = false

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
	# Disable Godot's built-in gravity. We apply gravity manually in
	# apply_liquid_forces() together with buoyancy, so both forces use
	# the same code path and timing — avoids the _process vs
	# _physics_process phase mismatch that made buoyancy ineffective.
	body.gravity_scale = 0.0
	body.position = screen_pos - receptacle_position

	var collision := CollisionPolygon2D.new()
	collision.polygon = verts
	body.add_child(collision)

	# No Polygon2D visual — rigid bodies are rendered cell-based by
	# inject_render_cells(), which writes their substance_id into
	# grid.cells so they're drawn by the same renderer as everything else.

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


func inject_render_cells(grid: ParticleGrid, liquid_readback: LiquidReadback) -> void:
	## Copy body substance_ids from _obstacle_mask_cpu into grid.cells
	## so the cell-based renderer draws rigid bodies the same as
	## everything else. Also clears liquid_readback at body cells so the
	## renderer doesn't blend residual water color on top of the body.
	##
	## Uses the SAME rasterized cell set as the obstacle mask (same body
	## transforms, same frame). Call AFTER mediator and BEFORE renderer.
	var n := mini(_obstacle_mask_cpu.size(), grid.cells.size())
	for i in range(n):
		if _obstacle_mask_cpu[i] > 0:
			grid.cells[i] = _obstacle_mask_cpu[i]
			# Clear liquid/vapor at body cells — prevents the renderer
			# from alpha-blending stale water/vapor data on top of the
			# body's grid color. Particles take a few frames to escape
			# newly-occupied cells, leaving residual readback data.
			if i < liquid_readback.markers.size():
				liquid_readback.markers[i] = 0
				liquid_readback.densities[i] = 0.0
				liquid_readback.secondary_markers[i] = 0


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
		# Store substance_id (not just 1) so inject_render_cells can
		# copy from the mask without re-rasterizing. The GPU shader
		# checks obstacle_mask > 0u which works for any non-zero value.
		PolygonRasterizer.rasterize(
			polygon,
			body.position,
			body.rotation,
			grid_width,
			grid_height,
			cell_size_px,
			_obstacle_mask_cpu,
			sub_id,
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

		# --- Find fluid surface and density from REFERENCE COLUMN ---
		# The body displaces water from nearby cells, so we can't sample
		# the body's bbox for surface/density — it's disrupted. Instead,
		# scan a reference column FAR from the body to find the undisturbed
		# fluid surface Y and density. Try multiple candidates because the
		# oval receptacle narrows at the edges — some columns may be walls.
		var ref_candidates: Array[int] = []
		# Prefer columns well inside the oval: 1/4 and 3/4 of grid width,
		# then center, then edges. Skip any that overlap the body's bbox.
		for c in [grid_width / 4, grid_width * 3 / 4, grid_width / 2, 30, grid_width - 30]:
			if c < cx_min - 5 or c > cx_max + 5:
				ref_candidates.append(c)
		# If ALL candidates overlap the body (huge body or bad luck), just
		# use the first candidate anyway — some data is better than none.
		if ref_candidates.is_empty():
			ref_candidates.append(grid_width / 4)

		# Find the fluid surface Y (topmost liquid row in a reference column).
		var ref_cx := ref_candidates[0]
		var surface_py := float(grid_height) * cell_size_px  # default: no water
		var found_liquid := false

		for c in ref_candidates:
			for ry in range(grid_height):
				var ridx := ry * grid_width + c
				if liquid_readback.densities[ridx] > 0.15:
					surface_py = float(ry) * cell_size_px
					ref_cx = c
					found_liquid = true
					break
			if found_liquid:
				break

		# --- Count body cells below the fluid surface ---
		# --- Hydrostatic pressure integration over body surface ---
		#
		# Two pressure sources per body column cx:
		#   TOP face: from ACTUAL fluid directly above the body at column cx.
		#     This captures locally-poured mercury pressing down on the block.
		#   BOTTOM face: from REFERENCE column (undisturbed). In an
		#     incompressible fluid, pressure at any depth equilibrates
		#     horizontally, so the reference column gives the correct
		#     bottom-face pressure regardless of what's on top of the body.
		#
		# Net: buoyancy when bottom_p > top_p. Mercury-on-wood adds to top_p
		# → less net upward → block sinks deeper. Asymmetric mercury (poured
		# on one side) creates asymmetric top_p → torque → block tilts.

		# Reference column pressure (for bottom faces).
		var pressure_ref := PackedFloat32Array()
		pressure_ref.resize(grid_height + 1)
		var cumulative_p := 0.0
		var surface_row := int(surface_py / cell_size_px) if found_liquid else grid_height
		for ry in range(grid_height):
			pressure_ref[ry] = cumulative_p
			if ry >= surface_row:
				var ref_idx := ry * grid_width + ref_cx
				if ref_idx < liquid_readback.markers.size():
					var marker: int = liquid_readback.markers[ref_idx]
					if marker > 0:
						var lsub := SubstanceRegistry.get_substance(marker)
						if lsub:
							cumulative_p += lsub.density * cell_size_px * BUOYANCY_G * MASS_SCALE
		pressure_ref[grid_height] = cumulative_p

		var pressure_force_y := 0.0
		var pressure_torque := 0.0
		var submerged_cells := 0
		var mask := _obstacle_mask_cpu
		var mask_size := mask.size()
		var markers := liquid_readback.markers
		var markers_size := markers.size()

		# Process each body column: compute actual top pressure, then
		# integrate top/bottom face contributions.
		for cx in range(cx_min, cx_max + 1):
			var px := (cx + 0.5) * cell_size_px
			var arm_x := px - body.position.x

			# Find topmost and bottommost body cells in this column.
			var top_cy := -1
			var bot_cy := -1
			for cy in range(cy_min, cy_max + 1):
				var py := (cy + 0.5) * cell_size_px
				if PolygonRasterizer._point_in_polygon(px, py, world_verts):
					if top_cy == -1:
						top_cy = cy
					bot_cy = cy

			if top_cy == -1:
				continue  # no body cells in this column

			# Actual top pressure: scan fluid directly above this column.
			# Captures mercury poured locally onto the body.
			var p_top_actual := 0.0
			for ry in range(surface_row, top_cy):
				var ridx := ry * grid_width + cx
				if ridx < markers_size:
					var marker: int = markers[ridx]
					if marker > 0:
						var lsub := SubstanceRegistry.get_substance(marker)
						if lsub:
							p_top_actual += lsub.density * cell_size_px * BUOYANCY_G * MASS_SCALE

			# Top face: actual pressure pushes DOWN.
			pressure_force_y += p_top_actual * cell_size_px
			pressure_torque += arm_x * p_top_actual * cell_size_px

			# Bottom face: reference pressure pushes UP — but ONLY if fluid
			# exists nearby below the body. Without this check, the reference
			# column provides phantom buoyancy when local water has drained.
			# Check a small neighborhood (±3 cells horizontal, +1..+3 cells
			# below) to avoid oscillation from the body displacing its own
			# support in the cells directly beneath it.
			var has_fluid_below := false
			for check_dy in range(1, 4):
				if has_fluid_below:
					break
				var check_row := bot_cy + check_dy
				if check_row >= grid_height:
					break
				for check_dx in range(-3, 4):
					var check_cx := cx + check_dx
					if check_cx < 0 or check_cx >= grid_width:
						continue
					var check_idx := check_row * grid_width + check_cx
					if check_idx < markers_size and markers[check_idx] > 0:
						# Verify this isn't another body's cell
						if check_idx >= mask_size or mask[check_idx] == 0:
							has_fluid_below = true
							break
			if has_fluid_below:
				var p_bot_ref := pressure_ref[mini(bot_cy + 1, grid_height)]
				pressure_force_y -= p_bot_ref * cell_size_px
				pressure_torque -= arm_x * p_bot_ref * cell_size_px

			# Count submerged cells in this column for drag.
			for cy in range(top_cy, bot_cy + 1):
				var py := (cy + 0.5) * cell_size_px
				if py >= surface_py:
					submerged_cells += 1

		# --- Apply gravity + pressure force ---
		var gravity_force := body.mass * BUOYANCY_G
		var net_y := gravity_force + pressure_force_y  # pressure_force_y is net (positive=down from top, negative=up from bottom)
		# Safety clamp.
		var max_net := MAX_BUOYANCY_FACTOR * gravity_force
		net_y = clampf(net_y, -max_net, max_net)

		body.constant_force = Vector2(0, net_y)

		# Average fluid density for drag (approximate from pressure at body center).
		var body_center_row := clampi((cy_min + cy_max) / 2, 0, grid_height - 1)
		var avg_fluid_density := 0.0
		if body_center_row < grid_height:
			var ref_idx := body_center_row * grid_width + ref_cx
			if ref_idx < liquid_readback.markers.size():
				var marker: int = liquid_readback.markers[ref_idx]
				if marker > 0:
					var lsub := SubstanceRegistry.get_substance(marker)
					if lsub:
						avg_fluid_density = lsub.density

		if debug_buoyancy and Engine.get_process_frames() % 60 == 0:
			print("[BUOY] %s: Y=%.0f vel=%.0f sub=%d surf=%.0f dens=%.2f pforce=%.0f grav=%.0f net=%.0f mass=%.2f" % [
				body.get_meta("substance_name", "?"),
				body.global_position.y, body.linear_velocity.y,
				submerged_cells, surface_py, avg_fluid_density,
				pressure_force_y, gravity_force, net_y, body.mass])

		if submerged_cells > 0:
			var density_ratio := sub.density / maxf(avg_fluid_density, 0.01)
			var buoyancy_margin: float
			if density_ratio <= 1.0:
				buoyancy_margin = 1.0 - density_ratio
			else:
				buoyancy_margin = 0.2
			var damp_scale := 1.0 + buoyancy_margin * DRAG_BUOYANCY_SCALE
			var effective_damp := DRAG_COEF * damp_scale * float(submerged_cells) * MASS_SCALE / maxf(body.mass, 0.01)
			body.linear_damp = effective_damp
			body.angular_damp = effective_damp
		else:
			body.linear_damp = 0.5
			body.angular_damp = 0.5

		# Torque from pressure asymmetry (tilts the body).
		var target_torque := pressure_torque * TORQUE_SCALE
		body.constant_torque = lerpf(body.constant_torque, target_torque, TORQUE_SMOOTHING)
