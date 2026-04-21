extends MPFSlide

const GENRE_COLUMNS := 2
const GENRE_CELL_SIZE := Vector2(540, 58)
const SELECTED_GENRE_COLOR := Color(0.96, 0.73, 0.28, 1)
const DIM_GENRE_COLOR := Color(0.67, 0.76, 0.7, 1)
const HEADER_DIM_COLOR := Color(0.82, 0.88, 0.84, 1)
const SELECTED_GENRE_SIZE := 50
const DIM_GENRE_SIZE := 40
const HEADER_SELECTED_SIZE := 72
const HEADER_DIM_SIZE := 58
const HEADER_GENRE_TEXT := "PICK A GENRE"
const HEADER_SONG_TEXT := "PICK A SONG"
const SONG_CELL_MIN_HEIGHT := 54
const SONG_CELL_FALLBACK_WIDTH := 1128.0
const SONG_ROW_SPACING := 0
const SONG_MAX_LINES := 1
const SELECTED_SONG_CONTEXT := "selected_song_music"
const PREVIEW_ENDED_EVENT := "song_select_preview_ended"
const HIGHLIGHT_WAVE_PIXELS := 4.0
const HIGHLIGHT_WAVE_SECONDS := 0.55

# MPF events are registered manually because this slide is shown by a display
# flow autoload instead of a normal mode slide_player entry.
var _handlers := {
	"song_select_updated": "_on_song_select_updated",
	"song_select_confirmed": "_on_song_select_confirmed",
}

# Used to avoid restarting the preview when the same song is confirmed.
var _playing_song_id := ""
var _preview_channel: GMCChannel = null
var _preview_finished_callable := Callable()
var _header_base_y := 0.0
var _header_wave_tween: Tween = null

@onready var _genre_label: Label = $Panel/Genre
@onready var _genres_grid: GridContainer = $Panel/Genres
@onready var _songs_list: VBoxContainer = $Panel/Songs


# MPF event registration for this slide.
func _ready() -> void:
	_header_base_y = _genre_label.position.y
	for event_name in _handlers.keys():
		MPF.server.add_event_handler(event_name, Callable(self, _handlers[event_name]))


func _exit_tree() -> void:
	_clear_preview_end_watch()
	for event_name in _handlers.keys():
		MPF.server.remove_event_handler(event_name, Callable(self, _handlers[event_name]))


# MPF event handlers that update the visible selection state.
func _on_song_select_updated(payload: Dictionary) -> void:
	var selecting_genre := str(payload.get("stage", "genre")) == "genre"
	_show_selection(payload, selecting_genre)

	# Genre browsing needs the grid rendered; song browsing renders through
	# _show_selection because the selected song list is stage-specific.
	if selecting_genre:
		_render_genres(payload)

	# Both stages can preview audio, including the highlighted header's random song.
	_play_song_from_payload(payload)


func _on_song_select_confirmed(payload: Dictionary) -> void:
	_show_confirmed_song(payload)
	_play_song_from_payload(payload)


# Shared UI state for genre browsing and song browsing.
func _show_selection(payload: Dictionary, selecting_genre: bool) -> void:
	_genre_label.text = HEADER_GENRE_TEXT if selecting_genre else HEADER_SONG_TEXT
	_style_header(bool(payload.get("random_selected", false)))
	_genres_grid.visible = selecting_genre
	_songs_list.visible = not selecting_genre

	# Only one dynamic list is visible at a time, so clear the hidden one to
	# stop old highlight tweens and keep the scene tree small.
	if selecting_genre:
		_clear_songs()
	else:
		_render_songs(payload)


func _show_confirmed_song(_payload: Dictionary) -> void:
	_genre_label.text = HEADER_SONG_TEXT
	_style_header(false)
	_genres_grid.hide()
	_songs_list.show()


func _style_header(selected: bool) -> void:
	_genre_label.add_theme_color_override("font_color", SELECTED_GENRE_COLOR if selected else HEADER_DIM_COLOR)
	_genre_label.add_theme_font_size_override("font_size", HEADER_SELECTED_SIZE if selected else HEADER_DIM_SIZE)
	if selected:
		_start_header_wave()
	else:
		_stop_header_wave()


func _start_header_wave() -> void:
	if _header_wave_tween and _header_wave_tween.is_valid():
		return
	_genre_label.position.y = _header_base_y
	_header_wave_tween = _animate_highlight(_genre_label, _header_base_y)


