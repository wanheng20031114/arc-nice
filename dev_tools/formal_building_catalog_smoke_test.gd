extends SceneTree

const GAME_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const HUD_SCENE := preload("res://scene/game_modes/tower_defense/ui/plant_selection/plant_selection_hud.tscn")
const DEFAULT_VIEWPORT := Vector2i(1152, 648)
const SMALL_VIEWPORT := Vector2i(800, 480)
const EXPECTED_CATEGORY_COUNTS := {
	PlantDefenseConfig.BuildingCategory.DEFENSE_TOWER: 4,
	PlantDefenseConfig.BuildingCategory.SUPPORT_TOWER: 5,
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
	await _test_host_rejects_unowned_catalog_placement()
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
	var game := GAME_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await _wait_layout_frames(3)
	var controller := game.plant_placement_controller
	var hud := controller.selection_hud
	_expect(
		not game.sandbox_free_building_enabled
		and not controller.free_placement_enabled
		and game.tower_multiplayer_mode_adapter.allows_debug_collectible_grants(),
		(
			"Formal tower defense must keep free placement disabled while "
			+ "debug builds retain F10 collectible grants."
		)
	)
	var t_event := InputEventKey.new()
	t_event.physical_keycode = KEY_T
	t_event.pressed = true
	_expect(t_event.is_action_pressed(&"plant"), "T key must map to the plant action.")
	controller._unhandled_input(t_event)
	_expect(controller.is_selecting(), "Pressing T must open the formal building catalog.")
	await _wait_layout_frames(3)
	_expect(
		hud.is_open()
		and hud.available_configs.size() == 19
		and hud.cards.size() == 19
		and not hud.free_placement_mode,
		"Formal catalog must show all 19 buildings in inventory mode."
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
	var corn := PlantDefenseRegistry.get_config(PlantDefenseRegistry.CORN_MACHINE_GUN_ID)
	var life_tower := PlantDefenseRegistry.get_config(PlantDefenseRegistry.LIFE_TOWER_ID)
	var speed_tower := PlantDefenseRegistry.get_config(PlantDefenseRegistry.SPEED_TOWER_ID)
	var stone_mill := PlantDefenseRegistry.get_config(PlantDefenseRegistry.STONE_MILL_ID)
	var corn_card := _find_card(hud, corn)
	var life_tower_card := _find_card(hud, life_tower)
	var speed_tower_card := _find_card(hud, speed_tower)
	_expect(
		hud.cards.all(
			func(card: PlantSelectionCard) -> bool: return card.owned_count == 0
		),
		"Formal tower defense must not grant any building item at startup."
	)
	_expect(
		corn_card != null
		and corn_card.owned_count == 0
		and corn_card.select_button.disabled
		and corn_card.surface_label.text
		== PlantDefenseConfig.get_placement_surface_label(corn.placement_surface),
		"Zero-count cards must remain visible with an explicit surface tag."
	)
	_expect(
		life_tower_card != null
		and life_tower_card.owned_count == 0
		and life_tower_card.select_button.disabled,
		"Life Tower must be visible in the T catalog and disabled only while inventory count is zero."
	)
	_expect(
		speed_tower_card != null
		and speed_tower_card.owned_count == 0
		and speed_tower_card.select_button.disabled,
		"Speed Tower must be visible in the T catalog and disabled only while inventory count is zero."
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
	var vertical_bar := hud.outer_scroll.get_v_scroll_bar()
	hud.outer_scroll.scroll_vertical = mini(
		180,
		maxi(roundi(vertical_bar.max_value - vertical_bar.page), 0)
	)
	await process_frame
	var remembered_vertical := hud.outer_scroll.scroll_vertical
	controller.cancel_placement()
	await create_timer(PlantSelectionHUD.TRANSITION_SECONDS + 0.03).timeout
	_expect(not hud.visible, "Catalog close fade must finish by 150 ms.")
	_expect(controller.open_selection(), "Catalog must reopen after cancellation.")
	await _wait_layout_frames(4)
	_expect(
		hud.selected_config == stone_mill
		and hud.outer_scroll.scroll_vertical == remembered_vertical,
		"HUD-local selection and outer vertical position must survive reopen."
	)

	await _test_shared_warehouse_catalog_placement(
		game,
		run_state,
		controller,
		hud,
		corn
	)

	await _place_formal_catalog_building(
		game,
		run_state,
		controller,
		hud,
		life_tower,
		"Life Tower"
	)
	await _place_formal_catalog_building(
		game,
		run_state,
		controller,
		hud,
		speed_tower,
		"Speed Tower"
	)

	current_scene = null
	game.queue_free()
	await _wait_until_freed(game)


func _place_formal_catalog_building(
	game: TowerDefenseGame,
	run_state: RunStateStore,
	controller: PlantPlacementController,
	hud: PlantSelectionHUD,
	config: PlantDefenseConfig,
	label: String
) -> void:
	if not controller.is_selecting():
		_expect(
			controller.open_selection(),
			"%s placement fixture must reopen the formal T catalog." % label
		)
		await _wait_layout_frames(3)
	var item := BuildingItemRegistry.get_item(config.plant_id)
	_expect(item != null, "%s must have a registered building item." % label)
	if item == null:
		return
	_expect(
		run_state.try_add_item_count(item, 2),
		"Placement fixture must explicitly add two stacked %s building items." % label
	)
	await process_frame
	_expect(
		run_state.get_inventory_item_total(item) == 2,
		"%s fixture must expose exactly two owned items in one stack." % label
	)
	hud.call("_select_config", config)
	hud.call("_confirm_selection")
	await process_frame
	_expect(
		controller.is_placing()
		and controller.placement_source
		== PlantPlacementController.PlacementSource.CATALOG_ITEM
		and controller.inventory_slot_index == -1,
		"%s confirmation must enter the authoritative catalog-item path." % label
	)
	_expect(
		not controller.valid_anchors.is_empty(),
		"Explicitly injected %s fixture must have a valid 2x2 placement anchor."
		% label
	)
	if controller.valid_anchors.is_empty():
		controller.cancel_placement()
		return
	var anchor := controller.valid_anchors[0]
	var footprint_cells := game.plant_system.get_footprint_cells(anchor, config)
	controller.call("_set_hovered_anchor", anchor, true)
	var plant_container := game.get_node("PlantContainer") as Node2D
	var plant_count_before: int = plant_container.get_child_count()
	controller.call("_try_place_hovered")
	await process_frame
	var placed_building := game.plant_system.get_plant_at_cell(anchor)
	var all_footprint_cells_registered := true
	for cell in footprint_cells:
		all_footprint_cells_registered = (
			all_footprint_cells_registered
			and game.plant_system.get_plant_at_cell(cell) == placed_building
		)
	_expect(
		plant_container.get_child_count() == plant_count_before + 1
		and footprint_cells.size() == 4
		and placed_building != null
		and placed_building.config == config
		and placed_building.footprint_cells == footprint_cells
		and all_footprint_cells_registered
		and run_state.get_inventory_item_total(item) == 1,
		"Formal T placement must register all four %s cells and consume one item from the stack."
		% label
	)


func _test_shared_warehouse_catalog_placement(
	game: TowerDefenseGame,
	run_state: RunStateStore,
	controller: PlantPlacementController,
	hud: PlantSelectionHUD,
	config: PlantDefenseConfig
) -> void:
	var item := BuildingItemRegistry.get_item(config.plant_id)
	_expect(item != null, "Shared-warehouse catalog fixture needs a building item.")
	if item == null:
		return
	var warehouse := await _create_operational_warehouse(game)
	if warehouse == null:
		return
	_expect(
		controller.is_selecting() and hud.is_open(),
		"Authoring an operational warehouse must not close the open T catalog."
	)
	var card := _find_card(hud, config)
	_expect(
		card != null and card.owned_count == 0 and card.select_button.disabled,
		"The warehouse catalog fixture must start with no owned target building."
	)
	if card == null:
		return

	_expect(
		warehouse.try_add_storage_item_count(item, 1),
		"The first shared-warehouse building item must be accepted."
	)
	await process_frame
	_expect(
		card.owned_count == 1 and not card.select_button.disabled,
		"An open T catalog must refresh immediately after shared storage changes."
	)
	_expect(
		warehouse.try_add_storage_item_count(item, 1),
		"The second shared-warehouse building item must stack."
	)
	_expect(
		run_state.try_add_item_count(item, 1),
		"The local player inventory must accept the priority-payment fixture item."
	)
	await process_frame
	_expect(
		card.owned_count == 3
		and run_state.get_inventory_item_total(item) == 1
		and warehouse.get_storage_item_total(item) == 2,
		"T catalog ownership must equal this player's backpack plus shared warehouses."
	)

	hud.call("_select_config", config)
	hud.call("_confirm_selection")
	await process_frame
	_expect(
		controller.is_placing()
		and controller.placement_source
		== PlantPlacementController.PlacementSource.CATALOG_ITEM
		and controller.inventory_slot_index == -1,
		"T confirmation must preserve a generic catalog source until Host resolution."
	)
	var first_plant_count := game.get_node("PlantContainer").get_child_count()
	if not _place_current_catalog_selection(controller):
		return
	await process_frame
	_expect(
		game.get_node("PlantContainer").get_child_count() == first_plant_count + 1
		and run_state.get_inventory_item_total(item) == 0
		and warehouse.get_storage_item_total(item) == 2
		and not controller.is_active(),
		"Catalog placement must consume the local backpack before shared storage."
	)

	_expect(
		controller.open_selection(),
		"The T catalog must reopen for the warehouse-only placement case."
	)
	await _wait_layout_frames(2)
	card = _find_card(hud, config)
	_expect(
		card != null
		and card.owned_count == 2
		and not card.select_button.disabled,
		"Warehouse-only ownership must keep the T card enabled."
	)
	if card == null:
		return
	hud.call("_select_config", config)
	hud.call("_confirm_selection")
	await process_frame
	var second_plant_count := game.get_node("PlantContainer").get_child_count()
	if not _place_current_catalog_selection(controller, true):
		return
	await process_frame
	_expect(
		game.get_node("PlantContainer").get_child_count() == second_plant_count + 1
		and run_state.get_inventory_item_total(item) == 0
		and warehouse.get_storage_item_total(item) == 1
		and controller.is_placing()
		and not controller.has_pending_placement_request()
		and controller.selected_config == config
		and game.player.controls_locked,
		"Shift catalog placement must consume one shared item and keep the same building active."
	)
	if not _place_current_catalog_selection(controller, true):
		return
	await process_frame
	_expect(
		game.get_node("PlantContainer").get_child_count() == second_plant_count + 2
		and run_state.get_inventory_item_total(item) == 0
		and warehouse.get_storage_item_total(item) == 0
		and not controller.is_active()
		and not controller.has_pending_placement_request()
		and not game.player.controls_locked,
		"Continuous catalog placement must consume exactly one item per success and exit on depletion."
	)


func _create_operational_warehouse(game: TowerDefenseGame) -> OakWarehouse:
	var warehouse_config := PlantDefenseRegistry.get_config(
		PlantDefenseRegistry.OAK_WAREHOUSE_ID
	)
	var anchors := game.plant_system.get_valid_anchors(warehouse_config)
	_expect(
		warehouse_config != null and not anchors.is_empty(),
		"Shared-warehouse catalog fixture needs a valid authored warehouse anchor."
	)
	if warehouse_config == null or anchors.is_empty():
		return null
	var warehouse := game.plant_system.try_place(
		warehouse_config,
		anchors.back()
	) as OakWarehouse
	_expect(warehouse != null, "The catalog fixture must place a real OakWarehouse.")
	if warehouse == null:
		return null
	if not warehouse.is_operational:
		await warehouse.construction_finished
	_expect(
		warehouse.is_operational
		and game.production_coordinator.warehouses.has(warehouse),
		"The shared warehouse must be operational and registered with production."
	)
	return warehouse


func _place_current_catalog_selection(
	controller: PlantPlacementController,
	continuous_requested: bool = false
) -> bool:
	_expect(
		controller.is_placing()
		and controller.placement_source
		== PlantPlacementController.PlacementSource.CATALOG_ITEM
		and not controller.valid_anchors.is_empty(),
		"The catalog item must expose an authoritative valid placement anchor."
	)
	if not controller.is_placing() or controller.valid_anchors.is_empty():
		controller.cancel_placement()
		return false
	controller.call("_set_hovered_anchor", controller.valid_anchors[0], true)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.shift_pressed = continuous_requested
	controller.call("_unhandled_input", click)
	return true


func _test_catalog_layout(viewport_size: Vector2i) -> void:
	var viewport := SubViewport.new()
	viewport.size = viewport_size
	root.add_child(viewport)
	var hud := HUD_SCENE.instantiate() as PlantSelectionHUD
	viewport.add_child(hud)
	var configs := PlantDefenseRegistry.get_all_configs()
	var agave := PlantDefenseRegistry.get_config(PlantDefenseRegistry.AGAVE_CANNON_ID)
	_expect(
		hud.open(configs, {PlantDefenseRegistry.AGAVE_CANNON_ID: 1}),
		"Catalog layout fixture must open."
	)
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
		and hud.outer_scroll.horizontal_scroll_mode
		== ScrollContainer.SCROLL_MODE_DISABLED
		and hud.outer_scroll.vertical_scroll_mode
		== ScrollContainer.SCROLL_MODE_AUTO,
		"Catalog must keep only the outer vertical follow-focus scroll."
	)
	for category_variant in EXPECTED_CATEGORY_COUNTS:
		var category := int(category_variant)
		var flow := hud.get_category_flow(category)
		_expect(
			flow != null
			and hud.get_category_row_count(category) <= 2,
			"Every category flow must wrap its cards into at most two rows."
		)
		if flow != null:
			var flow_rect := flow.get_global_rect()
			for card_variant in hud.category_cards[category]:
				var card := card_variant as PlantSelectionCard
				var card_rect := card.get_global_rect()
				_expect(
					card.get_node_or_null("Margin/Content/Stats") == null
					and card.custom_minimum_size.y <= 110.0
					and card_rect.end.x <= flow_rect.end.x + 0.5,
					"Wrapped cards must not overflow horizontally at %s."
					% viewport_size
				)
	if viewport_size == DEFAULT_VIEWPORT:
		for category in [
			PlantDefenseConfig.BuildingCategory.DEFENSE_TOWER,
			PlantDefenseConfig.BuildingCategory.SUPPORT_TOWER,
			PlantDefenseConfig.BuildingCategory.PRODUCTION_BUILDING,
		]:
			_expect(
				hud.get_category_row_count(category) == 1,
				"Core catalog categories must fit one row at the design viewport."
			)
	var confirmed_configs: Array[PlantDefenseConfig] = []
	hud.selection_confirmed.connect(
		func(config: PlantDefenseConfig) -> void: confirmed_configs.append(config)
	)
	var agave_card := _find_card(hud, agave)
	_expect(
		agave_card != null
		and not agave_card.select_button.disabled
		and agave_card.select_button.text == "部署",
		"An owned compact card must expose a direct deploy button."
	)
	if agave_card != null:
		agave_card.select_button.pressed.emit()
	_expect(
		confirmed_configs == [agave],
		"Pressing a card deploy button must confirm that building immediately."
	)
	for label_variant in hud.find_children("*", "Label", true, false):
		var label := label_variant as Label
		_expect(
			_label_has_text_inset(label)
			and label.get_visible_line_count() == label.get_line_count(),
			"Every catalog label must keep inset space and show all of its text lines."
		)
	hud.close()
	await create_timer(PlantSelectionHUD.TRANSITION_SECONDS + 0.03).timeout
	viewport.queue_free()
	await process_frame


func _test_host_rejects_unowned_catalog_placement() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.register_multiplayer_peer_states(PackedInt32Array([1, 2])),
		"The Host catalog rejection fixture must register its authoritative roster."
	)
	var game := GAME_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		{1: "Host", 2: "Client"},
		{1: &"weishidaier", 2: &"hoe_cat"}
	)
	root.add_child(game)
	current_scene = game
	await _wait_layout_frames(2)
	var tower_adapter := (
		game.get_multiplayer_mode_adapter()
		as TowerDefenseMultiplayerModeAdapter
	)
	_expect(tower_adapter != null, "Formal tower scene must author its multiplayer mode adapter.")
	if tower_adapter == null:
		return
	var rejections: Array[Dictionary] = []
	tower_adapter.plant_placement_rejected.connect(
		func(request_id: int, peer_id: int, reason: StringName) -> void:
			rejections.append({
				"request_id": request_id,
				"peer_id": peer_id,
				"reason": reason,
			})
	)
	var plant_container := game.get_node("PlantContainer") as Node2D
	var agave_config := PlantDefenseRegistry.get_config(
		PlantDefenseRegistry.AGAVE_CANNON_ID
	)
	var remote_player := game.get_player_for_peer(2)
	var valid_anchors := game.plant_system.get_valid_anchors_for_player(
		agave_config,
		remote_player
	)
	_expect(
		agave_config != null
		and remote_player != null
		and not valid_anchors.is_empty(),
		"The Host rejection fixture needs a valid remote-player placement anchor."
	)
	if agave_config == null or remote_player == null or valid_anchors.is_empty():
		return
	var agave_item := BuildingItemRegistry.get_item(
		PlantDefenseRegistry.AGAVE_CANNON_ID
	)
	var plant_count_before: int = plant_container.get_child_count()
	game.tower_multiplayer_mode_adapter.request_authoritative_plant_placement(
		2,
		77,
		PlantDefenseRegistry.AGAVE_CANNON_ID,
		valid_anchors[0]
	)
	_expect(
		rejections.size() == 1
		and rejections[0]["request_id"] == 77
		and rejections[0]["peer_id"] == 2
		and rejections[0]["reason"]
		== TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_INVENTORY_ITEM
		and plant_container.get_child_count() == plant_count_before
		and run_state.get_inventory_item_total_for_peer(2, agave_item) == 0,
		"Formal Host must reject an unowned T item instead of granting a free building."
	)

	var shared_warehouse := await _create_operational_warehouse(game)
	if shared_warehouse != null:
		_expect(
			shared_warehouse.try_add_storage_item_count(agave_item, 1),
			"The Host catalog fixture must seed one shared Agave building item."
		)
		valid_anchors = game.plant_system.get_valid_anchors_for_player(
			agave_config,
			remote_player
		)
		_expect(
			not valid_anchors.is_empty(),
			"The remote player must retain a valid anchor after the warehouse is built."
		)
		if not valid_anchors.is_empty():
			plant_count_before = plant_container.get_child_count()
			game.tower_multiplayer_mode_adapter.request_authoritative_plant_placement(
				2,
				78,
				PlantDefenseRegistry.AGAVE_CANNON_ID,
				valid_anchors[0]
			)
			_expect(
				rejections.size() == 1
				and plant_container.get_child_count() == plant_count_before + 1
				and run_state.get_inventory_item_total_for_peer(2, agave_item) == 0
				and shared_warehouse.get_storage_item_total(agave_item) == 0,
				(
					"A formal Host must let a remote player build from shared storage "
					+ "without moving the item through that player's backpack."
				)
			)
	_expect(
		tower_adapter.allows_debug_collectible_grants(),
		"Formal host debug builds must retain adapter collectible grants."
	)
	var collectible_pool := LuoxiMerchant.get_collectible_pool()
	if not collectible_pool.is_empty():
		var item := collectible_pool[0] as PickupConfig
		var total_before := run_state.get_inventory_item_total_for_peer(1, item)
		_expect(
			tower_adapter.grant_debug_collectible(item.resource_path)
			and run_state.get_inventory_item_total_for_peer(1, item)
			== total_before + 1,
			(
				"Formal host adapter grants must add exactly one collectible to "
				+ "the authoritative local-peer inventory."
			)
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


func _label_has_text_inset(label: Label) -> bool:
	var normal_style := label.get_theme_stylebox("normal")
	return (
		normal_style.content_margin_left >= 2.0
		and normal_style.content_margin_top >= 2.0
		and normal_style.content_margin_right >= 2.0
		and normal_style.content_margin_bottom >= 2.0
	)


func _cleanup_root() -> void:
	current_scene = null
	for _frame in 4:
		await process_frame
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
