# Alchemy Prototype Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a working alchemy simulation prototype that validates particle grid performance, fluid simulation, property-based emergent reactions, and the full player interaction loop.

**Architecture:** Three simulation systems (particle grid, MAC fluid, Godot rigid bodies) coordinated by a mediator. Six extensible fields (temperature, pressure, electricity, light, magnetism, sound) feed back into the simulation. Substances are data-driven `.tres` resources with properties that determine emergent reactions.

**Tech Stack:** Godot 4.x, GDScript, Image/ImageTexture rendering for particle grid, Godot physics for rigid bodies.

**Design Spec:** `docs/superpowers/specs/2026-04-05-alchemy-prototype-design.md`

---

## Phase 1: Foundation

### Task 1: Project Setup & Git Init

**Files:**
- Create: `project.godot`
- Create: `src/main.tscn`
- Create: `src/main.gd`
- Already exists: `CLAUDE.md`, `.gitignore`, `doc/vision.md`

- [ ] **Step 1: Initialize git repository**

```bash
cd /Users/zholobov/src/gd-alchemy-proto
git init
```

- [ ] **Step 2: Create project.godot**

Create `project.godot`:

```ini
; Engine configuration file.
; It's best edited using the editor UI and not directly,
; but it can also be manually edited.

config_version=5

[application]

config/name="Alchemy Prototype"
run/main_scene="res://src/main.tscn"
config/features=PackedStringArray("4.3", "Forward Plus")

[autoload]

SubstanceRegistry="*res://src/substance/substance_registry.gd"

[display]

window/size/viewport_width=1280
window/size/viewport_height=720
window/stretch/mode="canvas_items"
```

- [ ] **Step 3: Create minimal main scene**

Create `src/main.gd`:

```gdscript
extends Node2D


func _ready() -> void:
	print("Alchemy Prototype started")
```

Create `src/main.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://src/main.gd" id="1"]

[node name="Main" type="Node2D"]
script = ExtResource("1")
```

- [ ] **Step 4: Create substance registry autoload stub**

Create `src/substance/substance_registry.gd`:

```gdscript
extends Node
## Loads and indexes all substance definitions at startup.
## Autoloaded as SubstanceRegistry.

var substances: Array[Resource] = []
var name_to_id: Dictionary = {}


func _ready() -> void:
	_load_substances()


func _load_substances() -> void:
	# Index 0 is reserved for "empty cell"
	substances.append(null)
	var dir := DirAccess.open("res://data/substances/")
	if not dir:
		push_warning("No substances directory found")
		return
	dir.list_dir_begin()
	var filename := dir.get_next()
	while filename != "":
		if filename.ends_with(".tres"):
			var substance := load("res://data/substances/" + filename)
			if substance:
				substances.append(substance)
				name_to_id[substance.substance_name] = substances.size() - 1
		filename = dir.get_next()
	print("Loaded %d substances" % (substances.size() - 1))


func get_substance(id: int) -> Resource:
	if id <= 0 or id >= substances.size():
		return null
	return substances[id]


func get_id(substance_name: String) -> int:
	return name_to_id.get(substance_name, 0)


func get_count() -> int:
	return substances.size() - 1
```

- [ ] **Step 5: Run to verify**

```bash
godot --path /Users/zholobov/src/gd-alchemy-proto --headless --quit
```

Expected: exits cleanly, prints "Alchemy Prototype started" and "Loaded 0 substances" (no substances yet).

- [ ] **Step 6: Commit**

```bash
git add project.godot src/ CLAUDE.md .gitignore doc/ docs/ data/ assets/
git commit -m "feat: initial project setup with Godot 4.x scaffold"
```

---

### Task 2: Substance Definition System

**Files:**
- Create: `src/substance/substance_def.gd`
- Create: `data/substances/sulfur.tres`
- Create: `data/substances/iron_filings.tres`
- Create: `data/substances/salt.tres`
- Create: `data/substances/charcoal.tres`
- Create: `data/substances/water.tres`
- Create: `data/substances/oil.tres`
- Create: `data/substances/acid.tres`
- Create: `data/substances/rock.tres`
- Create: `data/substances/iron_ingot.tres`
- Create: `data/substances/crystal.tres`
- Create: `data/substances/ice.tres`
- Create: `data/substances/steam.tres`
- Create: `data/substances/flammable_gas.tres`
- Modify: `src/substance/substance_registry.gd`

- [ ] **Step 1: Create SubstanceDef resource script**

Create `src/substance/substance_def.gd`:

```gdscript
class_name SubstanceDef
extends Resource
## Data definition for a substance. All substances are defined as .tres resources
## with these properties. Reactions emerge from property comparisons, not recipes.

enum Phase { SOLID, POWDER, LIQUID, GAS }

@export_group("Identity")
@export var substance_name: String = ""
@export var phase: Phase = Phase.POWDER

@export_group("Physical")
@export var density: float = 1.0
@export var viscosity: float = 1.0  ## For liquids. Higher = thicker (honey > water).

@export_group("Thermal")
@export var melting_point: float = 1000.0  ## Temperature at which solid -> liquid.
@export var boiling_point: float = 2000.0  ## Temperature at which liquid -> gas.
@export var flash_point: float = -1.0  ## Temperature at which it ignites. -1 = non-flammable.
@export var conductivity_thermal: float = 0.1  ## How fast heat spreads through this. 0-1.

@export_group("Flammability")
@export var flammability: float = 0.0  ## 0 = inert, 1 = extremely flammable.
@export var burn_rate: float = 0.0  ## How fast it burns. 0-1.
@export var energy_density: float = 0.0  ## Heat released per unit burned.
@export var burn_products: Array[Dictionary] = []  ## [{substance: "name", ratio: 0.5}]

@export_group("Reactivity")
@export var acidity: float = 7.0  ## pH-like. <7 = acidic, >7 = basic, 7 = neutral.
@export var oxidizer_strength: float = 0.0  ## 0-1.
@export var reducer_strength: float = 0.0  ## 0-1.
@export var volatility: float = 0.0  ## How readily it becomes gas. 0-1.

@export_group("Electrical & Magnetic")
@export var conductivity_electric: float = 0.0  ## 0 = insulator, 1 = perfect conductor.
@export var magnetic_permeability: float = 0.0  ## 0 = non-magnetic, 1 = strongly magnetic.

@export_group("Visual")
@export var base_color: Color = Color.WHITE
@export var opacity: float = 1.0
@export var luminosity: float = 0.0  ## Light emission intensity. 0 = none.
@export var luminosity_color: Color = Color.WHITE
@export var glow_intensity: float = 0.0
```

- [ ] **Step 2: Update SubstanceRegistry to use SubstanceDef type**

In `src/substance/substance_registry.gd`, replace the type hints:

Change `var substances: Array[Resource] = []` to:
```gdscript
var substances: Array[SubstanceDef] = []
```

Change `func get_substance(id: int) -> Resource:` to:
```gdscript
func get_substance(id: int) -> SubstanceDef:
```

Change the `_load_substances` method's inner load to cast properly:
```gdscript
			var substance := load("res://data/substances/" + filename) as SubstanceDef
```

And the null append at start:
```gdscript
	substances.append(null)
```
Note: Godot allows null in typed arrays for `SubstanceDef`. If this causes issues, keep `Array` untyped.

- [ ] **Step 3: Create all 13 substance .tres files**

Create each file in `data/substances/`. The format for each `.tres` file:

`data/substances/sulfur.tres`:
```
[gd_resource type="Resource" script_class="SubstanceDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://src/substance/substance_def.gd" id="1"]

[resource]
script = ExtResource("1")
substance_name = "Sulfur"
phase = 1
density = 2.07
viscosity = 1.0
melting_point = 115.0
boiling_point = 445.0
flash_point = 232.0
conductivity_thermal = 0.2
flammability = 0.9
burn_rate = 0.7
energy_density = 0.8
burn_products = [{"substance": "Steam", "ratio": 0.4}, {"substance": "Flammable Gas", "ratio": 0.6}]
acidity = 5.0
oxidizer_strength = 0.0
reducer_strength = 0.3
volatility = 0.3
conductivity_electric = 0.0
magnetic_permeability = 0.0
base_color = Color(0.9, 0.85, 0.2, 1)
opacity = 1.0
luminosity = 0.0
luminosity_color = Color(1, 1, 1, 1)
glow_intensity = 0.0
```

`data/substances/iron_filings.tres`:
```
[gd_resource type="Resource" script_class="SubstanceDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://src/substance/substance_def.gd" id="1"]

[resource]
script = ExtResource("1")
substance_name = "Iron Filings"
phase = 1
density = 7.87
viscosity = 1.0
melting_point = 1538.0
boiling_point = 2862.0
flash_point = -1.0
conductivity_thermal = 0.8
flammability = 0.0
burn_rate = 0.0
energy_density = 0.0
burn_products = []
acidity = 7.0
oxidizer_strength = 0.0
reducer_strength = 0.6
volatility = 0.0
conductivity_electric = 0.9
magnetic_permeability = 0.95
base_color = Color(0.45, 0.45, 0.5, 1)
opacity = 1.0
luminosity = 0.0
luminosity_color = Color(1, 1, 1, 1)
glow_intensity = 0.0
```

`data/substances/salt.tres`:
```
[gd_resource type="Resource" script_class="SubstanceDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://src/substance/substance_def.gd" id="1"]

[resource]
script = ExtResource("1")
substance_name = "Salt"
phase = 1
density = 2.16
viscosity = 1.0
melting_point = 801.0
boiling_point = 1413.0
flash_point = -1.0
conductivity_thermal = 0.1
flammability = 0.0
burn_rate = 0.0
energy_density = 0.0
burn_products = []
acidity = 7.0
oxidizer_strength = 0.0
reducer_strength = 0.0
volatility = 0.0
conductivity_electric = 0.05
magnetic_permeability = 0.0
base_color = Color(0.95, 0.95, 0.9, 1)
opacity = 1.0
luminosity = 0.0
luminosity_color = Color(1, 1, 1, 1)
glow_intensity = 0.0
```

`data/substances/charcoal.tres`:
```
[gd_resource type="Resource" script_class="SubstanceDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://src/substance/substance_def.gd" id="1"]

[resource]
script = ExtResource("1")
substance_name = "Charcoal"
phase = 1
density = 1.5
viscosity = 1.0
melting_point = 3550.0
boiling_point = 4027.0
flash_point = 349.0
conductivity_thermal = 0.15
flammability = 0.95
burn_rate = 0.3
energy_density = 0.95
burn_products = [{"substance": "Steam", "ratio": 0.3}, {"substance": "Flammable Gas", "ratio": 0.7}]
acidity = 7.0
oxidizer_strength = 0.0
reducer_strength = 0.8
volatility = 0.1
conductivity_electric = 0.3
magnetic_permeability = 0.0
base_color = Color(0.15, 0.12, 0.1, 1)
opacity = 1.0
luminosity = 0.0
luminosity_color = Color(1, 1, 1, 1)
glow_intensity = 0.0
```

`data/substances/water.tres`:
```
[gd_resource type="Resource" script_class="SubstanceDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://src/substance/substance_def.gd" id="1"]

[resource]
script = ExtResource("1")
substance_name = "Water"
phase = 2
density = 1.0
viscosity = 0.3
melting_point = 0.0
boiling_point = 100.0
flash_point = -1.0
conductivity_thermal = 0.6
flammability = 0.0
burn_rate = 0.0
energy_density = 0.0
burn_products = []
acidity = 7.0
oxidizer_strength = 0.0
reducer_strength = 0.0
volatility = 0.3
conductivity_electric = 0.4
magnetic_permeability = 0.0
base_color = Color(0.2, 0.5, 0.9, 0.7)
opacity = 0.7
luminosity = 0.0
luminosity_color = Color(1, 1, 1, 1)
glow_intensity = 0.0
```

`data/substances/oil.tres`:
```
[gd_resource type="Resource" script_class="SubstanceDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://src/substance/substance_def.gd" id="1"]

[resource]
script = ExtResource("1")
substance_name = "Oil"
phase = 2
density = 0.8
viscosity = 0.7
melting_point = -20.0
boiling_point = 300.0
flash_point = 210.0
conductivity_thermal = 0.15
flammability = 0.8
burn_rate = 0.5
energy_density = 0.85
burn_products = [{"substance": "Steam", "ratio": 0.5}, {"substance": "Flammable Gas", "ratio": 0.5}]
acidity = 7.0
oxidizer_strength = 0.0
reducer_strength = 0.2
volatility = 0.2
conductivity_electric = 0.0
magnetic_permeability = 0.0
base_color = Color(0.3, 0.25, 0.05, 0.85)
opacity = 0.85
luminosity = 0.0
luminosity_color = Color(1, 1, 1, 1)
glow_intensity = 0.0
```

`data/substances/acid.tres`:
```
[gd_resource type="Resource" script_class="SubstanceDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://src/substance/substance_def.gd" id="1"]

[resource]
script = ExtResource("1")
substance_name = "Acid"
phase = 2
density = 1.4
viscosity = 0.4
melting_point = -35.0
boiling_point = 337.0
flash_point = -1.0
conductivity_thermal = 0.5
flammability = 0.0
burn_rate = 0.0
energy_density = 0.0
burn_products = []
acidity = 1.0
oxidizer_strength = 0.7
reducer_strength = 0.0
volatility = 0.4
conductivity_electric = 0.6
magnetic_permeability = 0.0
base_color = Color(0.4, 0.9, 0.2, 0.75)
opacity = 0.75
luminosity = 0.1
luminosity_color = Color(0.4, 1.0, 0.2, 1)
glow_intensity = 0.2
```

