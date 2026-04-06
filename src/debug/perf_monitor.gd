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
