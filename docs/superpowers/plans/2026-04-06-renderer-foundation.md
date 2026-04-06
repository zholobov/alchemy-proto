# Swappable Renderer Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a renderer interface and manager that allows swapping between multiple rendering backends at runtime with F5, starting with the existing pixel renderer as the first backend.

**Architecture:** A RendererBase class defines the interface. RendererManager handles lifecycle (lazy creation, F5 cycling, cleanup). The existing SubstanceRenderer is refactored to extend RendererBase. Receptacle no longer creates the renderer directly — the manager does.

**Tech Stack:** Godot 4.6, GDScript

---

### Task 1: Create RendererBase Interface

**Files:**
- Create: `src/rendering/renderer_base.gd`

- [ ] **Step 1: Create the base class**

Create `src/rendering/renderer_base.gd`:

```gdscript
class_name RendererBase
extends Node2D
## Base class for all substance renderers.
## Subclasses must override setup(), render(), get_renderer_name(), and cleanup().


func setup(p_grid: ParticleGrid, p_cell_size: int, p_fluid: FluidSim) -> void:
	pass


func render() -> void:
	pass


func get_renderer_name() -> String:
	return "Base"


func cleanup() -> void:
	pass
```

- [ ] **Step 2: Commit**

```bash
git add src/rendering/renderer_base.gd
git commit -m "feat: RendererBase interface for swappable rendering backends"
```

---

### Task 2: Refactor SubstanceRenderer to Extend RendererBase

**Files:**
- Modify: `src/rendering/substance_renderer.gd`

The current SubstanceRenderer extends Sprite2D directly. Refactor it to extend RendererBase (Node2D) and create a Sprite2D child internally.

- [ ] **Step 1: Rewrite SubstanceRenderer**

Replace the entire content of `src/rendering/substance_renderer.gd` with:

```gdscript
class_name SubstanceRenderer
extends RendererBase
## Debug pixel renderer. Renders the particle grid as a scaled-up pixel image.
## Each grid cell = 1 pixel in the image, scaled by cell_size on screen.

var grid: ParticleGrid
var cell_size: int = 4
var fluid: FluidSim
var _image: Image
var _texture: ImageTexture
var _pixel_data: PackedByteArray
var _sprite: Sprite2D

## Cache substance colors to avoid lookups every pixel every frame.
var _color_cache: PackedColorArray


func setup(p_grid: ParticleGrid, p_cell_size: int = 4, p_fluid: FluidSim = null) -> void:
	grid = p_grid
	cell_size = p_cell_size
	fluid = p_fluid

	_image = Image.create(grid.width, grid.height, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)

	_sprite = Sprite2D.new()
	_sprite.texture = _texture
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sprite.scale = Vector2(cell_size, cell_size)
	_sprite.centered = false
	add_child(_sprite)

	_pixel_data = PackedByteArray()
	_pixel_data.resize(grid.width * grid.height * 4)

	_rebuild_color_cache()


func get_renderer_name() -> String:
	return "Debug Pixel"


func cleanup() -> void:
	if _sprite:
		_sprite.queue_free()
		_sprite = null


func _rebuild_color_cache() -> void:
	_color_cache = PackedColorArray()
	_color_cache.resize(SubstanceRegistry.substances.size())
	_color_cache[0] = Color.TRANSPARENT
	for i in range(1, SubstanceRegistry.substances.size()):
		var substance := SubstanceRegistry.get_substance(i)
		if substance:
			_color_cache[i] = substance.base_color
		else:
			_color_cache[i] = Color.MAGENTA


func render() -> void:
	if not grid:
		return

	var size := grid.width * grid.height
	for i in range(size):
		var substance_id: int = grid.cells[i]
		var color: Color

		if substance_id == 0:
			color = Color.TRANSPARENT
		elif substance_id < _color_cache.size():
			color = _color_cache[substance_id]
		else:
			color = Color.MAGENTA

		# Blend fluid on top if present.
		if fluid and fluid.markers[i] != 0:
			var fluid_id: int = fluid.markers[i]
			var fluid_color: Color
			if fluid_id < _color_cache.size():
				fluid_color = _color_cache[fluid_id]
			else:
				fluid_color = Color.MAGENTA
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

	_image = Image.create_from_data(grid.width, grid.height, false, Image.FORMAT_RGBA8, _pixel_data)
	_texture.update(_image)
```

- [ ] **Step 2: Commit**

```bash
git add src/rendering/substance_renderer.gd
git commit -m "refactor: SubstanceRenderer extends RendererBase with Sprite2D child"
```

---

### Task 3: Create RendererManager

