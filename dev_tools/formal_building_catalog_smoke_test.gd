extends SceneTree

const GAME_SCENE := preload("res://scene/game_tower_defense.tscn")
const HUD_SCENE := preload("res://scene/plant_defense/plant_selection_hud.tscn")
const DEFAULT_VIEWPORT := Vector2i(1152, 648)
const SMALL_VIEWPORT := Vector2i(800, 480)
const EXPECTED_CATEGORY_COUNTS := {
	PlantDefenseConfig.BuildingCategory.DEFENSE_TOWER: 4,
	PlantDefenseConfig.BuildingCategory.SUPPORT_TOWER: 1,
	PlantDefenseConfig.BuildingCategory.PRODUCTION_BUILDING: 6,
	PlantDefenseConfig.BuildingCategory.TECHNOLOGY_BUILDING: 1,
	PlantDefenseConfig.BuildingCategory.FENCE: 1,
	PlantDefenseConfig.BuildingCategory.TERRAIN_BUILDING: 1,
	PlantDefenseConfig.BuildingCategory.STORAGE_BUILDING: 1,
}

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_formal_inventory_catalog_and_placement()
	await _test_catalog_layout(DEFAULT_VIEWPORT)
	await _test_catalog_layout(SMALL_VIEWPORT)
	await _test_host_rejects_free_placement()
	await _cleanup_root()
	if failures.is_empty():
		print("FORMAL_BUILDING_CATALOG_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_formal_inventory_catalog_and_placement() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier")
	var game := GAME_SCENE.instantiate() as GameTowerDefense
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await _wait_layout_frames(3)
	var controller := game.plant_placement_controller
	var hud := controller.selection_hud
	_expect(
		not game.sandbox_free_building_enabled
		and not controller.free_placement_enabled
		and not game.allows_debug_collectible_grants(),
		"Formal tower defense must disable free placement and debug grants."
	)
	_expect(controller.open_selection(), "Formal T catalog must open.")
	await _wait_layout_frames(3)
	_expect(
		hud.is_open()
		and hud.available_configs.size() == 15
		and hud.cards.size() == 15
		and not hud.free_placement_mode,
		"Formal catalog must show all 15 buildings in inventory mode."
	)
	for category_variant in EXPECTED_CATEGORY_COUNTS:
		var category := int(category_variant)
		_expect(
			hud.get_category_card_count(category)
			== int(EXPECTED_CATEGORY_COUNTS[category_variant]),
			"Category %d must contain exactly %d cards."
			% [category, int(EXPECTED_CATEGORY_COUNTS[category_variant])]
		)

	var agave := PlantDefenseRegistry.get_config(PlantDefenseRegistry.AGAVE_CANNON_ID)
	var warehouse := PlantDefenseRegistry.get_config(PlantDefenseRegistry.OAK_WAREHOUSE_ID)
	var station := PlantDefenseRegistry.get_config(
		PlantDefenseRegistry.WOOD_PROCESSING_STATION_ID
	)
	var corn := PlantDefenseRegistry.get_config(PlantDefenseRegistry.CORN_MACHINE_GUN_ID)
	var stone_mill := PlantDefenseRegistry.get_config(PlantDefenseRegistry.STONE_MILL_ID)
	var agave_card := _find_card(hud, agave)
	var warehouse_card := _find_card(hud, warehouse)
	var station_card := _find_card(hud, station)
	var corn_card := _find_card(hud, corn)
	_expect(
		agave_card != null
		and agave_card.owned_count == 1
		and warehouse_card != null
		and warehouse_card.owned_count == 1
		and station_card != null
		and station_card.owned_count == 1,
		"The starter package must be visible as 1/1/1 in the formal catalog."
	)
	_expect(
		corn_card != null
		and corn_card.owned_count == 0
		and corn_card.select_button.disabled
		and corn_card.surface_label.text
		== PlantDefenseConfig.get_placement_surface_label(corn.placement_surface),
		"Zero-count cards must remain visible with an explicit surface tag."
	)

	hud.call("_select_config", corn)
	hud.call("_confirm_selection")
	_expect(
		controller.is_selecting() and hud.confirm_button.disabled,
		"A zero-count building must be viewable but impossible to confirm."
	)
	hud.call("_select_config", agave)
	hud.call("_select_category_relative", 1)
	_expect(
		hud.selected_config.building_category
		== PlantDefenseConfig.BuildingCategory.SUPPORT_TOWER,
		"Down navigation must move from defense to the fixed support row."
	)
	hud.call("_select_category_relative", 1)
	_expect(
		hud.selected_config.building_category
		== PlantDefenseConfig.BuildingCategory.PRODUCTION_BUILDING,
		"Down navigation must continue to the fixed production row."
	)

	hud.call("_select_config", stone_mill)
	await _wait_layout_frames(2)
	var production_scroll := hud.get_category_scroll(
		PlantDefenseConfig.BuildingCategory.PRODUCTION_BUILDING
	)
	var vertical_bar := hud.outer_scroll.get_v_scroll_bar()
	var horizontal_bar := production_scroll.get_h_scroll_bar()
	hud.outer_scroll.scroll_vertical = mini(
		180,
		maxi(roundi(vertical_bar.max_value - vertical_bar.page), 0)
	)
	production_scroll.scroll_horizontal = mini(
		30,
		maxi(roundi(horizontal_bar.max_value - horizontal_bar.page), 0)
	)
	await process_frame
	var remembered_vertical := hud.outer_scroll.scroll_vertical
	var remembered_horizontal := production_scroll.scroll_horizontal
	controller.cancel_placement()
	await create_timer(PlantSelectionHUD.TRANSITION_SECONDS + 0.03).timeout
	_expect(not hud.visible, "Catalog close fade must finish by 150 ms.")
	_expect(controller.open_selection(), "Catalog must reopen after cancellation.")
	await _wait_layout_frames(4)
	production_scroll = hud.get_category_scroll(
		PlantDefenseConfig.BuildingCategory.PRODUCTION_BUILDING
	)
	_expect(
		hud.selected_config == stone_mill
		and hud.outer_scroll.scroll_vertical == remembered_vertical
		and production_scroll.scroll_horizontal == remembered_horizontal,
		"HUD-local selection and nested scroll positions must survive reopen."
	)

	hud.call("_select_config", agave)
	hud.call("_confirm_selection")
	await process_frame
	_expect(
		controller.is_placing()
		and controller.placement_source
		== PlantPlacementController.PlacementSource.INVENTORY_ITEM
		and controller.inventory_slot_index >= 0,
		"Formal confirmation must enter the existing inventory placement path."
	)
	_expect(
		not controller.valid_anchors.is_empty(),
		"Starter agave must have at least one valid formal placement anchor."
	)
	if not controller.valid_anchors.is_empty():
		var anchor := controller.valid_anchors[0]
		controller.call("_set_hovered_anchor", anchor, true)
		var plant_count_before := game.plant_container.get_child_count()
		controller.call("_try_place_hovered")
		await process_frame
		_expect(
			game.plant_container.get_child_count() == plant_count_before + 1
			and run_state.get_inventory_item_total(
				BuildingItemRegistry.get_item(PlantDefenseRegistry.AGAVE_CANNON_ID)
			) == 0,
			"Formal T placement must atomically consume the selected building item."
		)

	current_scene = null
	game.queue_free()
	await _wait_until_freed(game)


