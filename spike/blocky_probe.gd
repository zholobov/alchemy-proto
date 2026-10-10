extends Node2D
## SPIKE PROBE — throwaway code, not game code.
##
## Question: at which grid size does a pure-GDScript blocky simulation plus
## an ImageTexture render fit a 30 FPS frame in a web export on a roughly
## five-year-old Android phone?
##
## The load model matches the systems agreed on 2026-10-10:
##   move      falling-sand CA for powder / liquid / gas / cohesive solids
##   temp      pairwise heat exchange, per-substance conductivity and heat
##             capacity, latent heat for boiling, burner + torch sources
##   solution  dissolved solute diffusion and purity mixing in liquids
##   react     data-driven pair reactions (combustion = wood + air, etc.),
##             dissolution, phase changes
##   light     radiating luminous cells and fires
##   magnet    ferrous powder pulled toward a magnet
##   electric  breadth-first conduction from an electrode
##   scan      per-substance counts, purity, pressure (goal check + lid)
##   render    all cells composited into one nearest-filtered texture
##
## No shaders, no RenderingDevice — safe on the web Compatibility renderer.
## Delete this directory once the spike has an answer.

const SIZES: Array[Vector2i] = [
	Vector2i(64, 48), Vector2i(96, 72), Vector2i(128, 96),
	Vector2i(160, 120), Vector2i(200, 150),
]
const TICK_RATES: Array[float] = [5.0, 10.0, 20.0, 30.0, 0.0]  # 0 = every frame
const AMBIENT := 20.0
const LATENT_FULL := 400.0
const SATURATION := 3.0
const LIGHT_RADIUS := 6
const MAGNET_RADIUS := 12
const BFS_CAP := 4000
const MAX_FIRE_LIGHTS := 16
const REPORT_EVERY := 5.0
const SAMPLE_WINDOW := 120

# Substance ids index the per-substance tables below.
const AIR := 0
const WATER := 1
const OIL := 2
const SAND := 3
const SALT := 4
const IRON := 5
const STEAM := 6
const CO2 := 7
const STONE := 8
const WOOD := 9
const ASH := 10
const GLOW := 11
const SUB_COUNT := 12
const MAX_SUB := 16  # stride of the reaction index

const PH_NONE := 0
const PH_POWDER := 1
const PH_LIQUID := 2
const PH_GAS := 3
const PH_SOLID := 4

# --- per-substance tables ---
var sub_phase := PackedInt32Array()
var sub_density := PackedFloat32Array()
var sub_cond := PackedFloat32Array()
var sub_heatcap := PackedFloat32Array()
var sub_color := PackedColorArray()
var sub_name := PackedStringArray()

# --- reaction table: rx_index[a * MAX_SUB + b] -> reaction id or -1 ---
var rx_index := PackedInt32Array()
var rx_min_temp := PackedFloat32Array()
var rx_max_temp := PackedFloat32Array()
var rx_prob := PackedFloat32Array()
var rx_out_a := PackedInt32Array()
var rx_out_b := PackedInt32Array()
var rx_heat := PackedFloat32Array()
var rx_dissolve := PackedByteArray()  # 1 = a dissolves into b, 2 = b dissolves into a
var rx_light := PackedByteArray()     # 1 = fire: emits light this tick

# --- grid state ---
var gw := 0
var gh := 0
var cell_count := 0
var cells := PackedInt32Array()
var temp := PackedFloat32Array()
var latent := PackedFloat32Array()
var solute := PackedFloat32Array()
var purity := PackedFloat32Array()
var light := PackedFloat32Array()
var charged := PackedByteArray()
var moved := PackedByteArray()
var boundary := PackedByteArray()
var queue := PackedInt32Array()
var glow_cells := PackedInt32Array()
var fire_cells := PackedInt32Array()
var counts := PackedInt32Array()
var burner_cells := PackedInt32Array()

# --- tools and derived state ---
var lid_closed := false
var burner_on := false
var paused := false
var size_idx := 0
var rate_idx := 1
var torch_idx := -1
var electrode_idx := -1
var magnet_x := 0
var magnet_y := 0
var pressure := 0.0
var water_purity := 1.0
var boundary_pairs := 0
var occupied := 0
var tick_count := 0
var rng := RandomNumberGenerator.new()

# --- timing ---
var _accum := 0.0
var _pass_names: Array[String] = ["move", "temp", "solution", "react", "light", "magnet", "electric", "scan"]
var _pass_us := PackedFloat32Array()
var _pass_ticks := 0
var _tick_samples: Array[float] = []
var _render_samples: Array[float] = []
var _report_timer := 0.0
var _stats_line := ""
var _device := ""

# --- rendering / UI ---
var _image: Image
var _texture: ImageTexture
var _sprite: Sprite2D
var _pixels := PackedByteArray()
var _stats: Label
var _btn_size: Button
var _btn_rate: Button
var _btn_lid: Button
var _btn_burner: Button
var _btn_pause: Button
const VIEW_RECT := Rect2(20, 150, 760, 540)