`data/substances/rock.tres`:
```
[gd_resource type="Resource" script_class="SubstanceDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://src/substance/substance_def.gd" id="1"]

[resource]
script = ExtResource("1")
substance_name = "Rock"
phase = 0
density = 2.6
viscosity = 1.0
melting_point = 1200.0
boiling_point = 3000.0
flash_point = -1.0
conductivity_thermal = 0.3
flammability = 0.0
burn_rate = 0.0
energy_density = 0.0
burn_products = []
acidity = 7.0
oxidizer_strength = 0.0
reducer_strength = 0.0
volatility = 0.0
conductivity_electric = 0.01
magnetic_permeability = 0.0
base_color = Color(0.55, 0.5, 0.45, 1)
opacity = 1.0
luminosity = 0.0
luminosity_color = Color(1, 1, 1, 1)
glow_intensity = 0.0
```

`data/substances/iron_ingot.tres`:
```
[gd_resource type="Resource" script_class="SubstanceDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://src/substance/substance_def.gd" id="1"]

[resource]
script = ExtResource("1")
substance_name = "Iron Ingot"
phase = 0
density = 7.87
viscosity = 1.0
melting_point = 1538.0
boiling_point = 2862.0
flash_point = -1.0
conductivity_thermal = 0.8
flammability = 0.0
burn_rate = 0.0
energy_density = 0.0
burn_products = []
acidity = 7.0
oxidizer_strength = 0.0
reducer_strength = 0.6
volatility = 0.0
conductivity_electric = 0.9
magnetic_permeability = 0.95
base_color = Color(0.6, 0.6, 0.65, 1)
opacity = 1.0
luminosity = 0.0
luminosity_color = Color(1, 1, 1, 1)
glow_intensity = 0.0
```

`data/substances/crystal.tres`:
```
[gd_resource type="Resource" script_class="SubstanceDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://src/substance/substance_def.gd" id="1"]

[resource]
script = ExtResource("1")
substance_name = "Crystal"
phase = 0
density = 2.65
viscosity = 1.0
melting_point = 1713.0
boiling_point = 2950.0
flash_point = -1.0
conductivity_thermal = 0.15
flammability = 0.0
burn_rate = 0.0
energy_density = 0.0
burn_products = []
acidity = 7.0
oxidizer_strength = 0.0
reducer_strength = 0.0
volatility = 0.0
conductivity_electric = 0.0
magnetic_permeability = 0.0
base_color = Color(0.7, 0.85, 0.95, 0.9)
opacity = 0.9
luminosity = 0.0
luminosity_color = Color(0.6, 0.8, 1.0, 1)
glow_intensity = 0.0
```

`data/substances/ice.tres`:
```
[gd_resource type="Resource" script_class="SubstanceDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://src/substance/substance_def.gd" id="1"]

[resource]
script = ExtResource("1")
substance_name = "Ice"
phase = 0
density = 0.92
viscosity = 1.0
melting_point = 0.0
boiling_point = 100.0
flash_point = -1.0
conductivity_thermal = 0.4
flammability = 0.0
burn_rate = 0.0
energy_density = 0.0
burn_products = []
acidity = 7.0
oxidizer_strength = 0.0
reducer_strength = 0.0
volatility = 0.0
conductivity_electric = 0.01
magnetic_permeability = 0.0
base_color = Color(0.75, 0.9, 1.0, 0.85)
opacity = 0.85
luminosity = 0.0
luminosity_color = Color(1, 1, 1, 1)
glow_intensity = 0.0
```

`data/substances/steam.tres`:
```
[gd_resource type="Resource" script_class="SubstanceDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://src/substance/substance_def.gd" id="1"]

[resource]
script = ExtResource("1")
substance_name = "Steam"
phase = 3
density = 0.0006
viscosity = 0.05
melting_point = 0.0
boiling_point = 100.0
flash_point = -1.0
conductivity_thermal = 0.02
flammability = 0.0
burn_rate = 0.0
energy_density = 0.0
burn_products = []
acidity = 7.0
oxidizer_strength = 0.0
reducer_strength = 0.0
volatility = 1.0
conductivity_electric = 0.0
magnetic_permeability = 0.0
base_color = Color(0.9, 0.9, 0.95, 0.3)
opacity = 0.3
luminosity = 0.0
luminosity_color = Color(1, 1, 1, 1)
glow_intensity = 0.0
```

`data/substances/flammable_gas.tres`:
```
[gd_resource type="Resource" script_class="SubstanceDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://src/substance/substance_def.gd" id="1"]

[resource]
script = ExtResource("1")
substance_name = "Flammable Gas"
phase = 3
density = 0.001
viscosity = 0.05
melting_point = -200.0
boiling_point = -161.0
flash_point = 50.0
conductivity_thermal = 0.03
flammability = 1.0
burn_rate = 1.0
energy_density = 0.9
burn_products = [{"substance": "Steam", "ratio": 1.0}]
acidity = 7.0
oxidizer_strength = 0.0
reducer_strength = 0.5
volatility = 1.0
conductivity_electric = 0.0
magnetic_permeability = 0.0
base_color = Color(0.6, 0.5, 0.2, 0.2)
opacity = 0.2
luminosity = 0.0
luminosity_color = Color(1, 1, 1, 1)
glow_intensity = 0.0
```

- [ ] **Step 4: Run to verify substances load**

```bash
godot --path /Users/zholobov/src/gd-alchemy-proto --headless --quit
```

Expected: prints "Loaded 13 substances" and exits cleanly.

- [ ] **Step 5: Commit**

```bash
git add src/substance/substance_def.gd src/substance/substance_registry.gd data/substances/
git commit -m "feat: substance definition system with 13 initial substances"
```

---

## Phase 2: Particle Simulation & Rendering

### Task 3: Particle Grid Core

**Files:**
- Create: `src/simulation/particle_grid.gd`

This is the most performance-critical code in the project. Uses flat packed arrays for cache-friendly access. Each cell stores a substance ID (0 = empty) and per-particle state.

- [ ] **Step 1: Create particle grid with data structure and simulation rules**

Create `src/simulation/particle_grid.gd`:

```gdscript
class_name ParticleGrid
extends RefCounted
## 2D cellular automata grid for powder and gas particles.
## Uses flat packed arrays for performance. Cell 0 = empty.

var width: int
var height: int
var cells: PackedInt32Array  ## Substance ID per cell. 0 = empty.
var temperatures: PackedFloat32Array  ## Per-cell temperature in degrees.
var charges: PackedFloat32Array  ## Per-cell electrical charge.

## Boundary mask: 1 = inside receptacle, 0 = wall/outside.
var boundary: PackedByteArray

var _frame_count: int = 0
var _rng := RandomNumberGenerator.new()


func _init(w: int, h: int) -> void:
	width = w
	height = h
	var size := w * h
	cells = PackedInt32Array()
	cells.resize(size)
	temperatures = PackedFloat32Array()
	temperatures.resize(size)
	charges = PackedFloat32Array()
	charges.resize(size)
	boundary = PackedByteArray()
	boundary.resize(size)
	# Default: all cells are valid (open rectangle).
	boundary.fill(1)
	_rng.randomize()
	# Set ambient temperature.
	temperatures.fill(20.0)


func set_boundary_oval(center_x: int, center_y: int, radius_x: int, radius_y: int) -> void:
	## Marks cells inside an oval as valid (1), outside as wall (0).
	## Used to create the mortar/cauldron shape with a rounded bottom.
	boundary.fill(0)
	for y in range(height):
		for x in range(width):
			# Top is open (straight walls), bottom is rounded.
			var wall_margin := 2
			if x < wall_margin or x >= width - wall_margin:
				continue
			# Top half: straight walls.
			if y < center_y:
				boundary[y * width + x] = 1
			else:
				# Bottom half: oval shape.
				var dx := float(x - center_x) / float(radius_x)
				var dy := float(y - center_y) / float(radius_y)
				if dx * dx + dy * dy <= 1.0:
					boundary[y * width + x] = 1


func idx(x: int, y: int) -> int:
	return y * width + x


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height


func is_valid(x: int, y: int) -> bool:
	## Returns true if the cell is inside the receptacle boundary.
	if not in_bounds(x, y):
		return false
	return boundary[idx(x, y)] == 1


func is_empty(x: int, y: int) -> bool:
	return is_valid(x, y) and cells[idx(x, y)] == 0


func get_cell(x: int, y: int) -> int:
	if not in_bounds(x, y):
		return -1
	return cells[idx(x, y)]


func set_cell(x: int, y: int, substance_id: int) -> void:
	if is_valid(x, y):
		cells[idx(x, y)] = substance_id


func spawn_particle(x: int, y: int, substance_id: int) -> bool:
	## Tries to place a particle. Returns true if successful.
	if is_empty(x, y):
		cells[idx(x, y)] = substance_id
		return true
	return false


func clear_cell(x: int, y: int) -> void:
	if in_bounds(x, y):
		cells[idx(x, y)] = 0
		temperatures[idx(x, y)] = 20.0
		charges[idx(x, y)] = 0.0


func count_particles() -> int:
	var count := 0
	for i in range(cells.size()):
		if cells[i] != 0:
			count += 1
	return count


func update() -> void:
	## Run one simulation step. Bottom-to-top, alternating left-right scan.
	_frame_count += 1
	var scan_left := _frame_count % 2 == 0

	# Bottom-to-top so falling works correctly in one pass.
	for y in range(height - 1, -1, -1):
		if scan_left:
			for x in range(width):
				_update_particle(x, y)
		else:
			for x in range(width - 1, -1, -1):
				_update_particle(x, y)


func _update_particle(x: int, y: int) -> void:
	var i := idx(x, y)
	var substance_id := cells[i]
	if substance_id == 0:
		return

	var substance := SubstanceRegistry.get_substance(substance_id)
	if not substance:
		return

	match substance.phase:
		SubstanceDef.Phase.POWDER:
			_update_powder(x, y, substance_id, substance)
		SubstanceDef.Phase.GAS:
			_update_gas(x, y, substance_id, substance)
		# LIQUID and SOLID phases are handled by other systems.


func _update_powder(x: int, y: int, substance_id: int, substance: SubstanceDef) -> void:
	var i := idx(x, y)

	# 1. Try to fall straight down.
	if _try_move(x, y, x, y + 1, substance):
		return

	# 2. Try to fall diagonally (randomize direction to avoid bias).
	var go_left := _rng.randf() > 0.5
	var dx1 := -1 if go_left else 1
	var dx2 := 1 if go_left else -1
	if _try_move(x, y, x + dx1, y + 1, substance):
		return
	if _try_move(x, y, x + dx2, y + 1, substance):
		return


func _update_gas(x: int, y: int, substance_id: int, substance: SubstanceDef) -> void:
	var i := idx(x, y)

	# Gases rise (try to move up) and drift sideways.
	# 1. Try to rise straight up.
	if _try_move(x, y, x, y - 1, substance):
		return

	# 2. Try to rise diagonally.
	var go_left := _rng.randf() > 0.5
	var dx1 := -1 if go_left else 1
	var dx2 := 1 if go_left else -1
	if _try_move(x, y, x + dx1, y - 1, substance):
		return
	if _try_move(x, y, x + dx2, y - 1, substance):
		return

	# 3. Try to drift sideways.
	if _try_move(x, y, x + dx1, y, substance):
		return
	if _try_move(x, y, x + dx2, y, substance):
		return

	# 4. Gases dissipate over time.
	if _rng.randf() < 0.002:
		# Reached top or stuck — fade out.
		if y <= 2:
			clear_cell(x, y)


func _try_move(from_x: int, from_y: int, to_x: int, to_y: int, substance: SubstanceDef) -> bool:
	## Tries to move a particle to the target cell. Handles density-based displacement.
	if not is_valid(to_x, to_y):
		return false

	var target_id := cells[idx(to_x, to_y)]

	# Empty cell — just move.
	if target_id == 0:
		_swap(from_x, from_y, to_x, to_y)
		return true

	# Density displacement: heavy sinks through light.
	var target_substance := SubstanceRegistry.get_substance(target_id)
	if target_substance and substance.density > target_substance.density:
		# Only displace downward movement (sinking).
		if to_y > from_y:
			_swap(from_x, from_y, to_x, to_y)
			return true

	return false


func _swap(x1: int, y1: int, x2: int, y2: int) -> void:
	var i1 := idx(x1, y1)
	var i2 := idx(x2, y2)
	# Swap substance IDs.
	var tmp_cell := cells[i1]
	cells[i1] = cells[i2]
	cells[i2] = tmp_cell
	# Swap temperatures.
	var tmp_temp := temperatures[i1]
	temperatures[i1] = temperatures[i2]
	temperatures[i2] = tmp_temp
	# Swap charges.
	var tmp_charge := charges[i1]
	charges[i1] = charges[i2]
	charges[i2] = tmp_charge
```

- [ ] **Step 2: Commit**

```bash
git add src/simulation/particle_grid.gd
git commit -m "feat: particle grid with gravity, diagonal fall, density displacement, gas rising"
```

---

### Task 4: Substance Renderer

**Files:**
- Create: `src/rendering/substance_renderer.gd`

Renders the particle grid as an Image texture. Each grid cell maps to one pixel, displayed scaled up via nearest-neighbor filtering for a crisp pixel look.

- [ ] **Step 1: Create substance renderer**

Create `src/rendering/substance_renderer.gd`:

