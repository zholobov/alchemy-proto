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


static func evaluate(a: SubstanceDef, b: SubstanceDef, temp_a: float, _temp_b: float) -> ReactionResult:
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
		if SubstanceRegistry.sim_rng.randf() < 0.01:  # Slow dissolution.
			result.consumed_a = true
			result.sound_event = "dissolve"
			return result

	# Rule 7: Rusting — iron + water, very slow.
	if a.magnetic_permeability > 0.5 and b.substance_name == "Water":
		if SubstanceRegistry.sim_rng.randf() < 0.001:
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
