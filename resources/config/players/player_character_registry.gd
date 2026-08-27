extends RefCounted
class_name PlayerCharacterRegistry

const WEISHIDAIER_ID: StringName = &"weishidaier"
const HOE_CAT_ID: StringName = &"hoe_cat"
const TIYI_ID: StringName = &"tiyi"
const TANGO_ID: StringName = &"tango"
const VEHICLE_ID: StringName = &"vehicle"
const DEFAULT_CHARACTER_ID: StringName = WEISHIDAIER_ID

const WEISHIDAIER_CONFIG: PlayerCharacterConfig = preload(
	"res://resources/config/players/player_weishidaier.tres"
)
const HOE_CAT_CONFIG: PlayerCharacterConfig = preload(
	"res://resources/config/players/player_hoe_cat.tres"
)
const TIYI_CONFIG: PlayerCharacterConfig = preload(
	"res://resources/config/players/player_tiyi.tres"
)
const TANGO_CONFIG: PlayerCharacterConfig = preload(
	"res://resources/config/players/player_tango.tres"
)
const VEHICLE_CONFIG: PlayerCharacterConfig = preload(
	"res://resources/config/players/player_vehicle.tres"
)

const CHARACTER_CONFIGS := {
	WEISHIDAIER_ID: WEISHIDAIER_CONFIG,
	HOE_CAT_ID: HOE_CAT_CONFIG,
	TIYI_ID: TIYI_CONFIG,
	TANGO_ID: TANGO_CONFIG,
	VEHICLE_ID: VEHICLE_CONFIG,
}


static func get_config(character_id: StringName) -> PlayerCharacterConfig:
	return CHARACTER_CONFIGS.get(character_id) as PlayerCharacterConfig


static func get_all_configs() -> Array[PlayerCharacterConfig]:
	return [
		WEISHIDAIER_CONFIG,
		HOE_CAT_CONFIG,
		TIYI_CONFIG,
		TANGO_CONFIG,
		VEHICLE_CONFIG,
	]


static func get_character_menu_configs() -> Array[PlayerCharacterConfig]:
	var result: Array[PlayerCharacterConfig] = []
	for config in get_all_configs():
		if config != null and config.is_valid() and config.selectable_in_character_menu:
			result.append(config)
	return result


static func get_multiplayer_configs() -> Array[PlayerCharacterConfig]:
	var result: Array[PlayerCharacterConfig] = []
	for config in get_all_configs():
		if config != null and config.is_valid() and config.supports_multiplayer:
			result.append(config)
	return result


static func get_default_character_id() -> StringName:
	return DEFAULT_CHARACTER_ID


static func is_valid_character_id(character_id: StringName) -> bool:
	var config := get_config(character_id)
	return config != null and config.is_valid()


static func is_character_menu_selectable(character_id: StringName) -> bool:
	var config := get_config(character_id)
	return (
		config != null
		and config.is_valid()
		and config.selectable_in_character_menu
	)


static func is_multiplayer_character_id(character_id: StringName) -> bool:
	var config := get_config(character_id)
	return config != null and config.is_valid() and config.supports_multiplayer


static func supports_ammunition_reward(character_id: StringName) -> bool:
	var config := get_config(character_id)
	return config != null and config.supports_ammunition


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
