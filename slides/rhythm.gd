extends MPFSlide

const RHYTHM_STAGE_SCENE := preload("res://slides/rhythm_stage_3d.tscn")
const NOTE_START_SCALE := 0.46
const NOTE_END_SCALE := 1.2
const HOLD_TAIL_MIN_LENGTH := 1.4
const HOLD_TAIL_MAX_LENGTH := 8.4
const HOLD_TAIL_BUTTON_GAP := 0.2

var _notes := {}
var _travel_ms := 1600.0
var _handlers := {
	"rhythm_chart_started": "_on_chart_started",
	"rhythm_hold_started": "_on_hold_started",
	"rhythm_lane_pressed": "_on_lane_pressed",
	"rhythm_note_spawned": "_on_note_spawned",
	"rhythm_note_hit": "_on_note_hit",
	"rhythm_note_missed": "_on_note_missed",
	"rhythm_mode_finished": "_on_mode_finished",
}
var _lane_colors := {
	"left": Color("ff8f3d"),
	"center": Color("ffd84a"),
	"right": Color("45d9ff"),
}
var _feedback_colors := {
	"perfect": Color("ffd84a"),
	"good": Color("8df06c"),
	"miss": Color("ff5577"),
	"press": Color("ffffff"),
}
var _lane_flash_strength := {
	"left": 0.0,
	"center": 0.0,
	"right": 0.0,
}
var _lane_pad_materials := {}
var _lane_surface_materials := {}

var _viewport_container: SubViewportContainer
var _viewport: SubViewport
var _stage_3d: RhythmStage3D

@onready var _playfield: Control = $Playfield
@onready var _feedback_label: Label = $Hud/Feedback
@onready var _summary_label: Label = $Hud/Summary
@onready var _intro_label: Label = $Hud/Intro


func _ready() -> void:
	_feedback_label.modulate.a = 0.0
	_summary_label.hide()
	_setup_3d_playfield()
	for event_name in _handlers.keys():
		MPF.server.add_event_handler(event_name, Callable(self, _handlers[event_name]))


func _exit_tree() -> void:
	for event_name in _handlers.keys():
		MPF.server.remove_event_handler(event_name, Callable(self, _handlers[event_name]))


func _process(delta: float) -> void:
	if not _notes.is_empty():
		var now := Time.get_ticks_msec()
		for note_id in _notes.keys().duplicate():
			var note: Node3D = _notes[note_id]
			var lane: String = str(note.get_meta("lane"))
			var spawn_ms: int = int(note.get_meta("spawn_ms"))
			var travel_ms: float = float(note.get_meta("travel_ms"))
			if bool(note.get_meta("holding")):
				note.position = _note_position(lane, 1.0)
				note.scale = Vector3.ONE * NOTE_END_SCALE
				note.rotation.y = 0.0
				_update_hold_tail(note, now)
			else:
				var progress: float = clampf(float(now - spawn_ms) / travel_ms, 0.0, 1.15)
				var visible_progress := clampf(progress, 0.0, 1.0)
				note.position = _note_position(lane, progress)
				note.scale = Vector3.ONE * lerpf(NOTE_START_SCALE, NOTE_END_SCALE, visible_progress)
				note.rotation.y = deg_to_rad(sin(visible_progress * PI) * 7.0)

	_update_lane_visuals(delta)


func _on_chart_started(payload: Dictionary) -> void:
	_travel_ms = float(payload.get("travel_ms", _travel_ms))
	_summary_label.hide()
	_intro_label.modulate.a = 1.0
	_intro_label.text = "Tap the beats and hold the long notes"
	var tween := create_tween()
	tween.tween_interval(1.2)
	tween.tween_property(_intro_label, "modulate:a", 0.18, 0.4)


func _on_lane_pressed(payload: Dictionary) -> void:
	_pulse_lane(str(payload.get("lane", "")), _feedback_colors.press, 0.22)


