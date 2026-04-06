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
