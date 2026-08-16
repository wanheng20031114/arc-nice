extends SceneTree

const CATALOG_PATH := "res://scene/game_modes/game_mode_catalog.tres"
const EXPECTED_MODE_IDS := [0, 1, 2, 3, 4, 5, 6, 7, 8]
const EXPECTED_WIRE_KEYS := [
	"standard",
	"tower_defense",
	"test_arena_p1",
	"test_arena_p2",
	"test_arena_p3",
	"test_arena_p1b",
	"test_arena_p1c",
	"test_arena_p1d",
	"test_arena_p1e",
]
const EXPECTED_RELEASE_ORDER := [0, 1, 4]
const EXPECTED_DEVELOPMENT_ORDER := [0, 1, 2, 5, 6, 7, 8, 3, 4]

var failures := PackedStringArray()


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var heavyweight_paths := PackedStringArray([
		"res://scene/game_modes/standard/standard_game.tscn",
		"res://scene/game_modes/tower_defense/tower_defense_game.tscn",
		"res://scene/game_modes/rogue/route/rogue_route_game.tscn",
		"res://resources/config/campaigns/tower_defense/singleplayer/campaign.tres",
	])
	var cached_before := {}
	for path in heavyweight_paths:
		cached_before[path] = ResourceLoader.has_cached(path)

	var catalog := load(CATALOG_PATH) as GameModeCatalog
	_expect(catalog != null, "GameModeCatalog resource must load.")
	if catalog == null:
		_finish()
		return
	_expect(GameModeCatalog.validate_catalog().is_empty(), (
		"GameModeCatalog validation failed: %s"
		% [GameModeCatalog.validate_catalog()]
	))
	for path in heavyweight_paths:
		_expect(
			ResourceLoader.has_cached(path) == bool(cached_before[path]),
			"Loading the catalog must not load heavyweight resource: %s" % path
		)

	for index in range(EXPECTED_MODE_IDS.size()):
		var mode_id := int(EXPECTED_MODE_IDS[index])
		var definition := GameModeCatalog.get_definition(mode_id)
		_expect(definition != null, "Missing mode definition %d." % mode_id)
		if definition == null:
			continue
		_expect(
			String(definition.wire_key) == EXPECTED_WIRE_KEYS[index],
			"Mode %d wire key changed." % mode_id
		)
		_expect(
			GameModeCatalog.resolve_wire_key_or_default(
				String(definition.wire_key)
			) == mode_id,
			"Mode %d wire key must round-trip." % mode_id
		)
	_expect(
		GameModeCatalog.resolve_wire_key_or_default("unknown") == 0,
		"Unknown wire keys must resolve to standard mode."
	)
	var protocol_only_definition := GameModeDefinition.new()
	protocol_only_definition.mode_id = 42
	protocol_only_definition.wire_key = &"legacy_decode_only"
	_expect(
		protocol_only_definition.validate_definition().is_empty()
		and not protocol_only_definition.is_selectable_for(
			GameModeDefinition.SelectionAudience.RELEASE
		)
		and not protocol_only_definition.is_selectable_for(
			GameModeDefinition.SelectionAudience.DEVELOPMENT
		),
		"Protocol-only definitions must decode without becoming an authored entry."
	)
	_expect(
		GameModeCatalog.is_known_mode_id(GameModeCatalog.MODE_TEST_ARENA_P1E)
		and GameModeCatalog.is_development_selectable(
			GameModeCatalog.MODE_TEST_ARENA_P1E
		)
		and not GameModeCatalog.is_release_selectable(
			GameModeCatalog.MODE_TEST_ARENA_P1E
		),
		"P1E must remain a known development fixture without entering release admission."
	)

	var lobby_mode_ids := PackedInt32Array()
	for definition in GameModeCatalog.get_release_lobby_definitions():
		lobby_mode_ids.append(definition.mode_id)
	_expect(
		Array(lobby_mode_ids) == EXPECTED_RELEASE_ORDER,
		"Release lobby order changed: %s" % [lobby_mode_ids]
	)
	var development_mode_ids: Array[int] = []
	for definition in GameModeCatalog.get_development_definitions():
		development_mode_ids.append(definition.mode_id)
	_expect(
		development_mode_ids == EXPECTED_DEVELOPMENT_ORDER,
		"Development fixture order changed: %s" % [development_mode_ids]
	)
	var tower_definition := GameModeCatalog.get_definition(1)
	var p1_definition := GameModeCatalog.get_definition(2)
	var p1b_definition := GameModeCatalog.get_definition(5)
	var p1c_definition := GameModeCatalog.get_definition(6)
	var p1d_definition := GameModeCatalog.get_definition(7)
	var p1e_definition := GameModeCatalog.get_definition(8)
	var p2_definition := GameModeCatalog.get_definition(3)
	var standard_definition := GameModeCatalog.get_definition(0)
	_expect(
		standard_definition != null
		and standard_definition.multiplayer_entry_scene_path
		== "res://scene/game_modes/standard/multiplayer/standard_multiplayer_session.tscn",
		"Standard mode must own its multiplayer session entry."
	)
	for definition in [tower_definition, p1_definition, p1b_definition, p1c_definition, p1d_definition, p1e_definition, p2_definition]:
		_expect(
			definition != null
			and definition.multiplayer_entry_scene_path
			== "res://scene/game_modes/tower_defense/multiplayer/tower_defense_multiplayer_session.tscn",
			"Tower-defense modes must share the tower-defense session entry."
		)
	for definition in [tower_definition, p1_definition, p1b_definition, p1c_definition, p1d_definition, p1e_definition, p2_definition]:
		var preload_paths := GameModeCatalog.get_preload_resource_paths(definition)
		_expect(
			preload_paths.size() == 57,
			"Tower-defense preload profile must contain exactly 57 paths."
		)
		_expect(
			preload_paths.has(
				"res://scene/plant_defense/agave_cannonball.tscn"
			),
			"Tower-defense preload profile must retain the agave cannonball."
		)
		_expect(
			preload_paths.has(
				"res://resources/config/plant_defense/life_tower.tres"
			)
			and preload_paths.has(
				"res://scene/plant_defense/life_tower.tscn"
			),
			"Tower-defense preload profile must include the Life Tower config and scene."
		)
		_expect(
			preload_paths.has(
				"res://resources/config/plant_defense/speed_tower.tres"
			)
			and preload_paths.has(
				"res://scene/plant_defense/speed_tower.tscn"
			),
			"Tower-defense preload profile must include the Speed Tower config and scene."
		)
		_expect(
			preload_paths.has(
				"res://resources/config/plant_defense/attack_speed_tower.tres"
			)
			and preload_paths.has(
				"res://scene/plant_defense/attack_speed_tower.tscn"
			),
			"Tower-defense preload profile must include the Attack Speed Tower config and scene."
		)
	var rogue_definition := GameModeCatalog.get_definition(4)
	_expect(
		rogue_definition != null
		and GameModeCatalog.MODE_ROGUE == GameModeCatalog.MODE_TEST_ARENA_P3
		and GameModeCatalog.is_release_selectable(GameModeCatalog.MODE_ROGUE)
		and rogue_definition.wire_key == &"test_arena_p3"
		and rogue_definition.display_name == "肉鸽模式"
		and rogue_definition.lobby_label == "肉鸽模式"
		and not rogue_definition.include_starting_inventory
		and not rogue_definition.uses_wave_campaign,
		"Rogue must publish under its player-facing name while freezing the P3 wire contract."
	)
	_test_moved_uid_contracts()
	_finish()


func _test_moved_uid_contracts() -> void:
	for contract in [
		{
			"path": "res://scene/game_modes/standard/standard_game.gd.uid",
			"uid": "uid://7lyj58pu4nvs",
		},
		{
			"path": "res://scene/game_modes/tower_defense/tower_defense_game.gd.uid",
			"uid": "uid://d1w121mq74kpw",
		},
		{
			"path": "res://scene/game_modes/rogue/route/rogue_route_game.gd.uid",
			"uid": "uid://djtb4iw8wk0m6",
		},
	]:
		_expect(
			FileAccess.get_file_as_string(contract["path"]).strip_edges()
			== contract["uid"],
			"Moved script UID changed: %s" % contract["path"]
		)
	var combat_scene_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn"
	)
	_expect(
		combat_scene_source.begins_with(
			'[gd_scene format=4 uid="uid://cxpm27hl7fmro"]'
		),
		"Rogue combat scene UID changed during the mode move."
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("GAME_MODE_CATALOG_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
