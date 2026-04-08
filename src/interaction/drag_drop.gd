class_name DragDrop
extends Node2D
## Handles dragging substances from shelf to receptacle.

signal dropped(substance_id: int, phase: SubstanceDef.Phase, position: Vector2)
signal pouring(substance_id: int, position: Vector2)

var active_substance_id: int = 0
var active_phase: SubstanceDef.Phase = SubstanceDef.Phase.POWDER
var is_dragging: bool = false

var _drag_visual: ColorRect
var _drag_label: Label


func _ready() -> void:
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

	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		# LIQUID is polled directly by main.gd so the spawn runs BEFORE
		# fluid_solver.step() within the same _process call (matches the
		# test scene's spawn-then-step ordering). POWDER still uses the
		# signal path since its sim isn't CFL-sensitive.
		if active_phase == SubstanceDef.Phase.POWDER:
			pouring.emit(active_substance_id, mouse_pos)


func _input(event: InputEvent) -> void:
	if not is_dragging:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			if active_phase == SubstanceDef.Phase.SOLID:
				dropped.emit(active_substance_id, active_phase, get_global_mouse_position())
			cancel_drag()

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		cancel_drag()