func _test_catalog_layout(viewport_size: Vector2i) -> void:
	var viewport := SubViewport.new()
	viewport.size = viewport_size
	root.add_child(viewport)
	var hud := HUD_SCENE.instantiate() as PlantSelectionHUD
	viewport.add_child(hud)
	var configs := PlantDefenseRegistry.get_all_configs()
	_expect(hud.open(configs), "Catalog layout fixture must open.")
	await _wait_layout_frames(4)
	var footer := hud.get_node(
		"Root/ScreenMargin/Content/Margin/Layout/Footer"
	) as HBoxContainer
	var footer_rect := footer.get_global_rect()
	var catalog_rect := hud.outer_scroll.get_global_rect()
	_expect(
		footer_rect.position.x >= -0.5
		and footer_rect.position.y >= -0.5
		and footer_rect.end.x <= float(viewport_size.x) + 0.5
		and footer_rect.end.y <= float(viewport_size.y) + 0.5
		and catalog_rect.size.y > 0.0,
		"Catalog footer must remain visible at %s." % viewport_size
	)
	_expect(
		hud.outer_scroll.follow_focus
		and hud.outer_scroll.vertical_scroll_mode
		== ScrollContainer.SCROLL_MODE_AUTO,
		"Catalog must use an outer vertical follow-focus scroll."
	)
	for category_variant in EXPECTED_CATEGORY_COUNTS:
		var category := int(category_variant)
		var row_scroll := hud.get_category_scroll(category)
		_expect(
			row_scroll != null
			and row_scroll.follow_focus
			and row_scroll.horizontal_scroll_mode
			== ScrollContainer.SCROLL_MODE_AUTO
			and row_scroll.vertical_scroll_mode
			== ScrollContainer.SCROLL_MODE_DISABLED,
			"Every fixed category row must own an independent horizontal scroll."
		)
	hud.close()
	await create_timer(PlantSelectionHUD.TRANSITION_SECONDS + 0.03).timeout
	viewport.queue_free()
	await process_frame