```gdscript
class_name SubstanceRenderer
extends Sprite2D
## Renders the particle grid as a scaled-up pixel image.
## Each grid cell = 1 pixel in the image, scaled by cell_size on screen.

var grid: ParticleGrid
var cell_size: int = 4  ## Screen pixels per grid cell.
var _image: Image
var _texture: ImageTexture
var _pixel_data: PackedByteArray

## Cache substance colors to avoid lookups every pixel every frame.
var _color_cache: PackedColorArray


func setup(p_grid: ParticleGrid, p_cell_size: int = 4) -> void:
	grid = p_grid
	cell_size = p_cell_size

	_image = Image.create(grid.width, grid.height, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	texture = _texture
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	# Scale sprite so each pixel covers cell_size screen pixels.
	scale = Vector2(cell_size, cell_size)

	# Anchor at top-left.
	centered = false

	_pixel_data = PackedByteArray()
	_pixel_data.resize(grid.width * grid.height * 4)

	_rebuild_color_cache()


func _rebuild_color_cache() -> void:
	_color_cache = PackedColorArray()
	_color_cache.resize(SubstanceRegistry.substances.size())
	_color_cache[0] = Color.TRANSPARENT
	for i in range(1, SubstanceRegistry.substances.size()):
		var substance := SubstanceRegistry.get_substance(i)
		if substance:
			_color_cache[i] = substance.base_color
		else:
			_color_cache[i] = Color.MAGENTA  # Error color.


func render() -> void:
	if not grid:
		return

	var size := grid.width * grid.height
	for i in range(size):
		var substance_id := grid.cells[i]
		var color: Color
		if substance_id == 0:
			color = Color.TRANSPARENT
		elif substance_id < _color_cache.size():
			color = _color_cache[substance_id]
		else:
			color = Color.MAGENTA

		# Boundary cells that are walls render as dark gray.
		if grid.boundary[i] == 0:
			color = Color(0.15, 0.13, 0.12, 1.0)

		var offset := i * 4
		_pixel_data[offset] = int(color.r8)
		_pixel_data[offset + 1] = int(color.g8)
		_pixel_data[offset + 2] = int(color.b8)
		_pixel_data[offset + 3] = int(color.a8)

	_image = Image.create_from_data(grid.width, grid.height, false, Image.FORMAT_RGBA8, _pixel_data)
	_texture.update(_image)
```

- [ ] **Step 2: Commit**

```bash
git add src/rendering/substance_renderer.gd
git commit -m "feat: substance renderer using Image/ImageTexture pixel grid"
```

---

### Task 5: Receptacle & Boundaries

**Files:**
- Create: `src/receptacle/receptacle.gd`

The receptacle defines the boundary shape for the simulation grid. For the prototype, it's a node that configures the particle grid's boundary mask and draws the cauldron outline.

- [ ] **Step 1: Create receptacle**

Create `src/receptacle/receptacle.gd`:

```gdscript
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
```

- [ ] **Step 2: Commit**

```bash
git add src/receptacle/receptacle.gd
git commit -m "feat: receptacle with oval boundary mask and stone rim drawing"
```

---

### Task 6: Debug Overlay

**Files:**
- Create: `src/debug/fps_overlay.gd`
- Create: `src/debug/perf_monitor.gd`
- Create: `src/debug/game_log.gd`

Three debug components on a CanvasLayer so they draw on top of everything.

- [ ] **Step 1: Create FPS overlay (always visible)**

Create `src/debug/fps_overlay.gd`:

```gdscript
class_name FPSOverlay
extends Label
## Always-visible FPS counter in the top-left corner.


func _ready() -> void:
	# Position in top-left.
	position = Vector2(10, 10)
	add_theme_font_size_override("font_size", 16)
	add_theme_color_override("font_color", Color.YELLOW)


func _process(_delta: float) -> void:
	var fps := Engine.get_frames_per_second()
	var frame_ms := 1000.0 / maxf(fps, 1.0)
	text = "%d FPS (%.1f ms)" % [fps, frame_ms]
```

- [ ] **Step 2: Create performance monitor (toggleable)**

Create `src/debug/perf_monitor.gd`:

```gdscript
class_name PerfMonitor
extends VBoxContainer
## Toggleable detailed performance stats. Shows per-system frame times.
## Toggle with F3.

var _timings: Dictionary = {}
var _labels: Dictionary = {}
var _particle_count_label: Label
var _visible_state := false

## File logging.
var _log_file: FileAccess
var _log_enabled := false


func _ready() -> void:
	position = Vector2(10, 40)
	visible = false

	# Header.
	var header := Label.new()
	header.text = "--- Perf Monitor (F3) ---"
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", Color.CYAN)
	add_child(header)

	_particle_count_label = Label.new()
	_particle_count_label.add_theme_font_size_override("font_size", 13)
	_particle_count_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(_particle_count_label)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F3:
		_visible_state = not _visible_state
		visible = _visible_state


func begin_timing(system_name: String) -> void:
	_timings[system_name] = Time.get_ticks_usec()


func end_timing(system_name: String) -> void:
	if system_name not in _timings:
		return
	var elapsed_us := Time.get_ticks_usec() - _timings[system_name]
	var elapsed_ms := elapsed_us / 1000.0

	if system_name not in _labels:
		var label := Label.new()
		label.add_theme_font_size_override("font_size", 13)
		label.add_theme_color_override("font_color", Color.WHITE)
		add_child(label)
		_labels[system_name] = label

	_labels[system_name].text = "%s: %.2f ms" % [system_name, elapsed_ms]

	if _log_enabled and _log_file:
		_log_file.store_line("%d,%s,%.3f" % [Time.get_ticks_msec(), system_name, elapsed_ms])


func update_particle_count(count: int) -> void:
	_particle_count_label.text = "Particles: %d" % count


func set_file_logging(enabled: bool) -> void:
	## Toggle logging to file. F4 to toggle.
	_log_enabled = enabled
	if enabled and not _log_file:
		_log_file = FileAccess.open("user://perf_log.csv", FileAccess.WRITE)
		if _log_file:
			_log_file.store_line("timestamp_ms,system,elapsed_ms")
			print("Perf logging started: ", OS.get_user_data_dir() + "/perf_log.csv")
	elif not enabled and _log_file:
		_log_file.close()
		_log_file = null
		print("Perf logging stopped")
```

- [ ] **Step 3: Create game log (toggleable)**

Create `src/debug/game_log.gd`:

```gdscript
class_name GameLog
extends PanelContainer
## Toggleable in-game event log. Toggle with F2.
## Logs reactions, phase changes, threshold crossings, etc.

const MAX_ENTRIES := 100

var _label: RichTextLabel
var _visible_state := false


func _ready() -> void:
	visible = false
	custom_minimum_size = Vector2(400, 250)

	# Semi-transparent background.
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.7)
	style.set_corner_radius_all(4)
	add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	add_child(vbox)

	var header := Label.new()
	header.text = "Game Log (F2)"
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", Color.CYAN)
	vbox.add_child(header)

	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.scroll_following = true
	_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_label.add_theme_font_size_override("normal_font_size", 12)
	vbox.add_child(_label)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F2:
		_visible_state = not _visible_state
		visible = _visible_state


func log_event(message: String, color: Color = Color.WHITE) -> void:
	var timestamp := "%.1f" % (Time.get_ticks_msec() / 1000.0)
	var hex_color := color.to_html(false)
	_label.append_text("[color=#888]%s[/color] [color=#%s]%s[/color]\n" % [timestamp, hex_color, message])

	# Trim old entries.
	if _label.get_line_count() > MAX_ENTRIES:
		_label.clear()
		_label.append_text("[color=#888]--- log trimmed ---[/color]\n")
```

- [ ] **Step 4: Commit**

```bash
git add src/debug/
git commit -m "feat: debug overlay — FPS counter, perf monitor (F3), game log (F2)"
```

---

### Task 7: Test Input & First Integration

**Files:**
- Modify: `src/main.gd`

Wire everything together. Click to spawn particles, number keys to switch substance. This is the first runnable build.

**This is the BENCHMARK CHECKPOINT:** After completing this task, run the game and stress-test the particle grid. Spawn thousands of particles and observe FPS. The results determine whether GDScript is viable for the grid loop or if we need to consider compute shaders / GDExtension.

- [ ] **Step 1: Wire main scene with all systems**

Replace `src/main.gd`:

```gdscript
extends Node2D
## Main scene. Wires together simulation, rendering, and debug overlay.

var receptacle: Receptacle
var perf_monitor: PerfMonitor
var game_log: GameLog

var _selected_substance_id: int = 1
var _selected_substance_name: String = ""
var _substance_label: Label

## Spawn rate when holding mouse button.
const SPAWN_RADIUS := 3
const SPAWN_INTERVAL := 0.01  ## Seconds between spawn bursts.
var _spawn_timer: float = 0.0


func _ready() -> void:
	# Background color.
	RenderingServer.set_default_clear_color(Color(0.08, 0.06, 0.1))

	# Create receptacle (centered on screen).
	receptacle = Receptacle.new()
	add_child(receptacle)
	var screen_size := get_viewport_rect().size
	var rec_size := receptacle.get_screen_size()
	receptacle.position = Vector2(
		(screen_size.x - rec_size.x) / 2,
		screen_size.y - rec_size.y - 60
	)

	# Debug overlay on a CanvasLayer so it's always on top.
	var debug_layer := CanvasLayer.new()
	debug_layer.layer = 100
	add_child(debug_layer)

	var fps := FPSOverlay.new()
	debug_layer.add_child(fps)

	perf_monitor = PerfMonitor.new()
	debug_layer.add_child(perf_monitor)

	game_log = GameLog.new()
	game_log.anchor_right = 1.0
	game_log.position = Vector2(screen_size.x - 420, screen_size.y - 270)
	debug_layer.add_child(game_log)

	# Substance selector label.
	_substance_label = Label.new()
	_substance_label.position = Vector2(10, screen_size.y - 30)
	_substance_label.add_theme_font_size_override("font_size", 16)
	_substance_label.add_theme_color_override("font_color", Color.WHITE)
	debug_layer.add_child(_substance_label)
	_update_substance_label()

	game_log.log_event("Alchemy Prototype started", Color.CYAN)
	game_log.log_event("Click to spawn particles. Keys 1-9 to select substance.", Color.GREEN)
	game_log.log_event("F2 = toggle log, F3 = toggle perf, F4 = perf file logging", Color.GREEN)


func _input(event: InputEvent) -> void:
	# Number keys 1-9 to select substance.
	if event is InputEventKey and event.pressed:
		var key := event.keycode
		if key >= KEY_1 and key <= KEY_9:
			var index := key - KEY_1 + 1
			if index <= SubstanceRegistry.get_count():
				_selected_substance_id = index
				_update_substance_label()
				var substance := SubstanceRegistry.get_substance(index)
				game_log.log_event("Selected: %s" % substance.substance_name, substance.base_color)
		elif key == KEY_F4:
			perf_monitor._log_enabled = not perf_monitor._log_enabled
			perf_monitor.set_file_logging(perf_monitor._log_enabled)
		elif key == KEY_R:
			# Reset / clear receptacle.
			_clear_receptacle()
		elif key == KEY_F:
			# Flood fill for stress testing.
			_flood_fill()


func _process(delta: float) -> void:
	# --- Spawn particles on mouse hold ---
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_spawn_timer -= delta
		if _spawn_timer <= 0.0:
			_spawn_timer = SPAWN_INTERVAL
			_spawn_at_mouse()

	# --- Simulation update ---
	perf_monitor.begin_timing("Particle Grid")
	receptacle.grid.update()
	perf_monitor.end_timing("Particle Grid")

	# --- Rendering ---
	perf_monitor.begin_timing("Render")
	receptacle.renderer.render()
	perf_monitor.end_timing("Render")

	# --- Update particle count ---
	perf_monitor.update_particle_count(receptacle.grid.count_particles())


func _spawn_at_mouse() -> void:
	var mouse_pos := get_global_mouse_position()
	var grid_pos := receptacle.screen_to_grid(mouse_pos)

	# Spawn in a small radius for a brush effect.
	for dy in range(-SPAWN_RADIUS, SPAWN_RADIUS + 1):
		for dx in range(-SPAWN_RADIUS, SPAWN_RADIUS + 1):
			if dx * dx + dy * dy <= SPAWN_RADIUS * SPAWN_RADIUS:
				receptacle.grid.spawn_particle(grid_pos.x + dx, grid_pos.y + dy, _selected_substance_id)


func _update_substance_label() -> void:
	var substance := SubstanceRegistry.get_substance(_selected_substance_id)
	if substance:
		_selected_substance_name = substance.substance_name
	_substance_label.text = "Substance [%d]: %s  |  R=reset  F=flood" % [_selected_substance_id, _selected_substance_name]


func _clear_receptacle() -> void:
	for i in range(receptacle.grid.cells.size()):
		receptacle.grid.cells[i] = 0
		receptacle.grid.temperatures[i] = 20.0
		receptacle.grid.charges[i] = 0.0
	game_log.log_event("Receptacle cleared", Color.YELLOW)


func _flood_fill() -> void:
	## Fill the entire receptacle with selected substance for stress testing.
	var count := 0
	for i in range(receptacle.grid.cells.size()):
		if receptacle.grid.boundary[i] == 1 and receptacle.grid.cells[i] == 0:
			receptacle.grid.cells[i] = _selected_substance_id
			count += 1
	game_log.log_event("Flood filled %d cells with %s" % [count, _selected_substance_name], Color.ORANGE)
```

- [ ] **Step 2: Run the game**

```bash
godot --path /Users/zholobov/src/gd-alchemy-proto
```

Expected behavior:
- Window opens at 1280x720 with dark background
- Stone receptacle (mortar shape) centered lower portion of screen
- FPS counter in top-left (should show ~60 FPS)
- Click inside receptacle to spawn particles — they fall and pile up
- Keys 1-9 switch substance (different colors)
- F2 toggles game log, F3 toggles perf monitor
- R clears the receptacle
- F floods the receptacle (stress test — watch FPS drop)

- [ ] **Step 3: Benchmark**

Run the game and perform these tests:
1. Spawn particles by clicking/dragging. Note FPS with ~1000 particles.
2. Press F to flood fill. Note FPS with full receptacle (~20K-30K particles).
3. Press R to clear receptacle. Press F3 to see per-system timing.
4. Record results in the game log (F2).

If FPS drops below 30 at full fill on desktop, we'll need to optimize the grid loop (compute shader or GDExtension) before proceeding. Log findings in the commit message.

- [ ] **Step 4: Commit**

```bash
git add src/main.gd src/main.tscn
git commit -m "feat: first runnable build — particle grid, rendering, debug overlay, test input"
```

---

## Phase 3: Fluid Simulation

### Task 8: Fluid Simulation Core

**Files:**
- Create: `src/simulation/fluid_sim.gd`

