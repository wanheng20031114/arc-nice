extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var manager := TowerDefenseFateManager.new()
	root.add_child(manager)
	await process_frame
	_test_named_config_contract()
	_test_empty_interlude_finishes(manager)
	_test_authoritative_offer_contract(manager)
	_test_unoffered_vote_is_rejected(manager)
	_test_offer_order_survives_remote_state(manager)
	_test_empty_buff_pool_filters_options(manager)
	_test_tied_votes_follow_offer_order(manager)
	_test_waiting_disconnect(manager)
	_test_voting_disconnect(manager)
	_test_collectible_disconnect(manager)
	_test_last_peer_disconnect(manager)
	_test_host_timeout_recovery(manager)
	await create_timer(TowerDefenseFateManager.RESULT_DISPLAY_SECONDS + 0.1).timeout
	manager.queue_free()
	await process_frame
	if failures.is_empty():
		print("TOWER_DEFENSE_FATE_MANAGER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_named_config_contract() -> void:
	var options := TowerDefenseFateRegistry.get_all_option_configs()
	var buffs := TowerDefenseFateRegistry.get_all_permanent_buff_configs()
	_expect(
		TowerDefenseFateRegistry.is_valid_contract()
		and options.size() == 10
		and buffs.size() == 9,
		"The shared named fate registry must contain exactly 10 options and 9 buffs."
	)
	for config in options:
		_expect(
			not config.option_id.is_empty() and config.is_valid(),
			"Every fate option must have one valid named id."
		)
	for config in buffs:
		_expect(
			not config.buff_id.is_empty() and config.is_valid(),
			"Every permanent buff must have one valid named id."
		)


func _test_empty_interlude_finishes(manager: TowerDefenseFateManager) -> void:
	_begin(manager, 1, [])
	_expect(
		not manager.active,
		"An interlude with no eligible players must finish immediately."
	)


func _test_authoritative_offer_contract(
	manager: TowerDefenseFateManager
) -> void:
	manager.random_generator.seed = 7102026
	_begin(manager, 1, [1])
	var seen_option_ids: Dictionary = {}
	var all_options_are_registered := true
	for option_id in manager.available_option_ids:
		seen_option_ids[option_id] = true
		all_options_are_registered = (
			all_options_are_registered
			and TowerDefenseFateRegistry.get_option_config(option_id) != null
		)
	_expect(
		manager.available_option_ids.size()
		== TowerDefenseFateManager.FATE_OPTION_OFFER_COUNT,
		"Every fate round must authoritatively offer exactly three options."
	)
	_expect(
		seen_option_ids.size() == manager.available_option_ids.size(),
		"The authoritative option offer must not contain duplicates."
	)
	_expect(
		all_options_are_registered,
		"Every offered option must use a registered named fate id."
	)
	manager.force_finish()


func _test_unoffered_vote_is_rejected(
	manager: TowerDefenseFateManager
) -> void:
	_begin(manager, 1, [1])
	manager.record_interaction(1)
	var unoffered_option_id: StringName = &""
	for option_id in TowerDefenseFateRegistry.get_all_option_ids():
		if not manager.available_option_ids.has(option_id):
			unoffered_option_id = option_id
			break
	_expect(
		not unoffered_option_id.is_empty(),
		"The rejection fixture must find a registered option outside the offer."
	)
	_expect(
		not manager.submit_vote(1, unoffered_option_id, &""),
		"A registered option must be rejected when the host did not offer it."
	)
	_expect(
		manager.votes.is_empty()
		and manager.stage == TowerDefenseFateManager.STAGE_VOTING,
		"Rejecting an unoffered option must not record a vote or resolve."
	)
	manager.force_finish()


func _test_offer_order_survives_remote_state(
	manager: TowerDefenseFateManager
) -> void:
	_begin(manager, 1, [1])
	var host_offer := manager.available_option_ids.duplicate()
	var remote_manager := TowerDefenseFateManager.new()
	remote_manager.apply_remote_state(manager.export_state())
	_expect(
		remote_manager.available_option_ids == host_offer,
		"Exporting and applying fate state must preserve host offer order."
	)
	remote_manager.free()
	manager.force_finish()


func _test_empty_buff_pool_filters_options(
	manager: TowerDefenseFateManager
) -> void:
	manager.begin_interlude(
		1,
		&"next",
		_peers([1]),
		1,
		TowerDefenseFateRegistry.get_all_option_ids(),
		[]
	)
	var every_offer_is_usable := true
	for option_id in manager.available_option_ids:
		var config := TowerDefenseFateRegistry.get_option_config(option_id)
		every_offer_is_usable = (
			every_offer_is_usable
			and config != null
			and not config.requires_available_permanent_buff()
		)
	_expect(
		manager.available_option_ids.size()
		== TowerDefenseFateManager.FATE_OPTION_OFFER_COUNT
		and every_offer_is_usable,
		"An empty buff pool must still yield three immediately usable options."
	)
	manager.force_finish()


func _test_tied_votes_follow_offer_order(
	manager: TowerDefenseFateManager
) -> void:
	_begin(manager, 1, [1, 2])
	var first_option := manager.available_option_ids[0]
	var second_option := manager.available_option_ids[1]
	manager.record_interaction(1)
	manager.record_interaction(2)
	manager.submit_vote(1, first_option, &"")
	manager.submit_vote(2, second_option, &"")
	_expect(
		manager.stage == TowerDefenseFateManager.STAGE_RESOLVING
		and manager.winning_option_id == first_option,
		"A tied vote must resolve to the earliest option in host offer order."
	)
	manager.force_finish()


func _test_waiting_disconnect(manager: TowerDefenseFateManager) -> void:
	_begin(manager, 1, [1, 2])
	_expect(manager.record_interaction(1), "The first interaction must be accepted.")
	_expect(
		manager.remove_eligible_peer(2),
		"A disconnected eligible peer must be removed while waiting."
	)
	_expect(
		manager.stage == TowerDefenseFateManager.STAGE_VOTING,
		"Removing the only missing interaction must advance to voting."
	)
	manager.force_finish()


func _test_voting_disconnect(manager: TowerDefenseFateManager) -> void:
	_begin(manager, 2, [1, 2, 3])
	_set_offer(manager, [
		TowerDefenseFateRegistry.OPTION_XIRANG_GIFT,
		TowerDefenseFateRegistry.OPTION_BASE_REBUILD,
		TowerDefenseFateRegistry.OPTION_DASH_COOLDOWN,
	])
	for peer_id in [1, 2, 3]:
		manager.record_interaction(peer_id)
	manager.submit_vote(1, TowerDefenseFateRegistry.OPTION_XIRANG_GIFT, &"")
	manager.submit_vote(2, TowerDefenseFateRegistry.OPTION_XIRANG_GIFT, &"")
	manager.remove_eligible_peer(3)
	_expect(
		manager.stage == TowerDefenseFateManager.STAGE_RESOLVING,
		"Removing the last missing voter must resolve the remaining votes."
	)
	_expect(
		manager.winning_option_id == TowerDefenseFateRegistry.OPTION_XIRANG_GIFT,
		"The remaining named majority vote must win."
	)
	manager.force_finish()


func _test_collectible_disconnect(manager: TowerDefenseFateManager) -> void:
	_begin(manager, 3, [1, 2])
	_set_offer(manager, [
		TowerDefenseFateRegistry.OPTION_COLLECTIBLE_REWARD,
		TowerDefenseFateRegistry.OPTION_BASE_REBUILD,
		TowerDefenseFateRegistry.OPTION_DASH_COOLDOWN,
	])
	manager.record_interaction(1)
	manager.record_interaction(2)
	manager.submit_vote(1, TowerDefenseFateRegistry.OPTION_COLLECTIBLE_REWARD, &"")
	manager.submit_vote(2, TowerDefenseFateRegistry.OPTION_COLLECTIBLE_REWARD, &"")
	manager.begin_collectible_reward({1: ["a"], 2: ["b"]})
	manager.record_collectible_result(1, true, "done")
	manager.remove_eligible_peer(2)
	_expect(
		manager.stage == TowerDefenseFateManager.STAGE_RESOLVED,
		"Removing the last pending recipient must finalize collectible rewards."
	)
	manager.force_finish()


func _test_last_peer_disconnect(manager: TowerDefenseFateManager) -> void:
	_begin(manager, 4, [1])
	manager.remove_eligible_peer(1)
	_expect(not manager.active, "Removing the final eligible peer must end the interlude.")


func _test_host_timeout_recovery(manager: TowerDefenseFateManager) -> void:
	_begin(manager, 5, [1, 2], 1)
	_set_offer(manager, [
		TowerDefenseFateRegistry.OPTION_BASE_REBUILD,
		TowerDefenseFateRegistry.OPTION_DASH_COOLDOWN,
		TowerDefenseFateRegistry.OPTION_XIRANG_GIFT,
	])
	manager.record_interaction(1)
	manager.advance_stage_timeout(999.0)
	_expect(
		manager.stage == TowerDefenseFateManager.STAGE_WAIT_INTERACTIONS
		and manager.timeout_recovery_available,
		"Missing online players must still block interaction until timeout recovery."
	)
	_expect(
		not manager.request_timeout_recovery(2)
		and manager.request_timeout_recovery(1)
		and manager.stage == TowerDefenseFateManager.STAGE_VOTING,
		"Only the configured host may recover the timed-out interaction stage."
	)
	manager.submit_vote(1, TowerDefenseFateRegistry.OPTION_BASE_REBUILD, &"")
	manager.advance_stage_timeout(999.0)
	_expect(
		manager.request_timeout_recovery(1)
		and manager.stage == TowerDefenseFateManager.STAGE_RESOLVING
		and manager.votes.size() == 2
		and manager.winning_option_id == TowerDefenseFateRegistry.OPTION_BASE_REBUILD,
		"Host timeout recovery must fill missing votes deterministically from the host vote."
	)
	manager.force_finish()


func _begin(
	manager: TowerDefenseFateManager,
	day_number: int,
	peer_values: Array,
	host_peer_id: int = 1
) -> void:
	manager.begin_interlude(
		day_number,
		&"next",
		_peers(peer_values),
		host_peer_id,
		TowerDefenseFateRegistry.get_all_option_ids(),
		TowerDefenseFateRegistry.get_all_permanent_buff_ids()
	)


func _set_offer(
	manager: TowerDefenseFateManager,
	option_ids: Array[StringName]
) -> void:
	manager.available_option_ids = option_ids.duplicate()


func _peers(values: Array) -> Array[int]:
	var result: Array[int] = []
	for value in values:
		result.append(int(value))
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
