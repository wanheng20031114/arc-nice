extends SceneTree

const COORDINATOR_SOURCE_PATH := "res://scene/loading/game_load_coordinator.gd"
const TOWER_MODE_IDS := [1, 2, 5, 3]
const STANDARD_MODE_ID := 0
const ROGUE_MODE_ID := 4
const AGAVE_CANNONBALL_PATH := (
	"res://scene/plant_defense/agave_cannonball.tscn"
)
const TOWER_PRELOAD_PATHS := [
	"res://scene/plant_defense/agave_cannon.tscn",
	AGAVE_CANNONBALL_PATH,
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
]
const RETIRED_ENEMY_PROJECTILE_PRELOAD_PATHS := [
	"res://scene/enemy/capoo/capoo_ak47_bullet.tscn",
	"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.tscn",
	"res://scene/enemy/mechanical_life/combat_robot_gunner_elite_bullet.tscn",
	"res://scene/enemy/capoo/capoo_smg_bullet.tscn",
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn",
	"res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn",
	"res://scene/enemy/capoo/capoo_mage_fireball.tscn",
	"res://scene/enemy/capoo/capoo_mage_fireball_impact.tscn",
]
const SORTED_PLANT_IDS := [
	"agave_cannon",
	"corn_machine_gun",
	"bamboo_mortar",
	"grape_arc_tower",
	"hydrangea_rain_tower",
	"orange_charging_tower",
	"life_tower",
	"speed_tower",
	"attack_speed_tower",
	"wood_processing_station",
	"water_collector",
	"planting_base",
	"plant_cultivation_center",
	"excavator",
	"stone_mill",
	"research_center",
	"simple_fence",
	"vegetation_stake",
	"oak_warehouse",
]
const EAGER_CACHE_SENTINELS := [
	"res://resources/config/plant_defense/agave_cannon.tres",
	"res://scene/plant_defense/agave_cannon.tscn",
	AGAVE_CANNONBALL_PATH,
]

var failures := PackedStringArray()


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_no_eager_tower_plant_cache()
	_test_coordinator_source_boundary()
	var expected_profile := _build_expected_tower_profile()
	_test_catalog_profiles(expected_profile)
	_test_loading_manifests(expected_profile)
	_test_no_eager_tower_plant_cache()
	_finish()


func _test_no_eager_tower_plant_cache() -> void:
	for path in EAGER_CACHE_SENTINELS:
		_expect(
			not ResourceLoader.has_cached(path),
			"Project startup must not cache tower plant resource: %s" % path
		)


func _test_coordinator_source_boundary() -> void:
	var source := FileAccess.get_file_as_string(COORDINATOR_SOURCE_PATH)
	_expect(not source.is_empty(), "GameLoadCoordinator source must be readable.")
	_expect(
		not source.contains("PlantDefenseRegistry"),
		"GameLoadCoordinator must not depend on PlantDefenseRegistry."
	)
	_expect(
		source.contains("GameModeCatalog.get_preload_resource_paths(definition)"),
		"GameLoadCoordinator must consume the mode catalog preload profile."
	)


func _test_catalog_profiles(expected_profile: Array[String]) -> void:
	for mode_id in [STANDARD_MODE_ID, ROGUE_MODE_ID]:
		var definition := GameModeCatalog.get_definition(mode_id)
		_expect(definition != null, "Missing mode definition %d." % mode_id)
		if definition != null:
			_expect(
				GameModeCatalog.get_preload_resource_paths(definition).is_empty(),
				"Mode %d must not receive tower-defense preload resources." % mode_id
			)

	for mode_id in TOWER_MODE_IDS:
		var definition := GameModeCatalog.get_definition(mode_id)
		_expect(definition != null, "Missing tower-family mode %d." % mode_id)
		if definition == null:
			continue
		var actual_profile := Array(
			GameModeCatalog.get_preload_resource_paths(definition)
		)
		_expect(
			actual_profile == expected_profile,
			"Mode %d tower preload profile order/content changed." % mode_id
		)
		_expect(
			actual_profile.size() == _unique_count(actual_profile),
			"Mode %d tower preload profile contains duplicates." % mode_id
		)
		_expect_retired_projectiles_absent(
			actual_profile,
			"mode %d preload profile" % mode_id
		)


