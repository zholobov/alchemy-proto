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
var renderer: SubstanceRenderer


func _ready() -> void:
	# Create the particle grid.
	grid = ParticleGrid.new(GRID_WIDTH, GRID_HEIGHT)
	# Set up oval boundary for rounded bottom.
	# Oval center is at the middle-bottom area of the grid.
	var cx := GRID_WIDTH / 2
	var cy := int(GRID_HEIGHT * 0.45)  # Oval starts below midpoint.
	var rx := int(GRID_WIDTH / 2) - 4  # Horizontal radius, with wall margin.
	var ry := GRID_HEIGHT - cy - 4  # Vertical radius to bottom.
	grid.set_boundary_oval(cx, cy, rx, ry)

	# Create and set up the renderer as a child.
	renderer = SubstanceRenderer.new()
	renderer.setup(grid, CELL_SIZE)
	add_child(renderer)


func get_screen_size() -> Vector2:
	return Vector2(GRID_WIDTH * CELL_SIZE, GRID_HEIGHT * CELL_SIZE)


func grid_to_screen(gx: int, gy: int) -> Vector2:
	return Vector2(gx * CELL_SIZE, gy * CELL_SIZE)


func screen_to_grid(screen_pos: Vector2) -> Vector2i:
	var local := screen_pos - global_position
	return Vector2i(int(local.x) / CELL_SIZE, int(local.y) / CELL_SIZE)


func _draw() -> void:
	# Draw receptacle outline (stone rim).
	var w := GRID_WIDTH * CELL_SIZE
	var h := GRID_HEIGHT * CELL_SIZE
	var rim_color := Color(0.4, 0.37, 0.33, 1.0)
	var rim_width := 6.0

	# Left wall.
	draw_line(Vector2(0, 0), Vector2(0, h), rim_color, rim_width)
	# Right wall.
	draw_line(Vector2(w, 0), Vector2(w, h), rim_color, rim_width)
	# Bottom curve — approximate with line segments.
	var segments := 20
	for i in range(segments):
		var t1 := float(i) / segments
		var t2 := float(i + 1) / segments
		var angle1 := t1 * PI
		var angle2 := t2 * PI
		var cx_screen := w / 2.0
		var rx_screen := w / 2.0
		var ry_screen := h * 0.45
		var cy_screen := h - ry_screen
		var p1 := Vector2(cx_screen - cos(angle1) * rx_screen, cy_screen + sin(angle1) * ry_screen)
		var p2 := Vector2(cx_screen - cos(angle2) * rx_screen, cy_screen + sin(angle2) * ry_screen)
		draw_line(p1, p2, rim_color, rim_width)

	# Rim at top.
	draw_line(Vector2(-8, -2), Vector2(w + 8, -2), rim_color, rim_width + 4)
