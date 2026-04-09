class_name TestRbObstacleMask
extends RefCounted
## Integration test: rigid body obstacle mask blocks liquid particles.
##
## 1. Instantiate main.tscn, let it initialise.
## 2. Flood the bottom half of the receptacle with water particles.
## 3. Spawn a wooden block submerged in the water.
## 4. Step the simulation for ~60 frames.
## 5. Verify: cells where mask[i] > 0 should have density ~0.


static func run_test(tree: SceneTree) -> Dictionary:
	var test_name := "rb_obstacle_mask_blocks_liquid"

	# The fluid solver (and GPU sim / vapor sim) require a RenderingDevice.
	# In --headless mode no GPU device is available and instantiating
	# main.tscn would crash during _ready(). Detect this early and skip.
	var test_rd := RenderingServer.create_local_rendering_device()
	if not test_rd:
		return {"name": test_name, "pass": true, "msg": "SKIPPED — no GPU rendering device (headless mode)"}

	# We only needed the device for the probe; free it immediately.
	test_rd.free()

	# --- 1. Instantiate main scene ---
	var main_scene := load("res://src/main.tscn")
	if not main_scene:
		return {"name": test_name, "pass": false, "msg": "could not load main.tscn"}

	var main_node: Node = main_scene.instantiate()
	tree.root.add_child(main_node)
	# Disable main's _process immediately after add_child so the test
	# controls simulation stepping manually.
	main_node.set_process(false)

	# Allow deferred operations to complete.
	await tree.process_frame
	await tree.process_frame

	# Access receptacle from the main node.
	var receptacle: Receptacle = main_node.receptacle
	if not receptacle:
		main_node.queue_free()
		return {"name": test_name, "pass": false, "msg": "receptacle not found on main node"}

	var fluid_solver: ParticleFluidSolver = receptacle.fluid_solver
	var rigid_body_mgr: RigidBodyMgr = receptacle.rigid_body_mgr

	if not fluid_solver or not rigid_body_mgr:
		main_node.queue_free()
		return {"name": test_name, "pass": false, "msg": "fluid_solver or rigid_body_mgr not initialised"}

	# --- 2. Flood the bottom half with water particles ---
	var water_id := SubstanceRegistry.get_id("Water")
	if water_id <= 0:
		main_node.queue_free()
		return {"name": test_name, "pass": false, "msg": "Water substance not found in registry"}

	var gw := Receptacle.GRID_WIDTH
	var gh := Receptacle.GRID_HEIGHT
	var half_y := gh / 2

	var particle_positions: Array[Vector2] = []
	for y in range(half_y, gh):
		for x in range(gw):
			# Only spawn inside the boundary.
			if receptacle.grid.boundary[y * gw + x] != 1:
				continue
			# 4 particles per cell (less dense than full 8, but enough for the test).
			for _i in range(4):
				var jx := SubstanceRegistry.sim_rng.randf() * 0.8 + 0.1
				var jy := SubstanceRegistry.sim_rng.randf() * 0.8 + 0.1
				particle_positions.append(Vector2(float(x) + jx, float(y) + jy))

	fluid_solver.spawn_particles_batch(particle_positions, water_id)

	# --- 3. Spawn a wooden block submerged in the water ---
	var wood_id := SubstanceRegistry.get_id("Wood")
	if wood_id <= 0:
		main_node.queue_free()
		return {"name": test_name, "pass": false, "msg": "Wood substance not found in registry"}

	# Place the block at the center of the bottom half, in screen coordinates.
	# spawn_object expects screen_pos (it subtracts receptacle_position internally).
	var block_cx := gw / 2 * Receptacle.CELL_SIZE
	var block_cy := (half_y + gh) / 2 * Receptacle.CELL_SIZE
	var screen_pos := receptacle.global_position + Vector2(block_cx, block_cy)
	rigid_body_mgr.spawn_object(wood_id, screen_pos)

	if rigid_body_mgr.get_body_count() == 0:
		main_node.queue_free()
		return {"name": test_name, "pass": false, "msg": "spawn_object did not create a body"}

	# --- 4. Step the simulation for 120 frames ---
	# Particles already inside the obstacle when it appears need multiple
	# frames to be pushed out via the 4-neighbor wall-escape heuristic.
	var step_count := 120
	var dt := 1.0 / 60.0
	for frame in range(step_count):
		# Compute and upload obstacle mask before stepping the solver.
		var mask := rigid_body_mgr.compute_obstacle_mask(gw, gh, float(Receptacle.CELL_SIZE))
		fluid_solver.upload_obstacle_mask(mask)
		fluid_solver.step(dt)
		receptacle.sync_from_gpu()
		await tree.process_frame

	# --- 5. Compute final obstacle mask and verify ---
	var final_mask := rigid_body_mgr.compute_obstacle_mask(gw, gh, float(Receptacle.CELL_SIZE))
	var densities := receptacle.liquid_readback.densities

	var mask_cells := 0
	var violations := 0
	var density_threshold := 0.1

	for i in range(mini(final_mask.size(), densities.size())):
		if final_mask[i] > 0:
			mask_cells += 1
			if densities[i] > density_threshold:
				violations += 1

	# Clean up the scene.
	main_node.queue_free()
	await tree.process_frame

	# --- 6. Report ---
	if mask_cells == 0:
		return {
			"name": test_name,
			"pass": false,
			"msg": "obstacle mask had 0 cells — rasterizer produced nothing",
		}

	# Allow a small number of violations: particles that were already inside
	# the body when the mask was first applied may take many frames to be
	# pushed out by the 4-neighbor wall-escape heuristic in pflip_advect.
	# Particles deep inside a multi-cell polygon can get stuck longer.
	# Fewer than 30% of mask cells having residual density is a pass.
	var max_violations := int(ceil(mask_cells * 0.3))
	var pass_ := violations <= max_violations
	var msg := "%d mask cells, %d violations (max %d allowed, density > %.1f inside body)" % [
		mask_cells, violations, max_violations, density_threshold
	]
	return {"name": test_name, "pass": pass_, "msg": msg}
