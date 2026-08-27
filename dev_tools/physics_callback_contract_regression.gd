extends SceneTree

const RAPID_PROJECTILE_PRESENTER_SCENE := (
	"res://scene/combat/simulation/rapid_projectile_presenter.tscn"
)
const ROGUE_COMBAT_SCENES: Array[String] = [
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_02.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_03.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_04.tscn",
]

var _errors: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if Node.PHYSICS_INTERPOLATION_MODE_OFF != 2:
		_errors.append("Unexpected Node physics interpolation enum serialization value.")
	if Camera2D.CAMERA2D_PROCESS_PHYSICS != 0:
		_errors.append("Unexpected Camera2D physics callback serialization value.")
	_verify_rapid_projectile_presenter()
	for scene_path in ROGUE_COMBAT_SCENES:
		_verify_rogue_camera(scene_path)
	if _errors.is_empty():
		print("Physics callback contract regression passed.")
		quit(0)
		return
	for message in _errors:
		push_error(message)
	quit(1)


func _verify_rapid_projectile_presenter() -> void:
	var scene_text := _read_scene_text(RAPID_PROJECTILE_PRESENTER_SCENE)
	if scene_text.is_empty():
		return
	var root_section := _node_section(
		scene_text,
		"[node name=\"RapidProjectilePresenter\" type=\"Node2D\"]"
	)
	if not root_section.contains("\nphysics_interpolation_mode = 2\n"):
		_errors.append(
			"RapidProjectilePresenter must disable inherited physics interpolation "
			+ "because it synchronizes MultiMesh transforms from _process()."
		)


func _verify_rogue_camera(scene_path: String) -> void:
	var scene_text := _read_scene_text(scene_path)
	if scene_text.is_empty():
		return
	var camera_section := _node_section(
		scene_text,
		"[node name=\"Camera2D\" type=\"Camera2D\" parent=\".\""
	)
	if camera_section.is_empty():
		_errors.append("%s is missing Camera2D." % scene_path)
	elif not camera_section.contains("\nprocess_callback = 0\n"):
		_errors.append("%s Camera2D must use the physics callback." % scene_path)


func _read_scene_text(scene_path: String) -> String:
	if not FileAccess.file_exists(scene_path):
		_errors.append("Missing scene %s." % scene_path)
		return ""
	return FileAccess.get_file_as_string(scene_path).replace("\r\n", "\n")


func _node_section(scene_text: String, header_prefix: String) -> String:
	var section_start := scene_text.find(header_prefix)
	if section_start < 0:
		return ""
	var section_end := scene_text.find("\n[node ", section_start + header_prefix.length())
	if section_end < 0:
		section_end = scene_text.length()
	return scene_text.substr(section_start, section_end - section_start)