**Files:**
- Create: `src/rendering/renderer_manager.gd`

- [ ] **Step 1: Create the manager**

Create `src/rendering/renderer_manager.gd`:

```gdscript
class_name RendererManager
extends Node
## Manages swappable rendering backends.
## F5 cycles between registered renderers. Only one is active at a time.

var _renderer_classes: Array[GDScript] = []
var _renderer_names: Array[String] = []
var _current_index: int = 0
var _active_renderer: RendererBase

var _grid: ParticleGrid
var _cell_size: int
var _fluid: FluidSim
var _parent_node: Node2D  ## Receptacle — renderers are added as children of this.


func setup(parent: Node2D, grid: ParticleGrid, cell_size: int, fluid: FluidSim) -> void:
	_parent_node = parent
	_grid = grid
	_cell_size = cell_size
	_fluid = fluid

	# Register available renderers.
	_register(SubstanceRenderer, "Debug Pixel")

	# Activate the first renderer.
	_activate(0)


func _register(renderer_class: GDScript, display_name: String) -> void:
	_renderer_classes.append(renderer_class)
	_renderer_names.append(display_name)


func _activate(index: int) -> void:
	# Clean up current renderer.
	if _active_renderer:
		_active_renderer.cleanup()
		_parent_node.remove_child(_active_renderer)
		_active_renderer.queue_free()
		_active_renderer = null

	# Create new renderer.
	_current_index = index
	_active_renderer = _renderer_classes[index].new() as RendererBase
	_parent_node.add_child(_active_renderer)
	# Move to index 0 so it renders below field_renderer and other children.
	_parent_node.move_child(_active_renderer, 0)
	_active_renderer.setup(_grid, _cell_size, _fluid)

	print("Renderer switched to: %s" % _renderer_names[index])


func cycle_renderer() -> void:
	## Switch to the next renderer in the list.
	var next_index := (_current_index + 1) % _renderer_classes.size()
	_activate(next_index)


func render() -> void:
	if _active_renderer:
		_active_renderer.render()


func get_current_name() -> String:
	if _current_index < _renderer_names.size():
		return _renderer_names[_current_index]
	return "Unknown"
```

- [ ] **Step 2: Commit**

```bash
git add src/rendering/renderer_manager.gd
git commit -m "feat: RendererManager for swappable rendering backends"
```

---

### Task 4: Wire RendererManager into Game Loop

**Files:**
- Modify: `src/receptacle/receptacle.gd`
- Modify: `src/main.gd`
- Modify: `src/debug/fps_overlay.gd`

- [ ] **Step 1: Remove direct renderer creation from receptacle**

Read `src/receptacle/receptacle.gd`. Remove the renderer creation lines and the `renderer` field. Keep everything else.

Remove the field declaration:
```gdscript
var renderer: SubstanceRenderer
```

Remove these lines from `_ready()`:
```gdscript
	# Create and set up the renderer as a child.
	renderer = SubstanceRenderer.new()
	renderer.setup(grid, CELL_SIZE, fluid)
	add_child(renderer)
```

- [ ] **Step 2: Add RendererManager to main.gd**

Read `src/main.gd`. Add a new field:

```gdscript
var renderer_manager: RendererManager
```

In `_ready()`, after creating the receptacle and calling `receptacle.setup_rigid_bodies()`, add:

```gdscript
	# Create renderer manager.
	renderer_manager = RendererManager.new()
	renderer_manager.setup(receptacle, receptacle.grid, Receptacle.CELL_SIZE, receptacle.fluid)
	add_child(renderer_manager)
```

In `_process()`, replace `receptacle.renderer.render()` with:

```gdscript
	renderer_manager.render()
```

In `_input()`, add F5 handler after the existing key handlers:

```gdscript
		elif key == KEY_F5:
			renderer_manager.cycle_renderer()
			game_log.log_event("Renderer: %s" % renderer_manager.get_current_name(), Color.CYAN)
```

- [ ] **Step 3: Show renderer name in FPS overlay**

Read `src/debug/fps_overlay.gd`. Add a field for the renderer name source:

```gdscript
var renderer_manager: RendererManager
```

Update `_process()`:

```gdscript
func _process(_delta: float) -> void:
	var fps := Engine.get_frames_per_second()
	var frame_ms := 1000.0 / maxf(fps, 1.0)
	var renderer_name := ""
	if renderer_manager:
		renderer_name = " | %s" % renderer_manager.get_current_name()
	text = "%d FPS (%.1f ms)%s" % [fps, frame_ms, renderer_name]
```

