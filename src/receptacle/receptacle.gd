class_name Receptacle
extends Node2D
## The stone mortar/cauldron. Defines the simulation boundary shape
## and draws the receptacle outline.

## Grid dimensions for the simulation interior.
const GRID_WIDTH := 200
const GRID_HEIGHT := 150
const CELL_SIZE := 4  ## Screen pixels per grid cell.

## Receptacle physical properties.
var heat_resistance: float = 1200.0
var pressure_threshold: float = 100.0
var wall_conductivity: float = 0.05

var grid: ParticleGrid
## CPU-side liquid state from the PIC/FLIP solver readback. Populated each
## frame by sync_from_gpu(). Read by renderers, fields, and mediator.
var liquid_readback: LiquidReadback
## Grid MAC simulator for gases, fog, and steam. Stepped each frame by
## main._process(). Read by renderers for the vapor overlay.
var vapor_sim: VaporSim
var rigid_body_mgr: RigidBodyMgr
var gpu_sim: GpuSimulation
var fluid_solver: ParticleFluidSolver

## Canonical oval parameters in pixel space — single source of truth.
## All three systems (grid boundary, collision, drawing) derive from these.
var _oval_cx_px: float
var _oval_cy_px: float
var _oval_rx_px: float
var _oval_ry_px: float


func _ready() -> void:
	var w_px := float(GRID_WIDTH * CELL_SIZE)
	var h_px := float(GRID_HEIGHT * CELL_SIZE)

	# Define oval once in pixel space.
	_oval_cx_px = w_px / 2.0
	_oval_cy_px = h_px * 0.55  # Center of oval curve.
	_oval_rx_px = w_px / 2.0
	_oval_ry_px = h_px * 0.45

	# Create the particle grid with boundary derived from the canonical oval.
	grid = ParticleGrid.new(GRID_WIDTH, GRID_HEIGHT)
	var cx_grid: int = floori(_oval_cx_px / float(CELL_SIZE))
	var cy_grid: int = floori(_oval_cy_px / float(CELL_SIZE))
	var rx_grid: int = floori(_oval_rx_px / float(CELL_SIZE)) - 2  # wall_margin used by set_boundary_oval
	var ry_grid: int = floori(_oval_ry_px / float(CELL_SIZE))
	grid.set_boundary_oval(cx_grid, cy_grid, rx_grid, ry_grid)

	# Create GPU simulation.
	gpu_sim = GpuSimulation.new()
	gpu_sim.setup(GRID_WIDTH, GRID_HEIGHT, grid.boundary)

	# Create GPU PIC/FLIP particle fluid solver sharing the same boundary and
	# grid dimensions. Each liquid particle carries its substance id and
	# velocity; the grid is used only for pressure projection. Powders and
	# solids still live in the particle grid.
	fluid_solver = ParticleFluidSolver.new()
	fluid_solver.setup(GRID_WIDTH, GRID_HEIGHT, grid.boundary)
	fluid_solver.upload_substance_properties()

	# CPU-side mirror of the liquid solver state, rebuilt each frame.
	liquid_readback = LiquidReadback.new(GRID_WIDTH, GRID_HEIGHT)

	# GPU grid MAC simulator for vapor/fog/steam. Shares the oval boundary
	# so gases respect the container walls. Repurposed from the earlier
	# FluidSolver (same shader pipeline, gas-appropriate tuning + buoyancy).
	vapor_sim = VaporSim.new()
	vapor_sim.setup(GRID_WIDTH, GRID_HEIGHT, grid.boundary)
	vapor_sim.upload_substance_properties()

	# Create rigid body manager.
	rigid_body_mgr = RigidBodyMgr.new()
	add_child(rigid_body_mgr)

	# Create collision walls using the same canonical oval.
	var walls := StaticBody2D.new()
	add_child(walls)
	var wall_thick := 10.0

	# Left wall — extends from top to where oval starts.
	var left_col := CollisionShape2D.new()
	var left_shape := RectangleShape2D.new()
	left_shape.size = Vector2(wall_thick, _oval_cy_px)
	left_col.shape = left_shape
	left_col.position = Vector2(-wall_thick / 2.0, _oval_cy_px / 2.0)
	walls.add_child(left_col)

	# Right wall.
	var right_col := CollisionShape2D.new()
	var right_shape := RectangleShape2D.new()
	right_shape.size = Vector2(wall_thick, _oval_cy_px)
	right_col.shape = right_shape
	right_col.position = Vector2(w_px + wall_thick / 2.0, _oval_cy_px / 2.0)
	walls.add_child(right_col)

	# Oval bottom segments — same parameters as _draw() uses.
	var segments := 20
	for i in range(segments):
		var t1 := float(i) / segments
		var t2 := float(i + 1) / segments
		var angle1 := t1 * PI
		var angle2 := t2 * PI
		var p1 := Vector2(_oval_cx_px - cos(angle1) * _oval_rx_px, _oval_cy_px + sin(angle1) * _oval_ry_px)
		var p2 := Vector2(_oval_cx_px - cos(angle2) * _oval_rx_px, _oval_cy_px + sin(angle2) * _oval_ry_px)

		var seg_col := CollisionShape2D.new()
		var seg_shape := SegmentShape2D.new()
		seg_shape.a = p1
		seg_shape.b = p2
		seg_col.shape = seg_shape
		walls.add_child(seg_col)


