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
const EXPECTED_LOBBY_ORDER := [0, 1, 2, 5, 6, 7, 8, 3, 4]

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
	_expect(
		GameModeCatalog.is_valid_mode_id(GameModeCatalog.MODE_TEST_ARENA_P1E)
		and GameModeCatalog.is_mode_selectable(
			GameModeCatalog.MODE_TEST_ARENA_P1E
		),
		"P1E must remain known to v62 and expose its authored test entry."
	)

	var lobby_mode_ids := PackedInt32Array()
	for definition in GameModeCatalog.get_lobby_definitions():
		lobby_mode_ids.append(definition.mode_id)
	_expect(
		Array(lobby_mode_ids) == EXPECTED_LOBBY_ORDER,
		"Lobby order changed: %s" % [lobby_mode_ids]
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
			preload_paths.size() == 51,
			"Tower-defense preload profile must contain exactly 51 paths."
		)
		_expect(
			preload_paths.has(
				"res://scene/plant_defense/agave_cannonball.tscn"
			),
			"Tower-defense preload profile must retain the agave cannonball."
		)
	var rogue_definition := GameModeCatalog.get_definition(4)
	_expect(
		rogue_definition != null
		and not rogue_definition.include_starting_inventory
		and not rogue_definition.uses_wave_campaign,
		"P3 must retain its no-starting-inventory/no-wave-campaign policy."
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