func _test_loading_manifests(expected_profile: Array[String]) -> void:
	var coordinator := get_root().get_node_or_null("GameLoadCoordinator")
	_expect(coordinator != null, "GameLoadCoordinator autoload must exist.")
	if coordinator == null:
		return

	for mode_id in [STANDARD_MODE_ID, ROGUE_MODE_ID]:
		var definition := GameModeCatalog.get_definition(mode_id)
		if definition == null:
			continue
		var manifest := coordinator.call(
			"_build_singleplayer_manifest",
			definition.singleplayer_entry_scene_path
		) as Array
		_expect_no_tower_plants(manifest, "single-player mode %d" % mode_id)

	var net_manager := get_root().get_node_or_null("NetManager") as NetManagerStore
	_expect(
		net_manager != null,
		"NetManager autoload must satisfy the typed multiplayer manifest boundary."
	)
	if net_manager == null:
		return
	for mode_id in TOWER_MODE_IDS:
		var definition := GameModeCatalog.get_definition(mode_id)
		if definition == null:
			continue
		var singleplayer_manifest := coordinator.call(
			"_build_singleplayer_manifest",
			definition.singleplayer_entry_scene_path
		) as Array
		_expect_profile_once_in_order(
			singleplayer_manifest,
			expected_profile,
			"single-player mode %d" % mode_id
		)
		var multiplayer_manifest := coordinator.call(
			"_build_multiplayer_manifest",
			mode_id,
			net_manager
		) as Array
		_expect_profile_once_in_order(
			multiplayer_manifest,
			expected_profile,
			"multiplayer mode %d" % mode_id
		)
		_expect_retired_projectiles_absent(
			singleplayer_manifest,
			"single-player mode %d manifest" % mode_id
		)
		_expect_retired_projectiles_absent(
			multiplayer_manifest,
			"multiplayer mode %d manifest" % mode_id
		)


func _build_expected_tower_profile() -> Array[String]:
	var result: Array[String] = []
	for path_variant in TOWER_PRELOAD_PATHS:
		result.append(str(path_variant))
	for plant_id_variant in SORTED_PLANT_IDS:
		var plant_id := str(plant_id_variant)
		var config_path := (
			"res://resources/config/plant_defense/%s.tres" % plant_id
		)
		var scene_path := "res://scene/plant_defense/%s.tscn" % plant_id
		if not result.has(config_path):
			result.append(config_path)
		if not result.has(scene_path):
			result.append(scene_path)
	return result


func _expect_no_tower_plants(manifest: Array, label: String) -> void:
	for plant_id_variant in SORTED_PLANT_IDS:
		var plant_id := str(plant_id_variant)
		for path in [
			"res://resources/config/plant_defense/%s.tres" % plant_id,
			"res://scene/plant_defense/%s.tscn" % plant_id,
		]:
			_expect(
				not manifest.has(path),
				"%s must not include tower plant resource: %s" % [label, path]
			)
	_expect(
		not manifest.has(AGAVE_CANNONBALL_PATH),
		"%s must not include the agave cannonball." % label
	)


func _expect_profile_once_in_order(
	manifest: Array,
	expected_profile: Array[String],
	label: String
) -> void:
	var previous_index := -1
	for path in expected_profile:
		var path_index := manifest.find(path)
		_expect(path_index >= 0, "%s is missing preload path: %s" % [label, path])
		_expect(
			manifest.count(path) == 1,
			"%s must contain preload path exactly once: %s" % [label, path]
		)
		_expect(
			path_index > previous_index,
			"%s changed tower preload ordering at: %s" % [label, path]
		)
		previous_index = path_index


func _expect_retired_projectiles_absent(paths: Array, label: String) -> void:
	for retired_path in RETIRED_ENEMY_PROJECTILE_PRELOAD_PATHS:
		_expect(
			not paths.has(retired_path),
			"%s must not preload retired enemy projectile: %s"
			% [label, retired_path]
		)


func _unique_count(values: Array) -> int:
	var seen := {}
	for value in values:
		seen[value] = true
	return seen.size()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("GAME_MODE_PRELOAD_BOUNDARY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
