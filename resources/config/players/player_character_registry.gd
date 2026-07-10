extends RefCounted
class_name PlayerCharacterRegistry

const WEISHIDAIER_ID: StringName = &"weishidaier"
const HOE_CAT_ID: StringName = &"hoe_cat"
const DEFAULT_CHARACTER_ID: StringName = WEISHIDAIER_ID

const WEISHIDAIER_CONFIG: PlayerCharacterConfig = preload(
	"res://resources/config/players/player_weishidaier.tres"
)
const HOE_CAT_CONFIG: PlayerCharacterConfig = preload(
	"res://resources/config/players/player_hoe_cat.tres"
)

const CHARACTER_CONFIGS := {
	WEISHIDAIER_ID: WEISHIDAIER_CONFIG,
	HOE_CAT_ID: HOE_CAT_CONFIG,
}


static func get_config(character_id: StringName) -> PlayerCharacterConfig:
	return CHARACTER_CONFIGS.get(character_id) as PlayerCharacterConfig


static func get_all_configs() -> Array[PlayerCharacterConfig]:
	return [WEISHIDAIER_CONFIG, HOE_CAT_CONFIG]


static func get_default_character_id() -> StringName:
	return DEFAULT_CHARACTER_ID


static func is_valid_character_id(character_id: StringName) -> bool:
	var config := get_config(character_id)
	return config != null and config.is_valid()


static func instantiate_character(character_id: StringName) -> Player:
	var config := get_config(character_id)
	if config == null:
		push_error("Unknown player character id: %s" % character_id)
		return null
	if not ResourceLoader.exists(config.player_scene, "PackedScene"):
		push_error("Player character scene does not exist: %s" % config.player_scene)
		return null

	var packed_scene := load(config.player_scene) as PackedScene
	if packed_scene == null:
		push_error("Player character scene could not be loaded: %s" % config.player_scene)
		return null
	var instance := packed_scene.instantiate()
	var player := instance as Player
	if player == null:
		push_error("Player character scene root must inherit Player: %s" % config.player_scene)
		instance.free()
	return player
