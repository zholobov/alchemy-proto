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
