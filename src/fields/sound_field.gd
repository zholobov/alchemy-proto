class_name SoundField
extends RefCounted
## Sound system. Not a spatial field — triggers audio events.

var _pending_events: Array[Dictionary] = []
var _audio_players: Dictionary = {}
var _parent_node: Node

const MAX_SIMULTANEOUS := 5
var _active_count := 0


func setup(parent: Node) -> void:
	_parent_node = parent


func trigger(event_name: String, intensity: float = 1.0) -> void:
	if _pending_events.size() < MAX_SIMULTANEOUS:
		_pending_events.append({"name": event_name, "intensity": clampf(intensity, 0.0, 1.0)})


func flush() -> void:
	for event in _pending_events:
		_play(event["name"], event["intensity"])
	_pending_events.clear()


func _play(event_name: String, intensity: float) -> void:
	if intensity > 0.3:
		print("[SFX] %s (%.1f)" % [event_name, intensity])
