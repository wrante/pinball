extends MPFSlide

const BASE_SCORE_FONT_SIZE := 64
const ACTIVE_SCORE_FONT_SIZE := 77
const SCORE_MARGIN := 40.0
const SCORE_TOP := 30.0
const SCORE_BOTTOM_MARGIN := 52.0
const SCORE_WIDTH := 560.0
const SCORE_HEIGHT := 100.0
const CENTER_SCORE_FONT_SIZE := 110
const CENTER_SCORE_WIDTH := 900.0
const CENTER_SCORE_HEIGHT := 160.0

# Base slide listens for rhythm audio events because rhythm mode uses the same
# music bus that song select previews use.
var _handlers := {
	"rhythm_music_started": "_on_rhythm_music_started",
	"selected_song_pause_for_rhythm": "_on_selected_song_pause_for_rhythm",
	"selected_song_resume_after_rhythm": "_on_selected_song_resume_after_rhythm",
}

# Last known selected-song state, captured before rhythm replaces the bus audio.
var _paused_song := {}
var _score_labels := []
var _center_score_label: Label


func _ready() -> void:
	for event_name in _handlers.keys():
		MPF.server.add_event_handler(event_name, Callable(self, _handlers[event_name]))

	_build_scoreboard()
	_build_center_score()
	_connect_scoreboard_signals()
	_update_scoreboard()

	# The selected song can be interrupted by direct bus replacement, so listen
	# to the bus itself in addition to the MPF pause event.
	_connect_sound_bus_signals()


func _exit_tree() -> void:
	for event_name in _handlers.keys():
		MPF.server.remove_event_handler(event_name, Callable(self, _handlers[event_name]))
	_disconnect_scoreboard_signals()
	_disconnect_sound_bus_signals()


func _build_scoreboard() -> void:
	var parent := get_node_or_null("TextureRect")
	if not parent:
		return

	var score_placements := [
		{"preset": PRESET_TOP_LEFT, "left": SCORE_MARGIN, "top": SCORE_TOP, "right": SCORE_MARGIN + SCORE_WIDTH, "bottom": SCORE_TOP + SCORE_HEIGHT, "alignment": HORIZONTAL_ALIGNMENT_LEFT},
		{"preset": PRESET_TOP_RIGHT, "left": -SCORE_MARGIN - SCORE_WIDTH, "top": SCORE_TOP, "right": -SCORE_MARGIN, "bottom": SCORE_TOP + SCORE_HEIGHT, "alignment": HORIZONTAL_ALIGNMENT_RIGHT},
		{"preset": PRESET_BOTTOM_LEFT, "left": SCORE_MARGIN, "top": -SCORE_BOTTOM_MARGIN - SCORE_HEIGHT, "right": SCORE_MARGIN + SCORE_WIDTH, "bottom": -SCORE_BOTTOM_MARGIN, "alignment": HORIZONTAL_ALIGNMENT_LEFT},
		{"preset": PRESET_BOTTOM_RIGHT, "left": -SCORE_MARGIN - SCORE_WIDTH, "top": -SCORE_BOTTOM_MARGIN - SCORE_HEIGHT, "right": -SCORE_MARGIN, "bottom": -SCORE_BOTTOM_MARGIN, "alignment": HORIZONTAL_ALIGNMENT_RIGHT},
	]

	for player_index in range(4):
		var placement: Dictionary = score_placements[player_index]
		var label := Label.new()
		label.name = "Player%sScore" % (player_index + 1)
		label.layout_mode = 1
		label.set_anchors_preset(placement.preset, false)
		label.offset_left = placement.left
		label.offset_top = placement.top
		label.offset_right = placement.right
		label.offset_bottom = placement.bottom
		label.horizontal_alignment = placement.alignment
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.text = "00"
		label.add_theme_color_override("font_color", Color(0.96, 0.94, 0.82, 1.0))
		label.add_theme_color_override("font_shadow_color", Color(0.05, 0.08, 0.07, 0.9))
		label.add_theme_constant_override("shadow_offset_x", 3)
		label.add_theme_constant_override("shadow_offset_y", 3)
		label.add_theme_constant_override("shadow_outline_size", 2)
		label.add_theme_font_size_override("font_size", BASE_SCORE_FONT_SIZE)
		parent.add_child(label)
		_score_labels.append(label)