func _ready() -> void:
	Engine.max_fps = 60
	RenderingServer.set_default_clear_color(Color(0.05, 0.04, 0.06))
	_device = OS.get_name()
	if OS.has_feature("web"):
		var ua: Variant = JavaScriptBridge.eval("navigator.userAgent", true)
		_device += " | " + str(ua)
	else:
		_device += " | " + OS.get_processor_name()
	# Headless-ish runs: `godot --path . spike/blocky_probe.tscn -- size=2 rate=4`
	for arg in OS.get_cmdline_user_args():
		var kv: PackedStringArray = arg.split("=")
		if kv.size() != 2:
			continue
		if kv[0] == "size":
			size_idx = clampi(int(kv[1]), 0, SIZES.size() - 1)
		elif kv[0] == "rate":
			rate_idx = clampi(int(kv[1]), 0, TICK_RATES.size() - 1)
	_build_substances()
	_build_reactions()
	_build_ui()
	_pass_us.resize(_pass_names.size())
	_start_grid(size_idx)


# ---------------------------------------------------------------------------
# Data tables
# ---------------------------------------------------------------------------

func _build_substances() -> void:
	sub_phase.resize(SUB_COUNT)
	sub_density.resize(SUB_COUNT)
	sub_cond.resize(SUB_COUNT)
	sub_heatcap.resize(SUB_COUNT)
	sub_color.resize(SUB_COUNT)
	sub_name.resize(SUB_COUNT)
	_def(AIR, "Air", PH_NONE, 0.0012, 0.02, 1.0, Color(0.08, 0.06, 0.1))
	_def(WATER, "Water", PH_LIQUID, 1.0, 0.6, 4.0, Color(0.2, 0.5, 0.9))
	_def(OIL, "Oil", PH_LIQUID, 0.8, 0.15, 2.0, Color(0.35, 0.28, 0.08))
	_def(SAND, "Sand", PH_POWDER, 1.5, 0.3, 0.8, Color(0.8, 0.7, 0.4))
	_def(SALT, "Salt", PH_POWDER, 2.2, 0.1, 0.9, Color(0.95, 0.95, 0.9))
	_def(IRON, "Iron", PH_POWDER, 7.8, 0.8, 0.45, Color(0.45, 0.45, 0.5))
	_def(STEAM, "Steam", PH_GAS, 0.0006, 0.02, 2.0, Color(0.85, 0.85, 0.95))
	_def(CO2, "CO2", PH_GAS, 0.002, 0.02, 0.8, Color(0.45, 0.35, 0.3))
	_def(STONE, "Stone", PH_SOLID, 2.6, 0.3, 0.8, Color(0.5, 0.47, 0.45))
	_def(WOOD, "Wood", PH_SOLID, 0.65, 0.2, 1.7, Color(0.5, 0.32, 0.15))
	_def(ASH, "Ash", PH_POWDER, 0.5, 0.05, 0.8, Color(0.3, 0.3, 0.3))
	_def(GLOW, "Glow", PH_SOLID, 2.0, 0.2, 0.8, Color(0.6, 1.0, 0.8))


func _def(id: int, sname: String, ph: int, dens: float, cond: float, cap: float, col: Color) -> void:
	sub_name[id] = sname
	sub_phase[id] = ph
	sub_density[id] = dens
	sub_cond[id] = cond
	sub_heatcap[id] = cap
	sub_color[id] = col


func _build_reactions() -> void:
	rx_index.resize(MAX_SUB * MAX_SUB)
	rx_index.fill(-1)
	# Combustion is an ordinary two-reactant reaction: fuel + air -> products + heat.
	_rx(WOOD, AIR, 200.0, 9999.0, 0.15, ASH, CO2, 300.0, 0, 1)
	_rx(OIL, AIR, 210.0, 9999.0, 0.2, CO2, CO2, 250.0, 0, 1)
	# Dissolution: the powder vanishes, the liquid's solute rises.
	_rx(SALT, WATER, -9999.0, 9999.0, 0.05, AIR, WATER, 0.0, 1, 0)
	_rx(ASH, WATER, -9999.0, 9999.0, 0.01, AIR, WATER, 0.0, 1, 0)
	# Condensation on cold solids.
	_rx(STEAM, STONE, -9999.0, 60.0, 0.05, WATER, STONE, -20.0, 0, 0)
	_rx(STEAM, IRON, -9999.0, 60.0, 0.05, WATER, IRON, -20.0, 0, 0)