Marker-and-Cell (MAC) grid fluid simulation. Stores velocity components at cell faces, pressure at cell centers. Fluid markers track which liquid substance occupies each cell. Shares grid dimensions with the particle grid.

- [ ] **Step 1: Create fluid simulation**

Create `src/simulation/fluid_sim.gd`:

```gdscript
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
	## Full fluid simulation step.
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
				var div := u[u_idx(x + 1, y)] - u[u_idx(x, y)] + v[v_idx(x, y + 1)] - v[v_idx(x, y)]

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

			var substance_id := markers[idx(x, y)]

			# Get velocity at cell center (average of face velocities).
			var vx := (u[u_idx(x, y)] + u[u_idx(x + 1, y)]) * 0.5
			var vy := (v[v_idx(x, y)] + v[v_idx(x, y + 1)]) * 0.5

			# Trace back to source position.
			var src_x := float(x) - vx * delta
			var src_y := float(y) - vy * delta

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
```

- [ ] **Step 2: Commit**

```bash
git add src/simulation/fluid_sim.gd
git commit -m "feat: MAC grid fluid simulation — gravity, pressure projection, marker advection"
```

---

### Task 9: Fluid Rendering & Integration

**Files:**
- Modify: `src/rendering/substance_renderer.gd`
- Modify: `src/receptacle/receptacle.gd`
- Modify: `src/main.gd`

Extend the renderer to draw fluid on top of particles. Wire fluid sim into the game loop.

- [ ] **Step 1: Add fluid grid reference to renderer**

In `src/rendering/substance_renderer.gd`, add a fluid sim reference and blend fluid into the render:

Add field:
```gdscript
var fluid: FluidSim
```

Add setup parameter — change `setup` signature:
```gdscript
func setup(p_grid: ParticleGrid, p_cell_size: int = 4, p_fluid: FluidSim = null) -> void:
	grid = p_grid
	cell_size = p_cell_size
	fluid = p_fluid
	# ... rest unchanged
```

In the `render()` method, after setting particle color but before writing to `_pixel_data`, add fluid blending. Replace the inner loop body:

```gdscript
	for i in range(size):
		var substance_id := grid.cells[i]
		var color: Color

		if substance_id == 0:
			color = Color.TRANSPARENT
		elif substance_id < _color_cache.size():
			color = _color_cache[substance_id]
		else:
			color = Color.MAGENTA

		# Blend fluid on top if present.
		if fluid and fluid.markers[i] != 0:
			var fluid_id := fluid.markers[i]
			var fluid_color: Color
			if fluid_id < _color_cache.size():
				fluid_color = _color_cache[fluid_id]
			else:
				fluid_color = Color.MAGENTA
			# Fluid on top of particles — blend with alpha.
			if color.a > 0:
				color = color.lerp(fluid_color, fluid_color.a)
			else:
				color = fluid_color

		# Boundary walls.
		if grid.boundary[i] == 0:
			color = Color(0.15, 0.13, 0.12, 1.0)

		var offset := i * 4
		_pixel_data[offset] = int(color.r8)
		_pixel_data[offset + 1] = int(color.g8)
		_pixel_data[offset + 2] = int(color.b8)
		_pixel_data[offset + 3] = int(color.a8)
```

- [ ] **Step 2: Add FluidSim to receptacle**

In `src/receptacle/receptacle.gd`, add:

```gdscript
var fluid: FluidSim
```

In `_ready()`, after creating the particle grid and before creating the renderer, add:
```gdscript
	# Create fluid simulation sharing the same boundary.
	fluid = FluidSim.new(GRID_WIDTH, GRID_HEIGHT)
	fluid.boundary = grid.boundary
```

Change the renderer setup call:
```gdscript
	renderer.setup(grid, CELL_SIZE, fluid)
```

- [ ] **Step 3: Wire fluid sim into main game loop**

In `src/main.gd`, update `_process`:

```gdscript
func _process(delta: float) -> void:
	# --- Spawn particles on mouse hold ---
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_spawn_timer -= delta
		if _spawn_timer <= 0.0:
			_spawn_timer = SPAWN_INTERVAL
			_spawn_at_mouse()

	# --- Simulation update ---
	perf_monitor.begin_timing("Particle Grid")
	receptacle.grid.update()
	perf_monitor.end_timing("Particle Grid")

	perf_monitor.begin_timing("Fluid Sim")
	receptacle.fluid.update(delta)
	perf_monitor.end_timing("Fluid Sim")

	# --- Rendering ---
	perf_monitor.begin_timing("Render")
	receptacle.renderer.render()
	perf_monitor.end_timing("Render")

	# --- Update counts ---
	perf_monitor.update_particle_count(
		receptacle.grid.count_particles() + receptacle.fluid.count_fluid_cells()
	)
```

Update `_spawn_at_mouse` to spawn fluid for liquid substances:

```gdscript
func _spawn_at_mouse() -> void:
	var mouse_pos := get_global_mouse_position()
	var grid_pos := receptacle.screen_to_grid(mouse_pos)
	var substance := SubstanceRegistry.get_substance(_selected_substance_id)
	if not substance:
		return

	var is_liquid := substance.phase == SubstanceDef.Phase.LIQUID

	for dy in range(-SPAWN_RADIUS, SPAWN_RADIUS + 1):
		for dx in range(-SPAWN_RADIUS, SPAWN_RADIUS + 1):
			if dx * dx + dy * dy <= SPAWN_RADIUS * SPAWN_RADIUS:
				var px := grid_pos.x + dx
				var py := grid_pos.y + dy
				if is_liquid:
					receptacle.fluid.spawn_fluid(px, py, _selected_substance_id)
				else:
					receptacle.grid.spawn_particle(px, py, _selected_substance_id)
```

Update `_clear_receptacle` to also clear fluid:
```gdscript
func _clear_receptacle() -> void:
	for i in range(receptacle.grid.cells.size()):
		receptacle.grid.cells[i] = 0
		receptacle.grid.temperatures[i] = 20.0
		receptacle.grid.charges[i] = 0.0
	receptacle.fluid.markers.fill(0)
	receptacle.fluid.u.fill(0.0)
	receptacle.fluid.v.fill(0.0)
	receptacle.fluid.pressure.fill(0.0)
	game_log.log_event("Receptacle cleared", Color.YELLOW)
```

Update `_flood_fill` to handle liquid substances:
```gdscript
func _flood_fill() -> void:
	var substance := SubstanceRegistry.get_substance(_selected_substance_id)
	if not substance:
		return
	var is_liquid := substance.phase == SubstanceDef.Phase.LIQUID
	var count := 0
	for i in range(receptacle.grid.cells.size()):
		if receptacle.grid.boundary[i] == 1:
			if is_liquid:
				if receptacle.fluid.markers[i] == 0 and receptacle.grid.cells[i] == 0:
					receptacle.fluid.markers[i] = _selected_substance_id
					count += 1
			else:
				if receptacle.grid.cells[i] == 0 and receptacle.fluid.markers[i] == 0:
					receptacle.grid.cells[i] = _selected_substance_id
					count += 1
	game_log.log_event("Flood filled %d cells with %s" % [count, _selected_substance_name], Color.ORANGE)
```

- [ ] **Step 4: Run and verify**

