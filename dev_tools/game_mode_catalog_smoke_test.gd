extends SceneTree

const CATALOG_PATH := "res://scene/game_modes/game_mode_catalog.tres"
const EXPECTED_MODE_IDS := [0, 1, 2, 3, 4, 5]
const EXPECTED_WIRE_KEYS := [
	"standard",
	"tower_defense",
	"test_arena_p1",
	"test_arena_p2",
	"test_arena_p3",
	"test_arena_p1b",
]
const EXPECTED_LOBBY_ORDER := [0, 1, 2, 5, 3, 4]

var failures := PackedStringArray()


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var heavyweight_paths := PackedStringArray([
		"res://scene/game_modes/standard/standard_game.tscn",
		"res://scene/game_modes/tower_defense/tower_defense_game.tscn",
		"res://scene/test_arena/test_rogue_route_p3.tscn",
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
	var p2_definition := GameModeCatalog.get_definition(3)
	for definition in [tower_definition, p1_definition, p1b_definition, p2_definition]:
		_expect(
			GameModeCatalog.get_preload_resource_paths(definition).size() == 26,
			"Tower-defense preload profile must contain exactly 26 paths."
		)
	var rogue_definition := GameModeCatalog.get_definition(4)
	_expect(
		rogue_definition != null
		and not rogue_definition.include_starting_inventory
		and not rogue_definition.uses_wave_campaign,
		"P3 must retain its no-starting-inventory/no-wave-campaign policy."
	)
	_finish()


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