In `src/main.gd`, after creating the FPS overlay, wire the reference. Find where the FPSOverlay is created (`var fps := FPSOverlay.new()`) and add after it:

```gdscript
	fps.renderer_manager = renderer_manager
```

Note: the renderer_manager must be created BEFORE the FPS overlay reference is set. Reorder `_ready()` if needed so renderer_manager is created before the debug layer.

- [ ] **Step 4: Run and verify**

```bash
godot --path /Users/zholobov/src/gd-alchemy-proto
```

Expected:
- Game runs identically to before
- FPS overlay shows "60 FPS (16.7 ms) | Debug Pixel"
- F5 key logs "Renderer: Debug Pixel" (only one renderer registered, cycles to itself)
- Particles still render and simulate correctly

- [ ] **Step 5: Commit**

```bash
git add src/receptacle/receptacle.gd src/main.gd src/debug/fps_overlay.gd
git commit -m "feat: wire RendererManager into game loop, F5 cycles renderers"
```

---

### Task 5: Create Multi-Layer Renderer (Renderer C)

**Files:**
- Create: `src/rendering/shaders/powder_layer.gdshader`
- Create: `src/rendering/shaders/liquid_layer.gdshader`
- Create: `src/rendering/shaders/gas_layer.gdshader`
- Create: `src/rendering/multilayer_renderer.gd`
- Modify: `src/rendering/renderer_manager.gd`

This is the first non-pixel renderer. It separates substances into layers by phase and applies shaders for a smooth, textured look.

- [ ] **Step 1: Create powder layer shader**

Create directory `src/rendering/shaders/` and create `src/rendering/shaders/powder_layer.gdshader`:

```glsl
shader_type canvas_item;

uniform sampler2D noise_texture : repeat_enable;
uniform float grain_scale = 8.0;
uniform float grain_strength = 0.15;
uniform float time_offset = 0.0;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	if (base.a < 0.01) {
		discard;
	}

	// Add noise-based grain variation
	vec2 noise_uv = UV * grain_scale + vec2(time_offset * 0.01, 0.0);
	float noise_val = texture(noise_texture, noise_uv).r;

	// Vary color slightly per pixel
	vec3 color = base.rgb;
	color *= 0.85 + noise_val * grain_strength * 2.0;

	// Subtle edge darkening (vignette within each substance blob)
	float edge = smoothstep(0.0, 0.15, base.a);
	color *= 0.8 + edge * 0.2;

	COLOR = vec4(color, base.a);
}
```

- [ ] **Step 2: Create liquid layer shader**

Create `src/rendering/shaders/liquid_layer.gdshader`:

```glsl
shader_type canvas_item;

uniform float blur_amount = 1.5;
uniform float refraction_strength = 0.003;
uniform float time_speed = 1.0;

void fragment() {
	// Simple box blur for smooth blob edges
	vec2 ps = TEXTURE_PIXEL_SIZE;
	vec4 sum = vec4(0.0);
	float count = 0.0;

	for (int dy = -2; dy <= 2; dy++) {
		for (int dx = -2; dx <= 2; dx++) {
			vec2 offset = vec2(float(dx), float(dy)) * ps * blur_amount;
			vec4 sample_color = texture(TEXTURE, UV + offset);
			float weight = 1.0 / (1.0 + float(dx * dx + dy * dy));
			sum += sample_color * weight;
			count += weight;
		}
	}
	vec4 blurred = sum / count;

	if (blurred.a < 0.05) {
		discard;
	}

	// Smooth edges with smoothstep
	float alpha = smoothstep(0.1, 0.4, blurred.a);

	// Subtle refraction-like UV wobble
	float wobble_x = sin(UV.y * 30.0 + TIME * time_speed) * refraction_strength;
	float wobble_y = cos(UV.x * 25.0 + TIME * time_speed * 0.8) * refraction_strength;
	vec2 refracted_uv = UV + vec2(wobble_x, wobble_y);
	vec4 refracted = texture(TEXTURE, refracted_uv);

	vec3 color = mix(blurred.rgb, refracted.rgb, 0.3);

	COLOR = vec4(color, alpha * blurred.a);
}
```

- [ ] **Step 3: Create gas layer shader**

Create `src/rendering/shaders/gas_layer.gdshader`:

