extends SceneTree

const FATE_COORDINATOR_SCENE := preload(
	"res://scene/plant_defense/fate_coordinator.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := FATE_COORDINATOR_SCENE.instantiate() as FateCoordinator
	root.add_child(coordinator)
	await process_frame
	var manager := coordinator.manager
	var game := GameTowerDefense.new()
	game.fate_coordinator = coordinator
	game.fate_manager = manager
	coordinator.setup(game, game.day_cycle_config)
	manager.resolution_requested.disconnect(coordinator._on_resolution_requested)

	_test_stone_pending_disconnect(coordinator, manager)
	_test_partial_stone_delivery_revision(coordinator, manager)
	_test_collectible_missing_player(game, coordinator, manager)
	_test_remote_revision_guard(game, coordinator, manager)
	await _test_stone_inventory_access_overlay()
	await create_timer(TowerDefenseFateManager.RESULT_DISPLAY_SECONDS + 0.1).timeout

	coordinator.queue_free()
	game.free()
	await process_frame
	if failures.is_empty():
		print("TOWER_DEFENSE_FATE_EDGECASE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_stone_pending_disconnect(
	coordinator: FateCoordinator,
	manager: TowerDefenseFateManager
) -> void:
	_begin_resolving_vote(
		manager,
		[1, 2],
		TowerDefenseFateRegistry.OPTION_FATE_STONE
	)
	coordinator.pending_stone_peer_ids = [2]
	coordinator.remove_eligible_peer(2)
	_expect(
		manager.stage == TowerDefenseFateManager.STAGE_RESOLVED,
		"Removing the final stone-pending peer must finalize RESOLVING."
	)
	_expect(
		manager.eligible_peer_ids == [1],
		"A disconnected stone recipient must leave the eligible set."
	)
	manager.force_finish()


func _test_partial_stone_delivery_revision(
	coordinator: FateCoordinator,
	manager: TowerDefenseFateManager
) -> void:
	_begin_resolving_vote(
		manager,
		[1, 2],
		TowerDefenseFateRegistry.OPTION_FATE_STONE
	)
	coordinator.pending_stone_peer_ids = [1, 2]
	var revision_before := manager.state_revision
	coordinator.pending_stone_peer_ids = [2]
	manager.notify_external_state_changed()
	_expect(
		manager.state_revision == revision_before + 1,
		"Partial stone delivery must advance the authoritative fate revision."
	)
	_expect(
		manager.stage == TowerDefenseFateManager.STAGE_RESOLVING,
		"Partial stone delivery must keep resolving until every remaining peer is done."
	)
	coordinator.pending_stone_peer_ids.clear()
	manager.force_finish()


func _test_collectible_missing_player(
	game: GameTowerDefense,
	coordinator: FateCoordinator,
	manager: TowerDefenseFateManager
) -> void:
	_begin_resolving_vote(
		manager,
		[1, 2],
		TowerDefenseFateRegistry.OPTION_COLLECTIBLE_REWARD
	)
	manager.begin_collectible_reward({1: ["a"], 2: ["b"]})
	manager.record_collectible_result(1, true, "done")
	_expect(
		not coordinator.is_collectible_choice_pending_for_peer(1),
		"A peer that already claimed a collectible must be rejected before another write."
	)
	_expect(
		coordinator.is_collectible_choice_pending_for_peer(2),
		"An unclaimed eligible peer must remain able to choose its collectible."
	)
	var remaining_player := Player.new()
	game.runtime_mode = GameRuntimeBase.RuntimeMode.HOST_AUTHORITY
	game.peer_players = {1: remaining_player}
	coordinator._prune_missing_players()
	_expect(
		manager.stage == TowerDefenseFateManager.STAGE_RESOLVED,
		"A missing final collectible recipient must not deadlock the reward stage."
	)
	_expect(
		manager.eligible_peer_ids == [1],
		"The missing collectible recipient must be removed from eligibility."
	)
	game.peer_players.clear()
	remaining_player.free()
	manager.force_finish()


func _test_remote_revision_guard(
	game: GameTowerDefense,
	coordinator: FateCoordinator,
	manager: TowerDefenseFateManager
) -> void:
	game.runtime_mode = GameRuntimeBase.RuntimeMode.CLIENT_VIEW
	coordinator.elite_bias_day = 4
	manager.state_revision = 10
	game.apply_remote_xiaocong_fate_state({"revision": 9, "elite_bias_day": 99})
	_expect(
		coordinator.elite_bias_day == 4,
		"A stale fate snapshot must not overwrite coordinator runtime values."
	)
	game.runtime_mode = GameRuntimeBase.RuntimeMode.SINGLEPLAYER


func _test_stone_inventory_access_overlay() -> void:
	var overlay := preload(
		"res://scene/xiaocong_fate_choice_overlay.tscn"
	).instantiate() as XiaocongFateChoiceOverlay
	_expect(
		not overlay.visible,
		"The fate choice overlay must be hidden in the editor until runtime state opens it."
	)
	root.add_child(overlay)
	await process_frame
	var portrait_stage := overlay.get_node(
		"Root/ScreenMargin/MainRow/PortraitStage"
	) as Control
	var portrait_frame := overlay.get_node(
		"Root/ScreenMargin/MainRow/PortraitStage/PortraitFrame"
	) as Control
	var decision_column := overlay.get_node(
		"Root/ScreenMargin/MainRow/DecisionColumn"
	) as Control
	var overlay_root := overlay.get_node("Root") as Control
	var backdrop := overlay.get_node("Root/Backdrop") as TextureRect
	var entrance_back_buffer := overlay.get_node(
		"Root/EntranceBackBuffer"
	) as BackBufferCopy
	var entrance_reveal_cover := overlay.get_node(
		"Root/EntranceRevealCover"
	) as ColorRect
	var entrance_reveal_material := (
		entrance_reveal_cover.material as ShaderMaterial
	)
	var xiaocong_portrait := overlay.get_node(
		"Root/ScreenMargin/MainRow/PortraitStage/PortraitFrame/Xiaocong"
	) as TextureRect
	var portrait_source_size := xiaocong_portrait.texture.get_size()
	_expect(
		entrance_back_buffer.copy_mode == BackBufferCopy.COPY_MODE_VIEWPORT
		and not entrance_back_buffer.visible
		and entrance_back_buffer.get_index() < backdrop.get_index()
		and not entrance_reveal_cover.visible
		and entrance_reveal_cover.get_index()
		== overlay_root.get_child_count() - 1
		and entrance_reveal_cover.z_index >= 100
		and entrance_reveal_cover.mouse_filter == Control.MOUSE_FILTER_STOP,
		"The entrance reveal must save the old frame and block input above the UI."
	)
	_expect(
		entrance_reveal_material != null
		and entrance_reveal_material.resource_local_to_scene
		and entrance_reveal_material.shader.code.contains(
			"hint_screen_texture"
		)
		and entrance_reveal_material.shader.code.contains("reveal_progress")
		and entrance_reveal_material.get_shader_parameter(
			&"reveal_noise"
		) != null,
		"The Xiaocong entrance shader must combine the saved screen with organic noise."
	)
	_expect(
		portrait_source_size == Vector2(1098, 1433)
		and portrait_stage.custom_minimum_size == Vector2(390, 520)
		and portrait_frame.custom_minimum_size == Vector2(366, 478)
		and xiaocong_portrait.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST
		and xiaocong_portrait.scale.is_equal_approx(
			Vector2.ONE / 3.0
		)
		and xiaocong_portrait.stretch_mode
		== TextureRect.STRETCH_SCALE,
		"The left stage must display the full-resolution Xiaocong portrait at an exact nearest-neighbor 1/3 scale."
	)
	_expect(
		portrait_stage.get_global_rect().get_center().x
		< decision_column.get_global_rect().get_center().x,
		"The Xiaocong portrait must remain to the left of the decision column."
	)
	_expect(
		overlay.choice_cards.size()
		== TowerDefenseFateManager.FATE_OPTION_OFFER_COUNT
		and overlay.choice_list.get_child_count()
		== TowerDefenseFateManager.FATE_OPTION_OFFER_COUNT,
		"The decision column must contain exactly three fate cards."
	)
	var first_card := overlay.choice_cards[0]
	var card_title_font := (
		first_card.title_label.label_settings.font as FontVariation
	)
	var card_body_font := (
		first_card.description_label.label_settings.font as FontVariation
	)
	_expect(
		card_title_font != null
		and card_body_font != null
		and is_zero_approx(card_title_font.variation_embolden)
		and is_zero_approx(card_body_font.variation_embolden)
		and first_card.title_label.label_settings.font_size == 21
		and first_card.title_label.label_settings.outline_size == 1
		and first_card.description_label.label_settings.font_size == 16
		and first_card.description_label.label_settings.outline_size == 0,
		"The three fate cards must use normal-weight readable type instead of heavy emboldening."
	)
	var cards_preserve_art_and_rounding := true
	for card in overlay.choice_cards:
		var card_ratio := (
			card.background.texture.get_width()
			/ float(card.background.texture.get_height())
		)
		var mask_style := card.get_theme_stylebox("panel") as StyleBoxFlat
		var normal_style := (
			card.button.get_theme_stylebox("normal") as StyleBoxFlat
		)
		var hover_style := (
			card.button.get_theme_stylebox("hover") as StyleBoxFlat
		)
		var pressed_style := (
			card.button.get_theme_stylebox("pressed") as StyleBoxFlat
		)
		var focus_style := (
			card.button.get_theme_stylebox("focus") as StyleBoxFlat
		)
		var styles: Array[StyleBoxFlat] = [
			mask_style,
			normal_style,
			hover_style,
			pressed_style,
			focus_style,
		]
		var styles_share_radius := true
		for style in styles:
			styles_share_radius = (
				styles_share_radius
				and style != null
				and style.corner_radius_top_left == 8
				and style.corner_radius_top_right == 8
				and style.corner_radius_bottom_right == 8
				and style.corner_radius_bottom_left == 8
			)
		cards_preserve_art_and_rounding = (
			cards_preserve_art_and_rounding
			and card_ratio >= 4.2
			and card_ratio <= 4.3
			and card.background.stretch_mode
			== TextureRect.STRETCH_KEEP_ASPECT_COVERED
			and card.clip_children == CanvasItem.CLIP_CHILDREN_ONLY
			and styles_share_radius
			and mask_style.bg_color.a >= 0.99
			and normal_style.border_width_left == 1
			and hover_style.border_width_left == 2
			and pressed_style.border_width_left == 3
			and focus_style != pressed_style
		)
	_expect(
		cards_preserve_art_and_rounding,
		"All three card artworks and interaction states must share one rounded frame."
	)
	var state := {
		"active": true,
		"completed_day": 6,
		"stage": String(TowerDefenseFateManager.STAGE_VOTING),
		"host_peer_id": 1,
		"eligible_peer_ids": [1, 2],
		"available_option_ids": _option_wire_ids([
			TowerDefenseFateRegistry.OPTION_FATE_STONE,
			TowerDefenseFateRegistry.OPTION_CRITICAL_CORE,
			TowerDefenseFateRegistry.OPTION_BASE_REBUILD,
		]),
		"permanent_buff_offer": PackedStringArray(),
		"permanent_buff_votes": {},
		"available_permanent_buff_count": 9,
		"votes": {},
		"winning_option_id": "",
		"winning_permanent_buff_id": "",
		"pending_stone_peer_ids": [],
		"stage_time_remaining": 30.0,
		"timeout_recovery_available": false,
	}
	overlay.apply_state(state, 3, {})
	_expect(
		overlay.visible,
		"An active voting state must reveal the editor-hidden fate choice overlay."
	)
	_expect(
		entrance_back_buffer.visible
		and entrance_reveal_cover.visible
		and is_zero_approx(float(
			entrance_reveal_cover.get_instance_shader_parameter(
				&"reveal_progress"
			)
		)),
		"Opening the fate UI must start a fully covered edge-to-center reveal."
	)
	_expect(
		"旁观" in overlay.status_label.text,
		"A late non-eligible peer must be told that it is observing this day."
	)
	var all_cards_disabled := true
	for card in overlay.choice_cards:
		all_cards_disabled = all_cards_disabled and card.button.disabled
	_expect(all_cards_disabled, "A non-eligible observer must not have clickable fate cards.")
	await create_timer(0.14).timeout
	var mid_reveal_progress := float(
		entrance_reveal_cover.get_instance_shader_parameter(
			&"reveal_progress"
		)
	)
	_expect(
		mid_reveal_progress > 0.0 and mid_reveal_progress < 1.0,
		"The entrance shader must advance through a visible growth phase."
	)
	await create_timer(0.47).timeout
	var all_cards_fully_visible := true
	for card in overlay.choice_cards:
		all_cards_fully_visible = (
			all_cards_fully_visible
			and is_equal_approx(card.modulate.a, 1.0)
		)
	_expect(
		overlay.show_tween == null
		and not entrance_back_buffer.visible
		and not entrance_reveal_cover.visible
		and all_cards_fully_visible,
		"The reveal must finish quickly on three fully visible cards and disable its overhead."
	)
	overlay.apply_state(state, 3, {})
	_expect(
		overlay.show_tween == null,
		"A vote tally update in the same stage must not replay the show tween."
	)

	state["votes"] = {
		1: String(TowerDefenseFateRegistry.OPTION_FATE_STONE),
		2: String(TowerDefenseFateRegistry.OPTION_FATE_STONE),
	}
	overlay.apply_state(state, 3, {
		1: &"hoe_cat",
		2: &"weishidaier",
	})
	await process_frame
	var vote_row := overlay.choice_cards[0].vote_row
	var hoe_cat_texture: TextureRect = null
	var default_texture: TextureRect = null
	for vote_portrait in vote_row.get_children():
		var texture_rect := vote_portrait.get_node(
			"PortraitLayer/TextureRect"
		) as TextureRect
		if int(vote_portrait.get_meta(&"peer_id", -1)) == 1:
			hoe_cat_texture = texture_rect
		elif int(vote_portrait.get_meta(&"peer_id", -1)) == 2:
			default_texture = texture_rect
	_expect(
		hoe_cat_texture != null
		and default_texture != null
		and is_equal_approx(hoe_cat_texture.position.x, 2.0)
		and is_zero_approx(default_texture.position.x),
		"The Hoe Cat vote portrait must keep its two-pixel right compensation."
	)

	var submitted_option_ids: Array[StringName] = []
	var submitted_buff_option_ids: Array[StringName] = []
	var submitted_buff_ids: Array[StringName] = []
	overlay.choice_submitted.connect(
		func(option_id: StringName, permanent_buff_id: StringName) -> void:
			if permanent_buff_id.is_empty():
				submitted_option_ids.append(option_id)
			else:
				submitted_buff_option_ids.append(option_id)
				submitted_buff_ids.append(permanent_buff_id)
	)
	state["votes"] = {}
	overlay.apply_state(state, 1, {})
	for card in overlay.choice_cards:
		card.button.pressed.emit()
	_expect(
		submitted_option_ids == [
			TowerDefenseFateRegistry.OPTION_FATE_STONE,
			TowerDefenseFateRegistry.OPTION_CRITICAL_CORE,
			TowerDefenseFateRegistry.OPTION_BASE_REBUILD,
		],
		"Display slots one through three must submit the host's named offer order."
	)

	var critical_buff_offer: Array[StringName] = [
		TowerDefenseFateRegistry.BUFF_SLIME_SPEED_REDUCTION,
		TowerDefenseFateRegistry.BUFF_BUILDING_REGENERATION,
		TowerDefenseFateRegistry.BUFF_PLAYER_REGENERATION,
	]
	state["stage"] = String(
		TowerDefenseFateManager.STAGE_CRITICAL_BUFF_VOTING
	)
	state["permanent_buff_offer"] = _buff_wire_ids(critical_buff_offer)
	state["permanent_buff_votes"] = {
		2: String(critical_buff_offer[0]),
	}
	state["stage_time_remaining"] = 18.0
	# A peer can still have the first-stage permanent-contract modal open when
	# another peer's final vote makes Critical Core win. Its Cancel focus must
	# move onto a visible second-stage choice when that button is hidden.
	overlay.permanent_buff_offer = critical_buff_offer.duplicate()
	overlay._show_buff_modal()
	overlay.buff_cancel_button.grab_focus()
	overlay.apply_state(state, 1, {})
	var visible_buff_button_count := 0
	var all_critical_buttons_enabled := true
	for button in overlay.buff_buttons:
		if button.visible:
			visible_buff_button_count += 1
			all_critical_buttons_enabled = (
				all_critical_buttons_enabled and not button.disabled
			)
	_expect(
		overlay.buff_modal.visible
		and not overlay.choice_list.visible
		and not overlay.buff_cancel_button.visible
		and overlay.buff_cancel_button.disabled
		and visible_buff_button_count == 3
		and all_critical_buttons_enabled
		and overlay.buff_buttons.has(
			overlay.get_viewport().gui_get_focus_owner()
		),
		"Critical core must replace the fate cards with exactly three non-cancelable buff vote buttons."
	)
	_expect(
		"全局增益投票 1/2" in overlay.status_label.text
		and "1 票" in overlay.buff_buttons[0].text,
		"The critical-core second stage must show multiplayer vote progress and per-buff tallies."
	)
	overlay.buff_buttons[1].pressed.emit()
	_expect(
		overlay.buff_modal.visible
		and submitted_buff_option_ids == [
			TowerDefenseFateRegistry.OPTION_CRITICAL_CORE,
		]
		and submitted_buff_ids == [critical_buff_offer[1]],
		"An eligible player must submit critical_core plus the selected offered buff without closing the vote modal."
	)
	state["permanent_buff_votes"] = {
		1: String(critical_buff_offer[1]),
		2: String(critical_buff_offer[0]),
	}
	overlay.apply_state(state, 1, {})
	_expect(
		overlay.buff_buttons[1].text.begins_with("✓ ")
		and "1 票" in overlay.buff_buttons[1].text,
		"An authoritative critical-core snapshot must mark the local selection while keeping it changeable."
	)
	overlay.buff_buttons[2].pressed.emit()
	_expect(
		submitted_buff_ids == [critical_buff_offer[1], critical_buff_offer[2]],
		"An eligible player must be able to change the second-stage buff vote."
	)
	var critical_submission_count := submitted_buff_ids.size()
	overlay.apply_state(state, 3, {})
	var all_observer_buff_buttons_disabled := true
	for button in overlay.buff_buttons:
		if button.visible:
			all_observer_buff_buttons_disabled = (
				all_observer_buff_buttons_disabled and button.disabled
			)
	overlay.buff_buttons[0].pressed.emit()
	_expect(
		overlay.buff_modal.visible
		and "旁观" in overlay.status_label.text
		and all_observer_buff_buttons_disabled
		and submitted_buff_ids.size() == critical_submission_count,
		"A non-eligible peer must see the critical buff vote but cannot submit it."
	)
	state["eligible_peer_ids"] = [0]
	state["permanent_buff_votes"] = {}
	overlay.apply_state(state, 0, {})
	overlay.buff_cancel_button.pressed.emit()
	overlay.buff_buttons[0].pressed.emit()
	_expect(
		overlay.buff_modal.visible
		and submitted_buff_option_ids[-1]
		== TowerDefenseFateRegistry.OPTION_CRITICAL_CORE
		and submitted_buff_ids[-1] == critical_buff_offer[0],
		"Single-player critical-core selection must use the same non-cancelable three-choice vote UI."
	)

	state["eligible_peer_ids"] = [1, 2]
	state["stage"] = String(TowerDefenseFateManager.STAGE_COLLECTIBLE_REWARD)
	state["collectible_offers"] = {1: []}
	state["collectible_claimed_peer_ids"] = []
	state["collectible_status_by_peer"] = {
		1: "背包已满，请先清出一个空位后再次选择",
	}
	overlay.apply_state(state, 1, {})
	_expect(
		overlay.layer == XiaocongFateChoiceOverlay.INVENTORY_ACCESS_CANVAS_LAYER
		and "背包键" in overlay.collectible_status.text,
		"A full collectible inventory must expose the profile panel and explain how to retry."
	)

	state["stage"] = String(TowerDefenseFateManager.STAGE_RESOLVING)
	state["votes"] = {
		1: String(TowerDefenseFateRegistry.OPTION_FATE_STONE),
		2: String(TowerDefenseFateRegistry.OPTION_FATE_STONE),
	}
	state["winning_option_id"] = String(TowerDefenseFateRegistry.OPTION_FATE_STONE)
	state["pending_stone_peer_ids"] = [1]
	var submission_count_before_resolution := submitted_option_ids.size()
	overlay.apply_state(state, 1, {})
	overlay.choice_cards[0].button.pressed.emit()
	_expect(
		overlay.layer == XiaocongFateChoiceOverlay.INVENTORY_ACCESS_CANVAS_LAYER
		and submitted_option_ids.size() == submission_count_before_resolution,
		"A local full inventory must place the fate overlay below the profile panel."
	)
	_expect(
		overlay.get_node("Root").mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"The pending-stone overlay must let inventory access input pass through."
	)
	_expect(
		"自动获得" in overlay.status_label.text,
		"The local player must see how to clear space and that delivery is automatic."
	)
	state["pending_stone_peer_ids"] = [2]
	overlay.apply_state(state, 1, {})
	_expect(
		overlay.layer == XiaocongFateChoiceOverlay.DEFAULT_CANVAS_LAYER,
		"A player who is only waiting for another peer must keep the normal overlay layer."
	)
	state["stage"] = String(TowerDefenseFateManager.STAGE_RESOLVED)
	state["winning_option_id"] = String(TowerDefenseFateRegistry.OPTION_CRITICAL_CORE)
	state["winning_permanent_buff_id"] = String(
		TowerDefenseFateRegistry.BUFF_SLIME_SPEED_REDUCTION
	)
	state["pending_stone_peer_ids"] = []
	overlay.apply_state(state, 1, {})
	_expect(
		"史莱姆" in overlay.status_label.text,
		"Critical-core resolution text must name the permanent buff actually awarded."
	)
	state["active"] = false
	overlay.apply_state(state, 1, {})
	_expect(
		not overlay.visible
		and not entrance_back_buffer.visible
		and not entrance_reveal_cover.visible
		and overlay.show_tween == null,
		"An inactive fate state must hide the overlay and stop reveal resources."
	)
	await create_timer(0.3).timeout
	overlay.queue_free()
	await process_frame


func _begin_resolving_vote(
	manager: TowerDefenseFateManager,
	peer_ids: Array,
	option_id: StringName
) -> void:
	var typed_peer_ids: Array[int] = []
	for peer_id in peer_ids:
		typed_peer_ids.append(int(peer_id))
	manager.begin_interlude(
		1,
		&"next",
		typed_peer_ids,
		typed_peer_ids[0],
		TowerDefenseFateRegistry.get_all_option_ids(),
		TowerDefenseFateRegistry.get_all_permanent_buff_ids()
	)
	manager.available_option_ids = _ordered_offer_containing(option_id)
	for peer_id in typed_peer_ids:
		manager.record_interaction(peer_id)
	for peer_id in typed_peer_ids:
		manager.submit_vote(peer_id, option_id, &"")
	_expect(
		manager.stage == TowerDefenseFateManager.STAGE_RESOLVING,
		"Test setup must reach RESOLVING."
	)


func _ordered_offer_containing(option_id: StringName) -> Array[StringName]:
	var offer: Array[StringName] = [option_id]
	for candidate in TowerDefenseFateRegistry.get_all_option_ids():
		if candidate == option_id:
			continue
		offer.append(candidate)
		if offer.size() == TowerDefenseFateManager.FATE_OPTION_OFFER_COUNT:
			break
	return offer


func _option_wire_ids(option_ids: Array[StringName]) -> PackedStringArray:
	var result := PackedStringArray()
	for option_id in option_ids:
		result.append(String(option_id))
	return result


func _buff_wire_ids(buff_ids: Array[StringName]) -> PackedStringArray:
	var result := PackedStringArray()
	for buff_id in buff_ids:
		result.append(String(buff_id))
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