func _on_hold_started(payload: Dictionary) -> void:
	var note_id: int = int(payload.get("note_id", -1))
	if not _notes.has(note_id):
		return

	var note: Node3D = _notes[note_id]
	var duration_ms := maxf(float(note.get_meta("duration_ms", 0.0)), 1.0)
	var remaining_ms := maxf(float(payload.get("remaining_ms", duration_ms)), 0.0)
	var lane: String = str(payload.get("lane", note.get_meta("lane", "left")))
	var judgment: String = str(payload.get("judgment", "good"))

	note.set_meta("holding", true)
	note.set_meta("hold_end_local_ms", Time.get_ticks_msec() + int(remaining_ms))
	note.set_meta("hold_duration_ms", duration_ms)
	_set_hold_tail_ratio(note, clampf(remaining_ms / duration_ms, 0.0, 1.0))

	var feedback_color: Color = _feedback_colors.get(judgment, _feedback_colors.good)
	_pulse_lane(lane, feedback_color, 0.28)
	_show_feedback("HOLD", feedback_color)


func _on_note_spawned(payload: Dictionary) -> void:
	var lane: String = str(payload.get("lane", "left"))
	var note_id: int = int(payload.get("note_id", -1))
	var duration_ms := maxf(float(payload.get("duration_ms", 0.0)), 0.0)
	var note := _create_button_note(lane, note_id, duration_ms)
	note.set_meta("lane", lane)
	note.set_meta("spawn_ms", Time.get_ticks_msec())
	note.set_meta("travel_ms", float(payload.get("travel_ms", _travel_ms)))
	note.set_meta("duration_ms", duration_ms)
	note.set_meta("holding", false)
	_stage_3d.add_note(note)
	_notes[note_id] = note


func _on_note_hit(payload: Dictionary) -> void:
	var lane: String = str(payload.get("lane", "left"))
	var judgment: String = str(payload.get("judgment", "good"))
	var combo: int = int(payload.get("combo", 0))
	_remove_note(int(payload.get("note_id", -1)), true)
	_pulse_lane(lane, _feedback_colors.get(judgment, _feedback_colors.good), 0.28)
	_show_feedback("%s x%d" % [judgment.to_upper(), combo], _feedback_colors.get(judgment, _feedback_colors.good))


func _on_note_missed(payload: Dictionary) -> void:
	var lane: String = str(payload.get("lane", "left"))
	_remove_note(int(payload.get("note_id", -1)), false)
	_pulse_lane(lane, _feedback_colors.miss, 0.3)
	_show_feedback("MISS", _feedback_colors.miss)


func _on_mode_finished(payload: Dictionary) -> void:
	for note_id in _notes.keys().duplicate():
		_remove_note(note_id, false)
	_summary_label.text = "Set complete\n%d / %d hit\nBest combo %d\n%d%% accuracy" % [
		int(payload.get("hits", 0)),
		int(payload.get("total_notes", 0)),
		int(payload.get("best_combo", 0)),
		int(payload.get("accuracy", 0)),
	]
	_summary_label.show()
	_summary_label.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(_summary_label, "modulate:a", 1.0, 0.25)
	_show_feedback("JAM COMPLETE", Color("fff3a6"))


func _remove_note(note_id: int, is_hit: bool) -> void:
	if not _notes.has(note_id):
		return
	var note: Node3D = _notes[note_id]
	_notes.erase(note_id)
	var tween := create_tween()
	if is_hit:
		tween.tween_property(note, "scale", note.scale * 1.18, 0.08)
		tween.parallel().tween_property(note, "position:y", note.position.y + 0.32, 0.12)
	else:
		tween.tween_property(note, "position:y", note.position.y - 0.18, 0.12)
		tween.parallel().tween_property(note, "scale", note.scale * 0.92, 0.12)
	tween.finished.connect(note.queue_free)


func _show_feedback(text: String, color: Color) -> void:
	_feedback_label.text = text
	var modulate_color := color
	modulate_color.a = 1.0
	_feedback_label.modulate = modulate_color
	_feedback_label.scale = Vector2.ONE * 0.92
	var tween := create_tween()
	tween.tween_property(_feedback_label, "scale", Vector2.ONE, 0.08)
	tween.parallel().tween_property(_feedback_label, "modulate:a", 0.0, 0.45)


func _pulse_lane(lane: String, color: Color, fade_time: float) -> void:
	# The fade is handled in _update_lane_visuals(); this just kicks the glow.
	var _unused_fade_time := fade_time
	var _unused_color := color
	if lane not in _lane_flash_strength:
		return
	_lane_flash_strength[lane] = 1.0


