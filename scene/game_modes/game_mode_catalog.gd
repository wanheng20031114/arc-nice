extends Resource
class_name GameModeCatalog

const CATALOG_RESOURCE_PATH := "res://scene/game_modes/game_mode_catalog.tres"

# These values are part of the v54 room/wire contract. Keep every assignment
# explicit so inserting or reordering a lobby item can never renumber a mode.
const MODE_STANDARD := 0
const MODE_TOWER_DEFENSE := 1
const MODE_TEST_ARENA_P1 := 2
const MODE_TEST_ARENA_P2 := 3
const MODE_TEST_ARENA_P3 := 4
const MODE_TEST_ARENA_P1B := 5
const DEFAULT_MODE_ID := MODE_STANDARD
const TOWER_DEFENSE_PRELOAD_PROFILE := &"tower_defense"

const TOWER_DEFENSE_PRELOAD_RESOURCE_PATHS := [
	"res://scene/plant_defense/agave_cannon.tscn",
	"res://scene/plant_defense/agave_cannonball.tscn",
	"res://scene/plant_defense/oak_warehouse.tscn",
	"res://scene/plant_defense/wood_processing_station.tscn",
	"res://scene/plant_defense/stone_mill.tscn",
	"res://scene/plant_defense/excavator.tscn",
	"res://scene/plant_defense/simple_fence.tscn",
	"res://scene/plant_defense/plant_cultivation_center.tscn",
	"res://scene/plant_defense/planting_base.tscn",
	"res://scene/plant_defense/grape_arc_tower.tscn",
	"res://scene/combat/collectibles/collectible_arrow_projectile.tscn",
	"res://scene/combat/collectibles/collectible_sakura_rocket.tscn",
	"res://scene/combat/collectibles/collectible_sakura_explosion.tscn",
	"res://scene/enemy/capoo/capoo_ak47_bullet.tscn",
	"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.tscn",
	"res://scene/enemy/mechanical_life/combat_robot_gunner_elite_bullet.tscn",
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn",
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone_elite.tscn",
	"res://scene/enemy/capoo/capoo_smg_bullet.tscn",
	"res://scene/enemy/capoo/capoo_rpg_rocket.tscn",
	"res://scene/enemy/capoo/capoo_mage_fireball.tscn",
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn",
	"res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn",
	"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.tscn",
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.tscn",
	"res://scene/combat/projectiles/bullet.tscn",
	"res://scene/combat/projectiles/bullet_hit_effect.tscn",
	"res://scene/enemy/enemy_hit_effect.tscn",
	# Keep the former plant registry expansion as pure paths. The order is
	# intentionally identical to the registry's category/menu ordering so this
	# boundary change does not alter the tower-defense loading trace.
	"res://resources/config/plant_defense/agave_cannon.tres",
	"res://resources/config/plant_defense/corn_machine_gun.tres",
	"res://scene/plant_defense/corn_machine_gun.tscn",
	"res://resources/config/plant_defense/bamboo_mortar.tres",
	"res://scene/plant_defense/bamboo_mortar.tscn",
	"res://resources/config/plant_defense/grape_arc_tower.tres",
	"res://resources/config/plant_defense/hydrangea_rain_tower.tres",
	"res://scene/plant_defense/hydrangea_rain_tower.tscn",
	"res://resources/config/plant_defense/orange_charging_tower.tres",
	"res://scene/plant_defense/orange_charging_tower.tscn",
	"res://resources/config/plant_defense/wood_processing_station.tres",
	"res://resources/config/plant_defense/water_collector.tres",
	"res://scene/plant_defense/water_collector.tscn",
	"res://resources/config/plant_defense/planting_base.tres",
	"res://resources/config/plant_defense/plant_cultivation_center.tres",
	"res://resources/config/plant_defense/excavator.tres",
	"res://resources/config/plant_defense/stone_mill.tres",
	"res://resources/config/plant_defense/research_center.tres",
	"res://scene/plant_defense/research_center.tscn",
	"res://resources/config/plant_defense/simple_fence.tres",
	"res://resources/config/plant_defense/vegetation_stake.tres",
	"res://scene/plant_defense/vegetation_stake.tscn",
	"res://resources/config/plant_defense/oak_warehouse.tres",
]

@export var definitions: Array[GameModeDefinition] = []

static var _shared_catalog: GameModeCatalog = null

var _definition_by_id: Dictionary = {}
var _definition_by_wire_key: Dictionary = {}
var _definition_by_singleplayer_entry: Dictionary = {}
var _index_ready := false


static func get_shared() -> GameModeCatalog:
	if _shared_catalog == null:
		_shared_catalog = load(CATALOG_RESOURCE_PATH) as GameModeCatalog
	return _shared_catalog


static func get_definition(mode_id: int) -> GameModeDefinition:
	var catalog := get_shared()
	return catalog.find_definition(mode_id) if catalog != null else null


static func get_definition_by_wire_key(wire_key: String) -> GameModeDefinition:
	var catalog := get_shared()
	return catalog.find_definition_by_wire_key(wire_key) if catalog != null else null


static func get_definition_by_singleplayer_entry(
	scene_path: String
) -> GameModeDefinition:
	var catalog := get_shared()
	return (
		catalog.find_definition_by_singleplayer_entry(scene_path)
		if catalog != null
		else null
	)