func _stop_header_wave() -> void:
	if _header_wave_tween:
		_header_wave_tween.kill()
		_header_wave_tween = null
	_genre_label.position.y = _header_base_y


# Genre grid rendering, ordered top-to-bottom and then left-to-right.
func _render_genres(payload: Dictionary) -> void:
	var genres: Array = payload.get("genres", [])
	var selected_index := int(payload.get("selected_genre_index", -1))
	var row_count := int(ceil(float(genres.size()) / float(GENRE_COLUMNS)))
	_genres_grid.columns = GENRE_COLUMNS
	_clear_genres()

	for row in range(row_count):
		for column in range(GENRE_COLUMNS):
			# GridContainer fills rows first, so this index calculation maps the
			# sorted list into columns that read top-to-bottom.
			var index := column * row_count + row
			if index < genres.size():
				_add_genre_label(str(genres[index]), index == selected_index)


func _clear_genres() -> void:
	for child in _genres_grid.get_children():
		_genres_grid.remove_child(child)
		child.queue_free()


func _add_genre_label(genre_name: String, selected: bool) -> void:
	# The fixed cell lets selected text grow and animate without shifting the
	# neighboring genre labels around.
	var cell: Control = Control.new()
	cell.custom_minimum_size = GENRE_CELL_SIZE
	cell.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	cell.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var label: Label = Label.new()
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.text = _display_name(genre_name).to_upper()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", SELECTED_GENRE_COLOR if selected else DIM_GENRE_COLOR)
	label.add_theme_font_size_override("font_size", SELECTED_GENRE_SIZE if selected else DIM_GENRE_SIZE)
	cell.add_child(label)
	_genres_grid.add_child(cell)
	if selected:
		_animate_highlight(label, label.position.y)


# Song list rendering keeps rows fixed so the highlighted song does not shift layout.
func _render_songs(payload: Dictionary) -> void:
	var songs: PackedStringArray = str(payload.get("songs_text", "")).split("\n", false)
	var selected_index: int = maxi(0, int(payload.get("song_index", 1)) - 1)
	_songs_list.add_theme_constant_override("separation", SONG_ROW_SPACING)
	_clear_songs()

	for index in range(songs.size()):
		_add_song_label(str(songs[index]), index == selected_index)


func _clear_songs() -> void:
	for child in _songs_list.get_children():
		_songs_list.remove_child(child)
		child.queue_free()


func _add_song_label(song_name: String, selected: bool) -> void:
	# Song rows expand evenly inside the VBox so every title keeps a predictable
	# slot even when the highlighted font size changes.
	var cell: Control = Control.new()
	cell.custom_minimum_size = Vector2(SONG_CELL_FALLBACK_WIDTH, SONG_CELL_MIN_HEIGHT)
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cell.size_flags_stretch_ratio = 1.0

	var label: Label = Label.new()
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.text = _display_name(song_name)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.clip_text = true
	label.max_lines_visible = SONG_MAX_LINES
	label.add_theme_color_override("font_color", SELECTED_GENRE_COLOR if selected else DIM_GENRE_COLOR)
	label.add_theme_font_size_override("font_size", SELECTED_GENRE_SIZE if selected else DIM_GENRE_SIZE)
	cell.add_child(label)
	_songs_list.add_child(cell)
	if selected:
		_animate_highlight(label, label.position.y)


func _animate_highlight(label: Label, base_y: float) -> Tween:
	# A tiny vertical loop gives the current option life without changing the
	# fixed parent cell size or the layout of the rest of the list.
	var tween: Tween = label.create_tween()
	tween.set_loops()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(label, "position:y", base_y - HIGHLIGHT_WAVE_PIXELS, HIGHLIGHT_WAVE_SECONDS)
	tween.tween_property(label, "position:y", base_y + HIGHLIGHT_WAVE_PIXELS, HIGHLIGHT_WAVE_SECONDS * 2.0)
	tween.tween_property(label, "position:y", base_y, HIGHLIGHT_WAVE_SECONDS)
	return tween


func _display_name(raw_name: String) -> String:
	# macOS folder/file names sometimes use ":" where the player-facing title
	# should show "/".
	return raw_name.replace(":", "/")