func _setup_3d_playfield() -> void:
	_viewport_container = SubViewportContainer.new()
	_viewport_container.name = "Viewport3D"
	_viewport_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport_container.stretch = true
	_playfield.add_child(_viewport_container)
	_playfield.move_child(_viewport_container, 0)

	_viewport = SubViewport.new()
	_viewport.name = "RhythmViewport"
	_viewport.size = Vector2i(int(_playfield.size.x), int(_playfield.size.y))
	_viewport.transparent_bg = true
	_viewport.handle_input_locally = false
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport_container.add_child(_viewport)

	_stage_3d = RHYTHM_STAGE_SCENE.instantiate() as RhythmStage3D
	_viewport.add_child(_stage_3d)
	_capture_stage_materials()


func _create_button_note(lane: String, note_id: int, duration_ms: float = 0.0) -> Node3D:
	var lane_color: Color = _lane_colors.get(lane, Color.WHITE)
	var note_root := Node3D.new()
	note_root.name = "Note%d" % note_id
	note_root.position = _note_position(lane, 0.0)

	if duration_ms > 0.0:
		_attach_hold_tail(note_root, lane_color, duration_ms)

	var button_shadow := MeshInstance3D.new()
	var button_shadow_mesh := CylinderMesh.new()
	button_shadow_mesh.top_radius = 0.68
	button_shadow_mesh.bottom_radius = 0.8
	button_shadow_mesh.height = 0.06
	button_shadow.mesh = button_shadow_mesh
	button_shadow.position = Vector3(0.0, 0.02, 0.0)
	button_shadow.material_override = _make_material(lane_color.darkened(0.62), 0.02, 0.95, 0.0)
	note_root.add_child(button_shadow)

	var button_base := MeshInstance3D.new()
	var button_base_mesh := CylinderMesh.new()
	button_base_mesh.top_radius = 0.5
	button_base_mesh.bottom_radius = 0.58
	button_base_mesh.height = 0.24
	button_base.mesh = button_base_mesh
	button_base.position = Vector3(0.0, 0.15, 0.0)
	button_base.material_override = _make_material(lane_color.darkened(0.45), 0.18, 0.48, 0.05)
	note_root.add_child(button_base)

	var button_cap := MeshInstance3D.new()
	var button_cap_mesh := CylinderMesh.new()
	button_cap_mesh.top_radius = 0.68
	button_cap_mesh.bottom_radius = 0.62
	button_cap_mesh.height = 0.26
	button_cap.mesh = button_cap_mesh
	button_cap.position = Vector3(0.0, 0.34, 0.0)
	button_cap.material_override = _make_material(lane_color.lightened(0.06), 0.08, 0.1, 0.6)
	note_root.add_child(button_cap)

	var button_highlight := MeshInstance3D.new()
	var button_highlight_mesh := SphereMesh.new()
	button_highlight_mesh.radius = 0.22
	button_highlight_mesh.height = 0.44
	button_highlight.mesh = button_highlight_mesh
	button_highlight.scale = Vector3(1.8, 0.42, 1.25)
	button_highlight.position = Vector3(-0.12, 0.44, -0.08)
	button_highlight.material_override = _make_highlight_material()
	note_root.add_child(button_highlight)

	return note_root


func _note_position(lane: String, progress: float) -> Vector3:
	return _stage_3d.note_position(lane, progress)