func _build_center_score() -> void:
	var parent := get_node_or_null("TextureRect")
	if not parent:
		return

	_center_score_label = Label.new()
	_center_score_label.name = "CurrentPlayerScore"
	_center_score_label.layout_mode = 1
	_center_score_label.set_anchors_preset(PRESET_CENTER, false)
	_center_score_label.offset_left = -CENTER_SCORE_WIDTH / 2.0
	_center_score_label.offset_top = -CENTER_SCORE_HEIGHT / 2.0
	_center_score_label.offset_right = CENTER_SCORE_WIDTH / 2.0
	_center_score_label.offset_bottom = CENTER_SCORE_HEIGHT / 2.0
	_center_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center_score_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_center_score_label.text = "00"
	_center_score_label.add_theme_color_override("font_color", Color(0.96, 0.94, 0.82, 1.0))
	_center_score_label.add_theme_color_override("font_shadow_color", Color(0.9607843, 0.42352942, 0.54509807, 1))
	_center_score_label.add_theme_constant_override("shadow_offset_x", 3)
	_center_score_label.add_theme_constant_override("shadow_offset_y", 3)
	_center_score_label.add_theme_constant_override("shadow_outline_size", 2)
	_center_score_label.add_theme_font_size_override("font_size", CENTER_SCORE_FONT_SIZE)
	parent.add_child(_center_score_label)


func _connect_scoreboard_signals() -> void:
	var player_added := Callable(self, "_on_scoreboard_player_added")
	var player_updated := Callable(self, "_on_scoreboard_player_updated")
	var turn_started := Callable(self, "_on_scoreboard_turn_started")
	if not MPF.game.player_added.is_connected(player_added):
		MPF.game.player_added.connect(player_added)
	if not MPF.game.player_update.is_connected(player_updated):
		MPF.game.player_update.connect(player_updated)
	if not MPF.game.player_turn_started.is_connected(turn_started):
		MPF.game.player_turn_started.connect(turn_started)


func _disconnect_scoreboard_signals() -> void:
	var player_added := Callable(self, "_on_scoreboard_player_added")
	var player_updated := Callable(self, "_on_scoreboard_player_updated")
	var turn_started := Callable(self, "_on_scoreboard_turn_started")
	if MPF.game.player_added.is_connected(player_added):
		MPF.game.player_added.disconnect(player_added)
	if MPF.game.player_update.is_connected(player_updated):
		MPF.game.player_update.disconnect(player_updated)
	if MPF.game.player_turn_started.is_connected(turn_started):
		MPF.game.player_turn_started.disconnect(turn_started)


func _on_scoreboard_player_added(_total_players: int) -> void:
	_update_scoreboard()


func _on_scoreboard_player_updated(var_name: String, _value: Variant) -> void:
	if var_name == "score":
		_update_scoreboard()


func _on_scoreboard_turn_started(_player_number: int) -> void:
	_update_scoreboard()


func _update_scoreboard() -> void:
	var current_player_number := int(MPF.game.player.get("number", 0))
	var current_score := 0
	for player_index in range(_score_labels.size()):
		var label: Label = _score_labels[player_index]
		if MPF.game.players.size() <= player_index:
			label.hide()
			continue

		label.show()
		var score := 0
		score = int(MPF.game.players[player_index].get("score", 0))
		if current_player_number == player_index + 1:
			current_score = score
		label.text = "%02d" % score if score < 1000 else MPF.util.comma_sep(score)
		label.add_theme_font_size_override(
			"font_size",
			ACTIVE_SCORE_FONT_SIZE if current_player_number == player_index + 1 else BASE_SCORE_FONT_SIZE
		)

	if _center_score_label:
		if current_player_number <= 0:
			_center_score_label.hide()
		else:
			_center_score_label.show()
			_center_score_label.text = "%02d" % current_score if current_score < 1000 else MPF.util.comma_sep(current_score)


# Selected song playback is paused when rhythm music takes over.
func _on_selected_song_pause_for_rhythm(payload: Dictionary) -> void:
	var audio_path := str(payload.get("audio_path", ""))
	var sound_key := str(payload.get("sound_key", ""))
	if audio_path.is_empty() and sound_key.is_empty():
		return

	var bus_name := str(payload.get("song_bus", "music"))
	var channel = _find_playing_channel(bus_name, sound_key, audio_path)
	var position := float(payload.get("song_start_at", 0.0))

	# If the preview is still active, use its real playback position instead of
	# the configured start offset.
	if channel:
		position = _channel_playback_position(channel, position)

	_store_resume_position(audio_path, sound_key, bus_name, position)


# Rhythm music starts from its configured offset without changing note timing.
func _on_rhythm_music_started(payload: Dictionary) -> void:
	var sound_key := str(payload.get("song_key", ""))
	if sound_key.is_empty() or not MPF.media.sounds.has(sound_key):
		return

	var context := "rhythm_music"

	# Rhythm audio intentionally replaces the selected preview on the music bus;
	# note timing remains controlled by rhythm.py.
	MPF.media.sound.play_sounds({
		"settings": {
			sound_key: {
				"bus": str(payload.get("song_bus", "music")),
				"action": "replace",
				"start_at": maxf(0.0, float(payload.get("song_start_at", 0.0))),
				"key": sound_key,
				"custom_context": context,
			}
		},
		"context": context,
	})