```glsl
shader_type canvas_item;
render_mode blend_add;

uniform float blur_amount = 3.0;
uniform float distortion_strength = 0.01;
uniform float fade_strength = 0.7;

void fragment() {
	vec2 ps = TEXTURE_PIXEL_SIZE;

	// Heavy blur for soft gas clouds
	vec4 sum = vec4(0.0);
	float count = 0.0;
	for (int dy = -3; dy <= 3; dy++) {
		for (int dx = -3; dx <= 3; dx++) {
			vec2 offset = vec2(float(dx), float(dy)) * ps * blur_amount;
			float weight = 1.0 / (1.0 + float(dx * dx + dy * dy) * 0.5);
			sum += texture(TEXTURE, UV + offset) * weight;
			count += weight;
		}
	}
	vec4 blurred = sum / count;

	if (blurred.a < 0.01) {
		discard;
	}

	// Animated turbulence distortion
	float dist_x = sin(UV.y * 20.0 + TIME * 2.0) * distortion_strength;
	float dist_y = cos(UV.x * 15.0 + TIME * 1.5) * distortion_strength;
	vec4 distorted = texture(TEXTURE, UV + vec2(dist_x, dist_y));

	vec3 color = mix(blurred.rgb, distorted.rgb, 0.5);
	float alpha = blurred.a * fade_strength;

	COLOR = vec4(color, alpha);
}
```

- [ ] **Step 4: Create MultiLayerRenderer**

Create `src/rendering/multilayer_renderer.gd`:

```gdscript
class_name MultiLayerRenderer
extends RendererBase
## Multi-layer compositing renderer. Separates substances by phase,
## applies specialized shaders per layer, composites the result.

var grid: ParticleGrid
var cell_size: int = 4
var fluid: FluidSim

# Per-layer data images
var _powder_image: Image
var _liquid_image: Image
var _gas_image: Image

# Per-layer textures and sprites
var _powder_texture: ImageTexture
var _liquid_texture: ImageTexture
var _gas_texture: ImageTexture
var _powder_sprite: Sprite2D
var _liquid_sprite: Sprite2D
var _gas_sprite: Sprite2D

# Pixel data buffers
var _powder_pixels: PackedByteArray
var _liquid_pixels: PackedByteArray
var _gas_pixels: PackedByteArray

# Noise texture for powder grain
var _noise_texture: NoiseTexture2D

# Color cache
var _color_cache: PackedColorArray
var _phase_cache: PackedInt32Array


func setup(p_grid: ParticleGrid, p_cell_size: int = 4, p_fluid: FluidSim = null) -> void:
	grid = p_grid
	cell_size = p_cell_size
	fluid = p_fluid

	var w := grid.width
	var h := grid.height
	var buf_size := w * h * 4

	# Create images and textures for each layer
	_powder_image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	_powder_texture = ImageTexture.create_from_image(_powder_image)
	_liquid_image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	_liquid_texture = ImageTexture.create_from_image(_liquid_image)
	_gas_image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	_gas_texture = ImageTexture.create_from_image(_gas_image)

	_powder_pixels = PackedByteArray()
	_powder_pixels.resize(buf_size)
	_liquid_pixels = PackedByteArray()
	_liquid_pixels.resize(buf_size)
	_gas_pixels = PackedByteArray()
	_gas_pixels.resize(buf_size)

	# Create noise texture for powder grain
	_noise_texture = NoiseTexture2D.new()
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.05
	_noise_texture.noise = noise
	_noise_texture.width = 128
	_noise_texture.height = 128
	_noise_texture.seamless = true

	# Create sprites for each layer with shaders
	_powder_sprite = _create_layer_sprite(_powder_texture, "res://src/rendering/shaders/powder_layer.gdshader")
	if _powder_sprite.material is ShaderMaterial:
		(_powder_sprite.material as ShaderMaterial).set_shader_parameter("noise_texture", _noise_texture)
	add_child(_powder_sprite)

	_liquid_sprite = _create_layer_sprite(_liquid_texture, "res://src/rendering/shaders/liquid_layer.gdshader")
	add_child(_liquid_sprite)

	_gas_sprite = _create_layer_sprite(_gas_texture, "res://src/rendering/shaders/gas_layer.gdshader")
	add_child(_gas_sprite)

	_rebuild_caches()


func _create_layer_sprite(tex: ImageTexture, shader_path: String) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.texture = tex
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sprite.scale = Vector2(cell_size, cell_size)
	sprite.centered = false

	var shader_res := load(shader_path) as Shader
	if shader_res:
		var mat := ShaderMaterial.new()
		mat.shader = shader_res
		sprite.material = mat

	return sprite


func _rebuild_caches() -> void:
	var count := SubstanceRegistry.substances.size()
	_color_cache = PackedColorArray()
	_color_cache.resize(count)
	_phase_cache = PackedInt32Array()
	_phase_cache.resize(count)
	_color_cache[0] = Color.TRANSPARENT
	_phase_cache[0] = -1
	for i in range(1, count):
		var sub := SubstanceRegistry.get_substance(i)
		if sub:
			_color_cache[i] = sub.base_color
			_phase_cache[i] = sub.phase
		else:
			_color_cache[i] = Color.MAGENTA
			_phase_cache[i] = -1


func get_renderer_name() -> String:
	return "Multi-Layer"


func cleanup() -> void:
	for child in get_children():
		child.queue_free()


func render() -> void:
	if not grid:
		return

	# Clear all pixel buffers
	_powder_pixels.fill(0)
	_liquid_pixels.fill(0)
	_gas_pixels.fill(0)

	var size := grid.width * grid.height

	# Single pass: sort each cell into the appropriate layer
	for i in range(size):
		# Skip boundary walls
		if grid.boundary[i] == 0:
			# Draw walls in powder layer (opaque base)
			var off := i * 4
			_powder_pixels[off] = 38
			_powder_pixels[off + 1] = 33
			_powder_pixels[off + 2] = 30
			_powder_pixels[off + 3] = 255
			continue

		var substance_id: int = grid.cells[i]
		var fluid_id: int = fluid.markers[i] if fluid else 0

		# Handle fluid markers
		if fluid_id > 0 and fluid_id < _phase_cache.size():
			var phase: int = _phase_cache[fluid_id]
			var color: Color = _color_cache[fluid_id]
			if phase == SubstanceDef.Phase.LIQUID:
				_write_pixel(_liquid_pixels, i, color)
			elif phase == SubstanceDef.Phase.GAS:
				_write_pixel(_gas_pixels, i, color)

		# Handle grid particles (on top of or instead of fluid)
		if substance_id > 0 and substance_id < _phase_cache.size():
			var phase: int = _phase_cache[substance_id]
			var color: Color = _color_cache[substance_id]
			match phase:
				SubstanceDef.Phase.POWDER, SubstanceDef.Phase.SOLID:
					_write_pixel(_powder_pixels, i, color)
				SubstanceDef.Phase.LIQUID:
					_write_pixel(_liquid_pixels, i, color)
				SubstanceDef.Phase.GAS:
					_write_pixel(_gas_pixels, i, color)

	# Update textures
	var w := grid.width
	var h := grid.height
	_powder_image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, _powder_pixels)
	_powder_texture.update(_powder_image)
	_liquid_image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, _liquid_pixels)
	_liquid_texture.update(_liquid_image)
	_gas_image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, _gas_pixels)
	_gas_texture.update(_gas_image)


func _write_pixel(buffer: PackedByteArray, index: int, color: Color) -> void:
	var off := index * 4
	buffer[off] = int(color.r8)
	buffer[off + 1] = int(color.g8)
	buffer[off + 2] = int(color.b8)
	buffer[off + 3] = int(color.a8)
```

