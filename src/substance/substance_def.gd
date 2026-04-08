class_name SubstanceDef
extends Resource
## Data definition for a substance. All substances are defined as .tres resources
## with these properties. Reactions emerge from property comparisons, not recipes.

enum Phase { SOLID, POWDER, LIQUID, GAS }

@export_group("Identity")
@export var substance_name: String = ""
@export var phase: Phase = Phase.POWDER

@export_group("Physical")
## Mass per unit volume. Drives buoyancy (Archimedes) in both the vapor sim
## and PIC/FLIP liquid sim: effective gravity = g × (1 - ambient_density /
## density), where ambient is AIR_DENSITY in VaporSim (gas behavior vs air)
## and also AIR_DENSITY in PIC/FLIP for now (liquids fall in an empty
## receptacle, not immersed in another liquid). Use real-world relative
## values: water=1.0, oil=0.8, mercury=13.5, steam=0.0006, CO2≈0.002,
## methane≈0.00065. Air in our scale is ~0.0012 (water is 1000× denser).
@export var density: float = 1.0
@export var viscosity: float = 1.0  ## For liquids. Higher = thicker (honey > water).
## PIC/FLIP blend factor used by pflip_g2p.glsl. 1.0 = pure FLIP (lively,
## preserves swirl), 0.0 = pure PIC (heavy, dissipative). 0.95 is a standard
## lively water; drop toward 0.7-0.85 for sluggish fluids like oil or tar.
@export_range(0.0, 1.0) var flip_ratio: float = 0.95

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
