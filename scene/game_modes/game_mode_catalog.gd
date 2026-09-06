extends Resource
class_name GameModeCatalog

const CATALOG_RESOURCE_PATH := "res://scene/game_modes/game_mode_catalog.tres"

# These values remain part of the v62 room/wire contract. Keep every assignment
# explicit so inserting or reordering a lobby item can never renumber a mode.
const MODE_STANDARD := 0
const MODE_TOWER_DEFENSE := 1
const MODE_TEST_ARENA_P1 := 2
const MODE_TEST_ARENA_P2 := 3
const MODE_TEST_ARENA_P3 := 4
const MODE_TEST_ARENA_P1B := 5
const MODE_TEST_ARENA_P1C := 6
const MODE_TEST_ARENA_P1D := 7
const MODE_TEST_ARENA_P1E := 8
const MODE_MIRAGE_PVP := 9
# 肉鸽正式名称与旧 wire ID 解耦；数值 4 和 test_arena_p3 永久兼容。
const MODE_ROGUE := MODE_TEST_ARENA_P3
const DEFAULT_MODE_ID := MODE_STANDARD
const TOWER_DEFENSE_PRELOAD_PROFILE := &"tower_defense"
const FROZEN_MODE_IDS := [
	MODE_STANDARD,
	MODE_TOWER_DEFENSE,
	MODE_TEST_ARENA_P1,
	MODE_TEST_ARENA_P2,
	MODE_TEST_ARENA_P3,
	MODE_TEST_ARENA_P1B,
	MODE_TEST_ARENA_P1C,
	MODE_TEST_ARENA_P1D,
	MODE_TEST_ARENA_P1E,
	MODE_MIRAGE_PVP,
]
const RELEASE_MODE_IDS := [MODE_STANDARD, MODE_TOWER_DEFENSE, MODE_ROGUE, MODE_MIRAGE_PVP]

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
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn",
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone_elite.tscn",
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
	"res://resources/config/plant_defense/life_tower.tres",
	"res://scene/plant_defense/life_tower.tscn",
	"res://resources/config/plant_defense/speed_tower.tres",
	"res://scene/plant_defense/speed_tower.tscn",
	"res://resources/config/plant_defense/attack_speed_tower.tres",
	"res://scene/plant_defense/attack_speed_tower.tscn",
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


static func get_release_lobby_definitions() -> Array[GameModeDefinition]:
	var catalog := get_shared()
	return (
		catalog.list_selectable_definitions(
			GameModeDefinition.SelectionAudience.RELEASE
		)
		if catalog != null
		else []
	)


static func get_development_definitions() -> Array[GameModeDefinition]:
	var catalog := get_shared()
	return (
		catalog.list_selectable_definitions(
			GameModeDefinition.SelectionAudience.DEVELOPMENT
		)
		if catalog != null
		else []
	)


static func is_known_mode_id(mode_id: int) -> bool:
	return get_definition(mode_id) != null


## 正式准入必须调用此接口，不能用“协议认识”代替“允许新建”。
static func is_release_selectable(mode_id: int) -> bool:
	return is_selectable_for_audience(
		mode_id,
		GameModeDefinition.SelectionAudience.RELEASE
	)


## 调试场景和 fixture 必须显式声明开发受众，避免意外接入生产 UI。
static func is_development_selectable(mode_id: int) -> bool:
	return is_selectable_for_audience(
		mode_id,
		GameModeDefinition.SelectionAudience.DEVELOPMENT
	)


## 纯策略查询：调用方必须提供受众，便于在 debug 进程中模拟 release gate。
static func is_selectable_for_audience(
	mode_id: int,
	audience: GameModeDefinition.SelectionAudience
) -> bool:
	var definition := get_definition(mode_id)
	return (
		definition != null
		and definition.is_selectable_for(audience)
	)


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


func list_selectable_definitions(
	audience: GameModeDefinition.SelectionAudience
) -> Array[GameModeDefinition]:
	var result: Array[GameModeDefinition] = []
	for definition in definitions:
		if definition != null and definition.is_selectable_for(audience):
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
	var release_mode_ids: Array[int] = []
	var development_mode_ids: Array[int] = []
	if definitions.size() != FROZEN_MODE_IDS.size():
		errors.append("catalog must contain exactly %d stable modes" % FROZEN_MODE_IDS.size())
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
		if definition.is_selectable_for(
			GameModeDefinition.SelectionAudience.RELEASE
		):
			release_mode_ids.append(definition.mode_id)
		if definition.is_selectable_for(
			GameModeDefinition.SelectionAudience.DEVELOPMENT
		):
			development_mode_ids.append(definition.mode_id)
		if definition.visibility != GameModeDefinition.Visibility.PROTOCOL_ONLY:
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
	for expected_mode_id in FROZEN_MODE_IDS:
		if not seen_ids.has(expected_mode_id):
			errors.append("missing frozen mode id: %d" % expected_mode_id)
	release_mode_ids.sort()
	development_mode_ids.sort()
	if release_mode_ids != RELEASE_MODE_IDS:
		errors.append(
			"release modes must remain Standard/Tower/Rogue/Mirage PVP: %s"
			% [release_mode_ids]
		)
	var expected_development_ids: Array[int] = []
	for expected_mode_id in FROZEN_MODE_IDS:
		expected_development_ids.append(int(expected_mode_id))
	expected_development_ids.sort()
	if development_mode_ids != expected_development_ids:
		errors.append(
			"all authored frozen modes must remain development-selectable: %s"
			% [development_mode_ids]
		)
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
		if definition.supports_singleplayer:
			_definition_by_singleplayer_entry[
				definition.singleplayer_entry_scene_path
			] = definition
	_index_ready = true