func _attach_hold_tail(note_root: Node3D, lane_color: Color, duration_ms: float) -> void:
	var tail_length := clampf((duration_ms / maxf(_travel_ms, 1.0)) * 6.4, HOLD_TAIL_MIN_LENGTH, HOLD_TAIL_MAX_LENGTH)
	note_root.set_meta("hold_tail_length", tail_length)

	var tail_root := Node3D.new()
	tail_root.name = "HoldTail"
	note_root.add_child(tail_root)

	var tail_shadow := MeshInstance3D.new()
	var tail_shadow_mesh := BoxMesh.new()
	tail_shadow_mesh.size = Vector3(0.44, 0.05, tail_length)
	tail_shadow.mesh = tail_shadow_mesh
	tail_shadow.position = Vector3(0.0, 0.06, -HOLD_TAIL_BUTTON_GAP - (tail_length * 0.5))
	tail_shadow.material_override = _make_material(lane_color.darkened(0.62), 0.02, 0.92, 0.0)
	tail_shadow.set_meta("base_length", tail_length)
	tail_root.add_child(tail_shadow)

	var tail_body := MeshInstance3D.new()
	var tail_body_mesh := BoxMesh.new()
	tail_body_mesh.size = Vector3(0.36, 0.16, tail_length)
	tail_body.mesh = tail_body_mesh
	tail_body.position = Vector3(0.0, 0.18, -HOLD_TAIL_BUTTON_GAP - (tail_length * 0.5))
	tail_body.material_override = _make_material(lane_color.darkened(0.22), 0.1, 0.3, 0.16)
	tail_body.set_meta("base_length", tail_length)
	tail_root.add_child(tail_body)

	var glow_length := maxf(tail_length - 0.18, 0.32)
	var tail_glow := MeshInstance3D.new()
	var tail_glow_mesh := BoxMesh.new()
	tail_glow_mesh.size = Vector3(0.18, 0.06, glow_length)
	tail_glow.mesh = tail_glow_mesh
	tail_glow.position = Vector3(0.0, 0.28, -HOLD_TAIL_BUTTON_GAP - (glow_length * 0.5))
	tail_glow.material_override = _make_glow_material(lane_color, 0.34)
	tail_glow.set_meta("base_length", glow_length)
	tail_root.add_child(tail_glow)


func _update_hold_tail(note: Node3D, now_ms: int) -> void:
	var duration_ms := maxf(float(note.get_meta("hold_duration_ms", note.get_meta("duration_ms", 0.0))), 1.0)
	var hold_end_local_ms := float(note.get_meta("hold_end_local_ms", now_ms))
	var ratio := clampf((hold_end_local_ms - float(now_ms)) / duration_ms, 0.0, 1.0)
	_set_hold_tail_ratio(note, ratio)


func _set_hold_tail_ratio(note: Node3D, ratio: float) -> void:
	var hold_tail := note.get_node_or_null("HoldTail")
	if hold_tail == null:
		return

	var clamped_ratio := clampf(ratio, 0.0, 1.0)
	for child in hold_tail.get_children():
		var mesh := child as MeshInstance3D
		if mesh == null:
			continue

		var base_length := float(mesh.get_meta("base_length", 0.0))
		var visible_ratio := maxf(clamped_ratio, 0.025)
		mesh.visible = clamped_ratio > 0.01
		mesh.scale.z = visible_ratio
		mesh.position.z = -HOLD_TAIL_BUTTON_GAP - ((base_length * visible_ratio) * 0.5)


func _capture_stage_materials() -> void:
	for lane in _lane_flash_strength.keys():
		_lane_surface_materials[lane] = _stage_3d.lane_surface_material(lane)
		_lane_pad_materials[lane] = _stage_3d.lane_pad_material(lane)


func _update_lane_visuals(delta: float) -> void:
	for lane in _lane_flash_strength.keys():
		var strength: float = maxf(0.0, float(_lane_flash_strength[lane]) - (delta * 3.2))
		_lane_flash_strength[lane] = strength
		var lane_color: Color = _lane_colors.get(lane, Color.WHITE)

		var surface_material: StandardMaterial3D = _lane_surface_materials.get(lane)
		if surface_material:
			surface_material.albedo_color = lane_color.darkened(0.34).lerp(lane_color.lightened(0.06), strength * 0.18)
			surface_material.emission = lane_color
			surface_material.emission_energy_multiplier = 0.08 + (strength * 0.38)

		var pad_material: StandardMaterial3D = _lane_pad_materials.get(lane)
		if pad_material:
			pad_material.albedo_color = lane_color.lightened(0.05).lerp(Color.WHITE, strength * 0.22)
			pad_material.emission = lane_color.lerp(Color.WHITE, strength * 0.55)
			pad_material.emission_energy_multiplier = 0.55 + (strength * 2.1)


func _make_material(albedo: Color, metallic: float, roughness: float, emission_strength: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = albedo
	material.metallic = metallic
	material.roughness = roughness
	material.emission_enabled = emission_strength > 0.0
	material.emission = albedo.lightened(0.08)
	material.emission_energy_multiplier = emission_strength
	return material


func _make_glow_material(color: Color, emission_strength: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(color.r, color.g, color.b, 0.38)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = emission_strength
	return material


func _make_highlight_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 1.0, 1.0, 0.32)
	return material