func setup_rigid_bodies() -> void:
	rigid_body_mgr.setup(grid, global_position, CELL_SIZE)


func get_screen_size() -> Vector2:
	return Vector2(GRID_WIDTH * CELL_SIZE, GRID_HEIGHT * CELL_SIZE)


func grid_to_screen(gx: int, gy: int) -> Vector2:
	return Vector2(gx * CELL_SIZE, gy * CELL_SIZE)


func screen_to_grid(screen_pos: Vector2) -> Vector2i:
	var local := screen_pos - global_position
	var gx: int = floori(local.x / float(CELL_SIZE))
	var gy: int = floori(local.y / float(CELL_SIZE))
	return Vector2i(gx, gy)


func _draw() -> void:
	# Draw receptacle outline using the same canonical oval parameters.
	var w := GRID_WIDTH * CELL_SIZE
	var rim_color := Color(0.4, 0.37, 0.33, 1.0)
	var rim_width := 6.0

	# Left wall.
	draw_line(Vector2(0, 0), Vector2(0, _oval_cy_px), rim_color, rim_width)
	# Right wall.
	draw_line(Vector2(w, 0), Vector2(w, _oval_cy_px), rim_color, rim_width)
	# Bottom curve — same oval as collision and grid boundary.
	var segments := 20
	for i in range(segments):
		var t1 := float(i) / segments
		var t2 := float(i + 1) / segments
		var angle1 := t1 * PI
		var angle2 := t2 * PI
		var p1 := Vector2(_oval_cx_px - cos(angle1) * _oval_rx_px, _oval_cy_px + sin(angle1) * _oval_ry_px)
		var p2 := Vector2(_oval_cx_px - cos(angle2) * _oval_rx_px, _oval_cy_px + sin(angle2) * _oval_ry_px)
		draw_line(p1, p2, rim_color, rim_width)

	# Rim at top.
	draw_line(Vector2(-8, -2), Vector2(w + 8, -2), rim_color, rim_width + 4)


## Density threshold below which a cell is considered empty for rendering
## and mediator purposes. Renderers scale alpha by density so the fade-out
## is visual, not a hard cutoff — this threshold just drops cells with
## only a handful of stray particles that would otherwise flicker.
const LIQUID_VISIBLE_THRESHOLD := 0.005


func sync_from_gpu() -> void:
	var cells_data := gpu_sim.get_cells()
	var temps_data := gpu_sim.get_temperatures()
	for i in range(mini(cells_data.size(), grid.cells.size())):
		grid.cells[i] = cells_data[i]
	for i in range(mini(temps_data.size(), grid.temperatures.size())):
		grid.temperatures[i] = temps_data[i]

	# Populate liquid_readback from the PIC/FLIP solver's GPU readback.
	# Consumers (renderers, fields, mediator) read from liquid_readback.
	if fluid_solver:
		var density := fluid_solver.get_density_readback()
		var substance := fluid_solver.get_substance_readback()
		var substance2 := fluid_solver.get_secondary_substance_readback()
		var markers := liquid_readback.markers
		var densities := liquid_readback.densities
		var secondary_markers := liquid_readback.secondary_markers
		for i in range(mini(density.size(), markers.size())):
			if density[i] > LIQUID_VISIBLE_THRESHOLD:
				markers[i] = substance[i] if i < substance.size() else 0
				densities[i] = density[i]
				secondary_markers[i] = substance2[i] if i < substance2.size() else 0
			else:
				markers[i] = 0
				densities[i] = 0.0
				secondary_markers[i] = 0


func _exit_tree() -> void:
	if gpu_sim:
		gpu_sim.cleanup()
	if fluid_solver:
		fluid_solver.cleanup()
	if vapor_sim:
		vapor_sim.cleanup()
