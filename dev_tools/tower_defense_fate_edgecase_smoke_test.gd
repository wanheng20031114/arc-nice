extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var manager := TowerDefenseFateManager.new()
	root.add_child(manager)
	var game := GameTowerDefense.new()
	game.fate_manager = manager
	await process_frame

	_test_stone_pending_disconnect(game, manager)
	_test_partial_stone_delivery_revision(game, manager)
	_test_collectible_missing_player(game, manager)
	_test_remote_revision_guard(game, manager)
	await _test_stone_inventory_access_overlay()
	await create_timer(TowerDefenseFateManager.RESULT_DISPLAY_SECONDS + 0.1).timeout

	manager.queue_free()
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
	game: GameTowerDefense,
	manager: TowerDefenseFateManager
) -> void:
	_begin_resolving_vote(manager, [1, 2], 3)
	game.pending_fate_stone_peer_ids = [2]
	game.call("_remove_fate_eligible_peer", 2)
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
	game: GameTowerDefense,
	manager: TowerDefenseFateManager
) -> void:
	_begin_resolving_vote(manager, [1, 2], 3)
	game.pending_fate_stone_peer_ids = [1, 2]
	var revision_before := manager.state_revision
	game.pending_fate_stone_peer_ids = [2]
	manager.notify_external_state_changed()
	_expect(
		manager.state_revision == revision_before + 1,
		"Partial stone delivery must advance the authoritative fate revision."
	)
	_expect(
		manager.stage == TowerDefenseFateManager.STAGE_RESOLVING,
		"Partial stone delivery must keep resolving until every remaining peer is done."
	)
	game.pending_fate_stone_peer_ids.clear()
	manager.force_finish()


func _test_collectible_missing_player(
	game: GameTowerDefense,
	manager: TowerDefenseFateManager
) -> void:
	_begin_resolving_vote(manager, [1, 2], 2)
	manager.begin_collectible_reward({1: ["a"], 2: ["b"]})
	manager.record_collectible_result(1, true, "done")
	_expect(
		not bool(game.call("_is_fate_collectible_choice_pending_for_peer", 1)),
		"A peer that already claimed a collectible must be rejected before another write."
	)
	_expect(
		bool(game.call("_is_fate_collectible_choice_pending_for_peer", 2)),
		"An unclaimed eligible peer must remain able to choose its collectible."
	)
	var remaining_player := Player.new()
	game.peer_players = {1: remaining_player}
	game.call("_prune_missing_fate_players")
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
	manager: TowerDefenseFateManager
) -> void:
	game.runtime_mode = GameRuntimeBase.RuntimeMode.CLIENT_VIEW
	game.fate_elite_bias_day = 4
	manager.state_revision = 10
	game.apply_remote_xiaocong_fate_state({"revision": 9, "elite_bias_day": 99})
	_expect(
		game.fate_elite_bias_day == 4,
		"A stale fate snapshot must not overwrite extra runtime values before rejection."
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
	var main_panel := overlay.get_node("Root/Center/Panel") as PanelContainer
	_expect(
		main_panel.custom_minimum_size.y <= 620.0,
		"The fate choice panel must fit inside the default 648px viewport with margin."
	)
	var state := {
		"active": true,
		"completed_day": 1,
		"stage": TowerDefenseFateManager.STAGE_VOTING,
		"eligible_peer_ids": [1, 2],
		"permanent_buff_offer": [],
		"available_permanent_buff_count": 9,
		"votes": {},
		"winning_option_index": -1,
		"winning_permanent_buff_id": 0,
		"pending_stone_peer_ids": [],
	}
	overlay.apply_state(state, 3, {})
	_expect(
		overlay.visible,
		"An active voting state must reveal the editor-hidden fate choice overlay."
	)
	_expect(
		"旁观" in overlay.status_label.text,
		"A late non-eligible peer must be told that it is observing this day."
	)
	var all_cards_disabled := true
	for card in overlay.choice_cards:
		all_cards_disabled = all_cards_disabled and card.button.disabled
	_expect(all_cards_disabled, "A non-eligible observer must not have clickable fate cards.")
	await create_timer(0.3).timeout
	_expect(overlay.show_tween == null, "The initial overlay tween must finish during setup.")
	overlay.apply_state(state, 3, {})
	_expect(
		overlay.show_tween == null,
		"A vote tally update in the same stage must not replay the show tween."
	)

	state["stage"] = TowerDefenseFateManager.STAGE_COLLECTIBLE_REWARD
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

	state["stage"] = TowerDefenseFateManager.STAGE_RESOLVING
	state["votes"] = {1: 3, 2: 3}
	state["winning_option_index"] = 3
	state["pending_stone_peer_ids"] = [1]
	overlay.apply_state(state, 1, {})
	_expect(
		overlay.layer == XiaocongFateChoiceOverlay.INVENTORY_ACCESS_CANVAS_LAYER,
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
	state["stage"] = TowerDefenseFateManager.STAGE_RESOLVED
	state["winning_option_index"] = 7
	state["winning_permanent_buff_id"] = 5
	state["pending_stone_peer_ids"] = []
	overlay.apply_state(state, 1, {})
	_expect(
		"史莱姆" in overlay.status_label.text,
		"Option 8 resolution text must name the random permanent buff actually awarded."
	)
	state["active"] = false
	overlay.apply_state(state, 1, {})
	_expect(
		not overlay.visible,
		"An inactive fate state must hide the overlay again."
	)
	await create_timer(0.3).timeout
	overlay.queue_free()
	await process_frame


func _begin_resolving_vote(
	manager: TowerDefenseFateManager,
	peer_ids: Array,
	option_index: int
) -> void:
	var typed_peer_ids: Array[int] = []
	for peer_id in peer_ids:
		typed_peer_ids.append(int(peer_id))
	manager.begin_interlude(1, &"next", typed_peer_ids)
	for peer_id in typed_peer_ids:
		manager.record_interaction(peer_id)
	for peer_id in typed_peer_ids:
		manager.submit_vote(peer_id, option_index, 0)
	_expect(
		manager.stage == TowerDefenseFateManager.STAGE_RESOLVING,
		"Test setup must reach RESOLVING."
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