func _rx(a: int, b: int, tmin: float, tmax: float, prob: float, out_a: int, out_b: int,
		heat: float, dissolve: int, emits_light: int) -> void:
	# Ordered entry (a, b) ...
	var id := rx_prob.size()
	rx_index[a * MAX_SUB + b] = id
	rx_min_temp.append(tmin)
	rx_max_temp.append(tmax)
	rx_prob.append(prob)
	rx_out_a.append(out_a)
	rx_out_b.append(out_b)
	rx_heat.append(heat)
	rx_dissolve.append(dissolve)
	rx_light.append(emits_light)
	# ... and its mirror (b, a) so the pair lookup is order-independent.
	var mid := rx_prob.size()
	rx_index[b * MAX_SUB + a] = mid
	rx_min_temp.append(tmin)
	rx_max_temp.append(tmax)
	rx_prob.append(prob)
	rx_out_a.append(out_b)
	rx_out_b.append(out_a)
	rx_heat.append(heat)
	var mirrored_dissolve := 0
	if dissolve == 1:
		mirrored_dissolve = 2
	elif dissolve == 2:
		mirrored_dissolve = 1
	rx_dissolve.append(mirrored_dissolve)
	rx_light.append(emits_light)


# ---------------------------------------------------------------------------
# Grid setup and fill scenario
# ---------------------------------------------------------------------------

