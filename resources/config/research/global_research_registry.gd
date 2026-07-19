extends RefCounted
class_name GlobalResearchRegistry

const BUILDING_DEFENSE_ID: StringName = &"building_defense"
const PLAYER_MOVE_SPEED_ID: StringName = &"player_move_speed"
const MAX_WIRE_RESEARCH_ID_LENGTH := 64

const BUILDING_DEFENSE: GlobalResearchConfig = preload(
	"res://resources/config/research/building_defense.tres"
)
const PLAYER_MOVE_SPEED: GlobalResearchConfig = preload(
	"res://resources/config/research/player_move_speed.tres"
)

const RESEARCH_PROJECTS := {
	BUILDING_DEFENSE_ID: BUILDING_DEFENSE,
	PLAYER_MOVE_SPEED_ID: PLAYER_MOVE_SPEED,
}


static func get_config(research_id: StringName) -> GlobalResearchConfig:
	var config := RESEARCH_PROJECTS.get(research_id) as GlobalResearchConfig
	return (
		config
		if (
			config != null
			and config.research_id == research_id
			and config.is_valid()
		)
		else null
	)


static func get_config_by_wire_id(research_id: String) -> GlobalResearchConfig:
	if research_id.is_empty() or research_id.length() > MAX_WIRE_RESEARCH_ID_LENGTH:
		return null
	for registered_id_variant in RESEARCH_PROJECTS:
		var registered_id := registered_id_variant as StringName
		if String(registered_id) == research_id:
			return get_config(registered_id)
	return null


static func get_all_configs() -> Array[GlobalResearchConfig]:
	var configs: Array[GlobalResearchConfig] = []
	for research_id in [BUILDING_DEFENSE_ID, PLAYER_MOVE_SPEED_ID]:
		var config := get_config(research_id)
		if config != null:
			configs.append(config)
	return configs