func _test_host_rejects_free_placement() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier")
	var game := GAME_SCENE.instantiate() as GameTowerDefense
	game.auto_start_waves = false
	game.configure_multiplayer(
		GameRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		{1: "Host", 2: "Client"},
		{1: &"weishidaier", 2: &"weishidaier"}
	)
	root.add_child(game)
	current_scene = game
	await _wait_layout_frames(2)
	var rejections: Array[Dictionary] = []
	game.multiplayer_plant_placement_rejected.connect(
		func(request_id: int, peer_id: int, reason: StringName) -> void:
			rejections.append({
				"request_id": request_id,
				"peer_id": peer_id,
				"reason": reason,
			})
	)
	var plant_count_before := game.plant_container.get_child_count()
	game.request_multiplayer_plant_placement(
		2,
		77,
		PlantDefenseRegistry.AGAVE_CANNON_ID,
		Vector2i.ZERO
	)
	_expect(
		rejections.size() == 1
		and rejections[0]["request_id"] == 77
		and rejections[0]["peer_id"] == 2
		and rejections[0]["reason"]
		== GameTowerDefense.PLANT_PLACEMENT_REJECT_FREE_DISABLED
		and game.plant_container.get_child_count() == plant_count_before,
		"Formal host must reject the legacy free-placement RPC before placement."
	)
	var collectible_pool := LuoxiMerchant.get_collectible_pool()
	if not collectible_pool.is_empty():
		_expect(
			not game.grant_debug_collectible(
				(collectible_pool[0] as PickupConfig).resource_path
			),
			"Formal tower defense must reject direct debug collectible grants."
		)
	current_scene = null
	game.queue_free()
	await _wait_until_freed(game)


func _find_card(
	hud: PlantSelectionHUD,
	config: PlantDefenseConfig
) -> PlantSelectionCard:
	for card in hud.cards:
		if card.plant_config == config:
			return card
	return null


func _wait_layout_frames(frame_count: int) -> void:
	for _frame in frame_count:
		await process_frame
		await physics_frame


func _wait_until_freed(node: Node) -> void:
	for _frame in 10:
		if not is_instance_valid(node):
			return
		await process_frame
		await physics_frame


func _cleanup_root() -> void:
	current_scene = null
	for _frame in 4:
		await process_frame
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