func _start_grid(idx: int) -> void:
	size_idx = idx
	var size: Vector2i = SIZES[idx]
	gw = size.x
	gh = size.y
	cell_count = gw * gh
	rng.seed = 42
	tick_count = 0
	pressure = 0.0
	lid_closed = false

	cells = PackedInt32Array()
	cells.resize(cell_count)
	temp = PackedFloat32Array()
	temp.resize(cell_count)
	temp.fill(AMBIENT)
	latent = PackedFloat32Array()
	latent.resize(cell_count)
	solute = PackedFloat32Array()
	solute.resize(cell_count)
	purity = PackedFloat32Array()
	purity.resize(cell_count)
	purity.fill(1.0)
	light = PackedFloat32Array()
	light.resize(cell_count)
	charged = PackedByteArray()
	charged.resize(cell_count)
	moved = PackedByteArray()
	moved.resize(cell_count)
	queue = PackedInt32Array()
	queue.resize(BFS_CAP + 4)
	counts = PackedInt32Array()
	counts.resize(SUB_COUNT)
	glow_cells = PackedInt32Array()
	fire_cells = PackedInt32Array()
	burner_cells = PackedInt32Array()

	_build_boundary()
	_fill_scenario()

	_pixels = PackedByteArray()
	_pixels.resize(cell_count * 4)
	_image = Image.create(gw, gh, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	_sprite.texture = _texture
	var scale_factor := minf(VIEW_RECT.size.x / float(gw), VIEW_RECT.size.y / float(gh))
	_sprite.scale = Vector2(scale_factor, scale_factor)
	_sprite.position = VIEW_RECT.position

	_tick_samples.clear()
	_render_samples.clear()
	_pass_us.fill(0.0)
	_pass_ticks = 0
	_refresh_buttons()


func _build_boundary() -> void:
	## Same cauldron silhouette as the game: straight walls on top, oval bottom.
	boundary = PackedByteArray()
	boundary.resize(cell_count)
	var cx := float(gw) * 0.5
	var cy := float(gh) * 0.55
	var rx := float(gw) * 0.5 - 1.0
	var ry := float(gh) * 0.45
	for y in range(gh):
		for x in range(gw):
			if x < 1 or x >= gw - 1:
				continue
			var fy := float(y)
			if fy < cy:
				boundary[y * gw + x] = 1
			else:
				var dx := (float(x) + 0.5 - cx) / rx
				var dy := (fy - cy) / ry
				if dx * dx + dy * dy <= 1.0:
					boundary[y * gw + x] = 1


func _fill_scenario() -> void:
	## Heavy, boundary-rich load: layered liquids, powder piles sinking,
	## dissolving salt, solids floating and resting, gas above, fire at a torch.
	var water_top := int(float(gh) * 0.55)
	var oil_top := int(float(gh) * 0.49)
	# Water with oil on top.
	for y in range(oil_top, gh):
		for x in range(gw):
			var i := y * gw + x
			if boundary[i] == 0:
				continue
			cells[i] = WATER if y >= water_top else OIL
	# Salt clusters inside the water (they dissolve over time).
	var r_salt := maxi(2, int(float(gh) / 20.0))
	for k in range(4):
		var sx := int(float(gw) * (0.2 + 0.2 * float(k)))
		var sy := water_top + int(float(gh - water_top) * (0.3 + 0.12 * float(k % 3)))
		_blob(sx, sy, r_salt, SALT)
	# Sand piles on the surface near both walls (sink through oil and water).
	var pile_h := maxi(3, int(float(gh) / 10.0))
	_pile(int(float(gw) * 0.18), oil_top, pile_h, SAND)
	_pile(int(float(gw) * 0.82), oil_top, pile_h, SAND)
	# Iron pile near the magnet side.
	_pile(int(float(gw) * 0.68), oil_top, maxi(2, int(float(pile_h) * 0.6)), IRON)
	# Stone blocks (two resting on the floor, one suspended, falling as a clump)
	# with glow crystals embedded.
	var bw := maxi(3, int(float(gw) / 25.0))
	var bh := maxi(2, int(float(gh) / 25.0))
	_block(int(float(gw) * 0.35), gh - bh - 2, bw, bh, STONE)
	_block(int(float(gw) * 0.6), gh - bh - 2, bw, bh, STONE)
	_block(int(float(gw) * 0.5), water_top + bh, bw, bh, STONE)
	for k in range(4):
		var gx := int(float(gw) * (0.3 + 0.13 * float(k)))
		var gy := gh - 3 - (k % 2)
		var gi := gy * gw + gx
		if boundary[gi] != 0:
			cells[gi] = GLOW
			glow_cells.append(gi)
	# Wood blocks floating on the oil, one next to the torch.
	_block(int(float(gw) * 0.3), oil_top - bh, bw, bh, WOOD)
	_block(int(float(gw) * 0.52), oil_top - bh, bw, bh, WOOD)
	# Torch: an air cell held hot, 4-adjacent to the second wood block's top-right cell.
	var tx := int(float(gw) * 0.52) + bw
	var ty := oil_top - bh
	torch_idx = ty * gw + tx
	# Steam sprinkled through the air above the liquid.
	for y in range(2, oil_top - bh - 2):
		for x in range(2, gw - 2):
			var i := y * gw + x
			if boundary[i] != 0 and cells[i] == 0 and rng.randf() < 0.06:
				cells[i] = STEAM
				temp[i] = 100.0
	# Burner cells: bottom-most interior cell of the central columns.
	var half := int(float(gw) * 0.18)
	for x in range(int(float(gw) * 0.5) - half, int(float(gw) * 0.5) + half):
		for y in range(gh - 1, 0, -1):
			var i := y * gw + x
			if boundary[i] != 0:
				burner_cells.append(i)
				break
	# Electrode at the left wall at the oil line; magnet at the right wall above it.
	electrode_idx = oil_top * gw + 1
	magnet_x = gw - 2
	magnet_y = oil_top - 3


func _blob(cx: int, cy: int, r: int, id: int) -> void:
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r:
				continue
			var x := cx + dx
			var y := cy + dy
			if x < 0 or x >= gw or y < 0 or y >= gh:
				continue
			var i := y * gw + x
			if boundary[i] != 0:
				cells[i] = id


func _pile(cx: int, base_y: int, height: int, id: int) -> void:
	for k in range(height):
		var y := base_y - 1 - k
		var half := height - 1 - k
		for x in range(cx - half, cx + half + 1):
			if x < 0 or x >= gw or y < 0 or y >= gh:
				continue
			var i := y * gw + x
			if boundary[i] != 0:
				cells[i] = id


func _block(x0: int, y0: int, bw: int, bh: int, id: int) -> void:
	for y in range(y0, y0 + bh):
		for x in range(x0, x0 + bw):
			if x < 0 or x >= gw or y < 0 or y >= gh:
				continue
			var i := y * gw + x
			if boundary[i] != 0:
				cells[i] = id


# ---------------------------------------------------------------------------
# Tick
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not paused:
		var rate: float = TICK_RATES[rate_idx]
		if rate <= 0.0:
			_tick()
		else:
			var dt := 1.0 / rate
			_accum += minf(delta, 0.25)
			if _accum >= dt:
				_accum -= dt
				if _accum > dt:
					_accum = dt  # fell behind: never run more than one tick per frame
				_tick()
	var t0 := Time.get_ticks_usec()
	_render()
	var render_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	_render_samples.append(render_ms)
	if _render_samples.size() > SAMPLE_WINDOW:
		_render_samples.pop_front()
	_report_timer += delta
	if _report_timer >= 1.0:
		_report_timer = 0.0
		_update_stats()


func _tick() -> void:
	var t_start := Time.get_ticks_usec()
	var t0 := t_start
	_pass_move()
	var t1 := Time.get_ticks_usec()
	_pass_temp()
	var t2 := Time.get_ticks_usec()
	_pass_solution()
	var t3 := Time.get_ticks_usec()
	_pass_react()
	var t4 := Time.get_ticks_usec()
	_pass_light()
	var t5 := Time.get_ticks_usec()
	_pass_magnet()
	var t6 := Time.get_ticks_usec()
	_pass_electric()
	var t7 := Time.get_ticks_usec()
	_pass_scan()
	var t8 := Time.get_ticks_usec()
	_pass_us[0] += float(t1 - t0)
	_pass_us[1] += float(t2 - t1)
	_pass_us[2] += float(t3 - t2)
	_pass_us[3] += float(t4 - t3)
	_pass_us[4] += float(t5 - t4)
	_pass_us[5] += float(t6 - t5)
	_pass_us[6] += float(t7 - t6)
	_pass_us[7] += float(t8 - t7)
	_pass_ticks += 1
	_tick_samples.append(float(t8 - t_start) / 1000.0)
	if _tick_samples.size() > SAMPLE_WINDOW:
		_tick_samples.pop_front()
	tick_count += 1


# --- move: falling-sand CA ---------------------------------------------------

func _pass_move() -> void:
	moved.fill(0)
	var w := gw
	var h := gh
	var c := cells
	var mv := moved
	var bd := boundary
	var ph := sub_phase
	var dn := sub_density
	var left_first := (tick_count & 1) == 0
	var open_top := not lid_closed
	for y in range(h - 1, -1, -1):
		var row := y * w
		var x := 0 if left_first else w - 1
		var x_step := 1 if left_first else -1
		for _k in range(w):
			var i := row + x
			x += x_step
			var s: int = c[i]
			if s == 0 or mv[i] != 0 or bd[i] == 0:
				continue
			var p: int = ph[s]
			if p == PH_GAS:
				# Rise straight up through air or liquid.
				if y > 0:
					var j := i - w
					if bd[j] != 0:
						var t: int = c[j]
						if t == 0 or ph[t] == PH_LIQUID:
							_swap(i, j, s, t)
							continue
					# Diagonal up, random side first.
					var dx := -1 if rng.randf() < 0.5 else 1
					var jx := i - w + dx
					var xx := x - x_step + dx
					if xx >= 0 and xx < w and bd[jx] != 0 and c[jx] == 0:
						_swap(i, jx, s, 0)
						continue
					jx = i - w - dx
					xx = x - x_step - dx
					if xx >= 0 and xx < w and bd[jx] != 0 and c[jx] == 0:
						_swap(i, jx, s, 0)
						continue
				# Drift sideways.
				var sdx := -1 if rng.randf() < 0.5 else 1
				var sx := x - x_step + sdx
				if sx >= 0 and sx < w and bd[i + sdx] != 0 and c[i + sdx] == 0:
					_swap(i, i + sdx, s, 0)
					continue
				# Escape through the open rim.
				if open_top and y <= 1 and rng.randf() < 0.05:
					c[i] = 0
					temp[i] = AMBIENT
				continue
			# Powder, liquid, solid: fall straight down through air, gas, or lighter liquid.
			if y < h - 1:
				var j := i + w
				if bd[j] != 0:
					var t: int = c[j]
					if t == 0:
						_swap(i, j, s, 0)
						continue
					var tp: int = ph[t]
					if (tp == PH_GAS or tp == PH_LIQUID) and dn[s] > dn[t] * 1.05:
						_swap(i, j, s, t)
						continue
			if p == PH_SOLID:
				continue  # cohesive: only falls straight down, so blocks drop as clumps
			# Diagonal down, random side first.
			if y < h - 1:
				var ddx := -1 if rng.randf() < 0.5 else 1
				for _side in range(2):
					var xx := x - x_step + ddx
					if xx >= 0 and xx < w:
						var jd := i + w + ddx
						if bd[jd] != 0:
							var t: int = c[jd]
							if t == 0:
								_swap(i, jd, s, 0)
								break
							var tp: int = ph[t]
							if (tp == PH_GAS or tp == PH_LIQUID) and dn[s] > dn[t] * 1.05:
								_swap(i, jd, s, t)
								break
					ddx = -ddx
				if mv[i] != 0:
					continue
			if p != PH_LIQUID:
				continue
			# Liquid: spread sideways into air.
			var ldx := -1 if rng.randf() < 0.5 else 1
			var lx := x - x_step + ldx
			if lx >= 0 and lx < w and bd[i + ldx] != 0 and c[i + ldx] == 0:
				_swap(i, i + ldx, s, 0)
				continue
			lx = x - x_step - ldx
			if lx >= 0 and lx < w and bd[i - ldx] != 0 and c[i - ldx] == 0:
				_swap(i, i - ldx, s, 0)


func _swap(i: int, j: int, s: int, t: int) -> void:
	## Move cell i into j (and j's content back into i), carrying per-cell scalars.
	cells[j] = s
	cells[i] = t
	moved[j] = 1
	moved[i] = 1
	var tmp_f: float = temp[i]
	temp[i] = temp[j]
	temp[j] = tmp_f
	tmp_f = latent[i]
	latent[i] = latent[j]
	latent[j] = tmp_f
	tmp_f = solute[i]
	solute[i] = solute[j]
	solute[j] = tmp_f
	tmp_f = purity[i]
	purity[i] = purity[j]
	purity[j] = tmp_f


# --- temp: pairwise heat exchange ---------------------------------------------

func _pass_temp() -> void:
	var w := gw
	var h := gh
	var c := cells
	var tp := temp
	var bd := boundary
	var kc := sub_cond
	var hc := sub_heatcap
	var lat := latent
	var open_top := not lid_closed
	for y in range(h):
		var row := y * w
		var last_row := y == h - 1
		for x in range(w):
			var i := row + x
			if bd[i] == 0:
				continue
			var s: int = c[i]
			var t: float = tp[i]
			var k: float = kc[s]
			var cap: float = hc[s]
			# Exchange with right and down neighbours only: every pair once.
			if x < w - 1:
				var j := i + 1
				if bd[j] != 0:
					var u: int = c[j]
					var e := (tp[j] - t) * minf(k, kc[u]) * 0.25
					if e != 0.0:
						t += e / cap
						tp[j] -= e / hc[u]
			if not last_row:
				var j := i + w
				if bd[j] != 0:
					var u: int = c[j]
					var e := (tp[j] - t) * minf(k, kc[u]) * 0.25
					if e != 0.0:
						t += e / cap
						tp[j] -= e / hc[u]
			# Losses through walls and the open rim.
			t += (AMBIENT - t) * 0.002
			if s == 0 and y < 2 and open_top:
				t += (AMBIENT - t) * 0.2
			# Latent heat: water above boiling banks energy instead of heating.
			if s == WATER and t > 100.0:
				lat[i] += (t - 100.0) * cap
				t = 100.0
			tp[i] = t
	# Sources.
	if burner_on:
		for i in burner_cells:
			tp[i] += (650.0 - tp[i]) * 0.1
	if torch_idx >= 0 and c[torch_idx] == 0:
		tp[torch_idx] = 420.0


# --- solution: solute diffusion and purity mixing in liquids ------------------

func _pass_solution() -> void:
	var w := gw
	var h := gh
	var c := cells
	var ph := sub_phase
	var so := solute
	var pu := purity
	var bd := boundary
	for y in range(h):
		var row := y * w
		var last_row := y == h - 1
		for x in range(w):
			var i := row + x
			var s: int = c[i]
			if s == 0 or ph[s] != PH_LIQUID or bd[i] == 0:
				continue
			if x < w - 1:
				var j := i + 1
				var u: int = c[j]
				if u == s:
					var d := (so[j] - so[i]) * 0.2
					so[i] += d
					so[j] -= d
				elif u != 0 and ph[u] == PH_LIQUID:
					pu[i] -= 0.01 * pu[i]
					pu[j] -= 0.01 * pu[j]
			if not last_row:
				var j := i + w
				var u: int = c[j]
				if u == s:
					var d := (so[j] - so[i]) * 0.2
					so[i] += d
					so[j] -= d
				elif u != 0 and ph[u] == PH_LIQUID:
					pu[i] -= 0.01 * pu[i]
					pu[j] -= 0.01 * pu[j]


# --- react: pair reactions, dissolution, phase changes ------------------------

func _pass_react() -> void:
	var w := gw
	var h := gh
	var c := cells
	var tp := temp
	var lat := latent
	var so := solute
	var bd := boundary
	var rxi := rx_index
	var hc := sub_heatcap
	var pairs := 0
	fire_cells.resize(0)
	for y in range(h):
		var row := y * w
		var last_row := y == h - 1
		for x in range(w):
			var i := row + x
			var s: int = c[i]
			if s == 0 or bd[i] == 0:
				continue
			var t: float = tp[i]
			# Single-cell phase changes.
			if s == WATER:
				if lat[i] >= LATENT_FULL:
					lat[i] = 0.0
					if so[i] >= 1.0:
						c[i] = SALT  # the water is gone; its salt stays behind
						so[i] = 0.0
					else:
						c[i] = STEAM
						so[i] = 0.0
					continue
			elif s == STEAM:
				if t < 95.0 and rng.randf() < 0.002:
					c[i] = WATER
					continue
			# Pair reactions with the right and down neighbours (each pair once;
			# the table holds both orders).
			for side in range(2):
				var j: int
				if side == 0:
					if x >= w - 1:
						continue
					j = i + 1
				else:
					if last_row:
						continue
					j = i + w
				if bd[j] == 0:
					continue
				var u: int = c[j]
				if u == s:
					continue
				pairs += 1
				var r: int = rxi[s * MAX_SUB + u]
				if r < 0:
					continue
				var tt := maxf(t, tp[j])
				if tt < rx_min_temp[r] or tt > rx_max_temp[r]:
					continue
				if rng.randf() >= rx_prob[r]:
					continue
				var mode: int = rx_dissolve[r]
				if mode == 1:
					if so[j] < SATURATION:
						so[j] += 1.0
						c[i] = 0
				elif mode == 2:
					if so[i] < SATURATION:
						so[i] += 1.0
						c[j] = 0
				else:
					var oa: int = rx_out_a[r]
					var ob: int = rx_out_b[r]
					c[i] = oa
					c[j] = ob
					var q: float = rx_heat[r]
					if q != 0.0:
						tp[i] += q / hc[oa]
						tp[j] += q / hc[ob]
					if rx_light[r] != 0 and fire_cells.size() < MAX_FIRE_LIGHTS:
						fire_cells.append(i)
				break  # one reaction per cell per tick
	boundary_pairs = pairs


# --- light: radiate from glow crystals and fires ------------------------------

func _pass_light() -> void:
	light.fill(0.0)
	for i in glow_cells:
		if cells[i] == GLOW:
			_radiate(i, 1.0)
	for i in fire_cells:
		_radiate(i, 2.0)


func _radiate(i: int, intensity: float) -> void:
	var w := gw
	var h := gh
	var cx := i % w
	var cy := floori(float(i) / float(w))
	var lt := light
	for dy in range(-LIGHT_RADIUS, LIGHT_RADIUS + 1):
		var y := cy + dy
		if y < 0 or y >= h:
			continue
		for dx in range(-LIGHT_RADIUS, LIGHT_RADIUS + 1):
			var x := cx + dx
			if x < 0 or x >= w:
				continue
			var d2 := dx * dx + dy * dy
			if d2 > LIGHT_RADIUS * LIGHT_RADIUS:
				continue
			lt[y * w + x] += intensity / (1.0 + float(d2))


# --- magnet: pull ferrous powder --------------------------------------------

func _pass_magnet() -> void:
	var w := gw
	var h := gh
	var c := cells
	var ph := sub_phase
	for dy in range(-MAGNET_RADIUS, MAGNET_RADIUS + 1):
		var y := magnet_y + dy
		if y < 0 or y >= h:
			continue
		for dx in range(-MAGNET_RADIUS, MAGNET_RADIUS + 1):
			var x := magnet_x + dx
			if x < 0 or x >= w:
				continue
			var i := y * w + x
			if c[i] != IRON or moved[i] != 0:
				continue
			if rng.randf() >= 0.3:
				continue
			var sx := signi(magnet_x - x)
			var sy := signi(magnet_y - y)
			var tx := x + sx
			var ty := y + sy
			if tx < 0 or tx >= w or ty < 0 or ty >= h:
				continue
			var j := ty * w + tx
			if boundary[j] == 0:
				continue
			var u: int = c[j]
			if u == 0 or ph[u] == PH_LIQUID or ph[u] == PH_GAS:
				_swap(i, j, IRON, u)


# --- electric: breadth-first conduction from the electrode -------------------

func _pass_electric() -> void:
	charged.fill(0)
	if electrode_idx < 0:
		return
	var w := gw
	var h := gh
	var c := cells
	var so := solute
	var ch := charged
	var q := queue
	var head := 0
	var tail := 0
	if not _conducts(c[electrode_idx], so[electrode_idx]):
		return
	ch[electrode_idx] = 1
	q[tail] = electrode_idx
	tail += 1
	while head < tail and tail < BFS_CAP:
		var i: int = q[head]
		head += 1
		var x := i % w
		var y := floori(float(i) / float(w))
		if x > 0:
			var j := i - 1
			if ch[j] == 0 and _conducts(c[j], so[j]):
				ch[j] = 1
				q[tail] = j
				tail += 1
		if x < w - 1:
			var j := i + 1
			if ch[j] == 0 and _conducts(c[j], so[j]):
				ch[j] = 1
				q[tail] = j
				tail += 1
		if y > 0:
			var j := i - w
			if ch[j] == 0 and _conducts(c[j], so[j]):
				ch[j] = 1
				q[tail] = j
				tail += 1
		if y < h - 1:
			var j := i + w
			if ch[j] == 0 and _conducts(c[j], so[j]):
				ch[j] = 1
				q[tail] = j
				tail += 1


func _conducts(s: int, sol: float) -> bool:
	if s == IRON:
		return true
	return s == WATER and sol >= 0.3


# --- scan: counts, purity, pressure (the goal check) --------------------------

func _pass_scan() -> void:
	counts.fill(0)
	var c := cells
	var bd := boundary
	var pu := purity
	var cnt := counts
	var psum := 0.0
	var occ := 0
	for i in range(cell_count):
		if bd[i] == 0:
			continue
		var s: int = c[i]
		cnt[s] += 1
		if s != 0:
			occ += 1
			if s == WATER:
				psum += pu[i]
	occupied = occ
	var water_n: int = cnt[WATER]
	water_purity = psum / float(water_n) if water_n > 0 else 1.0
	var gas: int = cnt[STEAM] + cnt[CO2]
	var free: int = cnt[AIR] + gas
	pressure = float(gas) / float(free) if free > 0 else 0.0
	if lid_closed and pressure > 0.6:
		lid_closed = false  # the lid blows off
		_refresh_buttons()


# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

func _render() -> void:
	var pd := _pixels
	var c := cells
	var bd := boundary
	var cols := sub_color
	var tp := temp
	var lt := light
	var ch := charged
	var hot := Color(1.0, 0.3, 0.05)
	var spark := Color(0.5, 0.7, 1.0)
	var wall := Color(0.15, 0.13, 0.12)
	for i in range(cell_count):
		var off := i * 4
		var col: Color
		if bd[i] == 0:
			col = wall
		else:
			col = cols[c[i]]
			var t: float = tp[i]
			if t > 60.0:
				col = col.lerp(hot, clampf((t - 60.0) / 500.0, 0.0, 0.8))
			var l: float = lt[i]
			if l > 0.0:
				col = col.lightened(clampf(l * 0.5, 0.0, 0.6))
			if ch[i] != 0:
				col = col.lerp(spark, 0.5)
		pd[off] = col.r8
		pd[off + 1] = col.g8
		pd[off + 2] = col.b8
		pd[off + 3] = 255
	_image.set_data(gw, gh, false, Image.FORMAT_RGBA8, pd)
	_texture.update(_image)


# ---------------------------------------------------------------------------
# UI and stats
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_sprite = Sprite2D.new()
	_sprite.centered = false
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_sprite)

	var layer := CanvasLayer.new()
	add_child(layer)

	_stats = Label.new()
	_stats.position = Vector2(20, 8)
	_stats.add_theme_font_size_override("font_size", 22)
	_stats.add_theme_color_override("font_color", Color(1.0, 0.95, 0.6))
	layer.add_child(_stats)

	var bar := HBoxContainer.new()
	bar.position = Vector2(800, 150)
	bar.add_theme_constant_override("separation", 8)
	bar.size = Vector2(460, 540)
	layer.add_child(bar)
	var col_a := VBoxContainer.new()
	col_a.add_theme_constant_override("separation", 10)
	bar.add_child(col_a)
	var col_b := VBoxContainer.new()
	col_b.add_theme_constant_override("separation", 10)
	bar.add_child(col_b)

	_btn_size = _button(col_a, "Size", func() -> void: _start_grid((size_idx + 1) % SIZES.size()))
	_btn_rate = _button(col_a, "Rate", func() -> void:
		rate_idx = (rate_idx + 1) % TICK_RATES.size()
		_tick_samples.clear()
		_refresh_buttons())
	_btn_pause = _button(col_a, "Pause", func() -> void:
		paused = not paused
		_refresh_buttons())
	_btn_lid = _button(col_b, "Lid", func() -> void:
		lid_closed = not lid_closed
		_refresh_buttons())
	_btn_burner = _button(col_b, "Burner", func() -> void:
		burner_on = not burner_on
		_refresh_buttons())
	_button(col_b, "Reset", func() -> void: _start_grid(size_idx))
	_button(col_b, "Print", func() -> void: print(_stats_line))


