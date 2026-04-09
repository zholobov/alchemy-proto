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
const DRAG_COEF: float = 300.0

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


func inject_render_cells(grid: ParticleGrid, grid_width: int, grid_height: int, cell_size_px: float) -> void:
	## Write body substance_ids into grid.cells so the cell-based
	## renderer draws rigid bodies the same as everything else. Call
	## AFTER mediator.update() (so reactions see clean grid) and BEFORE
	## renderer.render(). sync_from_gpu() overwrites grid.cells next
	## frame, so this is a transient injection — no persistent state.
	for body in _bodies:
		if not is_instance_valid(body):
			continue
		var sub_id: int = body.get_meta("substance_id", 0)
		if sub_id <= 0:
			continue
		var sub := SubstanceRegistry.get_substance(sub_id)
		if not sub:
			continue
		var polygon: PackedVector2Array = sub.polygon
		if polygon.size() < 3:
			polygon = PackedVector2Array([
				Vector2(-15, -12), Vector2(15, -12), Vector2(15, 12), Vector2(-15, 12)
			])
		# Transform polygon to world space.
		var cos_r := cos(body.rotation)
		var sin_r := sin(body.rotation)
		var n := polygon.size()
		var world_verts := PackedVector2Array()
		world_verts.resize(n)
		var min_x := INF
		var max_x := -INF
		var min_y := INF
		var max_y := -INF
		for i in range(n):
			var v := polygon[i]
			var wv := Vector2(
				body.position.x + v.x * cos_r - v.y * sin_r,
				body.position.y + v.x * sin_r + v.y * cos_r,
			)
			world_verts[i] = wv
			if wv.x < min_x: min_x = wv.x
			elif wv.x > max_x: max_x = wv.x
			if wv.y < min_y: min_y = wv.y
			elif wv.y > max_y: max_y = wv.y
		var cx_min := maxi(floori(min_x / cell_size_px), 0)
		var cx_max := mini(floori(max_x / cell_size_px), grid_width - 1)
		var cy_min := maxi(floori(min_y / cell_size_px), 0)
		var cy_max := mini(floori(max_y / cell_size_px), grid_height - 1)
		for cy in range(cy_min, cy_max + 1):
			var py := (cy + 0.5) * cell_size_px
			for cx in range(cx_min, cx_max + 1):
				var px := (cx + 0.5) * cell_size_px
				if PolygonRasterizer._point_in_polygon(px, py, world_verts):
					grid.cells[cy * grid_width + cx] = sub_id


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

		var fluid_density := 0.0
		var surface_py := float(grid_height) * cell_size_px  # default: no water

		for ref_cx in ref_candidates:
			for ry in range(grid_height):
				var ridx := ry * grid_width + ref_cx
				if liquid_readback.densities[ridx] > 0.15:
					surface_py = float(ry) * cell_size_px
					var marker: int = liquid_readback.markers[ridx]
					if marker > 0:
						var lsub := SubstanceRegistry.get_substance(marker)
						if lsub:
							fluid_density = lsub.density
					break
			if fluid_density > 0.0:
				break  # found liquid at this column — done

		# --- Count body cells below the fluid surface ---
		var total_mass := 0.0
		var sum_x := 0.0
		var sum_y := 0.0
		var submerged_cells := 0

		if fluid_density > 0.0:
			for cy in range(cy_min, cy_max + 1):
				var py := (cy + 0.5) * cell_size_px
				if py < surface_py:
					continue  # above fluid surface — not submerged
				for cx in range(cx_min, cx_max + 1):
					var px := (cx + 0.5) * cell_size_px
					if not PolygonRasterizer._point_in_polygon(px, py, world_verts):
						continue
					submerged_cells += 1
					var cell_mass := fluid_density * cell_size_px * cell_size_px
					total_mass += cell_mass
					sum_x += px * cell_mass
					sum_y += py * cell_mass

		# --- Apply gravity + buoyancy as a persistent net force ---
		# We disabled Godot's built-in gravity (gravity_scale=0) so we can
		# combine gravity and buoyancy in the same code path. Using
		# constant_force (persistent) instead of apply_force (instantaneous)
		# because apply_force from _process() gets cleared before the next
		# _physics_process() can consume it.
		var gravity_force := body.mass * BUOYANCY_G  # weight, downward
		var buoyancy_force := total_mass * BUOYANCY_G * MASS_SCALE  # upward
		buoyancy_force = minf(buoyancy_force, MAX_BUOYANCY_FACTOR * gravity_force)
		var net_y := gravity_force - buoyancy_force  # positive = down

# --- Set forces ---
		# constant_force carries gravity + buoyancy (position-dependent).
		# linear_damp carries drag (velocity-dependent) — Godot applies
		# this INSIDE the physics integrator so there's no 1-frame lag
		# and no overshoot/divergence from stale velocity values.
		body.constant_force = Vector2(0, net_y)

		if debug_buoyancy and Engine.get_process_frames() % 60 == 0:
			print("[BUOY] %s: Y=%.0f vel=%.0f sub=%d surf=%.0f dens=%.2f buoy=%.0f grav=%.0f net=%.0f mass=%.2f" % [
				body.get_meta("substance_name", "?"),
				body.global_position.y, body.linear_velocity.y,
				submerged_cells, surface_py, fluid_density,
				buoyancy_force, gravity_force, net_y, body.mass])

		if submerged_cells > 0:
			# linear_damp in Godot = velocity decay fraction per second.
			# At damp=30, velocity halves in ~0.023s (≈1.4 frames). Strong
			# but stable because Godot integrates it within the step.
			body.linear_damp = DRAG_COEF * float(submerged_cells) * MASS_SCALE / maxf(body.mass, 0.01)
			# Angular damping prevents rotational oscillation from the
			# restoring torque. Same scaling as linear damp.
			body.angular_damp = DRAG_COEF * float(submerged_cells) * MASS_SCALE / maxf(body.mass, 0.01)
		else:
			body.linear_damp = 0.5
			body.angular_damp = 0.5

		# Torque from asymmetric submersion (tilts the body like a boat).
		# Scaled down (TORQUE_SCALE) so it's a gentle righting hint, and
		# smoothed via lerp to kill frame-to-frame jitter from the
		# discretized submerged-cell set changing as the body rocks.
		if total_mass > 0.0:
			var center := Vector2(sum_x / total_mass, sum_y / total_mass)
			var offset := center - body.global_position
			var target_torque := offset.x * net_y * TORQUE_SCALE
			body.constant_torque = lerpf(body.constant_torque, target_torque, TORQUE_SMOOTHING)
		else:
			body.constant_torque = lerpf(body.constant_torque, 0.0, TORQUE_SMOOTHING)