static func get_lobby_definitions() -> Array[GameModeDefinition]:
	var catalog := get_shared()
	return catalog.list_lobby_definitions() if catalog != null else []


static func is_valid_mode_id(mode_id: int) -> bool:
	return get_definition(mode_id) != null


static func resolve_wire_key_or_default(wire_key: String) -> int:
	var definition := get_definition_by_wire_key(wire_key)
	return definition.mode_id if definition != null else DEFAULT_MODE_ID


static func get_scene_load_weight(path: String) -> float:
	if path.ends_with("campaign.tres"):
		return 2.0
	var catalog := get_shared()
	if catalog != null:
		for definition in catalog.definitions:
			if definition == null:
				continue
			if path == definition.multiplayer_runtime_scene_path:
				return definition.runtime_load_weight
			if path == definition.multiplayer_entry_scene_path:
				return definition.entry_load_weight
	if path.contains("/player_"):
		return 1.0
	return 1.0


static func get_preload_resource_paths(
	definition: GameModeDefinition
) -> PackedStringArray:
	if (
		definition != null
		and definition.preload_profile == TOWER_DEFENSE_PRELOAD_PROFILE
	):
		return PackedStringArray(TOWER_DEFENSE_PRELOAD_RESOURCE_PATHS)
	return PackedStringArray()


static func validate_catalog() -> PackedStringArray:
	var catalog := get_shared()
	if catalog == null:
		return PackedStringArray(["catalog resource could not be loaded"])
	return catalog.validate_definitions()


func find_definition(mode_id: int) -> GameModeDefinition:
	_ensure_index()
	return _definition_by_id.get(mode_id) as GameModeDefinition


func find_definition_by_wire_key(wire_key: String) -> GameModeDefinition:
	_ensure_index()
	return (
		_definition_by_wire_key.get(wire_key.strip_edges().to_lower())
		as GameModeDefinition
	)


func find_definition_by_singleplayer_entry(
	scene_path: String
) -> GameModeDefinition:
	_ensure_index()
	return (
		_definition_by_singleplayer_entry.get(scene_path.strip_edges())
		as GameModeDefinition
	)


func list_lobby_definitions() -> Array[GameModeDefinition]:
	var result: Array[GameModeDefinition] = []
	for definition in definitions:
		if definition != null:
			result.append(definition)
	result.sort_custom(func(a: GameModeDefinition, b: GameModeDefinition) -> bool:
		return a.lobby_order < b.lobby_order
	)
	return result


func validate_definitions() -> PackedStringArray:
	var errors := PackedStringArray()
	var seen_ids := {}
	var seen_keys := {}
	var seen_orders := {}
	if definitions.size() != 6:
		errors.append("catalog must contain exactly 6 frozen v54 modes")
	for definition in definitions:
		if definition == null:
			errors.append("catalog contains a null definition")
			continue
		errors.append_array(definition.validate_definition())
		var normalized_key := String(definition.wire_key).to_lower()
		if seen_ids.has(definition.mode_id):
			errors.append("duplicate mode id: %d" % definition.mode_id)
		if seen_keys.has(normalized_key):
			errors.append("duplicate wire key: %s" % normalized_key)
		if seen_orders.has(definition.lobby_order):
			errors.append("duplicate lobby order: %d" % definition.lobby_order)
		seen_ids[definition.mode_id] = true
		seen_keys[normalized_key] = true
		seen_orders[definition.lobby_order] = true
		for path in [
			definition.singleplayer_entry_scene_path,
			definition.multiplayer_entry_scene_path,
			definition.multiplayer_runtime_scene_path,
			definition.lobby_icon_path,
		]:
			if not path.is_empty() and not ResourceLoader.exists(path):
				errors.append("mode %d path does not exist: %s" % [
					definition.mode_id,
					path,
				])
		if definition.uses_wave_campaign:
			for campaign_path in [
				definition.singleplayer_campaign_path,
				definition.multiplayer_campaign_path,
			]:
				if not ResourceLoader.exists(campaign_path):
					errors.append("mode %d campaign does not exist: %s" % [
						definition.mode_id,
						campaign_path,
					])
	for expected_mode_id in [
		MODE_STANDARD,
		MODE_TOWER_DEFENSE,
		MODE_TEST_ARENA_P1,
		MODE_TEST_ARENA_P2,
		MODE_TEST_ARENA_P3,
		MODE_TEST_ARENA_P1B,
	]:
		if not seen_ids.has(expected_mode_id):
			errors.append("missing frozen mode id: %d" % expected_mode_id)
	for preload_path in TOWER_DEFENSE_PRELOAD_RESOURCE_PATHS:
		if not ResourceLoader.exists(preload_path):
			errors.append("tower-defense preload path does not exist: %s" % preload_path)
	return errors


func _ensure_index() -> void:
	if _index_ready:
		return
	_definition_by_id.clear()
	_definition_by_wire_key.clear()
	_definition_by_singleplayer_entry.clear()
	for definition in definitions:
		if definition == null:
			continue
		_definition_by_id[definition.mode_id] = definition
		_definition_by_wire_key[String(definition.wire_key).to_lower()] = definition
		_definition_by_singleplayer_entry[
			definition.singleplayer_entry_scene_path
		] = definition
	_index_ready = true