# Selected song playback and highlight previews.
func _play_song_from_payload(payload: Dictionary) -> void:
	if not bool(payload.get("has_audio", false)):
		return

	var song_id := _song_id(payload)
	if song_id.is_empty():
		push_warning("Song select did not receive a sound key or audio path.")
		return

	# Repeated MPF update events should refresh the screen without restarting
	# the same preview from the beginning.
	if song_id == _playing_song_id:
		return

	if _play_audio_path(payload, song_id):
		return
	_play_sound_asset(payload, song_id)


func _song_id(payload: Dictionary) -> String:
	var audio_path := str(payload.get("audio_path", ""))
	if not audio_path.is_empty():
		return audio_path
	return str(payload.get("sound_key", ""))


func _play_audio_path(payload: Dictionary, song_id: String) -> bool:
	var audio_path := str(payload.get("audio_path", ""))
	if audio_path.is_empty():
		return false

	# Returning true for a missing direct file prevents a second warning from
	# the MPF sound-asset fallback for the same bad path.
	if not ResourceLoader.exists(audio_path):
		push_warning("Song select could not load audio path '%s'." % audio_path)
		return true

	var bus: GMCBus = MPF.media.sound.get_bus(str(payload.get("song_bus", "music")))

	# Direct stream playback bypasses MPF sound keys, so clear the bus manually
	# before playing the preview.
	_clear_preview_end_watch()
	for channel in bus.channels:
		if channel.playing:
			channel.stop_with_settings()
	bus.play(audio_path, _sound_settings(payload))
	_playing_song_id = song_id
	_watch_preview_end(bus, song_id)
	return true


func _play_sound_asset(payload: Dictionary, song_id: String) -> void:
	var sound_key := str(payload.get("sound_key", ""))
	if not MPF.media.sounds.has(sound_key):
		push_warning("Song select could not find sound asset '%s'." % sound_key)
		return

	var bus: GMCBus = MPF.media.sound.get_bus(str(payload.get("song_bus", "music")))
	_clear_preview_end_watch()
	MPF.media.sound.play_sounds({
		"settings": {
			sound_key: _sound_settings(payload)
		},
		"context": SELECTED_SONG_CONTEXT,
	})
	_playing_song_id = song_id
	_watch_preview_end(bus, song_id)


func _watch_preview_end(bus: GMCBus, song_id: String) -> void:
	# When the current preview naturally ends, MPF advances to the next song in
	# the same genre and posts a fresh song_select_updated payload.
	var channel: GMCChannel = _find_channel_for_song(bus, song_id)
	if not channel:
		return

	_preview_channel = channel
	_preview_finished_callable = Callable(self, "_on_preview_finished").bind(song_id)
	if not channel.finished.is_connected(_preview_finished_callable):
		channel.finished.connect(_preview_finished_callable)


func _clear_preview_end_watch() -> void:
	if _preview_channel and is_instance_valid(_preview_channel) and _preview_finished_callable.is_valid():
		if _preview_channel.finished.is_connected(_preview_finished_callable):
			_preview_channel.finished.disconnect(_preview_finished_callable)
	_preview_channel = null
	_preview_finished_callable = Callable()


func _on_preview_finished(song_id: String) -> void:
	if song_id != _playing_song_id:
		return

	# Clear the id before MPF posts the next song so a single-song genre can
	# restart the same file instead of being treated as already playing.
	_playing_song_id = ""
	_clear_preview_end_watch()
	MPF.server.send_event(PREVIEW_ENDED_EVENT)


func _find_channel_for_song(bus: GMCBus, song_id: String) -> GMCChannel:
	for channel in bus.channels:
		if not channel.stream:
			continue
		if str(channel.stream.resource_path) == song_id:
			return channel
		if channel.stream.has_meta("key") and str(channel.stream.get_meta("key")) == song_id:
			return channel
	return null


func _sound_settings(payload: Dictionary) -> Dictionary:
	var sound_key := str(payload.get("sound_key", ""))
	var audio_path := str(payload.get("audio_path", ""))
	return {
		"bus": str(payload.get("song_bus", "music")),
		"action": "replace",
		"start_at": float(payload.get("song_start_at", 0.0)),
		"key": sound_key if not sound_key.is_empty() else audio_path,
		"context": SELECTED_SONG_CONTEXT,
		"custom_context": SELECTED_SONG_CONTEXT,
	}