Run the game. Select a liquid substance (e.g., Water = key 5 if it's the 5th substance loaded). Click to spawn fluid — it should flow downward and pool at the bottom. Select powder and drop on top of liquid — powder should sink through lighter liquids or pile on top based on density.

- [ ] **Step 5: Commit**

```bash
git add src/rendering/substance_renderer.gd src/receptacle/receptacle.gd src/main.gd
git commit -m "feat: fluid simulation integrated — liquids flow, pool, and render with blending"
```

---

## Phase 4: Rigid Bodies

### Task 10: Rigid Body Manager

**Files:**
- Create: `src/simulation/rigid_body_mgr.gd`
- Modify: `src/receptacle/receptacle.gd`
- Modify: `src/main.gd`

Manages solid objects dropped into the receptacle. Uses Godot's RigidBody2D for physics. When a solid object dissolves/melts/shatters, it spawns particles or fluid into the grid.

- [ ] **Step 1: Create rigid body manager**

Create `src/simulation/rigid_body_mgr.gd`:

```gdscript
class_name RigidBodyMgr
extends Node2D
## Manages solid objects (RigidBody2D) inside the receptacle.
## Handles creation, displacement of grid cells, and dissolution.

var grid: ParticleGrid
var fluid: FluidSim
var _bodies: Array[RigidBody2D] = []

## Reference to receptacle for coordinate conversion.
var receptacle_position: Vector2
var cell_size: int


func setup(p_grid: ParticleGrid, p_fluid: FluidSim, p_receptacle_pos: Vector2, p_cell_size: int) -> void:
	grid = p_grid
	fluid = p_fluid
	receptacle_position = p_receptacle_pos
	cell_size = p_cell_size


func spawn_object(substance_id: int, screen_pos: Vector2) -> void:
	## Creates a RigidBody2D for a solid substance at the given screen position.
	var substance := SubstanceRegistry.get_substance(substance_id)
	if not substance or substance.phase != SubstanceDef.Phase.SOLID:
		return

	var body := RigidBody2D.new()
	body.mass = substance.density * 0.5  ## Scale density to reasonable mass.
	body.gravity_scale = 1.0
	body.position = screen_pos

	# Simple rectangle collision shape.
	var collision := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(30, 24)
	collision.shape = shape
	body.add_child(collision)

	# Visual representation — colored rectangle.
	var visual := ColorRect.new()
	visual.color = substance.base_color
	visual.size = shape.size
	visual.position = -shape.size / 2
	body.add_child(visual)

	# Store substance info on the body.
	body.set_meta("substance_id", substance_id)
	body.set_meta("substance_name", substance.substance_name)

	add_child(body)
	_bodies.append(body)


func get_body_count() -> int:
	return _bodies.size()


func dissolve_body(body: RigidBody2D) -> void:
	## Remove a rigid body and spawn particles/fluid in its place.
	var substance_id: int = body.get_meta("substance_id", 0)
	var substance := SubstanceRegistry.get_substance(substance_id)

	if substance:
		# Spawn particles at the body's grid position.
		var grid_pos := _screen_to_grid(body.global_position)
		var radius := 4
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if dx * dx + dy * dy <= radius * radius:
					# Spawn as powder version of the substance (simplified).
					grid.spawn_particle(grid_pos.x + dx, grid_pos.y + dy, substance_id)

	_bodies.erase(body)
	body.queue_free()


func _screen_to_grid(screen_pos: Vector2) -> Vector2i:
	var local := screen_pos - receptacle_position
	return Vector2i(int(local.x) / cell_size, int(local.y) / cell_size)
```

- [ ] **Step 2: Add receptacle collision walls for rigid bodies**

In `src/receptacle/receptacle.gd`, add a StaticBody2D with collision shapes for the receptacle walls so rigid bodies bounce off them. Add to `_ready()`:

```gdscript
	# Create static collision walls for rigid bodies.
	var walls := StaticBody2D.new()
	add_child(walls)

	var w_px := float(GRID_WIDTH * CELL_SIZE)
	var h_px := float(GRID_HEIGHT * CELL_SIZE)
	var wall_thick := 10.0

	# Left wall.
	var left_col := CollisionShape2D.new()
	var left_shape := RectangleShape2D.new()
	left_shape.size = Vector2(wall_thick, h_px)
	left_col.shape = left_shape
	left_col.position = Vector2(-wall_thick / 2.0, h_px / 2.0)
	walls.add_child(left_col)

	# Right wall.
	var right_col := CollisionShape2D.new()
	var right_shape := RectangleShape2D.new()
	right_shape.size = Vector2(wall_thick, h_px)
	right_col.shape = right_shape
	right_col.position = Vector2(w_px + wall_thick / 2.0, h_px / 2.0)
	walls.add_child(right_col)

	# Bottom — simplified as flat for rigid body collisions (visual is rounded).
	var bottom_col := CollisionShape2D.new()
	var bottom_shape := RectangleShape2D.new()
	bottom_shape.size = Vector2(w_px, wall_thick)
	bottom_col.shape = bottom_shape
	bottom_col.position = Vector2(w_px / 2.0, h_px + wall_thick / 2.0)
	walls.add_child(bottom_col)
```

Also add the rigid body manager as a field and create it in `_ready()`:

```gdscript
var rigid_body_mgr: RigidBodyMgr
```

In `_ready()`, after creating fluid:
```gdscript
	# Create rigid body manager.
	rigid_body_mgr = RigidBodyMgr.new()
	add_child(rigid_body_mgr)
```

And a method to call after positioning:
```gdscript
func setup_rigid_bodies() -> void:
	rigid_body_mgr.setup(grid, fluid, global_position, CELL_SIZE)
```

- [ ] **Step 3: Wire rigid bodies into main scene**

In `src/main.gd`, after setting receptacle position, call setup:
```gdscript
	receptacle.setup_rigid_bodies()
```

Update `_spawn_at_mouse` to handle solids:

```gdscript
func _spawn_at_mouse() -> void:
	var mouse_pos := get_global_mouse_position()
	var grid_pos := receptacle.screen_to_grid(mouse_pos)
	var substance := SubstanceRegistry.get_substance(_selected_substance_id)
	if not substance:
		return

	match substance.phase:
		SubstanceDef.Phase.LIQUID:
			for dy in range(-SPAWN_RADIUS, SPAWN_RADIUS + 1):
				for dx in range(-SPAWN_RADIUS, SPAWN_RADIUS + 1):
					if dx * dx + dy * dy <= SPAWN_RADIUS * SPAWN_RADIUS:
						receptacle.fluid.spawn_fluid(grid_pos.x + dx, grid_pos.y + dy, _selected_substance_id)
		SubstanceDef.Phase.SOLID:
			# Spawn one rigid body per click, not per frame.
			if _spawn_timer == SPAWN_INTERVAL:
				receptacle.rigid_body_mgr.spawn_object(_selected_substance_id, mouse_pos)
				_spawn_timer = 0.5  # Longer cooldown for solids.
		_:
			# Powder or gas — particle grid.
			for dy in range(-SPAWN_RADIUS, SPAWN_RADIUS + 1):
				for dx in range(-SPAWN_RADIUS, SPAWN_RADIUS + 1):
					if dx * dx + dy * dy <= SPAWN_RADIUS * SPAWN_RADIUS:
						receptacle.grid.spawn_particle(grid_pos.x + dx, grid_pos.y + dy, _selected_substance_id)
```

Update perf monitor in `_process` to show rigid body count and timing:

```gdscript
	perf_monitor.begin_timing("Rigid Bodies")
	# Rigid body physics is handled by Godot engine — nothing to call manually.
	perf_monitor.end_timing("Rigid Bodies")
```

- [ ] **Step 4: Run and verify**

Run the game. Select a solid substance (Rock, Iron Ingot, Crystal, or Ice — find their key number). Click above the receptacle to drop a solid object. It should fall under gravity and collide with the receptacle walls/floor. Drop multiple objects — they should stack and interact physically.

- [ ] **Step 5: Commit**

```bash
git add src/simulation/rigid_body_mgr.gd src/receptacle/receptacle.gd src/main.gd
git commit -m "feat: rigid body manager — solid objects fall, collide, and stack in receptacle"
```

---

## Phase 5: Reactions & Mediator

### Task 11: Reaction Rules Engine

**Files:**
- Create: `src/substance/reaction_rules.gd`

Property-based reaction evaluation. Checks pairs of substances in contact and returns reaction outcomes based on their properties.

- [ ] **Step 1: Create reaction rules engine**

Create `src/substance/reaction_rules.gd`:

```gdscript
class_name ReactionRules
extends RefCounted
## Evaluates property-based reactions between substances in contact.
## No hardcoded recipes — reactions emerge from property comparisons.

## Reaction output: what happens when two substances interact.
class ReactionResult:
	var consumed_a: bool = false  ## Source cell consumed.
	var consumed_b: bool = false  ## Target cell consumed.
	var spawn_substance: String = ""  ## New substance to spawn (by name).
	var heat_output: float = 0.0  ## Temperature delta applied to area.
	var gas_produced: String = ""  ## Gas substance name to spawn above.
	var light_output: float = 0.0  ## Light intensity produced.
	var charge_output: float = 0.0  ## Electrical charge produced.
	var sound_event: String = ""  ## Sound trigger name.

	func has_reaction() -> bool:
		return consumed_a or consumed_b or heat_output != 0.0 or gas_produced != "" or spawn_substance != ""


static func evaluate(a: SubstanceDef, b: SubstanceDef, temp_a: float, temp_b: float) -> ReactionResult:
	## Check all reaction rules between two substances.
	## a = the "active" substance, b = what it's touching.
	var result := ReactionResult.new()

	# Rule 1: Combustion — flammable substance near heat source.
	if a.flammability > 0.3 and a.flash_point > 0 and temp_a >= a.flash_point:
		result.consumed_a = true
		result.heat_output = a.energy_density * 50.0
		result.light_output = a.energy_density * 0.8
		if a.burn_products.size() > 0:
			# Pick first gas product.
			for product in a.burn_products:
				result.gas_produced = product["substance"]
				break
		else:
			result.gas_produced = "Steam"
		result.sound_event = "sizzle"
		return result

	# Rule 2: Acid dissolution — acidic substance meets reducer (metal).
	if a.acidity < 4.0 and b.reducer_strength > 0.3:
		result.consumed_b = true  # The metal dissolves.
		result.heat_output = a.acidity * -5.0 + 35.0  # Lower pH = more heat.
		result.gas_produced = "Flammable Gas"
		result.sound_event = "hiss"
		return result

	# Rule 3: Acid-base neutralization.
	if a.acidity < 4.0 and b.acidity > 10.0:
		result.consumed_a = true
		result.consumed_b = true
		result.spawn_substance = "Salt"
		result.heat_output = 15.0
		result.sound_event = "bubble"
		return result

	# Rule 4: Oxidizer + reducer — exothermic reaction.
	if a.oxidizer_strength > 0.5 and b.reducer_strength > 0.5:
		result.consumed_a = true
		result.consumed_b = true
		result.heat_output = (a.oxidizer_strength + b.reducer_strength) * 40.0
		result.light_output = 0.5
		result.gas_produced = "Steam"
		result.sound_event = "crack"
		return result

	# Rule 5: Heat transfer (not a "reaction" but physical interaction).
	# Handled separately by the temperature field — not here.

	# Rule 6: Dissolution — salt in water (simplified).
	if a.substance_name == "Salt" and b.phase == SubstanceDef.Phase.LIQUID and b.substance_name == "Water":
		if randf() < 0.01:  # Slow dissolution.
			result.consumed_a = true
			result.sound_event = "dissolve"
			return result

	# Rule 7: Rusting — iron + water, very slow.
	if a.magnetic_permeability > 0.5 and b.substance_name == "Water":
		if randf() < 0.001:
			result.consumed_a = true
			result.spawn_substance = "Salt"  # Simplified rust product.
			return result

	return result


static func check_phase_change(substance: SubstanceDef, temperature: float) -> Dictionary:
	## Returns phase change info if temperature triggers a transition.
	## Returns empty dict if no change.
	if substance.phase == SubstanceDef.Phase.SOLID or substance.phase == SubstanceDef.Phase.POWDER:
		if temperature >= substance.melting_point:
			return {"new_phase": "liquid", "target_substance": "Water"}  # Simplified.
	if substance.phase == SubstanceDef.Phase.LIQUID:
		if temperature >= substance.boiling_point:
			return {"new_phase": "gas", "target_substance": "Steam"}
		if temperature <= substance.melting_point:
			return {"new_phase": "solid", "target_substance": "Ice"}
	if substance.phase == SubstanceDef.Phase.GAS:
		if temperature <= substance.boiling_point:
			return {"new_phase": "liquid", "target_substance": "Water"}
	return {}
```

- [ ] **Step 2: Commit**

```bash
git add src/substance/reaction_rules.gd
git commit -m "feat: property-based reaction rules — combustion, acid, oxidation, phase changes"
```

---

### Task 12: Mediator

**Files:**
- Create: `src/simulation/mediator.gd`
- Modify: `src/main.gd`

Cross-system interaction handler. Checks boundaries where particles, fluids, and rigid bodies overlap. Applies reaction rules and produces outputs.

- [ ] **Step 1: Create mediator**

Create `src/simulation/mediator.gd`:

```gdscript
class_name Mediator
extends RefCounted
## Cross-system interaction handler. Checks contacts between particles,
## fluids, and rigid bodies. Applies reaction rules and feeds outputs
## back into the appropriate systems.

var grid: ParticleGrid
var fluid: FluidSim
var game_log: GameLog

## Track reaction count per frame for performance monitoring.
var reactions_this_frame: int = 0

const MAX_REACTIONS_PER_FRAME := 500  ## Cap to prevent runaway cascades.


func setup(p_grid: ParticleGrid, p_fluid: FluidSim, p_log: GameLog) -> void:
	grid = p_grid
	fluid = p_fluid
	game_log = p_log


func update() -> void:
	reactions_this_frame = 0
	_check_particle_contacts()
	_check_particle_fluid_contacts()


func _check_particle_contacts() -> void:
	## Check neighboring particles in the grid for reactions.
	for y in range(grid.height):
		for x in range(grid.width):
			if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
				return

			var id_a := grid.get_cell(x, y)
			if id_a <= 0:
				continue

			var substance_a := SubstanceRegistry.get_substance(id_a)
			if not substance_a:
				continue

			# Check 4-connected neighbors.
			var neighbors := [
				Vector2i(x + 1, y), Vector2i(x - 1, y),
				Vector2i(x, y + 1), Vector2i(x, y - 1),
			]

			for n in neighbors:
				if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
					return
				var id_b := grid.get_cell(n.x, n.y)
				if id_b <= 0 or id_b == id_a:
					continue

				var substance_b := SubstanceRegistry.get_substance(id_b)
				if not substance_b:
					continue

				var temp_a := grid.temperatures[grid.idx(x, y)]
				var temp_b := grid.temperatures[grid.idx(n.x, n.y)]

				var result := ReactionRules.evaluate(substance_a, substance_b, temp_a, temp_b)
				if result.has_reaction():
					_apply_reaction(x, y, n.x, n.y, result, substance_a, substance_b)
					reactions_this_frame += 1


func _check_particle_fluid_contacts() -> void:
	## Check where particles and fluid cells are adjacent.
	for y in range(grid.height):
		for x in range(grid.width):
			if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
				return

			var particle_id := grid.get_cell(x, y)
			var fluid_id := fluid.markers[grid.idx(x, y)] if grid.in_bounds(x, y) else 0

			# Particle in same cell as fluid.
			if particle_id > 0 and fluid_id > 0:
				var sub_p := SubstanceRegistry.get_substance(particle_id)
				var sub_f := SubstanceRegistry.get_substance(fluid_id)
				if sub_p and sub_f:
					var temp := grid.temperatures[grid.idx(x, y)]
					var result := ReactionRules.evaluate(sub_p, sub_f, temp, temp)
					if result.has_reaction():
						_apply_reaction_particle_fluid(x, y, result, sub_p, sub_f)
						reactions_this_frame += 1
						continue

			# Check particle neighbors for adjacent fluid.
			if particle_id > 0:
				var neighbors := [
					Vector2i(x + 1, y), Vector2i(x - 1, y),
					Vector2i(x, y + 1), Vector2i(x, y - 1),
				]
				for n in neighbors:
					if reactions_this_frame >= MAX_REACTIONS_PER_FRAME:
						return
					if not grid.in_bounds(n.x, n.y):
						continue
					var adj_fluid := fluid.markers[grid.idx(n.x, n.y)]
					if adj_fluid <= 0:
						continue
					var sub_p := SubstanceRegistry.get_substance(particle_id)
					var sub_f := SubstanceRegistry.get_substance(adj_fluid)
					if sub_p and sub_f:
						var temp := grid.temperatures[grid.idx(x, y)]
						var result := ReactionRules.evaluate(sub_p, sub_f, temp, temp)
						if result.has_reaction():
							_apply_reaction_mixed(x, y, n.x, n.y, result, sub_p, sub_f)
							reactions_this_frame += 1


func _apply_reaction(ax: int, ay: int, bx: int, by: int, result: ReactionRules.ReactionResult, sub_a: SubstanceDef, sub_b: SubstanceDef) -> void:
	if result.consumed_a:
		grid.clear_cell(ax, ay)
	if result.consumed_b:
		grid.clear_cell(bx, by)

	# Spawn new substance.
	if result.spawn_substance != "":
		var new_id := SubstanceRegistry.get_id(result.spawn_substance)
		if new_id > 0:
			if result.consumed_a:
				grid.spawn_particle(ax, ay, new_id)
			elif result.consumed_b:
				grid.spawn_particle(bx, by, new_id)

	# Heat output.
	if result.heat_output != 0.0:
		_apply_heat(ax, ay, result.heat_output)

	# Gas production.
	if result.gas_produced != "":
		_spawn_gas(ax, ay, result.gas_produced)

	# Log significant reactions.
	if game_log and (result.consumed_a or result.consumed_b):
		game_log.log_event(
			"%s + %s -> reaction" % [sub_a.substance_name, sub_b.substance_name],
			Color(1.0, 0.6, 0.2)
		)


func _apply_reaction_particle_fluid(x: int, y: int, result: ReactionRules.ReactionResult, sub_p: SubstanceDef, sub_f: SubstanceDef) -> void:
	if result.consumed_a:
		grid.clear_cell(x, y)
	if result.consumed_b:
		fluid.clear_cell(x, y)
	if result.heat_output != 0.0:
		_apply_heat(x, y, result.heat_output)
	if result.gas_produced != "":
		_spawn_gas(x, y, result.gas_produced)
	if result.spawn_substance != "":
		var new_id := SubstanceRegistry.get_id(result.spawn_substance)
		if new_id > 0 and result.consumed_a:
			grid.spawn_particle(x, y, new_id)


func _apply_reaction_mixed(px: int, py: int, fx: int, fy: int, result: ReactionRules.ReactionResult, sub_p: SubstanceDef, sub_f: SubstanceDef) -> void:
	if result.consumed_a:
		grid.clear_cell(px, py)
	if result.consumed_b:
		fluid.clear_cell(fx, fy)
	if result.heat_output != 0.0:
		_apply_heat(px, py, result.heat_output)
	if result.gas_produced != "":
		_spawn_gas(px, py, result.gas_produced)


func _apply_heat(x: int, y: int, amount: float) -> void:
	## Apply heat to a radius around the point.
	var radius := 3
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var nx := x + dx
			var ny := y + dy
			if grid.in_bounds(nx, ny):
				var dist := sqrt(float(dx * dx + dy * dy))
				var falloff := maxf(0.0, 1.0 - dist / float(radius))
				grid.temperatures[grid.idx(nx, ny)] += amount * falloff


func _spawn_gas(x: int, y: int, gas_name: String) -> void:
	## Spawn gas particles above the reaction point.
	var gas_id := SubstanceRegistry.get_id(gas_name)
	if gas_id <= 0:
		return
	# Try to spawn a few cells above.
	for dy in range(-3, 0):
		var ny := y + dy
		if grid.is_empty(x, ny):
			grid.spawn_particle(x, ny, gas_id)
			return
```

- [ ] **Step 2: Wire mediator into main game loop**

In `src/main.gd`, add mediator field:

```gdscript
var mediator: Mediator
```

In `_ready()`, after creating the receptacle and debug systems:
```gdscript
	# Create mediator.
	mediator = Mediator.new()
	mediator.setup(receptacle.grid, receptacle.fluid, game_log)
```

In `_process()`, add mediator timing after fluid sim:
```gdscript
	perf_monitor.begin_timing("Mediator")
	mediator.update()
	perf_monitor.end_timing("Mediator")
```

- [ ] **Step 3: Run and verify reactions**

Run the game. Test the following:
1. Drop iron filings (key for Iron Filings), then spawn acid (key for Acid) next to them. Should see dissolution reaction — iron disappears, gas rises, area heats up.
2. Drop sulfur, then raise its temperature somehow (will be easier with temperature field in next task, but acid reactions nearby produce heat that can trigger ignition if the heat is enough).
3. Check F2 game log for reaction events.

- [ ] **Step 4: Commit**

```bash
git add src/simulation/mediator.gd src/main.gd
git commit -m "feat: mediator — cross-system reactions, heat propagation, gas spawning"
```

---

## Phase 6: Fields System

### Task 13: Field Base & Temperature Field

**Files:**
- Create: `src/fields/field_base.gd`
- Create: `src/fields/temperature_field.gd`
- Create: `src/fields/pressure_field.gd`

The field base class and the two most critical fields.

- [ ] **Step 1: Create field base class**

Create `src/fields/field_base.gd`:

```gdscript
class_name FieldBase
extends RefCounted
## Base class for all simulation fields. A field is a continuous property
## that propagates across the simulation space and feeds back into reactions.

var width: int
var height: int
var values: PackedFloat32Array
var boundary: PackedByteArray

## Whether this field should update every frame or every N frames.
var update_interval: int = 1
var _frame_counter: int = 0


func _init(w: int, h: int) -> void:
	width = w
	height = h
	values = PackedFloat32Array()
	values.resize(w * h)
	boundary = PackedByteArray()
	boundary.resize(w * h)
	boundary.fill(1)


func idx(x: int, y: int) -> int:
	return y * width + x


func is_valid(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height and boundary[idx(x, y)] == 1


func get_value(x: int, y: int) -> float:
	if not is_valid(x, y):
		return 0.0
	return values[idx(x, y)]


func set_value(x: int, y: int, val: float) -> void:
	if is_valid(x, y):
		values[idx(x, y)] = val


func add_value(x: int, y: int, amount: float) -> void:
	if is_valid(x, y):
		values[idx(x, y)] += amount


func should_update() -> bool:
	_frame_counter += 1
	if _frame_counter >= update_interval:
		_frame_counter = 0
		return true
	return false


func update(_grid: ParticleGrid, _fluid: FluidSim, _delta: float) -> void:
	## Override in subclasses. Called each frame (or per update_interval).
	pass
```

- [ ] **Step 2: Create temperature field**

Create `src/fields/temperature_field.gd`:

```gdscript
class_name TemperatureField
extends FieldBase
## Temperature field. Heat conducts through substances based on thermal
## conductivity, radiates through air slowly, and cools toward ambient.

const AMBIENT_TEMP := 20.0
const AMBIENT_COOLING_RATE := 0.05  ## Per frame, fraction toward ambient.
const CONDUCTION_RATE := 0.1  ## Base conduction speed.
const RADIATION_RATE := 0.01  ## Heat radiation through empty space.


func update(grid: ParticleGrid, fluid: FluidSim, _delta: float) -> void:
	if not should_update():
		return

	# Sync: field values are the canonical temperature source.
	# Copy current state to work buffer.
	var new_values := values.duplicate()

	for y in range(height):
		for x in range(width):
			if not is_valid(x, y):
				continue

			var i := idx(x, y)
			var temp := values[i]
			var substance_id := grid.cells[i]
			var fluid_id := fluid.markers[i] if i < fluid.markers.size() else 0
			var has_substance := substance_id > 0 or fluid_id > 0

			# Get substance conductivity.
			var conductivity := RADIATION_RATE  # Default: empty air.
			if substance_id > 0:
				var sub := SubstanceRegistry.get_substance(substance_id)
				if sub:
					conductivity = sub.conductivity_thermal * CONDUCTION_RATE
			elif fluid_id > 0:
				var sub := SubstanceRegistry.get_substance(fluid_id)
				if sub:
					conductivity = sub.conductivity_thermal * CONDUCTION_RATE

			# Conduct heat to/from neighbors.
			var neighbors := [
				Vector2i(x + 1, y), Vector2i(x - 1, y),
				Vector2i(x, y + 1), Vector2i(x, y - 1),
			]

			for n in neighbors:
				if not is_valid(n.x, n.y):
					continue
				var ni := idx(n.x, n.y)
				var neighbor_temp := values[ni]
				var diff := neighbor_temp - temp

				# Heat flows from hot to cold.
				var flow := diff * conductivity
				new_values[i] += flow * 0.25  # Spread across 4 neighbors.

			# Ambient cooling.
			if has_substance:
				new_values[i] = lerpf(new_values[i], AMBIENT_TEMP, AMBIENT_COOLING_RATE * 0.1)
			else:
				new_values[i] = lerpf(new_values[i], AMBIENT_TEMP, AMBIENT_COOLING_RATE)

	values = new_values

	# Sync temperatures back to grid (grid.temperatures is used by mediator).
	for i in range(mini(values.size(), grid.temperatures.size())):
		grid.temperatures[i] = values[i]
```

- [ ] **Step 3: Create pressure field**

Create `src/fields/pressure_field.gd`:

```gdscript
class_name PressureField
extends FieldBase
## Pressure field. Tracks gas accumulation in the receptacle.
## When pressure exceeds the containment threshold, triggers explosion.

var gas_count: int = 0
var receptacle_volume: int = 0  ## Total valid cells.
var pressure_level: float = 0.0  ## 0-1 normalized, 1 = containment failure.
var containment_threshold: float = 100.0
var _has_exploded: bool = false

signal containment_failure


func calculate_volume() -> void:
	receptacle_volume = 0
	for i in range(boundary.size()):
		if boundary[i] == 1:
			receptacle_volume += 1


func update(grid: ParticleGrid, _fluid: FluidSim, _delta: float) -> void:
	if not should_update():
		return

	# Count gas particles.
	gas_count = 0
	for i in range(grid.cells.size()):
		if grid.cells[i] <= 0:
			continue
		var sub := SubstanceRegistry.get_substance(grid.cells[i])
		if sub and sub.phase == SubstanceDef.Phase.GAS:
			gas_count += 1

	# Calculate pressure as ratio of gas to available volume.
	if receptacle_volume > 0:
		pressure_level = float(gas_count) / float(receptacle_volume) * 10.0
	else:
		pressure_level = 0.0

	# Store as field values (for visualization).
	values.fill(pressure_level)

	# Check containment.
	if pressure_level >= 1.0 and not _has_exploded:
		_has_exploded = true
		containment_failure.emit()


func reset() -> void:
	_has_exploded = false
	pressure_level = 0.0
	gas_count = 0
```

- [ ] **Step 4: Commit**

```bash
git add src/fields/
git commit -m "feat: field system — base class, temperature conduction, pressure tracking"
```

---

### Task 14: Remaining Fields

**Files:**
- Create: `src/fields/electric_field.gd`
- Create: `src/fields/light_field.gd`
- Create: `src/fields/magnetic_field.gd`
- Create: `src/fields/sound_field.gd`

- [ ] **Step 1: Create electric field**

Create `src/fields/electric_field.gd`:

```gdscript
class_name ElectricField
extends FieldBase
## Electrical charge propagation through conductive substances.

const DISSIPATION_RATE := 0.05
const PROPAGATION_STRENGTH := 0.3


func _init(w: int, h: int) -> void:
	super(w, h)
	update_interval = 2  ## Update every other frame.


func update(grid: ParticleGrid, fluid: FluidSim, _delta: float) -> void:
	if not should_update():
		return

	var new_values := values.duplicate()

	for y in range(height):
		for x in range(width):
			if not is_valid(x, y):
				continue

			var i := idx(x, y)
			var charge := values[i]
			if absf(charge) < 0.001:
				continue

			# Get conductivity of this cell's substance.
			var substance_id := grid.cells[i]
			var fluid_id := fluid.markers[i] if i < fluid.markers.size() else 0
			var conductivity := 0.0

			if substance_id > 0:
				var sub := SubstanceRegistry.get_substance(substance_id)
				if sub:
					conductivity = sub.conductivity_electric
			elif fluid_id > 0:
				var sub := SubstanceRegistry.get_substance(fluid_id)
				if sub:
					conductivity = sub.conductivity_electric

			if conductivity < 0.01:
				# Insulator — charge doesn't flow, just dissipates.
				new_values[i] *= (1.0 - DISSIPATION_RATE)
				continue

			# Propagate to conductive neighbors.
			var neighbors := [
				Vector2i(x + 1, y), Vector2i(x - 1, y),
				Vector2i(x, y + 1), Vector2i(x, y - 1),
			]

			for n in neighbors:
				if not is_valid(n.x, n.y):
					continue
				var ni := idx(n.x, n.y)
				var n_sub_id := grid.cells[ni]
				var n_fluid_id := fluid.markers[ni] if ni < fluid.markers.size() else 0
				var n_conductivity := 0.0
				if n_sub_id > 0:
					var ns := SubstanceRegistry.get_substance(n_sub_id)
					if ns:
						n_conductivity = ns.conductivity_electric
				elif n_fluid_id > 0:
					var ns := SubstanceRegistry.get_substance(n_fluid_id)
					if ns:
						n_conductivity = ns.conductivity_electric

				if n_conductivity > 0.01:
					var flow := charge * conductivity * n_conductivity * PROPAGATION_STRENGTH * 0.25
					new_values[ni] += flow
					new_values[i] -= flow

			# Dissipate.
			new_values[i] *= (1.0 - DISSIPATION_RATE * (1.0 - conductivity))

	values = new_values

	# Sync charges back to grid.
	for i in range(mini(values.size(), grid.charges.size())):
		grid.charges[i] = values[i]
```

- [ ] **Step 2: Create light field**

Create `src/fields/light_field.gd`:

```gdscript
class_name LightField
extends FieldBase
## Tracks light emission across the simulation.
## Sources: luminous substances, hot substances, reactions.

const GLOW_TEMP_THRESHOLD := 300.0  ## Temperature above which things glow.
const TEMP_GLOW_FACTOR := 0.002  ## Glow per degree above threshold.

## Active light sources for the renderer to read.
var light_sources: Array[Dictionary] = []  ## [{x, y, intensity, color}]
const MAX_LIGHTS := 20


func _init(w: int, h: int) -> void:
	super(w, h)
	update_interval = 3  ## Update every 3rd frame — light is expensive.


func update(grid: ParticleGrid, fluid: FluidSim, _delta: float) -> void:
	if not should_update():
		return

	light_sources.clear()
	values.fill(0.0)

	for y in range(height):
		for x in range(width):
			if not is_valid(x, y):
				continue
			var i := idx(x, y)
			var substance_id := grid.cells[i]
			var fluid_id := fluid.markers[i] if i < fluid.markers.size() else 0
			var sub: SubstanceDef = null

			if substance_id > 0:
				sub = SubstanceRegistry.get_substance(substance_id)
			elif fluid_id > 0:
				sub = SubstanceRegistry.get_substance(fluid_id)

			if not sub:
				continue

			var intensity := 0.0
			var color := sub.luminosity_color

			# Innate luminosity.
			if sub.luminosity > 0.0:
				intensity += sub.luminosity

			# Temperature-based glow.
			var temp := grid.temperatures[i]
			if temp > GLOW_TEMP_THRESHOLD:
				intensity += (temp - GLOW_TEMP_THRESHOLD) * TEMP_GLOW_FACTOR
				# Hot glow shifts toward red/orange/white.
				var heat_ratio := clampf((temp - GLOW_TEMP_THRESHOLD) / 1000.0, 0.0, 1.0)
				color = Color.RED.lerp(Color.WHITE, heat_ratio)

			# Electrical glow.
			var charge := grid.charges[i]
			if absf(charge) > 0.1:
				intensity += absf(charge) * 0.3
				color = color.lerp(Color(0.5, 0.7, 1.0), 0.5)

			if intensity > 0.1:
				values[i] = intensity
				if light_sources.size() < MAX_LIGHTS:
					light_sources.append({
						"x": x, "y": y,
						"intensity": intensity,
						"color": color,
					})
```

- [ ] **Step 3: Create magnetic field**

Create `src/fields/magnetic_field.gd`:

```gdscript
class_name MagneticField
extends FieldBase
## Magnetic field. Radiates from magnetic substances, influences ferrous particles.

const FIELD_FALLOFF := 0.85  ## Per-cell falloff.
const PROPAGATION_RADIUS := 8


func _init(w: int, h: int) -> void:
	super(w, h)
	update_interval = 4  ## Update every 4th frame.


func update(grid: ParticleGrid, _fluid: FluidSim, _delta: float) -> void:
	if not should_update():
		return

	values.fill(0.0)

	# Find magnetic sources and radiate field.
	for y in range(height):
		for x in range(width):
			if not is_valid(x, y):
				continue
			var i := idx(x, y)
			var substance_id := grid.cells[i]
			if substance_id <= 0:
				continue
			var sub := SubstanceRegistry.get_substance(substance_id)
			if not sub or sub.magnetic_permeability < 0.1:
				continue

			# This cell is a magnetic source. Radiate field.
			var strength := sub.magnetic_permeability

			# Also: electric current generates magnetism.
			var charge := grid.charges[i]
			if absf(charge) > 0.1:
				strength += absf(charge) * 0.5

			_radiate(x, y, strength)


func _radiate(cx: int, cy: int, strength: float) -> void:
	for dy in range(-PROPAGATION_RADIUS, PROPAGATION_RADIUS + 1):
		for dx in range(-PROPAGATION_RADIUS, PROPAGATION_RADIUS + 1):
			var nx := cx + dx
			var ny := cy + dy
			if not is_valid(nx, ny):
				continue
			var dist := sqrt(float(dx * dx + dy * dy))
			if dist > PROPAGATION_RADIUS:
				continue
			var falloff := strength / maxf(1.0, dist * dist)  # Inverse square.
			values[idx(nx, ny)] += falloff


func apply_forces(grid: ParticleGrid) -> void:
	## Move magnetic particles toward field maxima. Called from mediator or main loop.
	for y in range(grid.height - 1, 0, -1):
		for x in range(1, grid.width - 1):
			var substance_id := grid.get_cell(x, y)
			if substance_id <= 0:
				continue
			var sub := SubstanceRegistry.get_substance(substance_id)
			if not sub or sub.magnetic_permeability < 0.1:
				continue

			# Find neighbor with strongest field.
			var best_dx := 0
			var best_dy := 0
			var best_val := values[idx(x, y)]

			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					if dx == 0 and dy == 0:
						continue
					var nx := x + dx
					var ny := y + dy
					if is_valid(nx, ny) and values[idx(nx, ny)] > best_val:
						if grid.get_cell(nx, ny) == 0:
							best_val = values[idx(nx, ny)]
							best_dx = dx
							best_dy = dy

			# Move toward strongest field (probabilistic to avoid jitter).
			if best_dx != 0 or best_dy != 0:
				if randf() < 0.3 * sub.magnetic_permeability:
					grid._swap(x, y, x + best_dx, y + best_dy)
```

- [ ] **Step 4: Create sound field**

Create `src/fields/sound_field.gd`:

```gdscript
class_name SoundField
extends RefCounted
## Sound system. Not a spatial field — triggers audio events.
## Queues sound events from reactions, plays them with volume scaling.

var _pending_events: Array[Dictionary] = []  ## [{name, intensity}]
var _audio_players: Dictionary = {}  ## name -> AudioStreamPlayer
var _parent_node: Node

const MAX_SIMULTANEOUS := 5
var _active_count := 0


func setup(parent: Node) -> void:
	_parent_node = parent


func trigger(event_name: String, intensity: float = 1.0) -> void:
	## Queue a sound event to play this frame.
	if _pending_events.size() < MAX_SIMULTANEOUS:
		_pending_events.append({"name": event_name, "intensity": clampf(intensity, 0.0, 1.0)})


func flush() -> void:
	## Play all queued events. Call once per frame after all systems update.
	for event in _pending_events:
		_play(event["name"], event["intensity"])
	_pending_events.clear()


func _play(event_name: String, intensity: float) -> void:
	## Placeholder: just prints the event. Replace with actual AudioStreamPlayer
	## once we have sound assets.
	if intensity > 0.3:
		print("[SFX] %s (%.1f)" % [event_name, intensity])
```

- [ ] **Step 5: Commit**

```bash
git add src/fields/
git commit -m "feat: electric, light, magnetic, and sound fields"
```

---

### Task 15: Field Renderer & Integration

**Files:**
- Create: `src/rendering/field_renderer.gd`
- Modify: `src/main.gd`

Visualizes field effects: temperature color shift on particles, light glow, electric sparks, magnetic field lines. Also wires all fields into the game loop.

- [ ] **Step 1: Create field renderer**

Create `src/rendering/field_renderer.gd`:

```gdscript
class_name FieldRenderer
extends Node2D
## Visualizes field effects on top of the substance renderer.
## Draws temperature color shifts, light glows, electric arcs.

var grid: ParticleGrid
var temperature_field: TemperatureField
var light_field: LightField
var electric_field: ElectricField
var pressure_field: PressureField
var cell_size: int = 4

## Godot Light2D nodes for dynamic lighting.
var _lights: Array[PointLight2D] = []
var _light_texture: Texture2D


func setup(p_grid: ParticleGrid, p_cell_size: int,
		p_temp: TemperatureField, p_light: LightField,
		p_electric: ElectricField, p_pressure: PressureField) -> void:
	grid = p_grid
	cell_size = p_cell_size
	temperature_field = p_temp
	light_field = p_light
	electric_field = p_electric
	pressure_field = p_pressure

	# Create a simple radial gradient texture for lights.
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in range(64):
		for x in range(64):
			var dx := float(x - 32) / 32.0
			var dy := float(y - 32) / 32.0
			var dist := sqrt(dx * dx + dy * dy)
			var alpha := clampf(1.0 - dist, 0.0, 1.0)
			alpha = alpha * alpha  # Quadratic falloff.
			img.set_pixel(x, y, Color(1, 1, 1, alpha))
	_light_texture = ImageTexture.create_from_image(img)


func update_visuals() -> void:
	# Update dynamic lights from light field.
	_update_lights()
	# Redraw overlays.
	queue_redraw()


func _update_lights() -> void:
	## Sync PointLight2D nodes with light field sources.
	var sources := light_field.light_sources

	# Add/remove lights to match source count.
	while _lights.size() < sources.size() and _lights.size() < 20:
		var light := PointLight2D.new()
		light.texture = _light_texture
		light.texture_scale = 2.0
		light.energy = 0.5
		light.blend_mode = Light2D.BLEND_MODE_ADD
		add_child(light)
		_lights.append(light)

	# Update positions and colors.
	for i in range(_lights.size()):
		if i < sources.size():
			var src := sources[i]
			_lights[i].visible = true
			_lights[i].position = Vector2(src["x"] * cell_size, src["y"] * cell_size)
			_lights[i].color = src["color"]
			_lights[i].energy = clampf(src["intensity"], 0.1, 2.0)
			_lights[i].texture_scale = 1.0 + src["intensity"] * 2.0
		else:
			_lights[i].visible = false


func _draw() -> void:
	if not grid:
		return

	# Draw electric arcs between highly charged cells.
	_draw_electric_arcs()

	# Draw pressure warning if pressure is building.
	if pressure_field and pressure_field.pressure_level > 0.3:
		_draw_pressure_warning()


func _draw_electric_arcs() -> void:
	if not electric_field:
		return
	for y in range(0, grid.height, 2):
		for x in range(0, grid.width, 2):
			var charge := electric_field.get_value(x, y)
			if absf(charge) < 0.5:
				continue
			# Draw a small spark at this cell.
			var pos := Vector2(x * cell_size, y * cell_size)
			var spark_color := Color(0.5, 0.7, 1.0, clampf(absf(charge), 0.0, 1.0))
			draw_rect(Rect2(pos, Vector2(cell_size, cell_size)), spark_color)


func _draw_pressure_warning() -> void:
	## Shake effect and red tint when pressure is high.
	var intensity := pressure_field.pressure_level
	# Red border glow.
	var border_color := Color(1.0, 0.2, 0.0, clampf(intensity * 0.5, 0.0, 0.8))
	var w := grid.width * cell_size
	var h := grid.height * cell_size
	var thickness := 3.0 + intensity * 5.0
	draw_rect(Rect2(0, 0, w, h), border_color, false, thickness)
```

- [ ] **Step 2: Wire all fields and renderer into main loop**

In `src/main.gd`, add field references:

```gdscript
var temperature_field: TemperatureField
var pressure_field: PressureField
var electric_field: ElectricField
var light_field: LightField
var magnetic_field: MagneticField
var sound_field: SoundField
var field_renderer: FieldRenderer
```

In `_ready()`, after creating receptacle and mediator, create fields:
```gdscript
	# Create fields — all share the same boundary.
	var gw := Receptacle.GRID_WIDTH
	var gh := Receptacle.GRID_HEIGHT
	var bound := receptacle.grid.boundary

	temperature_field = TemperatureField.new(gw, gh)
	temperature_field.boundary = bound

	pressure_field = PressureField.new(gw, gh)
	pressure_field.boundary = bound
	pressure_field.calculate_volume()
	pressure_field.containment_failure.connect(_on_containment_failure)

	electric_field = ElectricField.new(gw, gh)
	electric_field.boundary = bound

	light_field = LightField.new(gw, gh)
	light_field.boundary = bound

	magnetic_field = MagneticField.new(gw, gh)
	magnetic_field.boundary = bound

	sound_field = SoundField.new()
	sound_field.setup(self)

	# Create field renderer.
	field_renderer = FieldRenderer.new()
	field_renderer.setup(
		receptacle.grid, Receptacle.CELL_SIZE,
		temperature_field, light_field, electric_field, pressure_field
	)
	receptacle.add_child(field_renderer)
```

Add containment failure handler:
```gdscript
func _on_containment_failure() -> void:
	game_log.log_event("CONTAINMENT FAILURE — EXPLOSION!", Color.RED)
	# Scatter all particles outward.
	var grid := receptacle.grid
	for y in range(grid.height):
		for x in range(grid.width):
			if grid.get_cell(x, y) > 0:
				if randf() < 0.7:
					grid.clear_cell(x, y)
	receptacle.fluid.markers.fill(0)
	pressure_field.reset()
```

Update `_process()` to include all fields:
```gdscript
func _process(delta: float) -> void:
	# --- Spawn ---
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_spawn_timer -= delta
		if _spawn_timer <= 0.0:
			_spawn_timer = SPAWN_INTERVAL
			_spawn_at_mouse()

	# --- Simulation ---
	perf_monitor.begin_timing("Particle Grid")
	receptacle.grid.update()
	perf_monitor.end_timing("Particle Grid")

	perf_monitor.begin_timing("Fluid Sim")
	receptacle.fluid.update(delta)
	perf_monitor.end_timing("Fluid Sim")

	perf_monitor.begin_timing("Mediator")
	mediator.update()
	perf_monitor.end_timing("Mediator")

	# --- Fields ---
	perf_monitor.begin_timing("Fields")
	temperature_field.update(receptacle.grid, receptacle.fluid, delta)
	pressure_field.update(receptacle.grid, receptacle.fluid, delta)
	electric_field.update(receptacle.grid, receptacle.fluid, delta)
	light_field.update(receptacle.grid, receptacle.fluid, delta)
	magnetic_field.update(receptacle.grid, receptacle.fluid, delta)
	magnetic_field.apply_forces(receptacle.grid)
	sound_field.flush()
	perf_monitor.end_timing("Fields")

	# --- Rendering ---
	perf_monitor.begin_timing("Render")
	receptacle.renderer.render()
	field_renderer.update_visuals()
	perf_monitor.end_timing("Render")

	perf_monitor.update_particle_count(
		receptacle.grid.count_particles() + receptacle.fluid.count_fluid_cells()
	)
```

- [ ] **Step 3: Run and verify fields**

Run the game. Test:
1. Drop substances and observe temperature spreading (F3 shows timing).
2. Create reactions (acid + iron) and see if heat radiates to neighbors.
3. If enough gas is produced, watch pressure build and eventually trigger containment failure.
4. Light2D glow should appear near hot or luminous substances.

- [ ] **Step 4: Commit**

```bash
git add src/rendering/field_renderer.gd src/main.gd
git commit -m "feat: all fields integrated — temperature, pressure, electric, light, magnetic, sound"
```

---

## Phase 7: Player Interaction

### Task 16: Shelf & Drag-Drop

**Files:**
- Create: `src/interaction/shelf.gd`
- Create: `src/interaction/drag_drop.gd`
- Modify: `src/main.gd`

Replace the number-key test input with the actual shelf UI and drag-drop interaction.

- [ ] **Step 1: Create shelf**

Create `src/interaction/shelf.gd`:

```gdscript
class_name Shelf
extends HBoxContainer
## Top shelf displaying available substances as draggable items.

signal substance_picked(substance_id: int, phase: SubstanceDef.Phase)

const ITEM_SIZE := Vector2(70, 70)


func _ready() -> void:
	# Style the shelf bar.
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.16, 0.12, 0.1, 1.0)
	style.border_color = Color(0.3, 0.22, 0.16, 1.0)
	style.border_width_bottom = 3
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	add_theme_stylebox_override("panel", style)

	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override("separation", 8)

	_populate()


func _populate() -> void:
	for i in range(1, SubstanceRegistry.substances.size()):
		var substance := SubstanceRegistry.get_substance(i)
		if not substance:
			continue
		# Skip gases — they're reaction products, not player-placed.
		if substance.phase == SubstanceDef.Phase.GAS:
			continue

		var item := Button.new()
		item.custom_minimum_size = ITEM_SIZE
		item.text = substance.substance_name.substr(0, 8)
		item.tooltip_text = substance.substance_name

		# Style based on substance.
		var item_style := StyleBoxFlat.new()
		item_style.bg_color = substance.base_color.darkened(0.3)
		item_style.border_color = substance.base_color
		item_style.set_border_width_all(2)
		item_style.set_corner_radius_all(4)
		item.add_theme_stylebox_override("normal", item_style)

		var hover_style := item_style.duplicate()
		hover_style.bg_color = substance.base_color.darkened(0.1)
		item.add_theme_stylebox_override("hover", hover_style)

		item.add_theme_font_size_override("font_size", 11)
		item.add_theme_color_override("font_color", Color.WHITE)

		# Phase indicator.
		var phase_text := ""
		match substance.phase:
			SubstanceDef.Phase.POWDER: phase_text = "[P]"
			SubstanceDef.Phase.LIQUID: phase_text = "[L]"
			SubstanceDef.Phase.SOLID: phase_text = "[S]"
		item.text = "%s\n%s" % [substance.substance_name.substr(0, 7), phase_text]

		var sub_id := i
		item.pressed.connect(func(): substance_picked.emit(sub_id, substance.phase))

		add_child(item)
```

- [ ] **Step 2: Create drag-drop handler**

Create `src/interaction/drag_drop.gd`:

```gdscript
class_name DragDrop
extends Node2D
## Handles dragging substances from shelf to receptacle.
## For liquids: tilt to pour. For solids: drop as rigid body.
## For powders: drop as particle stream.

signal dropped(substance_id: int, phase: SubstanceDef.Phase, position: Vector2)
signal pouring(substance_id: int, position: Vector2)

var active_substance_id: int = 0
var active_phase: SubstanceDef.Phase = SubstanceDef.Phase.POWDER
var is_dragging: bool = false

var _drag_visual: ColorRect
var _drag_label: Label


func _ready() -> void:
	# Create drag visual (the "object" being dragged).
	_drag_visual = ColorRect.new()
	_drag_visual.size = Vector2(40, 40)
	_drag_visual.visible = false
	add_child(_drag_visual)

	_drag_label = Label.new()
	_drag_label.add_theme_font_size_override("font_size", 10)
	_drag_label.add_theme_color_override("font_color", Color.WHITE)
	_drag_visual.add_child(_drag_label)


func start_drag(substance_id: int, phase: SubstanceDef.Phase) -> void:
	active_substance_id = substance_id
	active_phase = phase
	is_dragging = true

	var substance := SubstanceRegistry.get_substance(substance_id)
	if substance:
		_drag_visual.color = substance.base_color
		_drag_label.text = substance.substance_name.substr(0, 6)

	_drag_visual.visible = true


func cancel_drag() -> void:
	is_dragging = false
	_drag_visual.visible = false
	active_substance_id = 0


func _process(_delta: float) -> void:
	if not is_dragging:
		return

	var mouse_pos := get_global_mouse_position()
	_drag_visual.global_position = mouse_pos - _drag_visual.size / 2

	# While holding left mouse, pour liquids/powders continuously.
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		match active_phase:
			SubstanceDef.Phase.LIQUID, SubstanceDef.Phase.POWDER:
				pouring.emit(active_substance_id, mouse_pos)


func _input(event: InputEvent) -> void:
	if not is_dragging:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			# Released — drop or finish pour.
			if active_phase == SubstanceDef.Phase.SOLID:
				dropped.emit(active_substance_id, active_phase, get_global_mouse_position())
			cancel_drag()

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		# Cancel drag.
		cancel_drag()
```

- [ ] **Step 3: Wire shelf and drag-drop into main scene**

In `src/main.gd`, add references:
```gdscript
var shelf: Shelf
var drag_drop: DragDrop
```

In `_ready()`, replace the substance_label setup with shelf and drag-drop:
```gdscript
	# Create shelf.
	var shelf_layer := CanvasLayer.new()
	shelf_layer.layer = 50
	add_child(shelf_layer)

	shelf = Shelf.new()
	shelf.anchor_right = 1.0
	shelf_layer.add_child(shelf)
	shelf.substance_picked.connect(_on_substance_picked)

	# Create drag-drop handler.
	drag_drop = DragDrop.new()
	add_child(drag_drop)
	drag_drop.dropped.connect(_on_substance_dropped)
	drag_drop.pouring.connect(_on_substance_pouring)
```

Add handler methods:
```gdscript
func _on_substance_picked(substance_id: int, phase: SubstanceDef.Phase) -> void:
	drag_drop.start_drag(substance_id, phase)
	var substance := SubstanceRegistry.get_substance(substance_id)
	if substance:
		game_log.log_event("Picked up: %s" % substance.substance_name, substance.base_color)


func _on_substance_dropped(substance_id: int, phase: SubstanceDef.Phase, pos: Vector2) -> void:
	if phase == SubstanceDef.Phase.SOLID:
		receptacle.rigid_body_mgr.spawn_object(substance_id, pos)


func _on_substance_pouring(substance_id: int, pos: Vector2) -> void:
	var grid_pos := receptacle.screen_to_grid(pos)
	var substance := SubstanceRegistry.get_substance(substance_id)
	if not substance:
		return

	var radius := 2
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx * dx + dy * dy <= radius * radius:
				var px := grid_pos.x + dx
				var py := grid_pos.y + dy
				if substance.phase == SubstanceDef.Phase.LIQUID:
					receptacle.fluid.spawn_fluid(px, py, substance_id)
				else:
					receptacle.grid.spawn_particle(px, py, substance_id)
```

Remove the old `_spawn_at_mouse` method and the direct mouse handling from `_process()`. Keep the number key input as a secondary control method.

- [ ] **Step 4: Run and verify**

Run the game. Click a substance on the shelf to pick it up. Click and hold to pour powders/liquids into the receptacle. Click to drop solids. Right-click to cancel.

- [ ] **Step 5: Commit**

```bash
git add src/interaction/ src/main.gd
git commit -m "feat: shelf UI and drag-drop interaction — pick, pour, and drop substances"
```

---

### Task 17: Dispenser Tool

**Files:**
- Create: `src/interaction/dispenser.gd`
- Modify: `src/interaction/shelf.gd`
- Modify: `src/main.gd`

Precision powder dispenser for fine control. Accessible from a button on the shelf.

- [ ] **Step 1: Create dispenser**

Create `src/interaction/dispenser.gd`:

```gdscript
class_name Dispenser
extends Node2D
## Precision dispenser for fine particle streams.
## Select substance, click and hold to emit a narrow stream.

var substance_id: int = 0
var flow_rate: float = 1.0  ## 1.0 = normal, 0.1 = very fine.
var is_active: bool = false

var _emit_timer: float = 0.0
var _grid: ParticleGrid
var _fluid: FluidSim
var _receptacle_pos: Vector2
var _cell_size: int

## Visual indicator.
var _cursor_indicator: ColorRect


func setup(grid: ParticleGrid, fluid: FluidSim, receptacle_pos: Vector2, cell_size: int) -> void:
	_grid = grid
	_fluid = fluid
	_receptacle_pos = receptacle_pos
	_cell_size = cell_size

	_cursor_indicator = ColorRect.new()
	_cursor_indicator.size = Vector2(8, 8)
	_cursor_indicator.color = Color(1, 1, 1, 0.5)
	_cursor_indicator.visible = false
	add_child(_cursor_indicator)


func activate(p_substance_id: int) -> void:
	substance_id = p_substance_id
	is_active = true
	_cursor_indicator.visible = true
	var sub := SubstanceRegistry.get_substance(substance_id)
	if sub:
		_cursor_indicator.color = sub.base_color
		_cursor_indicator.color.a = 0.7


func deactivate() -> void:
	is_active = false
	substance_id = 0
	_cursor_indicator.visible = false


func _process(delta: float) -> void:
	if not is_active:
		return

	var mouse_pos := get_global_mouse_position()
	_cursor_indicator.global_position = mouse_pos - _cursor_indicator.size / 2

	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_emit_timer -= delta
		if _emit_timer <= 0.0:
			_emit_timer = 0.02 / flow_rate
			_emit_particle(mouse_pos)


func _emit_particle(screen_pos: Vector2) -> void:
	var local := screen_pos - _receptacle_pos
	var gx := int(local.x) / _cell_size
	var gy := int(local.y) / _cell_size

	var sub := SubstanceRegistry.get_substance(substance_id)
	if not sub:
		return

	# Single particle stream — precision tool.
	if sub.phase == SubstanceDef.Phase.LIQUID:
		_fluid.spawn_fluid(gx, gy, substance_id)
	else:
		_grid.spawn_particle(gx, gy, substance_id)


func _input(event: InputEvent) -> void:
	if not is_active:
		return

	# Scroll to adjust flow rate.
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			flow_rate = clampf(flow_rate + 0.2, 0.1, 3.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			flow_rate = clampf(flow_rate - 0.2, 0.1, 3.0)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			deactivate()
```

- [ ] **Step 2: Add dispenser button to shelf**

In `src/interaction/shelf.gd`, add after the substance buttons in `_populate()`:

```gdscript
	# Separator.
	var sep := VSeparator.new()
	sep.custom_minimum_size.x = 20
	add_child(sep)

	# Dispenser button.
	var dispenser_btn := Button.new()
	dispenser_btn.custom_minimum_size = ITEM_SIZE
	dispenser_btn.text = "Dispenser\n[D]"
	dispenser_btn.add_theme_font_size_override("font_size", 11)
	var disp_style := StyleBoxFlat.new()
	disp_style.bg_color = Color(0.2, 0.2, 0.25, 1.0)
	disp_style.border_color = Color(0.5, 0.5, 0.6, 1.0)
	disp_style.set_border_width_all(2)
	disp_style.set_corner_radius_all(4)
	dispenser_btn.add_theme_stylebox_override("normal", disp_style)
	dispenser_btn.pressed.connect(func(): substance_picked.emit(-1, SubstanceDef.Phase.POWDER))
	add_child(dispenser_btn)
```

Add a signal for dispenser mode:
```gdscript
signal dispenser_requested
```

And wire the -1 ID in main.gd to activate dispenser mode.

- [ ] **Step 3: Wire dispenser into main scene**

In `src/main.gd`, add:
```gdscript
var dispenser: Dispenser
```

In `_ready()`:
```gdscript
	dispenser = Dispenser.new()
	dispenser.setup(receptacle.grid, receptacle.fluid, receptacle.global_position, Receptacle.CELL_SIZE)
	add_child(dispenser)
```

Update `_on_substance_picked` to handle dispenser mode:
```gdscript
func _on_substance_picked(substance_id: int, phase: SubstanceDef.Phase) -> void:
	if substance_id == -1:
		# Toggle dispenser with last selected substance.
		if dispenser.is_active:
			dispenser.deactivate()
		else:
			dispenser.activate(_selected_substance_id)
			game_log.log_event("Dispenser activated", Color.CYAN)
		return

	_selected_substance_id = substance_id
	dispenser.deactivate()
	drag_drop.start_drag(substance_id, phase)
	var substance := SubstanceRegistry.get_substance(substance_id)
	if substance:
		game_log.log_event("Picked up: %s" % substance.substance_name, substance.base_color)
```

Add D key shortcut in `_input`:
```gdscript
		elif key == KEY_D:
			if dispenser.is_active:
				dispenser.deactivate()
			else:
				dispenser.activate(_selected_substance_id)
```

- [ ] **Step 4: Run and verify**

Run the game. Click the Dispenser button or press D. Click and hold inside the receptacle for a fine particle stream. Scroll to adjust flow rate. Right-click to deactivate.

- [ ] **Step 5: Commit**

```bash
git add src/interaction/dispenser.gd src/interaction/shelf.gd src/main.gd
git commit -m "feat: precision dispenser tool — fine particle stream with adjustable flow rate"
```

---

## Phase 8: Final Integration

### Task 18: Reset Button & Final Polish

**Files:**
- Modify: `src/main.gd`
- Modify: `src/interaction/shelf.gd`

Add the "clean out receptacle" reset button and ensure all systems are properly connected for the final integration.

- [ ] **Step 1: Add reset button to shelf**

In `src/interaction/shelf.gd`, add after the dispenser button:

```gdscript
	# Reset button.
	var reset_btn := Button.new()
	reset_btn.custom_minimum_size = ITEM_SIZE
	reset_btn.text = "Reset\n[R]"
	reset_btn.add_theme_font_size_override("font_size", 11)
	var reset_style := StyleBoxFlat.new()
	reset_style.bg_color = Color(0.4, 0.1, 0.1, 1.0)
	reset_style.border_color = Color(0.8, 0.2, 0.2, 1.0)
	reset_style.set_border_width_all(2)
	reset_style.set_corner_radius_all(4)
	reset_btn.add_theme_stylebox_override("normal", reset_style)
	add_child(reset_btn)
```

Add signal:
```gdscript
signal reset_requested
```

Wire the button:
```gdscript
	reset_btn.pressed.connect(func(): reset_requested.emit())
```

- [ ] **Step 2: Connect reset in main scene**

In `src/main.gd`, in `_ready()`:
```gdscript
	shelf.reset_requested.connect(_clear_receptacle)
```

Update `_clear_receptacle` to reset all systems:
```gdscript
func _clear_receptacle() -> void:
	# Clear particle grid.
	receptacle.grid.cells.fill(0)
	receptacle.grid.temperatures.fill(20.0)
	receptacle.grid.charges.fill(0.0)
	# Clear fluid.
	receptacle.fluid.markers.fill(0)
	receptacle.fluid.u.fill(0.0)
	receptacle.fluid.v.fill(0.0)
	receptacle.fluid.pressure.fill(0.0)
	# Clear rigid bodies.
	for body in receptacle.rigid_body_mgr._bodies.duplicate():
		body.queue_free()
	receptacle.rigid_body_mgr._bodies.clear()
	# Reset fields.
	temperature_field.values.fill(20.0)
	pressure_field.reset()
	electric_field.values.fill(0.0)
	light_field.values.fill(0.0)
	light_field.light_sources.clear()
	magnetic_field.values.fill(0.0)
	# Log.
	game_log.log_event("Receptacle cleared — all systems reset", Color.YELLOW)
```

- [ ] **Step 3: Run full integration test**

Run the game and test the complete loop:
1. Pick up sulfur from shelf, pour into receptacle.
2. Pick up iron filings, pour on top.
3. Pick up acid, pour on both — watch reactions (gas, heat, dissolution).
4. Try solid objects — drop rock, iron ingot into acid.
5. Use dispenser for precise additions.
6. Watch fields in action (F3 for perf, F2 for log).
7. Hit Reset (R key or button) to clear everything.
8. Press F to flood fill, observe performance.

- [ ] **Step 4: Commit**

```bash
git add src/main.gd src/interaction/shelf.gd
git commit -m "feat: reset button and full system integration"
```

---

### Task 19: Final Benchmark & Documentation

**Files:**
- Modify: `CLAUDE.md`

Run comprehensive benchmarks and update documentation with findings.

- [ ] **Step 1: Run benchmark suite**

Run the game and perform systematic benchmarks with F3 (perf monitor) enabled:

| Test | Method | Record |
|------|--------|--------|
| Empty grid | Just run, no particles | FPS, grid update ms |
| 1K particles | Click to spawn | FPS, grid update ms |
| 5K particles | Click/flood partial | FPS, grid + render ms |
| 10K particles | Flood fill ~half | FPS, all timings |
| Full fill | Press F | FPS, all timings |
| Fluid only | Flood with water | FPS, fluid sim ms |
| Mixed | Powder + fluid + 5 solids | FPS, all timings |
| Reactions | Acid + iron flood | FPS, mediator ms |
| All fields active | Reactions producing heat/gas/charge | FPS, fields ms |

Enable file logging (F4) during the benchmark to capture data in `user://perf_log.csv`.

- [ ] **Step 2: Update CLAUDE.md with benchmark results**

Add a "Benchmark Results" section to CLAUDE.md with the recorded data and conclusions about whether GDScript is viable or if GDExtension/compute shaders are needed for the hot loops.

- [ ] **Step 3: Final commit**

```bash
git add CLAUDE.md
git commit -m "docs: benchmark results and performance findings"
```
