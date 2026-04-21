extends Node

# This autoload owns the song select slide transition because base mode now
# starts after song selection instead of immediately on ball start.
const SONG_SELECT_SLIDE := "song_select"
const SONG_SELECT_CONTEXT := "song_select"
const SONG_SELECT_PRIORITY := 1500

# MPF and the display window may finish startup on different frames.
const WINDOW_RETRY_FRAMES := 10

var _handlers := {
	"mode_song_select_started": "_on_song_select_show_slide",
	"song_select_show_slide": "_on_song_select_show_slide",
	"song_select_complete": "_on_song_select_complete",
}


func _ready() -> void:
	for event_name in _handlers.keys():
		MPF.server.add_event_handler(event_name, Callable(self, _handlers[event_name]))


func _exit_tree() -> void:
	for event_name in _handlers.keys():
		MPF.server.remove_event_handler(event_name, Callable(self, _handlers[event_name]))


# Song select is shown by a project-level autoload so base mode can start later.
func _on_song_select_show_slide(_payload: Dictionary) -> void:
	_play_slide(SONG_SELECT_SLIDE, "play", SONG_SELECT_CONTEXT, SONG_SELECT_PRIORITY)


func _on_song_select_complete(_payload: Dictionary) -> void:
	_play_slide(SONG_SELECT_SLIDE, "remove", SONG_SELECT_CONTEXT, 0)


func _play_slide(slide_name: String, action: String, context: String, priority: int, attempt: int = 0) -> void:
	# On a fresh game start, this can fire before the Godot media window exists.
	if not MPF.media or not MPF.media.window:
		if attempt < WINDOW_RETRY_FRAMES:
			await get_tree().process_frame
			_play_slide(slide_name, action, context, priority, attempt + 1)
		return

	# Keep expire disabled so the slide stays up until the mode explicitly
	# removes it after a song is confirmed.
	var settings := {}
	settings[slide_name] = {
		"action": action,
		"expire": false,
	}
	MPF.media.window.play_slides({
		"settings": settings,
		"context": context,
		"priority": priority,
	})
