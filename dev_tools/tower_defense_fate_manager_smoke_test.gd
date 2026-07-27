extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var manager := TowerDefenseFateManager.new()
	root.add_child(manager)
	await process_frame
	_test_empty_interlude_finishes(manager)
	_test_waiting_disconnect(manager)
	_test_voting_disconnect(manager)
	_test_collectible_disconnect(manager)
	_test_last_peer_disconnect(manager)
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


func _test_empty_interlude_finishes(manager: TowerDefenseFateManager) -> void:
	manager.begin_interlude(1, &"next", _peers([]))
	_expect(
		not manager.active,
		"An interlude with no eligible players must finish immediately."
	)


func _test_waiting_disconnect(manager: TowerDefenseFateManager) -> void:
	manager.begin_interlude(1, &"next", _peers([1, 2]))
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
	manager.begin_interlude(2, &"next", _peers([1, 2, 3]))
	for peer_id in [1, 2, 3]:
		manager.record_interaction(peer_id)
	manager.submit_vote(1, 4, 0)
	manager.submit_vote(2, 4, 0)
	manager.remove_eligible_peer(3)
	_expect(
		manager.stage == TowerDefenseFateManager.STAGE_RESOLVING,
		"Removing the last missing voter must resolve the remaining votes."
	)
	_expect(manager.winning_option_index == 4, "Remaining majority vote must win.")
	manager.force_finish()


func _test_collectible_disconnect(manager: TowerDefenseFateManager) -> void:
	manager.begin_interlude(3, &"next", _peers([1, 2]))
	manager.record_interaction(1)
	manager.record_interaction(2)
	manager.submit_vote(1, 2, 0)
	manager.submit_vote(2, 2, 0)
	manager.begin_collectible_reward({1: ["a"], 2: ["b"]})
	manager.record_collectible_result(1, true, "done")
	manager.remove_eligible_peer(2)
	_expect(
		manager.stage == TowerDefenseFateManager.STAGE_RESOLVED,
		"Removing the last pending recipient must finalize collectible rewards."
	)
	manager.force_finish()


func _test_last_peer_disconnect(manager: TowerDefenseFateManager) -> void:
	manager.begin_interlude(4, &"next", _peers([1]))
	manager.remove_eligible_peer(1)
	_expect(not manager.active, "Removing the final eligible peer must end the interlude.")


func _peers(values: Array) -> Array[int]:
	var result: Array[int] = []
	for value in values:
		result.append(int(value))
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