func _button(parent: Control, text: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(220, 64)
	b.add_theme_font_size_override("font_size", 24)
	b.pressed.connect(on_pressed)
	parent.add_child(b)
	return b


func _refresh_buttons() -> void:
	_btn_size.text = "Size: %dx%d" % [gw, gh]
	var rate: float = TICK_RATES[rate_idx]
	_btn_rate.text = "Tick: every frame" if rate <= 0.0 else "Tick: %d Hz" % int(rate)
	_btn_pause.text = "Resume" if paused else "Pause"
	_btn_lid.text = "Lid: %s" % ("closed" if lid_closed else "open")
	_btn_burner.text = "Burner: %s" % ("on" if burner_on else "off")


func _avg(samples: Array[float]) -> float:
	if samples.is_empty():
		return 0.0
	var total := 0.0
	for v in samples:
		total += v
	return total / float(samples.size())


func _max(samples: Array[float]) -> float:
	var m := 0.0
	for v in samples:
		if v > m:
			m = v
	return m


func _update_stats() -> void:
	var tick_avg := _avg(_tick_samples)
	var tick_max := _max(_tick_samples)
	var render_avg := _avg(_render_samples)
	var fps := float(Engine.get_frames_per_second())
	var rate: float = TICK_RATES[rate_idx]
	var effective_rate := rate if rate > 0.0 else fps
	var busy := (tick_avg * effective_rate + render_avg * fps) / 10.0  # percent of one second
	var breakdown := ""
	if _pass_ticks > 0:
		for k in range(_pass_names.size()):
			breakdown += "%s %.1f  " % [_pass_names[k], _pass_us[k] / float(_pass_ticks) / 1000.0]
	var header := "PROBE %dx%d = %d cells | occupied %d (%d%%) | boundary pairs %d | tick #%d" % [
		gw, gh, cell_count, occupied, int(100.0 * float(occupied) / float(cell_count)), boundary_pairs, tick_count]
	var timing := "tick %.1f ms avg, %.1f max @ %s | render %.1f ms | engine %d FPS | CPU busy ~%d%%" % [
		tick_avg, tick_max, ("every frame" if rate <= 0.0 else "%d Hz" % int(rate)), render_avg, int(fps), int(busy)]
	var world := "lid %s | burner %s | pressure %.2f | water purity %.2f | steam %d | co2 %d | ash %d | salt %d" % [
		("closed" if lid_closed else "open"), ("on" if burner_on else "off"), pressure, water_purity,
		counts[STEAM], counts[CO2], counts[ASH], counts[SALT]]
	_stats.text = header + "\n" + timing + "\n" + breakdown + "\n" + world + "\n" + _device
	_stats_line = "[PROBE] %dx%d occ=%d pairs=%d tick=%.2fms max=%.2fms render=%.2fms fps=%d busy=%d%% | %s| steam=%d co2=%d ash=%d salt=%d purity=%.2f pressure=%.2f | %s" % [
		gw, gh, occupied, boundary_pairs, tick_avg, tick_max, render_avg, int(fps), int(busy), breakdown,
		counts[STEAM], counts[CO2], counts[ASH], counts[SALT], water_purity, pressure, _device]
	if int(Time.get_ticks_msec() / 1000.0) % int(REPORT_EVERY) == 0:
		print(_stats_line)
