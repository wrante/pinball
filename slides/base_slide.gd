extends MPFSlide

# Base slide listens for rhythm audio events because rhythm mode uses the same
# music bus that song select previews use.
var _handlers := {
	"rhythm_music_started": "_on_rhythm_music_started",
	"selected_song_pause_for_rhythm": "_on_selected_song_pause_for_rhythm",
	"selected_song_resume_after_rhythm": "_on_selected_song_resume_after_rhythm",
}

# Last known selected-song state, captured before rhythm replaces the bus audio.
var _paused_song := {}


func _ready() -> void:
	for event_name in _handlers.keys():
		MPF.server.add_event_handler(event_name, Callable(self, _handlers[event_name]))

	# The selected song can be interrupted by direct bus replacement, so listen
	# to the bus itself in addition to the MPF pause event.
	_connect_sound_bus_signals()


func _exit_tree() -> void:
	for event_name in _handlers.keys():
		MPF.server.remove_event_handler(event_name, Callable(self, _handlers[event_name]))
	_disconnect_sound_bus_signals()


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