- [ ] **Step 5: Register Multi-Layer renderer in RendererManager**

In `src/rendering/renderer_manager.gd`, in `setup()`, add after the SubstanceRenderer registration:

```gdscript
	_register(MultiLayerRenderer, "Multi-Layer")
```

- [ ] **Step 6: Run and verify**

Run the game. Press F5 to switch to "Multi-Layer". Substances should appear with:
- Powder: textured/grainy surface instead of flat pixels
- Liquid: blurred blobs with subtle refraction wobble
- Gas: soft additive clouds with turbulence animation
- FPS overlay shows "| Multi-Layer"
- F5 again returns to "Debug Pixel"

- [ ] **Step 7: Commit**

```bash
git add src/rendering/shaders/ src/rendering/multilayer_renderer.gd src/rendering/renderer_manager.gd
git commit -m "feat: Multi-Layer compositing renderer with per-phase shaders"
```

---

### Task 6: Create Density Field Renderer (Renderer A)

**Files:**
- Create: `src/rendering/density_field_renderer.gd`
- Modify: `src/rendering/renderer_manager.gd`

This renderer generates per-substance density textures and uses linear filtering + smoothstep for organic blob shapes. It reuses the same layer sprite approach as the Multi-Layer renderer but groups by individual substance for per-substance blur.

- [ ] **Step 1: Create DensityFieldRenderer**

Create `src/rendering/density_field_renderer.gd`:

```gdscript
class_name DensityFieldRenderer
extends RendererBase
## Density field renderer. Generates per-substance density textures,
## blurs them for smooth organic blobs, composites with material shading.

var grid: ParticleGrid
var cell_size: int = 4
var fluid: FluidSim

var _output_sprite: Sprite2D
var _output_image: Image
var _output_texture: ImageTexture
var _output_pixels: PackedByteArray

# Blur work buffer
var _density_image: Image
var _density_pixels: PackedByteArray
var _blurred_pixels: PackedFloat32Array

# Color cache
var _color_cache: PackedColorArray


func setup(p_grid: ParticleGrid, p_cell_size: int = 4, p_fluid: FluidSim = null) -> void:
	grid = p_grid
	cell_size = p_cell_size
	fluid = p_fluid

	var w := grid.width
	var h := grid.height

	_output_image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	_output_texture = ImageTexture.create_from_image(_output_image)
	_output_pixels = PackedByteArray()
	_output_pixels.resize(w * h * 4)

	_density_pixels = PackedByteArray()
	_density_pixels.resize(w * h)
	_blurred_pixels = PackedFloat32Array()
	_blurred_pixels.resize(w * h)

	_output_sprite = Sprite2D.new()
	_output_sprite.texture = _output_texture
	_output_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_output_sprite.scale = Vector2(cell_size, cell_size)
	_output_sprite.centered = false
	add_child(_output_sprite)

	_rebuild_color_cache()


func _rebuild_color_cache() -> void:
	_color_cache = PackedColorArray()
	_color_cache.resize(SubstanceRegistry.substances.size())
	_color_cache[0] = Color.TRANSPARENT
	for i in range(1, SubstanceRegistry.substances.size()):
		var sub := SubstanceRegistry.get_substance(i)
		if sub:
			_color_cache[i] = sub.base_color
		else:
			_color_cache[i] = Color.MAGENTA


func get_renderer_name() -> String:
	return "Density Field"


func cleanup() -> void:
	for child in get_children():
		child.queue_free()


func render() -> void:
	if not grid:
		return

	var w := grid.width
	var h := grid.height
	var size := w * h

	# Clear output
	_output_pixels.fill(0)

	# Find which substance IDs are present
	var active_substances: Dictionary = {}
	for i in range(size):
		var sid: int = grid.cells[i]
		if sid > 0:
			active_substances[sid] = true
		if fluid:
			var fid: int = fluid.markers[i]
			if fid > 0:
				active_substances[fid] = true

	# Process each active substance: build density, blur, composite
	for sid in active_substances:
		var color: Color = _color_cache[sid] if sid < _color_cache.size() else Color.MAGENTA

		# Build density field for this substance
		_density_pixels.fill(0)
		for i in range(size):
			if grid.cells[i] == sid or (fluid and fluid.markers[i] == sid):
				_density_pixels[i] = 255

		# Box blur the density field (2 passes for smooth result)
		_blur_density(w, h)
		_blur_density(w, h)

		# Composite: where density > threshold, blend substance color
		for i in range(size):
			var density: float = _blurred_pixels[i]
			if density < 0.05:
				continue

			# Smoothstep for soft edges
			var alpha: float = _smoothstep(0.1, 0.6, density)
			alpha *= color.a

			# Blend into output (simple alpha compositing)
			var off := i * 4
			var existing_a: float = float(_output_pixels[off + 3]) / 255.0
			var out_a: float = alpha + existing_a * (1.0 - alpha)
			if out_a > 0.0:
				var inv_blend := existing_a * (1.0 - alpha) / out_a
				_output_pixels[off] = int((color.r * alpha / out_a + float(_output_pixels[off]) / 255.0 * inv_blend) * 255.0)
				_output_pixels[off + 1] = int((color.g * alpha / out_a + float(_output_pixels[off + 1]) / 255.0 * inv_blend) * 255.0)
				_output_pixels[off + 2] = int((color.b * alpha / out_a + float(_output_pixels[off + 2]) / 255.0 * inv_blend) * 255.0)
				_output_pixels[off + 3] = int(out_a * 255.0)

	# Draw boundary walls
	for i in range(size):
		if grid.boundary[i] == 0:
			var off := i * 4
			_output_pixels[off] = 38
			_output_pixels[off + 1] = 33
			_output_pixels[off + 2] = 30
			_output_pixels[off + 3] = 255

	_output_image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, _output_pixels)
	_output_texture.update(_output_image)


func _blur_density(w: int, h: int) -> void:
	## Simple box blur on density field. Input: _density_pixels (bytes). Output: _blurred_pixels (floats).
	for y in range(h):
		for x in range(w):
			var sum := 0.0
			var count := 0.0
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					var nx := x + dx
					var ny := y + dy
					if nx >= 0 and nx < w and ny >= 0 and ny < h:
						sum += float(_density_pixels[ny * w + nx]) / 255.0
						count += 1.0
			_blurred_pixels[y * w + x] = sum / count

	# Copy blurred back to density for multi-pass
	for i in range(w * h):
		_density_pixels[i] = int(clampf(_blurred_pixels[i], 0.0, 1.0) * 255.0)


func _smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
```

