@tool
class_name RhythmStage3D
extends Node3D

const _LANE_NAMES := {
	"left": "LeftLane",
	"center": "CenterLane",
	"right": "RightLane",
}

func _ready() -> void:
	_update_camera()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		_update_camera()


func add_note(note: Node3D) -> void:
	var notes_root := get_node_or_null("Notes") as Node3D
	if notes_root:
		notes_root.add_child(note)
	else:
		add_child(note)


func note_position(lane: String, progress: float) -> Vector3:
	var start_marker := get_node_or_null("NotePathStart") as Marker3D
	var end_marker := get_node_or_null("NotePathEnd") as Marker3D
	if start_marker == null or end_marker == null:
		return Vector3.ZERO
	var lane_root := _lane_root(lane)
	var lane_origin := lane_root.position if lane_root else Vector3.ZERO
	var weight := clampf(progress, 0.0, 1.15)
	var start := start_marker.position
	var end := end_marker.position
	return lane_origin + Vector3(
		lerpf(start.x, end.x, weight),
		lerpf(start.y, end.y, weight),
		lerpf(start.z, end.z, weight)
	)


func lane_surface_material(lane: String) -> StandardMaterial3D:
	return _mesh_material("Lanes/%s/Surface" % _lane_name(lane))


func lane_pad_material(lane: String) -> StandardMaterial3D:
	return _mesh_material("Lanes/%s/HitPad" % _lane_name(lane))


func _update_camera() -> void:
	var camera := get_node_or_null("Camera3D") as Camera3D
	var camera_target := get_node_or_null("CameraTarget") as Marker3D
	if camera and camera_target:
		camera.look_at(camera_target.global_position, Vector3.UP)


func _lane_root(lane: String) -> Node3D:
	return get_node_or_null("Lanes/%s" % _lane_name(lane)) as Node3D


func _lane_name(lane: String) -> String:
	return str(_LANE_NAMES.get(lane, "CenterLane"))


func _mesh_material(path: String) -> StandardMaterial3D:
	var mesh := get_node_or_null(path) as MeshInstance3D
	if mesh == null:
		return null
	return mesh.material_override as StandardMaterial3D
