extends SceneTree

const GAME_SCENE := preload("res://scene/game_modes/standard/standard_game.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const APPLE_COLLECTIBLE := preload("res://resources/config/collectibles/collectible_apple.tres")
const WATER_BOTTLE_MATERIAL := preload(
	"res://resources/config/materials/material_water_bottle.tres"
)
const AGAVE_CANNON_BUILDING := preload(
	"res://resources/config/buildings/building_agave_cannon.tres"
)
const WINDWALK_POTION := preload(
	"res://resources/config/consumables/windwalk_potion.tres"
)
const WATER_SOURCE := preload(
	"res://resources/config/production/water_source.tres"
)
const DebugInventoryGrantCatalogScript := preload(
	"res://resources/config/debug_inventory_grant_catalog.gd"
)

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "DebugShortcutsSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_input_map()
	await _test_cheat_xirang_action()
	await _test_debug_collectible_window()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("DEBUG_SHORTCUTS_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_input_map() -> void:
	_expect(InputMap.has_action("cheat_xirang"), "Input map must include cheat_xirang.")
	_expect(InputMap.has_action("cheat_collectibles"), "Input map must include cheat_collectibles.")
	_expect(InputMap.has_action("full_screen"), "Input map must include full_screen.")


func _test_cheat_xirang_action() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	await process_frame
	await physics_frame

	var event := _make_action("cheat_xirang")
	player._unhandled_input(event)
	_expect(player.current_xirang == 1000, "cheat_xirang must grant 1000 xirang.")

	player.queue_free()
	await process_frame
	await physics_frame


func _test_debug_collectible_window() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()

	var game := GAME_SCENE.instantiate() as StandardGame
	game.set("auto_start_waves", false)
	test_root.add_child(game)
	await process_frame
	await physics_frame
	_expect(game.player.current_xirang == StandardGame.INITIAL_PLAYER_XIRANG, "StandardGame player must start with initial xirang.")

	var window := game.get_node_or_null("SettingsLayer/DebugCollectibleWindow") as DebugCollectibleWindow
	_expect(window != null, "StandardGame must include DebugCollectibleWindow under SettingsLayer.")
	if window == null:
		game.queue_free()
		return

	game._unhandled_input(_make_action("cheat_collectibles"))
	_expect(window.is_open(), "cheat_collectibles must open the debug collectible window.")
	_expect(game.player.controls_locked, "Opening the debug collectible window must lock player controls.")
	_expect(
		window.collectible_list.get_item_count()
		== (
			DebugInventoryGrantCatalogScript.get_collectibles().size()
			+ DebugInventoryGrantCatalogScript.get_materials().size()
			+ 1
		),
		"Debug window must list all collectibles, a resource header, and all inventory materials."
	)
	var material_section_index := (
		DebugInventoryGrantCatalogScript.get_collectibles().size()
	)
	_expect(
		window.collectible_list.is_item_disabled(material_section_index)
		and window.collectible_list.get_item_metadata(material_section_index) == null
		and window.collectible_list.get_item_text(material_section_index)
		== DebugCollectibleWindow.MATERIAL_SECTION_TITLE,
		"Resource items must start in a disabled section at the bottom of the F10 catalog."
	)
	var materials := DebugInventoryGrantCatalogScript.get_materials()
	_expect(
		materials.size() == 14
		and DebugInventoryGrantCatalogScript.get_for_path(
			AGAVE_CANNON_BUILDING.resource_path
		) == null
		and DebugInventoryGrantCatalogScript.get_for_path(
			WINDWALK_POTION.resource_path
		) == null
		and DebugInventoryGrantCatalogScript.get_for_path(WATER_SOURCE.resource_path)
		== null,
		"F10 grants must expose all 14 materials while rejecting buildings, consumables, and non-inventory water tiles."
	)
	for material_offset in materials.size():
		var material := materials[material_offset]
		var item_index := material_section_index + 1 + material_offset
		_expect(
			str(window.collectible_list.get_item_metadata(item_index))
			== material.resource_path,
			"Every trusted material must appear after the F10 resource header in stable order."
		)

	window.collectible_requested.emit(APPLE_COLLECTIBLE.resource_path)
	await process_frame
	_expect(
		run_state.get_item(0) == RunStateStore.STARTING_WOOD
		and run_state.get_item_count(0) == RunStateStore.STARTING_WOOD_COUNT
		and run_state.get_item(1) == APPLE_COLLECTIBLE,
		"Debug collectible request must preserve starting wood and add the selected collectible."
	)
	_expect(not game.has_luoxi_collectible_claimed(0), "Debug collectible grant must not spend Luoxi's round claim.")
	var water_index := _find_item_index_by_path(
		window.collectible_list,
		WATER_BOTTLE_MATERIAL.resource_path
	)
	var water_before := run_state.get_inventory_item_total(WATER_BOTTLE_MATERIAL)
	window.collectible_list.item_activated.emit(water_index)
	await process_frame
	_expect(
		water_index > material_section_index
		and run_state.get_inventory_item_total(WATER_BOTTLE_MATERIAL)
		== water_before + 1
		and window.status_label.text.contains(WATER_BOTTLE_MATERIAL.display_name),
		"Activating a resource entry must grant exactly one item and report its real name."
	)

	window.close()
	await process_frame
	_expect(not game.player.controls_locked, "Closing the debug collectible window must unlock player controls when no other modal is open.")

	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _make_action(action_name: String) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action_name
	event.pressed = true
	return event


func _find_item_index_by_path(item_list: ItemList, config_path: String) -> int:
	for item_index in item_list.get_item_count():
		if str(item_list.get_item_metadata(item_index)) == config_path:
			return item_index
	return -1


func _stop_audio_players(root_node: Node) -> void:
	for child in root_node.get_children():
		if child is AudioStreamPlayer or child is AudioStreamPlayer2D:
			child.stop()
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