- [ ] **Step 2: Register in RendererManager**

In `src/rendering/renderer_manager.gd`, in `setup()`, add:

```gdscript
	_register(DensityFieldRenderer, "Density Field")
```

- [ ] **Step 3: Run and verify**

Run the game. Spawn particles. Press F5 twice to reach "Density Field". Substances should appear as smooth blurred blobs instead of sharp pixels. The blobs should have soft edges and organic shapes where particles cluster.

- [ ] **Step 4: Commit**

```bash
git add src/rendering/density_field_renderer.gd src/rendering/renderer_manager.gd
git commit -m "feat: Density Field renderer with blur and smoothstep blobs"
```

---

### Task 7: Create Marching Squares Renderer (Renderer B)

**Files:**
- Create: `src/rendering/marching_squares.gd`
- Create: `src/rendering/marching_squares_renderer.gd`
- Modify: `src/rendering/renderer_manager.gd`

- [ ] **Step 1: Create marching squares algorithm**

Create `src/rendering/marching_squares.gd`:

```gdscript
class_name MarchingSquares
extends RefCounted
## Marching squares algorithm. Generates smooth contour polygons from a density grid.

## Lookup table: for each of the 16 corner states, which edges have contour segments.
## Each edge is encoded as a pair of edge indices (0=top, 1=right, 2=bottom, 3=left).
const EDGE_TABLE: Array = [
	[],                 # 0000
	[[3, 2]],           # 0001
	[[2, 1]],           # 0010
	[[3, 1]],           # 0011
	[[1, 0]],           # 0100
	[[3, 0], [1, 2]],   # 0101 (ambiguous, use saddle)
	[[2, 0]],           # 0110
	[[3, 0]],           # 0111
	[[0, 3]],           # 1000
	[[0, 2]],           # 1001
	[[0, 1], [2, 3]],   # 1010 (ambiguous)
	[[0, 1]],           # 1011
	[[1, 3]],           # 1100
	[[1, 2]],           # 1101
	[[2, 3]],           # 1110
	[],                 # 1111
]


static func extract_filled_cells(density: PackedFloat32Array, w: int, h: int, threshold: float) -> PackedVector2Array:
	## Returns filled cell positions (centers) where density >= threshold.
	## Used for simple polygon fill rendering.
	var result := PackedVector2Array()
	for y in range(h):
		for x in range(w):
			if density[y * w + x] >= threshold:
				result.append(Vector2(float(x) + 0.5, float(y) + 0.5))
	return result


static func extract_contour_segments(density: PackedFloat32Array, w: int, h: int, threshold: float) -> PackedVector2Array:
	## Returns pairs of points (p1, p2, p1, p2, ...) forming contour line segments.
	var segments := PackedVector2Array()

	for y in range(h - 1):
		for x in range(w - 1):
			# Four corners of this cell (clockwise from top-left)
			var tl := density[y * w + x]
			var tr := density[y * w + x + 1]
			var br := density[(y + 1) * w + x + 1]
			var bl := density[(y + 1) * w + x]

			# Compute cell index (4-bit, one bit per corner)
			var cell_index := 0
			if tl >= threshold: cell_index |= 8
			if tr >= threshold: cell_index |= 4
			if br >= threshold: cell_index |= 2
			if bl >= threshold: cell_index |= 1

			if cell_index == 0 or cell_index == 15:
				continue

			# Interpolated edge midpoints
			var edges: Array[Vector2] = [
				_lerp_edge(x, y, x + 1, y, tl, tr, threshold),         # Edge 0: top
				_lerp_edge(x + 1, y, x + 1, y + 1, tr, br, threshold), # Edge 1: right
				_lerp_edge(x, y + 1, x + 1, y + 1, bl, br, threshold), # Edge 2: bottom
				_lerp_edge(x, y, x, y + 1, tl, bl, threshold),         # Edge 3: left
			]

			# Look up which edges to connect
			var edge_pairs: Array = EDGE_TABLE[cell_index]
			for pair in edge_pairs:
				segments.append(edges[pair[0]])
				segments.append(edges[pair[1]])

	return segments


static func _lerp_edge(x1: int, y1: int, x2: int, y2: int, v1: float, v2: float, threshold: float) -> Vector2:
	var t := 0.5
	if absf(v2 - v1) > 0.001:
		t = clampf((threshold - v1) / (v2 - v1), 0.0, 1.0)
	return Vector2(
		float(x1) + t * float(x2 - x1),
		float(y1) + t * float(y2 - y1)
	)
```