# Replacement audio captures the selected song position before another track takes its bus.
func _on_sound_replacing(bus_name: String, channel, settings: Dictionary) -> void:
	var _unused_settings := settings
	if not channel or not channel.stream or not channel.playing:
		return
	if not channel.stream.has_meta("context") or str(channel.stream.get_meta("context")) != "selected_song_music":
		return

	_store_resume_position(
		str(channel.stream.resource_path),
		str(channel.stream.get_meta("key", "")),
		bus_name,
		_channel_playback_position(channel, 0.0)
	)


func _store_resume_position(audio_path: String, sound_key: String, bus_name: String, position: float) -> void:
	_paused_song = {
		"audio_path": audio_path,
		"sound_key": sound_key,
		"song_bus": bus_name,
		"position": position,
	}

	# Send the captured position back to MPF so rhythm.py can include it in the
	# resume event even if this slide is rebuilt.
	MPF.server.send_event_with_args("selected_song_resume_position_captured", {
		"audio_path": audio_path,
		"sound_key": sound_key,
		"song_bus": bus_name,
		"resume_position": position,
	}, false)


# Selected song playback resumes after rhythm mode ends.
func _on_selected_song_resume_after_rhythm(payload: Dictionary) -> void:
	var audio_path := str(payload.get("audio_path", _paused_song.get("audio_path", "")))
	var sound_key := str(payload.get("sound_key", _paused_song.get("sound_key", "")))
	var bus_name := str(payload.get("song_bus", _paused_song.get("song_bus", "music")))
	var start_at := _resume_position(audio_path, sound_key, payload)
	var context := "selected_song_music"

	if not audio_path.is_empty():
		# Most song select previews use direct res:// file paths.
		if not ResourceLoader.exists(audio_path):
			push_warning("Could not resume selected song path '%s'." % audio_path)
			return

		var bus = MPF.media.sound.get_bus(bus_name)
		for channel in bus.channels:
			if channel.playing:
				channel.stop_with_settings()
		bus.play(audio_path, {
			"bus": bus_name,
			"action": "replace",
			"start_at": start_at,
			"key": sound_key if not sound_key.is_empty() else audio_path,
			"context": context,
			"custom_context": context,
		})
		return

	# Config-defined songs can still resume through MPF sound assets.
	if sound_key.is_empty() or not MPF.media.sounds.has(sound_key):
		return

	MPF.media.sound.play_sounds({
		"settings": {
			sound_key: {
				"bus": bus_name,
				"action": "replace",
				"start_at": start_at,
				"key": sound_key,
				"custom_context": context,
			}
		},
		"context": context,
	})


func _resume_position(audio_path: String, sound_key: String, payload: Dictionary) -> float:
	# Prefer the locally captured position when it matches the requested song;
	# otherwise fall back to the position MPF sent in the resume event.
	if _paused_song.get("audio_path", "") == audio_path or _paused_song.get("sound_key", "") == sound_key:
		return float(_paused_song.get("position", payload.get("song_start_at", 0.0)))
	return float(payload.get("song_start_at", 0.0))


func _channel_playback_position(channel, fallback: float) -> float:
	# The MPF-GMC channel patch exposes latency-adjusted playback when available.
	if channel.has_method("get_playback_position_with_latency"):
		return channel.get_playback_position_with_latency()
	return channel.get_playback_position() if channel else fallback


func _connect_sound_bus_signals() -> void:
	if not MPF.media or not MPF.media.sound:
		return
	var callable := Callable(self, "_on_sound_replacing")
	for bus in MPF.media.sound.buses.values():
		# Guard against reconnecting if the slide is rebuilt.
		if not bus.sound_replacing.is_connected(callable):
			bus.sound_replacing.connect(callable)


func _disconnect_sound_bus_signals() -> void:
	if not MPF.media or not MPF.media.sound:
		return
	var callable := Callable(self, "_on_sound_replacing")
	for bus in MPF.media.sound.buses.values():
		if bus.sound_replacing.is_connected(callable):
			bus.sound_replacing.disconnect(callable)


func _find_playing_channel(bus_name: String, sound_key: String, audio_path: String):
	if not MPF.media.sound.buses.has(bus_name):
		return null

	var bus = MPF.media.sound.get_bus(bus_name)
	for channel in bus.channels:
		if not channel.stream or not channel.playing:
			continue

		# Direct file previews match resource_path; MPF sound assets match key.
		if not audio_path.is_empty() and str(channel.stream.resource_path) == audio_path:
			return channel
		if not sound_key.is_empty() and channel.stream.has_meta("key") and str(channel.stream.get_meta("key")) == sound_key:
			return channel
	return null
