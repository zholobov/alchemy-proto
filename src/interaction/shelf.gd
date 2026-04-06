class_name Shelf
extends HBoxContainer
## Top shelf displaying available substances as draggable items.

signal substance_picked(substance_id: int, phase: SubstanceDef.Phase)
signal reset_requested

const ITEM_SIZE := Vector2(70, 70)


func _ready() -> void:
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
		if substance.phase == SubstanceDef.Phase.GAS:
			continue

		var item := Button.new()
		item.custom_minimum_size = ITEM_SIZE

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

		var phase_text := ""
		match substance.phase:
			SubstanceDef.Phase.POWDER: phase_text = "[P]"
			SubstanceDef.Phase.LIQUID: phase_text = "[L]"
			SubstanceDef.Phase.SOLID: phase_text = "[S]"
		item.text = "%s\n%s" % [substance.substance_name.substr(0, 7), phase_text]
		item.tooltip_text = substance.substance_name

		var sub_id := i
		item.pressed.connect(func(): substance_picked.emit(sub_id, substance.phase))

		add_child(item)

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
	reset_btn.pressed.connect(func(): reset_requested.emit())
	add_child(reset_btn)