- [ ] **Step 2: Create MarchingSquaresRenderer**

Create `src/rendering/marching_squares_renderer.gd`:

```gdscript
class_name MarchingSquaresRenderer
extends RendererBase
## Marching squares renderer. Extracts smooth contour polygons from grid data,
## fills with textured substance colors, draws anti-aliased outlines.

var grid: ParticleGrid
var cell_size: int = 4
var fluid: FluidSim

var _density: PackedFloat32Array
var _color_cache: PackedColorArray

const THRESHOLD := 0.3
const OUTLINE_COLOR := Color(0.2, 0.18, 0.15, 0.6)
const OUTLINE_WIDTH := 1.5


func setup(p_grid: ParticleGrid, p_cell_size: int = 4, p_fluid: FluidSim = null) -> void:
	grid = p_grid
	cell_size = p_cell_size
	fluid = p_fluid
	_density = PackedFloat32Array()
	_density.resize(grid.width * grid.height)

	_color_cache = PackedColorArray()
	_color_cache.resize(SubstanceRegistry.substances.size())
	_color_cache[0] = Color.TRANSPARENT
	for i in range(1, SubstanceRegistry.substances.size()):
		var sub := SubstanceRegistry.get_substance(i)
		if sub:
			_color_cache[i] = sub.base_color
		else:
			_color_cache[i] = Color.MAGENTA


func get_renderer_name() -> String:
	return "Marching Squares"


func cleanup() -> void:
	pass


func render() -> void:
	if not grid:
		return
	queue_redraw()


func _draw() -> void:
	if not grid:
		return

	var w := grid.width
	var h := grid.height
	var size := w * h
	var cs := float(cell_size)

	# Draw boundary walls first
	for y in range(h):
		for x in range(w):
			if grid.boundary[y * w + x] == 0:
				draw_rect(Rect2(Vector2(x, y) * cs, Vector2(cs, cs)),
					Color(0.15, 0.13, 0.12, 1.0))

	# Find active substances
	var active_substances: Dictionary = {}
	for i in range(size):
		var sid: int = grid.cells[i]
		if sid > 0:
			active_substances[sid] = true
		if fluid and fluid.markers[i] > 0:
			var fid: int = fluid.markers[i]
			active_substances[fid] = true

	# Process each substance
	for sid in active_substances:
		var color: Color = _color_cache[sid] if sid < _color_cache.size() else Color.MAGENTA

		# Build density field
		_density.fill(0.0)
		for i in range(size):
			if grid.cells[i] == sid or (fluid and fluid.markers[i] == sid):
				_density[i] = 1.0

		# Simple blur (1 pass) for smoother contours
		var blurred := PackedFloat32Array()
		blurred.resize(size)
		for y in range(h):
			for x in range(w):
				var sum := 0.0
				var count := 0.0
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						var nx := x + dx
						var ny := y + dy
						if nx >= 0 and nx < w and ny >= 0 and ny < h:
							sum += _density[ny * w + nx]
							count += 1.0
				blurred[y * w + x] = sum / count

		# Draw filled cells as rounded rects
		for y in range(h):
			for x in range(w):
				if blurred[y * w + x] >= THRESHOLD:
					var pos := Vector2(float(x) * cs, float(y) * cs)
					draw_rect(Rect2(pos, Vector2(cs, cs)), color)

		# Extract and draw contour outlines
		var segments := MarchingSquares.extract_contour_segments(blurred, w, h, THRESHOLD)
		for i in range(0, segments.size() - 1, 2):
			var p1 := segments[i] * cs
			var p2 := segments[i + 1] * cs
			draw_line(p1, p2, OUTLINE_COLOR, OUTLINE_WIDTH, true)
```

- [ ] **Step 3: Register in RendererManager**

In `src/rendering/renderer_manager.gd`, in `setup()`, add:

```gdscript
	_register(MarchingSquaresRenderer, "Marching Squares")
```

- [ ] **Step 4: Run and verify**

Run the game. Spawn particles. Press F5 to cycle to "Marching Squares". Substances should have smooth contour outlines instead of pixel edges. The fills are still rectangular per-cell but the outlines should be smooth interpolated lines.

Note: This renderer may be slower due to CPU-side density blur and contour extraction. Check FPS with F3. If under 30 FPS, this is expected — the risk was identified in the plan.

- [ ] **Step 5: Commit**

```bash
git add src/rendering/marching_squares.gd src/rendering/marching_squares_renderer.gd src/rendering/renderer_manager.gd
git commit -m "feat: Marching Squares renderer with contour outlines"
```
