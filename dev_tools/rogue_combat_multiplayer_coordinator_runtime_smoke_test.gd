extends SceneTree

## 多人 Rouge 作战协调器运行态 smoke。
##
## 单进程 SceneTree 无法伪造 MultiplayerAPI.get_remote_sender_id()，因此本测试
## 不直接调用客户端 RPC 入口，而是驱动相同的房主本地权威分支与真实状态机方法。
## 仅替换 MpGame 的创建结果，避免在单元测试里启动完整联网战场。

const COORDINATOR := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_multiplayer_coordinator.gd"
)
const ROUTE_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)
const FAKE_EMBEDDED_RUNTIME := preload(
	"res://dev_tools/fixtures/rogue_combat_multiplayer_test_session.tscn"
)
const WOOD_MATERIAL: PickupConfig = preload(
	"res://resources/config/materials/material_wood.tres"
)
const FORMAL_CONFIG: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/encounter_01.tres"
)
const SUITCASE_CONFIG: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/suitcase_battle.tres"
)
const EMERGENCY_CONFIG: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/emergency_narrow_road_01.tres"
)


class FakeNetManager extends NetManagerStore:
	var send_ready_peer_ids: Dictionary = {}
	var reconnect_delivery_preparing_peer_ids: Dictionary = {}
	var reconnecting_peer_ids: Dictionary = {}
	var participant_incarnations: Dictionary = {}
	var gameplay_ingress_admitted := true
	var host_role := true
	var local_peer_id := 1
	var runtime_projection_reports: Array[Dictionary] = []
	var terminated_projection_peers: Array[int] = []
	var terminated_membership_projection_reasons: Array[String] = []
	var accepted_projection_outcomes: Dictionary = {}

	func is_host() -> bool:
		return host_role

	func is_client() -> bool:
		return not host_role

	func get_host_peer_id() -> int:
		return 1

	func get_local_peer_id() -> int:
		return local_peer_id

	func is_peer_send_ready(peer_id: int) -> bool:
		return send_ready_peer_ids.has(peer_id)

	func is_reconnect_delivery_preparing(peer_id: int) -> bool:
		return reconnect_delivery_preparing_peer_ids.has(peer_id)

	func is_session_member_reconnecting(peer_id: int) -> bool:
		return reconnecting_peer_ids.has(peer_id)

	func get_session_participant_incarnation(peer_id: int) -> int:
		return int(participant_incarnations.get(peer_id, peer_id))

	func is_gameplay_ingress_admitted(_peer_id: int) -> bool:
		return gameplay_ingress_admitted

	func report_reconnected_runtime_projection(
		old_peer_id: int,
		new_peer_id: int,
		outcome: MultiplayerReconnectTypesScript.RuntimeProjectionOutcome
	) -> bool:
		if accepted_projection_outcomes.has(new_peer_id):
			return (
				int(accepted_projection_outcomes[new_peer_id]) == int(outcome)
			)
		accepted_projection_outcomes[new_peer_id] = int(outcome)
		runtime_projection_reports.append({
			"old_peer_id": old_peer_id,
			"new_peer_id": new_peer_id,
			"outcome": int(outcome),
		})
		return true

	func terminate_for_runtime_projection_failure(
		peer_id: int,
		_reason: String
	) -> bool:
		terminated_projection_peers.append(peer_id)
		return true

	func terminate_for_session_membership_projection_failure(
		reason: String
	) -> bool:
		terminated_membership_projection_reasons.append(reason)
		return true


class RewardCombatGameHarness extends RogueCombatGame:
	var fixture_players: Dictionary = {}

	func get_player_for_peer(peer_id: int) -> Player:
		return fixture_players.get(peer_id) as Player


class RuntimeCoordinatorHarness extends RogueCombatMultiplayerCoordinator:
	var create_runtime_result := true
	var terminal_spectator_dispatches: Array[Dictionary] = []
	var host_settlement_commit_result := true
	var host_settlement_commit_uses_super := false
	var host_settlement_commit_observations: Array[Dictionary] = []
	var host_settlement_broadcasts: Array[Dictionary] = []
	var settlement_event_order: Array[String] = []
	var reconnect_prepare_dispatches: Array[Dictionary] = []

	func _create_embedded_runtime() -> bool:
		return create_runtime_result

	func _freeze_participant_reward_identities() -> bool:
		_participant_character_ids.clear()
		_participant_stable_keys.clear()
		_last_combat_xirang_by_peer.clear()
		for peer_id_variant in _participant_peer_ids.keys():
			var peer_id := int(peer_id_variant)
			_participant_character_ids[peer_id] = &"weishidaier"
			_participant_stable_keys[peer_id] = "runtime-fixture:%d" % peer_id
			_last_combat_xirang_by_peer[peer_id] = int(
				_entry_xirang_by_peer.get(peer_id, 0)
			)
		return not _participant_peer_ids.is_empty()

	func _dispatch_terminal_spectator_sync(
		peer_id: int,
		occurrence_key: String,
		settlement: Dictionary,
		include_route_spectator: bool = true
	) -> void:
		settlement_event_order.append("spectator:%d" % peer_id)
		terminal_spectator_dispatches.append({
			"peer_id": peer_id,
			"occurrence_key": occurrence_key,
			"settlement": settlement.duplicate(true),
			"include_route_spectator": include_route_spectator,
		})

	func _commit_host_settlement_locally(settlement: Dictionary) -> bool:
		var occurrence_key := str(settlement.get("occurrence_key", ""))
		host_settlement_commit_observations.append({
			"occurrence_key": occurrence_key,
			"tombstone_present": _settled_occurrences.has(occurrence_key),
			"broadcast_count": host_settlement_broadcasts.size(),
			"settlement": settlement.duplicate(true),
		})
		if host_settlement_commit_uses_super:
			return super._commit_host_settlement_locally(settlement)
		return host_settlement_commit_result

	func _broadcast_authoritative_settlement(
		occurrence_key: String,
		settlement: Dictionary
	) -> void:
		settlement_event_order.append("broadcast")
		host_settlement_broadcasts.append({
			"occurrence_key": occurrence_key,
			"settlement": settlement.duplicate(true),
			"tombstone_present": _settled_occurrences.has(occurrence_key),
		})

	func _dispatch_reconnected_combat_prepare(
		new_peer_id: int,
		activate_immediately: bool
	) -> void:
		reconnect_prepare_dispatches.append({
			"peer_id": new_peer_id,
			"activate_immediately": activate_immediately,
			"occurrence_key": _active_occurrence_key,
		})


var _failures: PackedStringArray = []
var _fixture_root: Node2D = null
var _route: RogueRouteGame = null
var _coordinator: RuntimeCoordinatorHarness = null
var _fake_net_manager: FakeNetManager = null


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await _create_fixture()
	if "--projection-order-only" in OS.get_cmdline_user_args():
		_test_route_first_reconnect_waits_for_player_projection()
		_test_pending_reconnect_projection_survives_phase_change()
		_test_reconnect_prepare_waits_for_post_ready_lease()
		_test_standalone_projection_owner_reports_once()
		_test_canonical_peer_survives_failed_two_hop_reconnect()
		_test_projection_outcome_cas_conflicts()
		_test_client_failed_projection_fails_closed()
		_test_stale_outcome_first_is_rejected()
		await _destroy_fixture()
		if _failures.is_empty():
			print("ROGUE_RECONNECT_PROJECTION_ORDER_SMOKE_TEST_OK")
			quit(0)
			return
		for failure in _failures:
			push_error(failure)
		quit(1)
		return
	_test_prepare_requires_route_resolved_config()
	_test_terminal_safe_releases_protocol_but_keeps_result()
	_test_next_prepare_collects_stale_result()
	_test_new_layout_clears_combat_idempotency_caches()
	_test_host_settlement_commit_gates_broadcast()
	_test_pending_reconnect_is_spectator_before_settlement_broadcast()
	_test_late_activation_cannot_rewind_settled_phase()
	_test_emergency_reward_snapshot_is_peer_private()
	_test_completed_emergency_choice_can_disconnect_and_remap()
	_test_ready_emergency_choice_can_disconnect_and_remap()
	_test_emergency_disconnect_forfeit_and_reward_commit()
	_test_emergency_reconnect_reward_rollback_state_remaps()
	await _test_real_reward_mutation_rolls_back_after_commit_failure()
	await _test_disconnected_original_participant_receives_victory_rewards()
	_test_player_left_preserves_participant_and_shrinks_barriers()
	_test_client_abort_admission_is_prepare_only()
	_test_reconnect_prepare_marker_lifecycle()
	_test_route_first_reconnect_waits_for_player_projection()
	_test_pending_reconnect_projection_survives_phase_change()
	_test_reconnect_prepare_waits_for_post_ready_lease()
	_test_standalone_projection_owner_reports_once()
	_test_canonical_peer_survives_failed_two_hop_reconnect()
	_test_projection_outcome_cas_conflicts()
	_test_client_failed_projection_fails_closed()
	_test_stale_outcome_first_is_rejected()
	_test_prepare_barrier_timeout_aborts_entry()
	_test_reconnect_activation_timeout_downgrades_peer()
	_test_terminal_spectator_sync_retries_send_ready()
	_test_terminal_barrier_timeout_forces_safe_release()
	_test_reconnect_remaps_terminal_settlement()
	_test_host_missing_reconnect_runtime_becomes_spectator()
	_test_active_reconnect_spectator_receives_later_settlement()
	_test_precombat_disconnect_reconnect_stays_route_spectator()
	_test_route_spectator_settlement_converges_economy()
	await _test_prepared_barrier_reveals_before_single_activation()
	_test_dispatch_window_reconnect_skips_completed_barrier()
	await _test_abort_during_entry_reveal_clears_cover()
	await _test_route_reset_aborts_terminal_sequence()
	_test_authoritative_prepare_failure_aborts_safely()
	_test_authoritative_config_failure_aborts_safely()
	await _test_authoritative_activation_failure_aborts_safely()
	await _destroy_fixture()

	if _failures.is_empty():
		print("ROGUE_COMBAT_MULTIPLAYER_COORDINATOR_RUNTIME_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_prepare_requires_route_resolved_config() -> void:
	_reset_fixture_state()
	var participants := PackedInt32Array([1])
	var entry_xirang := {1: 500}
	_expect(
		not _coordinator._begin_protocol(
			90,
			9001,
			"combat:runtime:missing-config:90",
			participants,
			entry_xirang,
			false,
			&"",
			null
		),
		"多人 prepare 缺少路线解析配置时必须拒绝，不能回退到默认作战。"
	)
	_expect(
		not _coordinator._begin_protocol(
			91,
			9101,
			"combat:runtime:mismatched-config:91",
			participants,
			entry_xirang,
			false,
			&"underground_church_01",
			FORMAL_CONFIG
		),
		"多人 prepare 的配置 ID 与已解析资源不一致时必须拒绝。"
	)
	_expect(
		_coordinator._phase == COORDINATOR.ProtocolPhase.IDLE
		and _coordinator._active_encounter_config == null,
		"被拒绝的配置不得冻结协议状态。"
	)


func _configure_emergency_reward_fixture(
	peer_ids: Array[int],
	occurrence_key: String = "emergency:runtime:reward:1"
) -> RogueEmergencyRewardSelectionSession:
	_reset_fixture_state()
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	_coordinator._phase = COORDINATOR.ProtocolPhase.REWARD_SELECTING
	_coordinator._active_node_id = 91
	_coordinator._active_content_seed = 910_027
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._active_combat_config_id = EMERGENCY_CONFIG.encounter_id
	_coordinator._active_encounter_config = EMERGENCY_CONFIG
	_coordinator._participant_peer_ids.clear()
	_coordinator._participant_stable_keys.clear()
	_coordinator._participant_character_ids.clear()
	_coordinator._entry_xirang_by_peer.clear()
	_coordinator._last_combat_xirang_by_peer.clear()
	var stable_keys: Dictionary = {}
	var character_ids: Dictionary = {}
	var base_xirang: Dictionary = {}
	for peer_id in peer_ids:
		run_state.register_multiplayer_peer_state(peer_id)
		_coordinator._participant_peer_ids[peer_id] = true
		stable_keys[peer_id] = "emergency-fixture:%d" % peer_id
		character_ids[peer_id] = &"weishidaier"
		base_xirang[peer_id] = 700 + peer_id
		_coordinator._participant_stable_keys[peer_id] = stable_keys[peer_id]
		_coordinator._participant_character_ids[peer_id] = character_ids[peer_id]
		_coordinator._entry_xirang_by_peer[peer_id] = base_xirang[peer_id]
		_coordinator._last_combat_xirang_by_peer[peer_id] = base_xirang[peer_id]
	var session := RogueEmergencyRewardSelectionSession.new()
	_expect(
		session.begin_authority(
			run_state,
			StringName(occurrence_key),
			_coordinator._active_content_seed,
			peer_ids,
			EMERGENCY_CONFIG.reward_config,
			false,
			stable_keys,
			character_ids,
			base_xirang
		),
		"紧急多人奖励 fixture 必须能建立权威选择会话。"
	)
	_coordinator._emergency_reward_session = session
	_coordinator._emergency_reward_rollback_state = (
		_coordinator._capture_host_reward_rollback_state()
	)
	_coordinator._emergency_reward_completion_retry_requested = false
	return session


func _test_emergency_reward_snapshot_is_peer_private() -> void:
	var session := _configure_emergency_reward_fixture([1, 2])
	var peer_one_projection := _coordinator._build_emergency_reward_projection(1)
	var peer_two_projection := _coordinator._build_emergency_reward_projection(2)
	_expect(
		COORDINATOR.ProtocolPhase.REWARD_SELECTING
		!= COORDINATOR.ProtocolPhase.ACTIVE,
		"紧急奖励选择必须有独立协议阶段，不能复用 ACTIVE。"
	)
	_expect(
		not peer_one_projection.has("participants")
		and not peer_one_projection.has("offers_by_peer")
		and int((peer_one_projection.get(
			"local_participant",
			{}
		) as Dictionary).get("peer_id", -1)) == 1,
		"发给 peer1 的投影只能包含 peer1 候选，不能泄露全队 participant。"
	)
	_expect(
		not peer_two_projection.has("participants")
		and int((peer_two_projection.get(
			"local_participant",
			{}
		) as Dictionary).get("peer_id", -1)) == 2,
		"发给 peer2 的投影只能包含 peer2 本地候选。"
	)
	var peer_one_offers := (
		(peer_one_projection["local_participant"] as Dictionary).get(
			"current_offer_paths",
			[]
		) as Array
	)
	var peer_two_offers := (
		(peer_two_projection["local_participant"] as Dictionary).get(
			"current_offer_paths",
			[]
		) as Array
	)
	_expect(
		peer_one_offers.size() == 2 and peer_two_offers.size() == 2,
		"每个客户端投影都必须恰有本轮两个候选。"
	)
	var before_revision := session.get_revision()
	var stale_client_revision := before_revision
	session.advance(1.0)
	_coordinator._handle_emergency_reward_choice_request(
		1,
		stale_client_revision,
		0,
		0
	)
	_expect(
		int(session.get_peer_state(1).get("round_index", 0)) == 1,
		"其他玩家倒计时引发全局 revision 推进后，旧但非未来的合法点击仍须接受。"
	)
	session.advance(29.0)
	_expect(
		session.get_revision() > before_revision
		and int(session.get_peer_state(1).get("round_index", 0)) == 1
		and int(session.get_peer_state(2).get("round_index", 0)) == 1,
		"房主推进30秒必须为尚未选择的在线玩家执行确定性超时选择。"
	)
	_coordinator._reset_emergency_reward_selection()
	_expect(
		_coordinator._emergency_reward_session == null
		and _coordinator._emergency_reward_client_snapshot.is_empty()
		and not _route.emergency_reward_choice_overlay.visible,
		"协议 reset 必须清理紧急奖励会话、客户端投影与 Overlay。"
	)


func _test_emergency_disconnect_forfeit_and_reward_commit() -> void:
	var occurrence_key := "emergency:runtime:disconnect:2"
	var session := _configure_emergency_reward_fixture([1, 2], occurrence_key)
	var run_state := root.get_node("RunState") as RunStateStore
	_coordinator._disconnected_participants[2] = {
		"entry_xirang": 702,
		"last_combat_xirang": 702,
	}
	_expect(
		session.mark_peer_disconnected(2, occurrence_key),
		"选择阶段断线必须立即把玩家标记为 forfeit。"
	)
	_expect(
		run_state.remap_multiplayer_peer_state(
			2,
			3,
			run_state.get_multiplayer_session_membership_revision() + 1
		) == RunStateStore.MultiplayerPeerRemapResult.MIGRATED
		and session.remap_disconnected_peer(2, 3),
		"断线玩家重连必须先提交持久账本身份，再迁移最终基础奖励投递 peer。"
	)
	var remapped_state := session.get_peer_state(3)
	_expect(
		bool(remapped_state.get("completed", false))
		and bool(remapped_state.get("disconnected", false))
		and (remapped_state.get("selected_paths", []) as Array).is_empty(),
		"重连后的 forfeit 状态必须保持完成且无收藏品，不能重新开放补选。"
	)
	# 同步 coordinator 的 canonical peer 映射，模拟正式重连 old -> new。
	_coordinator._participant_peer_ids.erase(2)
	_coordinator._participant_peer_ids[3] = true
	for peer_map in [
		_coordinator._participant_stable_keys,
		_coordinator._participant_character_ids,
		_coordinator._entry_xirang_by_peer,
		_coordinator._last_combat_xirang_by_peer,
	]:
		peer_map[3] = peer_map[2]
		peer_map.erase(2)
	_coordinator._disconnected_participants.erase(2)
	_coordinator._disconnected_participants[3] = true
	for round_index in range(2):
		var choice := session.submit_choice(
			1,
			occurrence_key,
			round_index,
			0
		)
		_expect(
			bool(choice.get("accepted", false)),
			"在线玩家第%d轮选择应被房主接受。" % (round_index + 1)
		)
	_expect(
		session.is_ready_to_settle(),
		"只应等待在线玩家；forfeit 玩家不得阻塞全队结算。"
	)
	var light_before := (
		(root.get_node("RunState") as RunStateStore).get_party_light_stone_amount()
	)
	_coordinator.host_settlement_commit_uses_super = true
	_coordinator._emergency_reward_completion_retry_requested = true
	_coordinator._local_outcome_received = true
	_coordinator._local_outcome_victory = true
	_coordinator._try_complete_host_emergency_rewards()
	var settlement := (
		_coordinator.host_settlement_broadcasts.back().get(
			"settlement",
			{}
		) as Dictionary
		if not _coordinator.host_settlement_broadcasts.is_empty()
		else {}
	)
	var results := settlement.get("results_by_peer", {}) as Dictionary
	var xirang := settlement.get("final_xirang_by_peer", {}) as Dictionary
	var result_one := results.get(1, {}) as Dictionary
	var result_three := results.get(3, {}) as Dictionary
	_expect(
		_coordinator._phase == COORDINATOR.ProtocolPhase.SETTLED,
		"紧急选择完成后必须进入既有 SETTLED 终局协议。"
	)
	_expect(
		int(result_one.get("extra_xirang", 0))
		== int(result_three.get("extra_xirang", -1))
		and int(xirang.get(1, 0)) - 701 == int(xirang.get(3, 0)) - 702,
		"所有原参战者（含 forfeit 重连者）必须获得同一个整百息壤数。"
	)
	_expect(
		(result_one.get("item_rewards", []) as Array).size() == 3
		and (result_three.get("item_rewards", []) as Array).is_empty()
		and bool(result_three.get("reward_selection_forfeited", false)),
		"在线玩家获得两收藏品与资源；forfeit 玩家放弃尚未入包的全部物品。"
	)
	_expect(
		int(result_one.get("shared_light_stone_reward", 0)) == 1
		and int(result_three.get("shared_light_stone_reward", 0)) == 1
		and (root.get_node("RunState") as RunStateStore)
		.get_party_light_stone_amount() == light_before + 1,
		"settlement 顶层同步光石 ledger，并且全队共享光石只增加一次。"
	)


func _test_emergency_reconnect_reward_rollback_state_remaps() -> void:
	var occurrence_key := "emergency:runtime:reconnect-rollback:5"
	var session := _configure_emergency_reward_fixture([1, 2], occurrence_key)
	var run_state := root.get_node("RunState") as RunStateStore
	var inventory_one_before := run_state.export_inventory_snapshot_for_peer(1)
	var inventory_two_before := run_state.export_inventory_snapshot_for_peer(2)
	var light_before := run_state.get_party_light_stone_amount()
	var light_revision_before := run_state.get_party_light_stone_ledger_revision()
	_coordinator._disconnected_participants[2] = {
		"entry_xirang": 702,
		"last_combat_xirang": 702,
	}
	_expect(
		session.mark_peer_disconnected(2, occurrence_key)
		and run_state.remap_multiplayer_peer_state(
			2,
			3,
			run_state.get_multiplayer_session_membership_revision() + 1
		) == RunStateStore.MultiplayerPeerRemapResult.MIGRATED
		and session.remap_disconnected_peer(2, 3),
		"奖励阶段重连夹具必须先迁移会话与 RunState 身份。"
	)
	_coordinator._remap_reconnected_participant_identity(2, 3)
	var rollback_snapshots := (
		_coordinator._emergency_reward_rollback_state.get(
			"inventory_snapshots_by_peer",
			{}
		) as Dictionary
	)
	_expect(
		rollback_snapshots.has(3)
		and not rollback_snapshots.has(2)
		and int((rollback_snapshots[3] as Dictionary).get("peer_id", -1)) == 3,
		"紧急奖励回滚背包快照必须随 old→new peer 同步迁移。"
	)
	for round_index in range(2):
		_expect(
			bool(session.submit_choice(
				1,
				occurrence_key,
				round_index,
				0
			).get("accepted", false)),
			"在线玩家应完成第%d轮选择。" % (round_index + 1)
		)
	var reward_batch := session.complete_rewards() as Dictionary
	_expect(
		bool(reward_batch.get("resolved", false))
		and run_state.get_party_light_stone_amount() == light_before + 1,
		"失败注入前必须已真实完成紧急奖励 CAS。"
	)
	var settlement := {
		"node_id": _coordinator._active_node_id,
		"content_seed": _coordinator._active_content_seed,
		"occurrence_key": occurrence_key,
		"victory": true,
		"failure_reason": "",
		"consume_node": true,
		"final_xirang_by_peer": reward_batch.get("final_xirang_by_peer", {}),
		"inventory_snapshots_by_peer": reward_batch.get(
			"inventory_snapshots_by_peer",
			{}
		),
		"results_by_peer": reward_batch.get("results_by_peer", {}),
		"light_stone_ledger": reward_batch.get("light_stone_ledger", {}),
	}
	_coordinator.host_settlement_commit_result = false
	_expect(
		not _coordinator._publish_host_settlement(
			occurrence_key,
			settlement,
			_coordinator._emergency_reward_rollback_state
		),
		"奖励 CAS 后注入的终局提交失败必须拒绝发布并触发回滚。"
	)
	var inventory_one_after := run_state.export_inventory_snapshot_for_peer(1)
	var inventory_three_after := run_state.export_inventory_snapshot_for_peer(3)
	_expect(
		_inventory_contents(inventory_one_after)
		== _inventory_contents(inventory_one_before)
		and _inventory_contents(inventory_three_after)
		== _inventory_contents(inventory_two_before),
		"终局提交失败后必须按重连后的 peer 完整恢复奖励前背包内容。"
	)
	_expect(
		run_state.get_party_xirang_balance(1) == 0
		and run_state.get_party_xirang_balance(3) == 0
		and run_state.get_party_light_stone_amount() == light_before
		and run_state.get_party_light_stone_ledger_revision()
		> light_revision_before,
		"终局提交失败后必须恢复两名玩家息壤与共享光石，并保持 revision 单调。"
	)
	_expect(
		_coordinator._phase == COORDINATOR.ProtocolPhase.REWARD_SELECTING
		and _coordinator._active_occurrence_key == occurrence_key
		and _coordinator.host_settlement_broadcasts.is_empty(),
		"重连后的奖励回滚成功时不得广播失败结算；激活战斗必须留在屏障内等待可靠重试。"
	)


func _test_completed_emergency_choice_can_disconnect_and_remap() -> void:
	var occurrence_key := "emergency:runtime:completed-disconnect:3"
	var session := _configure_emergency_reward_fixture([1, 2], occurrence_key)
	var run_state := root.get_node("RunState") as RunStateStore
	for round_index in range(2):
		_expect(
			bool(session.submit_choice(
				2,
				occurrence_key,
				round_index,
				0
			).get("accepted", false)),
			"已先完成的 peer2 两轮选择必须可提交。"
		)
	_expect(
		not session.is_ready_to_settle(),
		"peer2 完成后仍须等待在线 peer1。"
	)
	var selected_before := (
		session.get_peer_state(2).get("selected_paths", []) as Array
	).duplicate()
	_expect(
		session.mark_peer_disconnected(2, occurrence_key)
		and run_state.remap_multiplayer_peer_state(
			2,
			4,
			run_state.get_multiplayer_session_membership_revision() + 1
		) == RunStateStore.MultiplayerPeerRemapResult.MIGRATED
		and session.remap_disconnected_peer(2, 4),
		"已完成选择但仍在等待时断线，也必须能迁移到重连 peer。"
	)
	var remapped := session.get_peer_state(4)
	_expect(
		bool(remapped.get("disconnected", false))
		and bool(remapped.get("completed", false))
		and (remapped.get("selected_paths", []) as Array) == selected_before,
		"已完成玩家断线重连不得重开选择，也不得丢失已锁定选择。"
	)
	_coordinator._reset_emergency_reward_selection()


func _test_ready_emergency_choice_can_disconnect_and_remap() -> void:
	var occurrence_key := "emergency:runtime:ready-disconnect:4"
	var session := _configure_emergency_reward_fixture([1], occurrence_key)
	var run_state := root.get_node("RunState") as RunStateStore
	for round_index in range(2):
		_expect(
			bool(session.submit_choice(
				1,
				occurrence_key,
				round_index,
				0
			).get("accepted", false)),
			"单一玩家两轮选择必须完成。"
		)
	_expect(session.is_ready_to_settle(), "全员完成后会话必须进入 READY。")
	_expect(
		session.mark_peer_disconnected(1, occurrence_key)
		and run_state.remap_multiplayer_peer_state(
			1,
			5,
			run_state.get_multiplayer_session_membership_revision() + 1
		) == RunStateStore.MultiplayerPeerRemapResult.MIGRATED
		and session.remap_disconnected_peer(1, 5),
		"READY 与最终 CAS 之间断线仍必须能标记并迁移基础奖励投递 peer。"
	)
	_expect(
		session.is_ready_to_settle()
		and bool(session.get_peer_state(5).get("disconnected", false)),
		"READY 断线迁移不得重开选择或改变 ready 阶段。"
	)
	_coordinator._reset_emergency_reward_selection()
func _create_fixture() -> void:
	_fixture_root = Node2D.new()
	_fixture_root.name = "RogueCombatCoordinatorRuntimeFixture"
	_route = ROUTE_SCENE.instantiate() as RogueRouteGame
	_route.name = "RogueRoute"
	_route.auto_initialize = false
	_route.manage_return_locally = false
	_coordinator = RuntimeCoordinatorHarness.new()
	_coordinator.name = "RogueCombatCoordinator"
	_fake_net_manager = FakeNetManager.new()
	_fake_net_manager.name = "FakeNetManager"
	_fixture_root.add_child(_route)
	_fixture_root.add_child(_coordinator)
	_fixture_root.add_child(_fake_net_manager)
	root.add_child(_fixture_root)
	await process_frame

	_coordinator.bind_network_dependencies(
		_route,
		_fake_net_manager,
		root.get_node("RunState") as RunStateStore,
		RogueCombatMultiplayerCoordinator.SessionProjectionOwner.THIS_COORDINATOR
	)
	_expect(
		FORMAL_CONFIG.is_ready_to_enable(),
		"普通作战池中的 encounter_01 配置应处于已确认、可启用状态。"
	)
	_expect(
		_coordinator.is_enabled(),
		"运行态 fixture 中多人协调器应启用。"
	)


func _destroy_fixture() -> void:
	if _fixture_root != null and is_instance_valid(_fixture_root):
		_fixture_root.queue_free()
	await process_frame
	_fixture_root = null
	_route = null
	_coordinator = null
	_fake_net_manager = null


func _test_terminal_safe_releases_protocol_but_keeps_result() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:terminal-safe:1"
	_seed_route_combat(11, 1101, occurrence_key)
	_route.set_route_presentation_enabled(false)
	_route.show_combat_result({
		"victory": false,
		"failure_reason": "测试结算仍打开",
	})

	_coordinator._phase = COORDINATOR.ProtocolPhase.SETTLED
	_coordinator._active_node_id = 11
	_coordinator._active_content_seed = 1101
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true}
	_coordinator._settlement_received = true
	_coordinator._local_terminal_finalized = true
	_coordinator._local_result_visible = true
	_coordinator._local_result_occurrence_key = occurrence_key
	_coordinator._local_result_participant_peer_ids = {1: true}
	var runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	runtime.name = "TerminalRuntime"
	_coordinator.add_child(runtime)
	_coordinator._combat_network = runtime

	_coordinator._receive_safe_to_teardown(occurrence_key)

	_expect(
		_coordinator._phase == COORDINATOR.ProtocolPhase.IDLE,
		"terminal safe 后协议 phase 必须立即回到 IDLE。"
	)
	_expect(
		_coordinator._combat_network == null,
		"terminal safe 后必须释放本地战场引用。"
	)
	_expect(
		_coordinator._local_result_occurrence_key == occurrence_key,
		"释放协议运行时不得清除独立的结算 occurrence。"
	)
	_expect(
		_coordinator._local_result_visible
		and _route.combat_result_overlay.visible,
		"某位玩家尚未关闭时，terminal safe 不得关闭其结算 Overlay。"
	)
	_expect(
		_route.is_normal_combat_active(),
		"结果仍打开时路线作战阶段应继续由独立结果生命周期持有。"
	)


func _test_next_prepare_collects_stale_result() -> void:
	var old_occurrence_key := _coordinator._local_result_occurrence_key
	var new_occurrence_key := "combat:runtime:next-prepare:2"
	_coordinator.create_runtime_result = true
	var began := _coordinator._begin_protocol(
		12,
		1202,
		new_occurrence_key,
		PackedInt32Array([1]),
		{1: 450},
		false,
		FORMAL_CONFIG.encounter_id,
		FORMAL_CONFIG
	)

	_expect(began, "下一次 prepare 应能启动新的协议 occurrence。")
	_expect(
		_coordinator._phase == COORDINATOR.ProtocolPhase.PREPARING
		and _coordinator._active_occurrence_key == new_occurrence_key,
		"下一次 prepare 应进入新 occurrence 的 PREPARING。"
	)
	_expect(
		_coordinator._local_result_occurrence_key.is_empty()
		and not _coordinator._local_result_visible,
		"下一次 prepare 必须自动清理旧结算生命周期。"
	)
	_expect(
		not _route.combat_result_overlay.visible,
		"下一次 prepare 必须自动收起仍打开的旧结算 Overlay。"
	)
	_expect(
		not _route.is_normal_combat_active(),
		"自动收旧结果时必须用旧 occurrence 完成上一场路线阶段。"
	)
	_expect(
		old_occurrence_key == "combat:runtime:terminal-safe:1",
		"测试前置应保留上一场独立 occurrence，而非被协议 reset 清空。"
	)
	_coordinator._abort_authoritative_protocol(&"test_cleanup")


func _test_new_layout_clears_combat_idempotency_caches() -> void:
	_reset_fixture_state()
	_coordinator._consumed_node_ids[17] = true
	_coordinator._settled_occurrences["combat:old-layout:17:1"] = true
	_coordinator._on_host_layout_committed({}, {})
	_expect(
		_coordinator._consumed_node_ids.is_empty()
		and _coordinator._settled_occurrences.is_empty(),
		(
			"新路线布局提交时必须同时清理节点消费与 occurrence 结算幂等缓存，"
			+ "避免确定性 key 在下一局被误判为已结算。"
		)
	)


func _test_host_settlement_commit_gates_broadcast() -> void:
	_reset_fixture_state()
	const NODE_ID := 18
	var occurrence_key := "combat:runtime:settlement-commit-gate:2c"
	var settlement := {
		"occurrence_key": occurrence_key,
		"victory": true,
	}
	_seed_route_combat(NODE_ID, 1802, occurrence_key)
	_route.set_route_presentation_enabled(false)
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_node_id = NODE_ID
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._expected_prepared_peers = {1: true, 2: true}
	_coordinator._prepared_peers = {1: true, 2: true}
	_coordinator._expected_terminal_peers = {1: true, 2: true}
	_coordinator._settlement_scheduled = true
	var runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	_coordinator.add_child(runtime)
	_coordinator._combat_network = runtime
	_coordinator.host_settlement_commit_result = false
	_expect(
		not _coordinator._publish_host_settlement(occurrence_key, settlement)
		and not _coordinator._settled_occurrences.has(occurrence_key)
		and _coordinator.host_settlement_broadcasts.is_empty(),
		"Host 本地结算提交失败时不得写幂等缓存或向客户端广播。"
	)
	var failed_observation := (
		_coordinator.host_settlement_commit_observations[0] as Dictionary
	)
	_expect(
		not bool(failed_observation.get("tombstone_present", true))
		and int(failed_observation.get("broadcast_count", -1)) == 0,
		"本地结算提交必须发生在 settled tombstone 与首个远端广播之前。"
	)
	_expect(
		_coordinator._phase == COORDINATOR.ProtocolPhase.ACTIVE
		and _coordinator._active_occurrence_key == occurrence_key
		and _coordinator._combat_network == runtime
		and _route.is_normal_combat_active()
		and not _route._route_presentation_enabled
		and _coordinator._settlement_scheduled
		and not _coordinator._consumed_node_ids.has(NODE_ID),
		"激活战斗结算失败必须保留战场与结算屏障，不能回图、免费回滚成本或消费节点。"
	)

	_reset_fixture_state()
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator.host_settlement_commit_result = true
	_expect(
		_coordinator._publish_host_settlement(occurrence_key, settlement)
		and _coordinator._settled_occurrences.has(occurrence_key)
		and _coordinator.host_settlement_broadcasts.size() == 1,
		"本地提交恢复后必须只发布一次权威结算并写入幂等缓存。"
	)
	var successful_observation := (
		_coordinator.host_settlement_commit_observations[0] as Dictionary
	)
	var broadcast := _coordinator.host_settlement_broadcasts[0] as Dictionary
	_expect(
		not bool(successful_observation.get("tombstone_present", true))
		and int(successful_observation.get("broadcast_count", -1)) == 0
		and bool(broadcast.get("tombstone_present", false)),
		"成功顺序必须严格为本地 commit -> settled tombstone -> remote broadcast。"
	)
	_expect(
		not _coordinator._publish_host_settlement(occurrence_key, settlement)
		and _coordinator.host_settlement_commit_observations.size() == 1
		and _coordinator.host_settlement_broadcasts.size() == 1,
		"重复结算必须在本地 commit 前被幂等缓存拦截，不能再次发布。"
	)


func _test_pending_reconnect_is_spectator_before_settlement_broadcast() -> void:
	_reset_fixture_state()
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	run_state.register_multiplayer_peer_state(1)
	run_state.register_multiplayer_peer_state(2)
	var occurrence_key := "combat:runtime:settlement-pending-reconnect:2d"
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_node_id = 19
	_coordinator._active_content_seed = 1902
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._entry_xirang_by_peer = {1: 100, 2: 200}
	_coordinator._pending_reconnect_prepare_peers[2] = {
		"occurrence_key": occurrence_key,
		"deadline_msec": 99_999,
	}
	_fake_net_manager.send_ready_peer_ids = {2: true}
	var runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	_coordinator.add_child(runtime)
	_coordinator._combat_network = runtime
	_coordinator.host_settlement_commit_uses_super = true
	var settlement := {
		"node_id": 19,
		"content_seed": 1902,
		"occurrence_key": occurrence_key,
		"victory": false,
		"failure_reason": "重连结算顺序测试",
		"consume_node": false,
		"final_xirang_by_peer": {1: 100, 2: 200},
		"inventory_snapshots_by_peer": {
			1: run_state.export_inventory_snapshot_for_peer(1),
			2: run_state.export_inventory_snapshot_for_peer(2),
		},
		"results_by_peer": {
			1: {"peer_id": 1, "victory": false},
			2: {"peer_id": 2, "victory": false},
		},
	}

	_expect(
		_coordinator._publish_host_settlement(occurrence_key, settlement),
		"Host 真实结算提交应成功。"
	)
	var spectator_dispatch := (
		_coordinator.terminal_spectator_dispatches[0] as Dictionary
		if not _coordinator.terminal_spectator_dispatches.is_empty()
		else {}
	)
	_expect(
		_coordinator.settlement_event_order == ["spectator:2", "broadcast"]
		and not (spectator_dispatch.get("settlement", {}) as Dictionary).is_empty(),
		(
			"未 ACTIVATED 的重连 peer 必须先在可靠 CH0 收到 spectator，"
			+ "随后携带结算，普通结算广播只能发生在其后。"
		)
	)
	_expect(
		not _coordinator._pending_reconnect_prepare_peers.has(2)
		and _coordinator._disconnected_participants.has(2)
		and not _coordinator._expected_terminal_peers.has(2)
		and runtime.suspended_peers == [PackedInt32Array([2, -1])],
		"结算前降级必须同时退出 reconnect/terminal barrier 并停止战斗收发。"
	)
	_reset_fixture_state()


func _test_late_activation_cannot_rewind_settled_phase() -> void:
	_reset_fixture_state()
	_coordinator._phase = COORDINATOR.ProtocolPhase.SETTLED
	_coordinator._active_occurrence_key = "combat:runtime:late-activation:2e"
	_coordinator._settlement_received = true
	_coordinator._local_runtime_prepared = true
	var runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	runtime.activation_result = true
	_coordinator.add_child(runtime)
	_coordinator._combat_network = runtime

	_expect(
		not _coordinator._activate_local_runtime()
		and _coordinator._phase == COORDINATOR.ProtocolPhase.SETTLED
		and not _coordinator._local_runtime_activated
		and runtime.activation_calls == 0,
		"迟到的本地激活不得启动已结算战场或把 SETTLED 回写为 ACTIVE。"
	)
	_reset_fixture_state()


func _test_real_reward_mutation_rolls_back_after_commit_failure() -> void:
	_reset_fixture_state()
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	run_state.register_multiplayer_peer_state(1)
	var occurrence_key := "combat:runtime:reward-rollback:2f"
	_seed_route_combat(20, 2002, occurrence_key)
	var runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	runtime.name = "RewardRollbackRuntime"
	_fixture_root.add_child(runtime)
	var combat_game := RewardCombatGameHarness.new()
	var battle_player := PlayerCharacterRegistry.instantiate_character(
		&"weishidaier"
	) as Player
	_fixture_root.add_child(battle_player)
	await process_frame
	await physics_frame
	battle_player.configure_multiplayer_control(1, true, "Host")
	combat_game.fixture_players[1] = battle_player

	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_node_id = 20
	_coordinator._active_content_seed = 2002
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true}
	_coordinator._entry_xirang_by_peer = {1: battle_player.get_xirang()}
	_coordinator._combat_network = runtime
	_coordinator._combat_game = combat_game
	_coordinator._settlement_scheduled = true
	_coordinator.host_settlement_commit_result = false
	var xirang_before := battle_player.get_xirang()
	var inventory_before := run_state.export_inventory_snapshot_for_peer(1)
	var revision_before := int(inventory_before.get("revision", -1))
	var rollback_state := _coordinator._capture_host_reward_rollback_state()
	battle_player.grant_xirang_reward(
		FORMAL_CONFIG.extra_xirang,
		false
	)
	var reward_result := RogueCombatRewardResolver.resolve_reward(
		run_state,
		StringName(occurrence_key),
		_coordinator._active_content_seed,
		1,
		FORMAL_CONFIG.extra_xirang,
		true,
		battle_player
	)
	reward_result["victory"] = true
	var settlement := {
		"node_id": 20,
		"content_seed": 2002,
		"occurrence_key": occurrence_key,
		"victory": true,
		"failure_reason": "",
		"consume_node": true,
		"final_xirang_by_peer": {1: battle_player.get_xirang()},
		"inventory_snapshots_by_peer": {
			1: run_state.export_inventory_snapshot_for_peer(1),
		},
		"results_by_peer": {1: reward_result},
	}
	_expect(
		not _coordinator._publish_host_settlement(
			occurrence_key,
			settlement,
			rollback_state
		),
		"真实奖励写入后的注入 commit 失败必须拒绝发布。"
	)

	var observation := (
		_coordinator.host_settlement_commit_observations[0] as Dictionary
		if not _coordinator.host_settlement_commit_observations.is_empty()
		else {}
	)
	var attempted_settlement := observation.get("settlement", {}) as Dictionary
	var attempted_xirang := (
		attempted_settlement.get("final_xirang_by_peer", {}) as Dictionary
	)
	var attempted_inventories := (
		attempted_settlement.get("inventory_snapshots_by_peer", {}) as Dictionary
	)
	var attempted_inventory := attempted_inventories.get(1, {}) as Dictionary
	var inventory_after := run_state.export_inventory_snapshot_for_peer(1)
	_expect(
		int(attempted_xirang.get(1, -1))
		== xirang_before + FORMAL_CONFIG.extra_xirang
		and int(attempted_inventory.get("revision", -1)) > revision_before,
		"失败注入必须发生在真实息壤与收藏品奖励已经写入之后。"
	)
	_expect(
		battle_player.get_xirang() == xirang_before
		and _inventory_contents(inventory_after)
		== _inventory_contents(inventory_before)
		and int(inventory_after.get("revision", -1))
		> int(attempted_inventory.get("revision", -1)),
		(
			"本地结算 commit 失败必须完整恢复 Player 息壤与奖励前背包内容，"
			+ "同时以更高 revision 发布回滚。"
		)
	)
	_expect(
		_coordinator._phase == COORDINATOR.ProtocolPhase.ACTIVE
		and _coordinator._active_occurrence_key == occurrence_key
		and _coordinator._combat_network == runtime
		and not _coordinator._consumed_node_ids.has(20)
		and _coordinator.host_settlement_broadcasts.is_empty(),
		"奖励回滚后必须保留激活战场等待结算重试，且不得消费节点或广播失败结算。"
	)
	battle_player.queue_free()
	combat_game.free()
	for _frame in 3:
		await process_frame
		await physics_frame
	_reset_fixture_state()


func _test_disconnected_original_participant_receives_victory_rewards() -> void:
	_reset_fixture_state()
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	run_state.register_multiplayer_peer_state(1)
	run_state.register_multiplayer_peer_state(2)
	var occurrence_key := "followup_combat:runtime:disconnected-reward:2g"
	var combat_game := RewardCombatGameHarness.new()
	var connected_player := PlayerCharacterRegistry.instantiate_character(
		&"weishidaier"
	) as Player
	_fixture_root.add_child(connected_player)
	await process_frame
	await physics_frame
	connected_player.configure_multiplayer_control(1, true, "Host")
	connected_player.current_xirang = 1210
	combat_game.fixture_players[1] = connected_player

	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_node_id = 21
	_coordinator._active_content_seed = 2102
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._active_combat_config_id = &"suitcase_battle"
	_coordinator._active_encounter_config = SUITCASE_CONFIG
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._entry_xirang_by_peer = {1: 1000, 2: 1000}
	_coordinator._participant_character_ids = {
		1: &"weishidaier",
		2: &"tiyi",
	}
	_coordinator._participant_stable_keys = {
		1: "account:connected:1",
		2: "account:disconnected:2",
	}
	_coordinator._last_combat_xirang_by_peer = {1: 1210, 2: 1460}
	_coordinator._disconnected_participants = {
		2: {
			"entry_xirang": 1000,
			"last_combat_xirang": 1460,
			"was_prepared": true,
			"was_terminal_ready": false,
		},
	}
	_coordinator._combat_game = combat_game
	_coordinator._settlement_scheduled = true
	_coordinator._settle_host_outcome(occurrence_key, true, "")

	var observation := (
		_coordinator.host_settlement_commit_observations[0] as Dictionary
		if not _coordinator.host_settlement_commit_observations.is_empty()
		else {}
	)
	var settlement := observation.get("settlement", {}) as Dictionary
	var results := settlement.get("results_by_peer", {}) as Dictionary
	var final_xirang := settlement.get("final_xirang_by_peer", {}) as Dictionary
	var disconnected_result := results.get(2, {}) as Dictionary
	var extra_xirang := int(disconnected_result.get("extra_xirang", 0))
	_expect(
		(disconnected_result.get("item_rewards", []) as Array).size() == 3
		and extra_xirang >= 2000
		and extra_xirang <= 3000
		and extra_xirang % 100 == 0,
		"战斗中断线的原始参战者仍应获得两件收藏品、六块木板和整百息壤。"
	)
	_expect(
		int(final_xirang.get(2, -1)) == 1460 + extra_xirang,
		"断线参战者的胜利奖励必须叠加到断线前最后的战场息壤。"
	)
	var disconnected_inventory := run_state.export_inventory_snapshot_for_peer(2)
	var occupied_slots := 0
	for slot_value in disconnected_inventory.get("slots", []) as Array:
		if not str((slot_value as Dictionary).get("config_path", "")).is_empty():
			occupied_slots += 1
	_expect(occupied_slots >= 3, "断线参战者的奖励必须实际提交到其RunState背包。")

	connected_player.queue_free()
	combat_game.free()
	for _frame in 2:
		await process_frame
		await physics_frame
	_reset_fixture_state()


func _test_player_left_preserves_participant_and_shrinks_barriers() -> void:
	_reset_fixture_state()
	_coordinator._phase = COORDINATOR.ProtocolPhase.PREPARING
	_coordinator._active_occurrence_key = "combat:runtime:left:3"
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._entry_xirang_by_peer = {1: 300, 2: 700}
	_coordinator._expected_prepared_peers = {1: true, 2: true}
	_coordinator._prepared_peers = {2: true}
	_coordinator._expected_terminal_peers = {1: true, 2: true}
	_coordinator._terminal_ready_peers = {2: true}

	_coordinator._on_player_left(2)

	_expect(
		_coordinator._participant_peer_ids.has(2),
		"断线玩家必须保留在冻结的参战 roster 中，供重连恢复。"
	)
	_expect(
		_coordinator._disconnected_participants.has(2)
		and int((_coordinator._disconnected_participants[2] as Dictionary).get(
			"entry_xirang",
			-1
		)) == 700,
		"断线记录必须保存参战身份及入口息壤。"
	)
	_expect(
		not _coordinator._expected_prepared_peers.has(2)
		and not _coordinator._prepared_peers.has(2)
		and not _coordinator._expected_terminal_peers.has(2)
		and not _coordinator._terminal_ready_peers.has(2),
		"断线玩家必须退出 prepare 与 terminal 两个 barrier。"
	)


func _test_client_abort_admission_is_prepare_only() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:abort-admission:3a"
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._phase = COORDINATOR.ProtocolPhase.PREPARING
	var accepted_reason_count := 0
	for reason_variant in COORDINATOR.CLIENT_PREPARATION_ABORT_REASONS.keys():
		if _coordinator._can_accept_client_abort_request(
			2,
			occurrence_key,
			StringName(reason_variant)
		):
			accepted_reason_count += 1
	_expect(
		accepted_reason_count
		== COORDINATOR.CLIENT_PREPARATION_ABORT_REASONS.size()
		and not _coordinator._can_accept_client_abort_request(
			2,
			occurrence_key,
			&"victory_presentation_interrupted"
		)
		and not _coordinator._can_accept_client_abort_request(
			2,
			occurrence_key,
			&"arbitrary_remote_reason"
		)
		and not _coordinator._can_accept_client_abort_request(
			3,
			occurrence_key,
			&"runtime_create_failed"
		)
		and not _coordinator._can_accept_client_abort_request(
			2,
			occurrence_key + ":stale",
			&"runtime_create_failed"
		),
		(
			"客户端只能在 PREPARING 阶段、当前 occurrence 中，由冻结名单内成员"
			+ "上报八种白名单准备失败。"
		)
	)
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._activation_dispatch_started = true
	_coordinator._pending_reconnect_prepare_peers[2] = {
		"occurrence_key": occurrence_key,
		"deadline_msec": 99_999,
	}
	_expect(
		not _coordinator._can_accept_client_abort_request(
			2,
			occurrence_key,
			&"runtime_create_failed"
		)
		and _coordinator._can_withdraw_failed_runtime_participant(
			2,
			occurrence_key,
			&"runtime_create_failed"
		),
		"ACTIVE 重连恢复失败只能退出该 pending peer，不得终止整场战斗。"
	)
	_coordinator._pending_reconnect_prepare_peers.clear()
	_expect(
		not _coordinator._can_withdraw_failed_runtime_participant(
			2,
			occurrence_key,
			&"runtime_create_failed"
		),
		"未收到本次即时恢复包的 ACTIVE peer 不得伪造失败降级。"
	)
	_coordinator._phase = COORDINATOR.ProtocolPhase.SETTLED
	_coordinator._pending_reconnect_prepare_peers[2] = {
		"occurrence_key": occurrence_key,
		"deadline_msec": 99_999,
	}
	_expect(
		not _coordinator._can_accept_client_abort_request(
			2,
			occurrence_key,
			&"runtime_create_failed"
		)
		and _coordinator._can_withdraw_failed_runtime_participant(
			2,
			occurrence_key,
			&"runtime_create_failed"
		),
		"SETTLED 重连失败只能降级该 pending peer，不得回滚终局。"
	)

	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._entry_xirang_by_peer = {1: 500, 2: 500}
	_coordinator._expected_terminal_peers = {1: true, 2: true}
	var runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	_coordinator.add_child(runtime)
	_coordinator._combat_network = runtime
	_coordinator._withdraw_failed_runtime_participant(
		2,
		occurrence_key,
		&"runtime_create_failed"
	)
	_expect(
		_coordinator._phase == COORDINATOR.ProtocolPhase.ACTIVE
		and _coordinator._disconnected_participants.has(2)
		and not _coordinator._expected_terminal_peers.has(2)
		and not _coordinator._pending_reconnect_prepare_peers.has(2),
		"单端恢复失败必须保持 Host 战斗运行并退出所有 barrier。"
	)
	_expect(
		runtime.suspended_peers == [PackedInt32Array([2, -1])],
		"Host MpGame 必须停止失败 peer 的战斗收发。"
	)
	_reset_fixture_state()


func _test_route_first_reconnect_waits_for_player_projection() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:route-first-reconnect:3c"
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._entry_xirang_by_peer = {1: 500, 2: 700}
	_coordinator._participant_character_ids = {1: &"weishidaier", 2: &"tiyi"}
	_coordinator._participant_stable_keys = {1: "account:1", 2: "account:2"}
	_coordinator._last_combat_xirang_by_peer = {1: 500, 2: 760}
	_coordinator._disconnected_participants = {
		2: {
			"entry_xirang": 700,
			"last_combat_xirang": 760,
			"was_prepared": true,
			"was_terminal_ready": false,
		},
	}
	# 客户端分支无需实际 ENet peer，也能验证 roster 决策是否被监听顺序改变。
	_fake_net_manager.host_role = false
	var runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	_coordinator.add_child(runtime)
	_coordinator._combat_network = runtime
	runtime.reconnected_player_projection_resolved.connect(
		_coordinator._on_embedded_reconnected_player_projection_resolved
	)

	# 模拟 MpRogueRoute 比动态创建的 MpGame 更早连接 player_reconnected。
	_coordinator.handle_reconnected_identity_committed(2, 3)
	_expect(
		not _coordinator._participant_peer_ids.has(2)
		and _coordinator._participant_peer_ids.has(3)
		and _coordinator._disconnected_participants.has(3)
		and _coordinator._reconnecting_peer_ids.has(3)
		and _coordinator._pending_reconnected_identity_resolutions.has(3)
		and not _coordinator._pending_reconnect_prepare_peers.has(3)
		and runtime.suspended_peers.is_empty(),
		"路线监听者先到时必须立即推进规范 raw peer，同时保持 PROJECTING 能力门。"
	)
	runtime.reconnected_player_projection_resolved.emit(
		2,
		3,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
	)
	_expect(
		not _coordinator._participant_peer_ids.has(2)
		and _coordinator._participant_peer_ids.has(3)
		and not _coordinator._pending_reconnected_identity_resolutions.has(3)
		and not _coordinator._pending_reconnect_prepare_peers.has(3)
		and runtime.suspended_peers.is_empty(),
		"MpGame 明确恢复后只开放能力，不能再次迁移或错误降级客户端。"
	)
	_coordinator.handle_reconnected_identity_committed(2, 3)
	_expect(
		not _coordinator._pending_spectator_peers.has(3)
		and not _coordinator._reconnecting_peer_ids.has(3),
		"已完成的 reconnect 精确重放必须幂等，不能把当前参战者重新排入观战队列。"
	)
	_reset_fixture_state()


func _test_standalone_projection_owner_reports_once() -> void:
	_reset_fixture_state()
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_occurrence_key = "combat:runtime:aggregate-owner:3h"
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._entry_xirang_by_peer = {1: 500, 2: 700}
	_coordinator._disconnected_participants = {
		2: {
			"entry_xirang": 700,
			"was_prepared": true,
			"was_terminal_ready": false,
		},
	}
	_expect(
		_coordinator.handle_reconnected_identity_committed(2, 3),
		"独立路线必须先接受 route identity 结果。"
	)
	_coordinator._on_embedded_reconnected_player_projection_resolved(
		2,
		3,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
	)
	_expect(
		_fake_net_manager.runtime_projection_reports.size() == 1
		and int(
			_fake_net_manager.runtime_projection_reports[0].get("old_peer_id", 0)
		) == 2
		and int(
			_fake_net_manager.runtime_projection_reports[0].get("new_peer_id", 0)
		) == 3
		and int(_fake_net_manager.runtime_projection_reports[0].get("outcome", -1))
		== MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
		and _fake_net_manager.terminated_projection_peers.is_empty(),
		"独立 P3 只能由作战聚合器向 NetManager 报告一次会话终态。"
	)
	_coordinator._on_embedded_reconnected_player_projection_resolved(
		2,
		3,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
	)
	_expect(
		_fake_net_manager.runtime_projection_reports.size() == 1,
		"内嵌 Player 结果重放不得产生第二个会话聚合报告。"
	)
	_reset_fixture_state()


func _test_canonical_peer_survives_failed_two_hop_reconnect() -> void:
	_reset_fixture_state()
	_coordinator._session_projection_owner = (
		COORDINATOR.SessionProjectionOwner.ENCLOSING_RUNTIME
	)
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_occurrence_key = "combat:runtime:two-hop:3i"
	_coordinator._participant_peer_ids = {2: true}
	_coordinator._entry_xirang_by_peer = {2: 700}
	_coordinator._participant_character_ids = {2: &"tiyi"}
	_coordinator._participant_stable_keys = {2: "account:2"}
	_coordinator._participant_incarnations = {2: 202}
	_coordinator._last_combat_xirang_by_peer = {2: 760}
	_coordinator._disconnected_participants = {
		2: {
			"entry_xirang": 700,
			"last_combat_xirang": 760,
			"was_prepared": true,
			"was_terminal_ready": false,
		},
	}
	_fake_net_manager.host_role = false
	_expect(
		_coordinator.handle_reconnected_identity_committed(2, 7),
		"2 -> 7 的 route identity 应先提交规范作战 peer。"
	)
	_coordinator._on_embedded_reconnected_player_projection_resolved(
		2,
		7,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.FAILED
	)
	_expect(
		_coordinator._participant_peer_ids.has(7)
		and not _coordinator._participant_peer_ids.has(2)
		and _coordinator._disconnected_participants.has(7),
		"CREATE_FAILED 只能关闭 7 的战斗能力，不能把规范身份退回 2。"
	)

	# 7 在降级后再次掉线，并于结算阶段迁到 8；所有冻结奖励与结算地址
	# 必须沿同一规范身份继续前进，不能残留 2/7 的状态副本。
	_coordinator._on_player_left(7)
	_coordinator._phase = COORDINATOR.ProtocolPhase.SETTLED
	_coordinator._settlement_received = true
	_coordinator._pending_settlement = {
		"final_xirang_by_peer": {7: 880},
		"inventory_snapshots_by_peer": {7: {"peer_id": 7, "items": []}},
		"results_by_peer": {7: {"peer_id": 7, "victory": true}},
	}
	_expect(
		_coordinator.handle_reconnected_identity_committed(7, 8),
		"7 -> 8 的第二跳必须以当前规范 peer 继续迁移。"
	)
	var settlement_results := (
		_coordinator._pending_settlement.get("results_by_peer", {}) as Dictionary
	)
	_expect(
		_coordinator._participant_peer_ids == {8: true}
		and _coordinator._entry_xirang_by_peer.has(8)
		and not _coordinator._entry_xirang_by_peer.has(2)
		and not _coordinator._entry_xirang_by_peer.has(7)
		and _coordinator._participant_character_ids.has(8)
		and _coordinator._participant_stable_keys.has(8)
		and _coordinator._participant_incarnations.get(8, 0) == 202
		and _coordinator._last_combat_xirang_by_peer.has(8)
		and settlement_results.has(8)
		and not settlement_results.has(7)
		and int((settlement_results[8] as Dictionary).get("peer_id", 0)) == 8,
		"两跳后 roster、冻结奖励与结算 payload 的唯一 raw peer 必须是 8。"
	)
	_reset_fixture_state()


func _test_projection_outcome_cas_conflicts() -> void:
	_reset_fixture_state()
	_coordinator._session_projection_owner = (
		COORDINATOR.SessionProjectionOwner.ENCLOSING_RUNTIME
	)
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_occurrence_key = "combat:runtime:outcome-cas:3j"
	_coordinator._participant_peer_ids = {2: true}
	_coordinator._entry_xirang_by_peer = {2: 700}
	_coordinator._participant_incarnations = {2: 22}
	_coordinator._disconnected_participants = {
		2: {"entry_xirang": 700, "was_prepared": true},
	}
	_fake_net_manager.host_role = false
	_fake_net_manager.reconnecting_peer_ids[3] = true
	_fake_net_manager.participant_incarnations[3] = 22
	_coordinator._on_embedded_reconnected_player_projection_resolved(
		2,
		3,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.SUSPENDED
	)
	_coordinator._on_embedded_reconnected_player_projection_resolved(
		2,
		3,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
	)
	_coordinator.handle_reconnected_identity_committed(2, 3)
	var downgraded := (
		_coordinator._resolved_reconnected_identity_resolutions.get(3, {})
		as Dictionary
	)
	_expect(
		int(downgraded.get("effective_outcome", -1))
		== MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.SUSPENDED
		and _coordinator._disconnected_participants.has(3)
		and not _coordinator._pending_reconnect_prepare_peers.has(3),
		"外层 owner 的 SUSPENDED -> RESTORED 冲突必须保持降级，禁止升级。"
	)

	_reset_fixture_state()
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_occurrence_key = "combat:runtime:outcome-cas:3k"
	_coordinator._participant_peer_ids = {4: true}
	_coordinator._entry_xirang_by_peer = {4: 800}
	_coordinator._participant_incarnations = {4: 44}
	_coordinator._disconnected_participants = {
		4: {"entry_xirang": 800, "was_prepared": true},
	}
	_coordinator.handle_reconnected_identity_committed(4, 5)
	_coordinator._on_embedded_reconnected_player_projection_resolved(
		4,
		5,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
	)
	_coordinator._on_embedded_reconnected_player_projection_resolved(
		4,
		5,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.SUSPENDED
	)
	_expect(
		_fake_net_manager.runtime_projection_reports.size() == 1
		and _fake_net_manager.terminated_projection_peers == [5],
		"独立 owner 已完成后的冲突终态必须 fail-close，不能生成第二次有效报告。"
	)
	_reset_fixture_state()


func _test_client_failed_projection_fails_closed() -> void:
	_reset_fixture_state()
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_occurrence_key = "combat:runtime:client-failed:3l"
	_coordinator._participant_peer_ids = {2: true}
	_coordinator._entry_xirang_by_peer = {2: 700}
	_coordinator._participant_incarnations = {2: 22}
	_coordinator._disconnected_participants = {
		2: {"entry_xirang": 700, "was_prepared": true},
	}
	_fake_net_manager.host_role = false
	_coordinator.handle_reconnected_identity_committed(2, 3)
	_coordinator._on_embedded_reconnected_player_projection_resolved(
		2,
		3,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.FAILED
	)
	_expect(
		_fake_net_manager.terminated_membership_projection_reasons.size() == 1
		and _coordinator._participant_peer_ids.has(3)
		and _coordinator._disconnected_participants.has(3),
		"THIS_COORDINATOR 的 Client FAILED 必须本地终止且保留已提交的规范身份。"
	)
	_reset_fixture_state()


func _test_stale_outcome_first_is_rejected() -> void:
	_reset_fixture_state()
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_occurrence_key = "combat:runtime:stale-outcome:3m"
	_coordinator._participant_peer_ids = {2: true}
	_coordinator._entry_xirang_by_peer = {2: 700}
	_coordinator._participant_incarnations = {2: 22}
	_coordinator._disconnected_participants = {
		2: {"entry_xirang": 700, "was_prepared": true},
	}
	_fake_net_manager.host_role = false
	_fake_net_manager.reconnecting_peer_ids[7] = true
	_fake_net_manager.participant_incarnations[7] = 999
	_coordinator._on_embedded_reconnected_player_projection_resolved(
		2,
		7,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
	)
	_expect(
		not _coordinator._pending_reconnected_identity_resolutions.has(7),
		"不同 incarnation 即使 raw peer 仍为 RECONNECTING 也不能新建 pending。"
	)
	_fake_net_manager.participant_incarnations[7] = 22
	_fake_net_manager.reconnecting_peer_ids.erase(7)
	_coordinator._on_embedded_reconnected_player_projection_resolved(
		2,
		7,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
	)
	_expect(
		not _coordinator._pending_reconnected_identity_resolutions.has(7),
		"非 RECONNECTING 的迟到 2 -> 7 outcome 必须被拒绝。"
	)
	_fake_net_manager.reconnecting_peer_ids[7] = true
	_coordinator._on_embedded_reconnected_player_projection_resolved(
		2,
		7,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
	)
	_expect(
		_coordinator._pending_reconnected_identity_resolutions.has(7),
		"同 incarnation 的当前 RECONNECTING 成员仍必须支持合法 component-first。"
	)
	_coordinator._clear_pending_reconnected_identity_resolution(7)
	_fake_net_manager.reconnecting_peer_ids.erase(7)
	_coordinator._on_embedded_reconnected_player_projection_resolved(
		2,
		7,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
	)
	_expect(
		not _coordinator._pending_reconnected_identity_resolutions.has(7)
		and not _coordinator._reconnecting_peer_ids.has(7),
		"事务清理后迟到的旧 hop outcome 不得复活能力门。"
	)
	_reset_fixture_state()


func _test_reconnect_prepare_waits_for_post_ready_lease() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:post-ready:3f"
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_node_id = 39
	_coordinator._active_content_seed = 3909
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._active_combat_config_id = FORMAL_CONFIG.encounter_id
	_coordinator._active_config_signature = "fixture-signature"
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._entry_xirang_by_peer = {1: 500, 2: 700}
	_coordinator._disconnected_participants = {
		2: {
			"entry_xirang": 700,
			"was_prepared": true,
			"was_terminal_ready": false,
		},
	}

	# Player 组件先完成时只建立 intent；PREPARING_DELIVERY 租约到达前
	# 不得误降级 spectator，也不得提前发送 prepare。
	_coordinator._finish_player_reconnected(
		2,
		3,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
	)
	_expect(
		_coordinator._pending_reconnect_prepare_peers.has(3)
		and _coordinator.reconnect_prepare_dispatches.is_empty(),
		"Player 投影先到时，PREPARING_DELIVERY 前必须零 prepare 发包。"
	)
	_fake_net_manager.reconnect_delivery_preparing_peer_ids[3] = true
	_expect(
		_coordinator.handle_reconnected_member_ready(
			2,
			3,
			MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
		)
		and _coordinator.reconnect_prepare_dispatches.size() == 1
		and bool(
			_coordinator.reconnect_prepare_dispatches[0].get(
				"activate_immediately",
				false
			)
		),
		"PREPARING_DELIVERY 租约到达后必须恰好一次发送立即激活 prepare。"
	)
	_expect(
		_coordinator.handle_reconnected_member_ready(
			2,
			3,
			MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
		)
		and _coordinator.reconnect_prepare_dispatches.size() == 1,
		"重复 PREPARING_DELIVERY 租约必须幂等，不能重复发送 prepare。"
	)

	# 反向顺序：route 已提交后 ready 可以先于内嵌 Player，租约必须保留。
	_reset_fixture_state()
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_node_id = 40
	_coordinator._active_content_seed = 4010
	_coordinator._active_occurrence_key = "combat:runtime:ready-first:3g"
	_coordinator._active_combat_config_id = FORMAL_CONFIG.encounter_id
	_coordinator._active_config_signature = "fixture-signature"
	_coordinator._participant_peer_ids = {1: true, 4: true}
	_coordinator._entry_xirang_by_peer = {1: 500, 4: 800}
	_coordinator._disconnected_participants = {
		4: {
			"entry_xirang": 800,
			"was_prepared": true,
			"was_terminal_ready": false,
		},
	}
	_coordinator._reconnecting_peer_ids[5] = true
	_fake_net_manager.send_ready_peer_ids[5] = true
	_expect(
		_coordinator.handle_reconnected_member_ready(
			4,
			5,
			MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
		)
		and _coordinator.reconnect_prepare_dispatches.is_empty(),
		"ready 先到时必须只保留租约，不能在 Player 投影前发包。"
	)
	_coordinator._finish_player_reconnected(
		4,
		5,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
	)
	_expect(
		_coordinator.reconnect_prepare_dispatches.size() == 1
		and int(_coordinator.reconnect_prepare_dispatches[0].get("peer_id", 0)) == 5,
		"Player 投影后必须消费先到的 ready 租约且仅发送一次。"
	)
	_reset_fixture_state()


func _test_pending_reconnect_projection_survives_phase_change() -> void:
	_reset_fixture_state()
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_occurrence_key = "combat:runtime:phase-boundary-reconnect:3d"
	_coordinator._participant_peer_ids = {2: true}
	_coordinator._entry_xirang_by_peer = {2: 700}
	_coordinator._participant_character_ids = {2: &"tiyi"}
	_coordinator._participant_stable_keys = {2: "account:2"}
	_coordinator._last_combat_xirang_by_peer = {2: 760}
	_coordinator._disconnected_participants = {
		2: {
			"entry_xirang": 700,
			"last_combat_xirang": 760,
			"was_prepared": true,
			"was_terminal_ready": false,
		},
	}
	_fake_net_manager.host_role = false

	# 路线结果在 ACTIVE 先到，Player 结果到达前协议推进到奖励阶段。
	# 这个阶段变化不能使已启动的身份事务永远留在 pending。
	_coordinator.handle_reconnected_identity_committed(2, 3)
	_coordinator._phase = COORDINATOR.ProtocolPhase.REWARD_SELECTING
	_coordinator._on_embedded_reconnected_player_projection_resolved(
		2,
		3,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
	)
	_expect(
		not _coordinator._pending_reconnected_identity_resolutions.has(3)
		and not _coordinator._reconnecting_peer_ids.has(3)
		and not _coordinator._participant_peer_ids.has(2)
		and _coordinator._participant_peer_ids.has(3),
		"阶段推进后仍必须消费 ACTIVE 已启动的路线/Player 投影汇合事务。"
	)

	# 反向顺序也必须消费同一 pending，不能因为路线结果到达时阶段已改变
	# 而绕开先到的 Player 明确结果。
	_reset_fixture_state()
	_fake_net_manager.host_role = false
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_occurrence_key = "combat:runtime:phase-boundary-reconnect:3e"
	_coordinator._participant_peer_ids = {4: true}
	_coordinator._entry_xirang_by_peer = {4: 800}
	_coordinator._participant_character_ids = {4: &"tiyi"}
	_coordinator._participant_stable_keys = {4: "account:4"}
	_coordinator._participant_incarnations = {4: 44}
	_coordinator._last_combat_xirang_by_peer = {4: 830}
	_coordinator._disconnected_participants = {
		4: {
			"entry_xirang": 800,
			"last_combat_xirang": 830,
			"was_prepared": true,
			"was_terminal_ready": false,
		},
	}
	_fake_net_manager.reconnecting_peer_ids[5] = true
	_fake_net_manager.participant_incarnations[5] = 44
	_coordinator._on_embedded_reconnected_player_projection_resolved(
		4,
		5,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
	)
	_coordinator._phase = COORDINATOR.ProtocolPhase.REWARD_SELECTING
	_coordinator.handle_reconnected_identity_committed(4, 5)
	_expect(
		not _coordinator._pending_reconnected_identity_resolutions.has(5)
		and not _coordinator._reconnecting_peer_ids.has(5)
		and not _coordinator._participant_peer_ids.has(4)
		and _coordinator._participant_peer_ids.has(5),
		"Player 投影先到且阶段推进后，路线提交仍必须汇合同一身份事务。"
	)
	_reset_fixture_state()


func _test_reconnect_prepare_marker_lifecycle() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:reconnect-marker:3b"
	_coordinator._phase = COORDINATOR.ProtocolPhase.PREPARING
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._expected_prepared_peers = {1: true, 2: true}
	_coordinator._pending_reconnect_prepare_peers[2] = {
		"occurrence_key": occurrence_key,
		"deadline_msec": 0,
		"prepare_dispatched": false,
	}

	_fake_net_manager.gameplay_ingress_admitted = false
	_coordinator._accept_combat_prepared(2, occurrence_key)
	_expect(
		not _coordinator._prepared_peers.has(2),
		"RECONNECTING 成员不得在玩法租约生效前推进 prepare barrier。"
	)
	_fake_net_manager.gameplay_ingress_admitted = true
	_coordinator._accept_combat_prepared(2, occurrence_key)
	_expect(
		_coordinator._prepared_peers.has(2)
		and _coordinator._pending_reconnect_prepare_peers.has(2),
		"PREPARING 重连的首个 prepared 必须满足 barrier 但保留失败窗口。"
	)
	_coordinator._activation_dispatch_started = true
	_coordinator._accept_combat_prepared(2, occurrence_key)
	_expect(
		_coordinator._pending_reconnect_prepare_peers.has(2)
		and _coordinator._can_withdraw_failed_runtime_participant(
			2,
			occurrence_key,
			&"runtime_activate_failed"
		),
		"重复 PREPARED 不得伪装成激活成功或提前关闭失败窗口。"
	)
	_coordinator._accept_combat_activated(2, occurrence_key)
	_expect(
		_coordinator._pending_reconnect_prepare_peers.has(2),
		"Host 尚未实际发送 prepare 时，伪造 ACTIVATED 不得消费恢复租约。"
	)
	var pending := (
		_coordinator._pending_reconnect_prepare_peers[2] as Dictionary
	)
	pending["prepare_dispatched"] = true
	_coordinator._pending_reconnect_prepare_peers[2] = pending
	_coordinator._accept_combat_activated(2, occurrence_key)
	_expect(
		not _coordinator._pending_reconnect_prepare_peers.has(2)
		and not _coordinator._can_withdraw_failed_runtime_participant(
			2,
			occurrence_key,
			&"runtime_activate_failed"
		),
		"独立 ACTIVATED 确认后必须关闭该 peer 的失败窗口。"
	)
	_reset_fixture_state()


func _test_prepare_barrier_timeout_aborts_entry() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:prepare-timeout:3c"
	_seed_route_combat(31, 3103, occurrence_key)
	_expect(
		_coordinator._begin_protocol(
			31,
			3103,
			occurrence_key,
			PackedInt32Array([1, 2]),
			{1: 500, 2: 500},
			false,
			FORMAL_CONFIG.encounter_id,
			FORMAL_CONFIG
		),
		"prepare timeout 夹具必须进入 PREPARING。"
	)
	_coordinator._prepare_barrier_deadline_msec = 10_000
	_coordinator._poll_prepare_barrier_timeout(9_999)
	_expect(
		_coordinator._phase == COORDINATOR.ProtocolPhase.PREPARING,
		"prepare deadline 前不得中断作战进入。"
	)
	_coordinator._poll_prepare_barrier_timeout(10_000)
	_assert_abort_recovered(31, "prepare barrier 超时")


func _test_reconnect_activation_timeout_downgrades_peer() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:reconnect-timeout:3d"
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._entry_xirang_by_peer = {1: 500, 2: 500}
	_coordinator._pending_reconnect_prepare_peers[2] = {
		"occurrence_key": occurrence_key,
		"deadline_msec": 10_000,
	}
	var runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	_coordinator.add_child(runtime)
	_coordinator._combat_network = runtime

	_coordinator._poll_reconnect_activation_timeouts(9_999)
	_expect(
		_coordinator._pending_reconnect_prepare_peers.has(2),
		"重连 activation deadline 前必须继续等待。"
	)
	_coordinator._poll_reconnect_activation_timeouts(10_000)
	_expect(
		_coordinator._phase == COORDINATOR.ProtocolPhase.ACTIVE
		and _coordinator._disconnected_participants.has(2)
		and not _coordinator._pending_reconnect_prepare_peers.has(2)
		and runtime.suspended_peers == [PackedInt32Array([2, -1])],
		"重连激活静默超时必须只降级该 peer，Host 战斗继续。"
	)
	_reset_fixture_state()


func _test_terminal_barrier_timeout_forces_safe_release() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:terminal-timeout:3e"
	_seed_route_combat(33, 3303, occurrence_key)
	_route.set_route_presentation_enabled(false)
	_coordinator._phase = COORDINATOR.ProtocolPhase.SETTLED
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._entry_xirang_by_peer = {1: 500, 2: 500}
	_coordinator._expected_terminal_peers = {1: true, 2: true}
	_coordinator._settlement_received = true
	_coordinator._pending_settlement = {
		"occurrence_key": occurrence_key,
		"results_by_peer": {
			1: {
				"peer_id": 1,
				"victory": false,
				"failure_reason": "终局演出超时测试",
			},
		},
	}
	_coordinator._local_result_occurrence_key = occurrence_key
	_coordinator._terminal_barrier_deadline_msec = 10_000
	var runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	_coordinator.add_child(runtime)
	_coordinator._combat_network = runtime

	_coordinator._poll_terminal_barrier_timeout(10_000)
	_expect(
		_coordinator._phase == COORDINATOR.ProtocolPhase.IDLE
		and _coordinator._combat_network == null
		and not _route.is_normal_combat_active()
		and _route._route_presentation_enabled
		and _coordinator._local_result_visible
		and _route.combat_result_overlay.visible
		and runtime.suspended_peers == [PackedInt32Array([2, -1])],
		(
			"terminal-ready 静默 peer 超时后必须强制回图并完成安全释放，"
			+ "但不能吞掉已经生成的本地结算面板。"
		)
	)
	_reset_fixture_state()


func _test_terminal_spectator_sync_retries_send_ready() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:spectator-send-ready:3e"
	_coordinator._phase = COORDINATOR.ProtocolPhase.SETTLED
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._settlement_received = true
	_coordinator._pending_settlement = {
		"occurrence_key": occurrence_key,
		"results_by_peer": {2: {"peer_id": 2, "victory": true}},
	}

	_coordinator._send_terminal_reconnect_spectator(2, occurrence_key)
	_expect(
		_coordinator._pending_terminal_spectator_syncs.has(2)
		and _coordinator.terminal_spectator_dispatches.is_empty(),
		"send-ready 尚未建立时，观战与结算同步必须保留为可重试状态。"
	)
	_fake_net_manager.send_ready_peer_ids[2] = true
	_coordinator._poll_pending_terminal_spectator_syncs()
	var dispatched := (
		_coordinator.terminal_spectator_dispatches[0]
		if not _coordinator.terminal_spectator_dispatches.is_empty()
		else {}
	) as Dictionary
	_expect(
		not _coordinator._pending_terminal_spectator_syncs.has(2)
		and _coordinator.terminal_spectator_dispatches.size() == 1
		and int(dispatched.get("peer_id", -1)) == 2
		and str(dispatched.get("occurrence_key", "")) == occurrence_key
		and not (dispatched.get("settlement", {}) as Dictionary).is_empty(),
		"send-ready 恢复后必须恰好一次补发观战状态和权威结算。"
	)
	_fake_net_manager.send_ready_peer_ids.erase(2)
	_reset_fixture_state()


func _test_reconnect_remaps_terminal_settlement() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:reconnect:4"
	_coordinator._phase = COORDINATOR.ProtocolPhase.SETTLED
	_coordinator._active_node_id = 14
	_coordinator._active_content_seed = 1404
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._entry_xirang_by_peer = {1: 500, 2: 800}
	_coordinator._participant_character_ids = {1: &"weishidaier", 2: &"tiyi"}
	_coordinator._participant_stable_keys = {1: "account:1", 2: "account:2"}
	_coordinator._last_combat_xirang_by_peer = {1: 600, 2: 1120}
	_coordinator._disconnected_participants = {
		2: {
			"entry_xirang": 800,
			"was_prepared": true,
			"was_terminal_ready": false,
		},
	}
	_coordinator._expected_terminal_peers = {1: true}
	_coordinator._settlement_received = true
	_coordinator._pending_settlement = {
		"occurrence_key": occurrence_key,
		"final_xirang_by_peer": {1: 600, 2: 1300},
		"inventory_snapshots_by_peer": {
			1: {"peer_id": 1, "items": []},
			2: {"peer_id": 2, "items": ["loot_for_old_peer"]},
		},
		"results_by_peer": {
			1: {"peer_id": 1, "victory": true},
			2: {"peer_id": 2, "victory": true},
		},
	}
	var runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	var combat_game := RewardCombatGameHarness.new()
	var restored_player := PlayerCharacterRegistry.instantiate_character(
		&"weishidaier"
	) as Player
	_fixture_root.add_child(restored_player)
	combat_game.fixture_players[3] = restored_player
	runtime.game_runtime = combat_game
	_coordinator.add_child(runtime)
	_coordinator._combat_network = runtime

	# remote_sender_id 无法在单进程伪造；直接覆盖相同的房主本地迁移分支。
	_coordinator._finish_player_reconnected(
		2,
		3,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.SUSPENDED
	)

	_expect(
		not _coordinator._participant_peer_ids.has(2)
		and _coordinator._participant_peer_ids.has(3),
		"重连必须将冻结 roster 从 old peer 映射到 new peer。"
	)
	_expect(
		not _coordinator._entry_xirang_by_peer.has(2)
		and int(_coordinator._entry_xirang_by_peer.get(3, -1)) == 800,
		"重连必须迁移入口息壤。"
	)
	_expect(
		not _coordinator._participant_character_ids.has(2)
		and StringName(_coordinator._participant_character_ids.get(3, &""))
		== &"tiyi"
		and not _coordinator._participant_stable_keys.has(2)
		and str(_coordinator._participant_stable_keys.get(3, ""))
		== "account:2"
		and not _coordinator._last_combat_xirang_by_peer.has(2)
		and int(_coordinator._last_combat_xirang_by_peer.get(3, -1)) == 1120,
		"重连必须同步迁移冻结角色、稳定身份与最后战场息壤。"
	)
	_expect(
		not _coordinator._disconnected_participants.has(2)
		and _coordinator._disconnected_participants.has(3)
		and not _coordinator._expected_terminal_peers.has(3)
		and not _coordinator._pending_reconnect_prepare_peers.has(3)
		and runtime.suspended_peers == [PackedInt32Array([3, 2])],
		"SETTLED 重连必须直接降级路线观战，不再创建或激活已结束的战场。"
	)
	for map_key in [
		"final_xirang_by_peer",
		"inventory_snapshots_by_peer",
		"results_by_peer",
	]:
		var peer_map := _coordinator._pending_settlement[map_key] as Dictionary
		_expect(
			not peer_map.has(2) and peer_map.has(3),
			"重连必须迁移 settlement 映射：%s。" % map_key
		)
	var inventory := (
		_coordinator._pending_settlement["inventory_snapshots_by_peer"]
		as Dictionary
	)
	var results := (
		_coordinator._pending_settlement["results_by_peer"] as Dictionary
	)
	_expect(
		int((inventory[3] as Dictionary).get("peer_id", -1)) == 3
		and int((results[3] as Dictionary).get("peer_id", -1)) == 3,
		"重连后字典 payload 内部 peer_id 也必须改为 new peer。"
	)


func _test_host_missing_reconnect_runtime_becomes_spectator() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:missing-host-player:4b"
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._entry_xirang_by_peer = {1: 500, 2: 900}
	_coordinator._disconnected_participants = {
		2: {
			"entry_xirang": 900,
			"was_prepared": true,
			"was_terminal_ready": false,
		},
	}
	_coordinator._reconnecting_peer_ids[3] = true
	var runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	var combat_game := RewardCombatGameHarness.new()
	runtime.game_runtime = combat_game
	_coordinator.add_child(runtime)
	_coordinator._combat_network = runtime

	_coordinator._finish_player_reconnected(
		2,
		3,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.SUSPENDED
	)

	_expect(
		not _coordinator._participant_peer_ids.has(2)
		and _coordinator._participant_peer_ids.has(3)
		and _coordinator._disconnected_participants.has(3)
		and not _coordinator._pending_reconnect_prepare_peers.has(3),
		"Host 缺少权威 Player 时必须迁移结算身份但禁止发送战斗恢复包。"
	)
	_expect(
		runtime.suspended_peers == [PackedInt32Array([3, 2])],
		"Host 缺 Player 的身份链必须同步迁移为 suspended roster。"
	)
	_reset_fixture_state()


func _test_active_reconnect_spectator_receives_later_settlement() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:late-spectator-settlement:4bb"
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._entry_xirang_by_peer = {1: 500, 2: 900}
	_coordinator._participant_character_ids = {1: &"weishidaier", 2: &"tiyi"}
	_coordinator._participant_stable_keys = {1: "account:1", 2: "account:2"}
	_coordinator._last_combat_xirang_by_peer = {1: 600, 2: 1120}
	_coordinator._disconnected_participants = {
		2: {
			"entry_xirang": 900,
			"last_combat_xirang": 1120,
			"was_prepared": true,
			"was_terminal_ready": false,
		},
	}
	_coordinator._reconnecting_peer_ids[3] = true
	_fake_net_manager.send_ready_peer_ids[3] = true
	var runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	runtime.game_runtime = RewardCombatGameHarness.new()
	_coordinator.add_child(runtime)
	_coordinator._combat_network = runtime

	_coordinator._finish_player_reconnected(
		2,
		3,
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.SUSPENDED
	)
	var first_dispatch := (
		_coordinator.terminal_spectator_dispatches[0]
		if not _coordinator.terminal_spectator_dispatches.is_empty()
		else {}
	) as Dictionary
	_expect(
		_coordinator._pending_terminal_spectator_syncs.has(3)
		and _coordinator.terminal_spectator_dispatches.size() == 1
		and bool(first_dispatch.get("include_route_spectator", false))
		and (first_dispatch.get("settlement", {}) as Dictionary).is_empty(),
		(
			"ACTIVE 重连无法恢复战场时，必须先发路线旁观状态，"
			+ "并保留等待权威结算的定向同步记录。"
		)
	)

	_coordinator._pending_settlement = {
		"occurrence_key": occurrence_key,
		"victory": true,
		"final_xirang_by_peer": {1: 2600, 3: 3120},
		"inventory_snapshots_by_peer": {
			1: {"peer_id": 1, "slots": []},
			3: {"peer_id": 3, "slots": ["rewarded"]},
		},
		"results_by_peer": {
			1: {"peer_id": 1, "victory": true},
			3: {"peer_id": 3, "victory": true, "item_rewards": []},
		},
	}
	_coordinator._settlement_received = true
	_coordinator._poll_pending_terminal_spectator_syncs()
	var second_dispatch := (
		_coordinator.terminal_spectator_dispatches[1]
		if _coordinator.terminal_spectator_dispatches.size() > 1
		else {}
	) as Dictionary
	var delivered_settlement := (
		second_dispatch.get("settlement", {}) as Dictionary
	)
	_expect(
		not _coordinator._pending_terminal_spectator_syncs.has(3)
		and _coordinator.terminal_spectator_dispatches.size() == 2
		and not bool(second_dispatch.get("include_route_spectator", true))
		and int(
			(delivered_settlement.get("final_xirang_by_peer", {}) as Dictionary)
			.get(3, -1)
		) == 3120,
		(
			"权威胜利结算生成后，已降级的新 peer 必须恰好再收到一次"
			+ "背包/息壤/奖励 settlement，且不能重复发送旁观切换。"
		)
	)
	_fake_net_manager.send_ready_peer_ids.erase(3)
	_reset_fixture_state()


func _test_route_spectator_settlement_converges_economy() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:spectator-economy:4c"
	var node_id := 44
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	run_state.register_multiplayer_peer_state(1)
	run_state.register_multiplayer_peer_state(2)
	run_state.register_multiplayer_peer_state(3)
	_expect(
		run_state.try_add_item_count_for_peer(2, WOOD_MATERIAL, 1),
		"观战结算夹具必须先建立旧客户端背包。"
	)

	var authoritative := RunStateStore.new()
	authoritative.begin_new_run(&"weishidaier", false)
	authoritative.register_multiplayer_peer_state(1)
	authoritative.register_multiplayer_peer_state(2)
	authoritative.register_multiplayer_peer_state(3)
	_expect(
		authoritative.try_add_item_count_for_peer(2, WOOD_MATERIAL, 1)
		and authoritative.try_add_item_count_for_peer(2, WOOD_MATERIAL, 4)
		and authoritative.set_party_xirang_balances({1: 600, 2: 777, 3: 333}),
		(
			"观战结算夹具必须从客户端已知基线继续推进 Host revision，"
			+ "不能制造同 revision 异内容的伪权威快照。"
		)
	)

	_fake_net_manager.host_role = false
	_fake_net_manager.local_peer_id = 2
	_route._multiplayer_avatar_mode = true
	_route._local_peer_id = 2
	_expect(
		_route.add_multiplayer_player(
			2,
			"Spectator",
			PlayerCharacterRegistry.WEISHIDAIER_ID,
			Vector2.ZERO
		),
		"观战结算夹具必须创建路线角色。"
	)
	var route_player := _route.get_player_for_peer(2)
	var late_join_route_player := _route.get_player_for_peer(3)
	if late_join_route_player == null and _route.peer_players.has(3):
		# 前序重连夹具可能留下已释放节点的字典占位；该 smoke 在同一 Route
		# 复用多组身份，先清掉无效测试键再创建本组真实 late spectator。
		_route.peer_players.erase(3)
		_route._player_names.erase(3)
		_route._player_character_ids.erase(3)
		_route._player_stable_keys.erase(3)
	_expect(
		late_join_route_player != null
		or _route.add_multiplayer_player(
			3,
			"PureLateJoinSpectator",
			PlayerCharacterRegistry.WEISHIDAIER_ID,
			Vector2(32.0, 0.0)
		),
		"终局观战恢复夹具必须创建未参战的 late-join 路线角色。"
	)
	late_join_route_player = _route.get_player_for_peer(3)
	if route_player != null:
		route_player.current_xirang = 100
		route_player.current_health = 7
	if late_join_route_player != null:
		late_join_route_player.current_health = 9
	_seed_route_combat(node_id, 4404, occurrence_key)
	var settlement := {
		"node_id": node_id,
		"occurrence_key": occurrence_key,
		"victory": true,
		"consume_node": true,
		"final_xirang_by_peer": {1: 600, 2: 777},
		"inventory_snapshots_by_peer": {
			1: authoritative.export_inventory_snapshot_for_peer(1),
			2: authoritative.export_inventory_snapshot_for_peer(2),
		},
		"results_by_peer": {
			1: {"peer_id": 1, "victory": true},
			2: {"peer_id": 2, "victory": true},
		},
		"party_xirang_ledger": authoritative.export_party_xirang_ledger(),
	}
	var economy_probe := run_state.export_party_economy_snapshot(
		PackedInt32Array([1, 2])
	)
	economy_probe["inventories"] = [
		(settlement["inventory_snapshots_by_peer"] as Dictionary)[1],
		(settlement["inventory_snapshots_by_peer"] as Dictionary)[2],
	]
	economy_probe["xirang_ledger"] = settlement["party_xirang_ledger"]
	_expect(
		run_state.validate_party_economy_snapshot(economy_probe),
		"终局观战经济夹具的 participant 背包与完整 Party 账本必须可原子预检。"
	)

	# 模拟参战者在终局重连后降级观战：release 必须在 reset 前冻结 {1,2}，
	# 不能让随后变成空字典的活跃 roster 治疗未参战的 peer 3。
	_coordinator._phase = COORDINATOR.ProtocolPhase.SETTLED
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._settlement_received = true
	_coordinator._pending_settlement = settlement.duplicate(true)
	_coordinator._release_local_combat_to_route_spectator(occurrence_key)
	_expect(
		run_state.get_inventory_item_total_for_peer(2, WOOD_MATERIAL) == 5
		and run_state.get_inventory_revision_for_peer(2)
		== authoritative.get_inventory_revision_for_peer(2)
		and run_state.get_party_xirang_balance(2) == 777
		and route_player != null
		and route_player.current_xirang == 777
		and route_player.current_health == route_player.max_health
		and late_join_route_player != null
		and late_join_route_player.current_health == 9,
		(
			"终局重连观战者必须收敛背包/息壤并满血，"
			+ "pure late-join spectator 的生命值必须保持不变："
			+ "items=%d balance=%d participant_hp=%d late_hp=%d key=%s。"
			% [
				run_state.get_inventory_item_total_for_peer(2, WOOD_MATERIAL),
				run_state.get_party_xirang_balance(2),
				route_player.current_health if route_player != null else -1,
				(
					late_join_route_player.current_health
					if late_join_route_player != null
					else -1
				),
				_coordinator._route_spectator_occurrence_key,
			]
		)
	)
	_route._sync_route_player_xirang_from_run_state()
	_expect(
		route_player != null and route_player.current_xirang == 777,
		"后续路线事件从 RunState 重载时不得把战后息壤回退到战前值。"
	)
	_expect(
		not _route.is_normal_combat_active()
		and _route._route_presentation_enabled
		and _coordinator._route_spectator_occurrence_key.is_empty()
		and _coordinator._consumed_node_ids.has(node_id)
		and _coordinator._phase == COORDINATOR.ProtocolPhase.IDLE,
		"观战经济结算必须结束本地路线战斗且不进入胜利/terminal 流程。"
	)
	# fresh reconnect 进程从未持有 ACTIVE roster，只能从三张已校验且 exact-key
	# 的 Host settlement map 恢复本地真实 participant。
	var fresh_occurrence_key := "%s:fresh" % occurrence_key
	var fresh_settlement := settlement.duplicate(true)
	fresh_settlement["occurrence_key"] = fresh_occurrence_key
	fresh_settlement["node_id"] = node_id + 1
	fresh_settlement["consume_node"] = false
	if route_player != null:
		route_player.current_health = 5
	_seed_route_combat(node_id + 1, 4405, fresh_occurrence_key)
	_coordinator._route_spectator_occurrence_key = fresh_occurrence_key
	_coordinator._route_spectator_participant_peer_ids.clear()
	var fresh_participant_applied := (
		_coordinator._apply_route_spectator_settlement(
			fresh_occurrence_key,
			fresh_settlement,
			{}
		)
	)
	_expect(
		fresh_participant_applied
		and route_player != null
		and route_player.current_health == route_player.max_health
		and late_join_route_player != null
		and late_join_route_player.current_health == 9,
		"fresh terminal participant 必须从 exact settlement keyset 恢复，late spectator 不变。"
	)

	# 同一份 participant settlement 不含 peer 3；pure late joiner 即使先收到
	# route-spectator 状态，也不能从空本地 roster 推导出治疗权限。
	var pure_late_occurrence_key := "%s:pure-late" % occurrence_key
	var pure_late_settlement := settlement.duplicate(true)
	pure_late_settlement["occurrence_key"] = pure_late_occurrence_key
	_fake_net_manager.local_peer_id = 3
	if late_join_route_player != null:
		late_join_route_player.current_health = 8
	_coordinator._route_spectator_occurrence_key = pure_late_occurrence_key
	_coordinator._route_spectator_participant_peer_ids.clear()
	_expect(
		not _coordinator._apply_route_spectator_settlement(
			pure_late_occurrence_key,
			pure_late_settlement,
			{}
		)
		and late_join_route_player != null
		and late_join_route_player.current_health == 8,
		"pure late-join spectator 不在 settlement keyset 时必须零治疗拒绝。"
	)
	_coordinator._route_spectator_occurrence_key = ""
	_coordinator._route_spectator_participant_peer_ids.clear()
	_fake_net_manager.local_peer_id = 2
	_route.remove_multiplayer_player(2)
	_route.remove_multiplayer_player(3)
	_route._multiplayer_avatar_mode = false
	_fake_net_manager.host_role = true
	_fake_net_manager.local_peer_id = 1
	authoritative.free()
	_reset_fixture_state()


func _test_precombat_disconnect_reconnect_stays_route_spectator() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:precombat-left:5"
	_coordinator._phase = COORDINATOR.ProtocolPhase.ACTIVE
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._entry_xirang_by_peer = {1: 500, 2: 500}
	_coordinator._reconnecting_peer_ids[4] = true

	# old=3 left before the combat roster was frozen and therefore has no
	# disconnected-participant record. Its new identity must remain on the route.
	_coordinator._finish_player_reconnected(3, 4)

	_expect(
		_coordinator._participant_peer_ids == {1: true, 2: true}
		and not _coordinator._entry_xirang_by_peer.has(4),
		"A pre-combat leaver must not join the frozen combat or settlement roster on reconnect."
	)
	_expect(
		not _coordinator._reconnecting_peer_ids.has(4)
		and _coordinator._pending_spectator_peers.has(4),
		"A non-participant reconnect must be queued for an explicit route-spectator sync."
	)


func _test_prepared_barrier_reveals_before_single_activation() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:entry-reveal:5"
	_seed_route_combat(15, 1505, occurrence_key)
	_expect(
		_coordinator._begin_protocol(
			15,
			1505,
			occurrence_key,
			PackedInt32Array([1, 2]),
			{1: 500, 2: 500},
			false,
			FORMAL_CONFIG.encounter_id,
			FORMAL_CONFIG
		),
		"入口 reveal 夹具必须先进入 PREPARING。"
	)
	var runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	runtime.name = "EntryRevealRuntime"
	runtime.activation_result = true
	_coordinator.add_child(runtime)
	_coordinator._combat_network = runtime
	_coordinator._local_runtime_prepared = true
	_coordinator._expected_prepared_peers = {1: true, 2: true}
	_coordinator._prepared_peers = {1: true}
	_set_entry_transition_covered()

	_coordinator._try_activate_host_barrier()
	_expect(
		not _coordinator._activation_dispatch_started
		and not _coordinator._local_activation_requested
		and runtime.activation_calls == 0
		and _route.combat_scene_transition.is_covered(),
		"全员 prepared 前不得 dispatch、reveal 或激活本地战场。"
	)

	_coordinator._prepared_peers[2] = true
	_coordinator._try_activate_host_barrier()
	_expect(
		_coordinator._activation_dispatch_started
		and _coordinator._local_activation_requested
		and runtime.activation_calls == 0,
		"全员 prepared 后只能先请求 entry reveal，不能同步抢跑 activate。"
	)
	await process_frame
	var reveal_serial := int(
		_route.combat_scene_transition.get("_transition_serial")
	)
	_expect(
		bool(_coordinator._request_local_runtime_activation())
		and int(_route.combat_scene_transition.get("_transition_serial"))
		== reveal_serial
		and runtime.activation_calls == 0,
		"重复 activation 请求必须复用正在进行的 reveal，不得重启 Tween。"
	)
	await create_timer(
		RogueSceneTransition.REVEAL_DURATION_SECONDS + 0.08,
		true
	).timeout
	_expect(
		_coordinator._phase == COORDINATOR.ProtocolPhase.ACTIVE
		and _coordinator._local_runtime_activated
		and runtime.activation_calls == 1
		and not _route.combat_scene_transition.visible,
		"prepared barrier 完成后必须等待 reveal 结束，再且仅激活一次运行时。"
	)
	var serial_after_activation := int(
		_route.combat_scene_transition.get("_transition_serial")
	)
	_expect(
		bool(_coordinator._request_local_runtime_activation())
		and runtime.activation_calls == 1
		and int(_route.combat_scene_transition.get("_transition_serial"))
		== serial_after_activation,
		"ACTIVE 后的重复 activation 包必须幂等，不能重复激活或再次 reveal。"
	)


func _test_dispatch_window_reconnect_skips_completed_barrier() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:dispatch-reconnect:6"
	_coordinator._phase = COORDINATOR.ProtocolPhase.PREPARING
	_coordinator._active_node_id = 16
	_coordinator._active_content_seed = 1606
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true, 2: true}
	_coordinator._entry_xirang_by_peer = {1: 500, 2: 700}
	_coordinator._disconnected_participants = {
		2: {
			"entry_xirang": 700,
			"was_prepared": true,
			"was_terminal_ready": false,
		},
	}
	_coordinator._expected_prepared_peers = {1: true}
	_coordinator._prepared_peers = {1: true}
	_coordinator._activation_dispatch_started = true
	_coordinator._activate_when_prepared = true

	_coordinator._finish_player_reconnected(2, 3)
	var coordinator_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/rogue/combat/rogue_combat_multiplayer_coordinator.gd"
	)
	_expect(
		not _coordinator._participant_peer_ids.has(2)
		and _coordinator._participant_peer_ids.has(3)
		and not _coordinator._expected_prepared_peers.has(3),
		"activation 已 dispatch 的 reveal 窗口内，重连 peer 不得重新加入已结束 barrier。"
	)
	_expect(
		coordinator_source.contains(
			"] or _activation_dispatch_started"
		),
		"dispatch 窗口重连的 net_combat_prepare 必须携带 activate_immediately。"
	)


func _test_abort_during_entry_reveal_clears_cover() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:entry-abort:7"
	_seed_route_combat(17, 1707, occurrence_key)
	_expect(
		_coordinator._begin_protocol(
			17,
			1707,
			occurrence_key,
			PackedInt32Array([1]),
			{1: 700},
			false,
			FORMAL_CONFIG.encounter_id,
			FORMAL_CONFIG
		),
		"入口 abort 夹具必须先进入 PREPARING。"
	)
	var runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	runtime.name = "EntryAbortRuntime"
	runtime.activation_result = true
	_coordinator.add_child(runtime)
	_coordinator._combat_network = runtime
	_coordinator._local_runtime_prepared = true
	_coordinator._expected_prepared_peers = {1: true}
	_coordinator._prepared_peers = {1: true}
	_set_entry_transition_covered()
	_coordinator._try_activate_host_barrier()
	await process_frame
	_expect(
		_coordinator._activation_dispatch_started
		and _route.combat_scene_transition.visible
		and not _coordinator._local_runtime_activated,
		"abort 前置必须处于 entry reveal 中且尚未激活战场。"
	)

	_coordinator._abort_authoritative_protocol(&"test_abort_during_reveal")
	_expect(
		not _route.combat_scene_transition.visible
		and is_zero_approx(_route.combat_scene_transition.progress),
		"权威 abort 必须立即清除 shader cover 与鼠标遮挡。"
	)
	await create_timer(
		RogueSceneTransition.REVEAL_DURATION_SECONDS + 0.08,
		true
	).timeout
	_expect(
		_coordinator._phase == COORDINATOR.ProtocolPhase.IDLE
		and not _coordinator._local_runtime_activated
		and not _route.combat_scene_transition.visible,
		"被 abort 的旧 reveal 协程结束后不得复活或激活已释放战场。"
	)


func _test_route_reset_aborts_terminal_sequence() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:victory-reset:5"
	_seed_route_combat(15, 1505, occurrence_key)
	_route.set_route_presentation_enabled(false)
	_coordinator._phase = COORDINATOR.ProtocolPhase.SETTLED
	_coordinator._active_node_id = 15
	_coordinator._active_content_seed = 1505
	_coordinator._active_occurrence_key = occurrence_key
	_coordinator._participant_peer_ids = {1: true}
	_coordinator._settlement_received = true
	_coordinator._local_outcome_received = true
	_coordinator._local_outcome_victory = true
	_coordinator._local_terminal_finalized = true
	_coordinator._local_result_occurrence_key = occurrence_key
	var runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	runtime.name = "InterruptedVictoryRuntime"
	_coordinator.add_child(runtime)
	_coordinator._combat_network = runtime

	_route._reset_normal_combat_stage(true)
	await process_frame

	_expect(
		_coordinator._phase == COORDINATOR.ProtocolPhase.IDLE
		and _coordinator._combat_network == null
		and _coordinator._active_occurrence_key.is_empty(),
		"胜利演出中的路线重置必须进入权威 abort，不能遗留 terminal barrier。"
	)
	_expect(
		not _route.is_normal_combat_active()
		and _route.get_node("World").visible
		and not _route.combat_victory_presentation.visible
		and not _route.combat_scene_transition.visible,
		"胜利演出中断后必须恢复路线并清空标题与转场。"
	)


func _test_authoritative_prepare_failure_aborts_safely() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:prepare-failed:5"
	_seed_route_combat(15, 1505, occurrence_key)
	_coordinator.create_runtime_result = false
	var began := _coordinator._begin_protocol(
		15,
		1505,
		occurrence_key,
		PackedInt32Array([1]),
		{1: 500},
		false,
		FORMAL_CONFIG.encounter_id,
		FORMAL_CONFIG
	)
	_expect(not began, "运行时创建失败时 _begin_protocol 必须返回 false。")

	# 与房主 _on_normal_combat_requested 的失败分支相同：创建失败后权威 abort。
	_coordinator._abort_authoritative_protocol(&"host_runtime_create_failed")
	_assert_abort_recovered(15, "prepare/create 失败")


func _test_authoritative_config_failure_aborts_safely() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:config-failed:6"
	_seed_route_combat(16, 1606, occurrence_key)
	_coordinator.create_runtime_result = true
	var began := _coordinator._begin_protocol(
		16,
		1606,
		occurrence_key,
		PackedInt32Array([1]),
		{1: 600},
		false,
		FORMAL_CONFIG.encounter_id,
		FORMAL_CONFIG
	)
	_expect(began, "config 失败用例应先进入 PREPARING。")
	var invalid_runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	invalid_runtime.name = "RuntimeWithoutGameRuntime"
	_coordinator.add_child(invalid_runtime)
	_coordinator._combat_network = invalid_runtime
	_expect(
		not _coordinator._configure_occurrence_runtime(),
		"多人会话尚无 CombatRuntimeBase 时 occurrence 配置必须失败。"
	)

	# _on_embedded_runtime_prepared 对这个 false 执行同一个房主权威 abort；
	# 这里直接进入该权威分支，避免把预期失败写成测试框架错误日志。
	_coordinator._abort_authoritative_protocol(&"runtime_config_failed")
	_assert_abort_recovered(16, "config 失败")


func _test_authoritative_activation_failure_aborts_safely() -> void:
	_reset_fixture_state()
	var occurrence_key := "combat:runtime:activate-failed:7"
	_seed_route_combat(17, 1707, occurrence_key)
	_coordinator.create_runtime_result = true
	var began := _coordinator._begin_protocol(
		17,
		1707,
		occurrence_key,
		PackedInt32Array([1]),
		{1: 700},
		false,
		FORMAL_CONFIG.encounter_id,
		FORMAL_CONFIG
	)
	_expect(began, "activate 失败用例应先进入 PREPARING。")
	var failing_runtime := (
		FAKE_EMBEDDED_RUNTIME.instantiate()
		as RogueCombatMultiplayerTestSession
	)
	failing_runtime.name = "RuntimeRejectingActivation"
	failing_runtime.activation_result = false
	_coordinator.add_child(failing_runtime)
	_coordinator._combat_network = failing_runtime
	_coordinator._local_runtime_prepared = true
	_coordinator._expected_prepared_peers = {1: true}
	_coordinator._prepared_peers = {1: true}

	# 真实 barrier 会先异步等待 entry reveal，再调用 _activate_local_runtime；
	# false 后进入同一房主权威 abort 分支。
	_coordinator._try_activate_host_barrier()
	await process_frame
	await process_frame
	_assert_abort_recovered(17, "activate 失败")


func _assert_abort_recovered(node_id: int, context: String) -> void:
	_expect(
		_coordinator._phase == COORDINATOR.ProtocolPhase.IDLE
		and _coordinator._active_occurrence_key.is_empty(),
		"%s后协议必须回到 IDLE。" % context
	)
	_expect(
		not _route.is_normal_combat_active()
		and _route._route_presentation_enabled,
		"%s后必须完成作战阶段并恢复路线显示。" % context
	)
	_expect(
		not _coordinator._consumed_node_ids.has(node_id),
		"%s属于技术回滚，不得消费战斗节点。" % context
	)
	_expect(
		_coordinator._combat_network == null,
		"%s后不得保留嵌入战场引用。" % context
	)
	_expect(
		not _route.combat_scene_transition.visible
		and is_zero_approx(_route.combat_scene_transition.progress),
		"%s后不得残留入口 shader cover。" % context
	)


func _reset_fixture_state() -> void:
	if (
		_coordinator._combat_network != null
		and is_instance_valid(_coordinator._combat_network)
	):
		_coordinator._combat_network.queue_free()
	_coordinator._combat_network = null
	_coordinator._combat_game = null
	_coordinator._reset_protocol_state()
	_coordinator._pending_terminal_spectator_syncs.clear()
	_coordinator._clear_local_result_lifecycle()
	_coordinator._consumed_node_ids.clear()
	_coordinator.create_runtime_result = true
	_coordinator.terminal_spectator_dispatches.clear()
	_coordinator.host_settlement_commit_result = true
	_coordinator.host_settlement_commit_uses_super = false
	_coordinator.host_settlement_commit_observations.clear()
	_coordinator.host_settlement_broadcasts.clear()
	_coordinator.settlement_event_order.clear()
	_coordinator.reconnect_prepare_dispatches.clear()
	_fake_net_manager.send_ready_peer_ids.clear()
	_fake_net_manager.reconnect_delivery_preparing_peer_ids.clear()
	_fake_net_manager.reconnecting_peer_ids.clear()
	_fake_net_manager.participant_incarnations.clear()
	_fake_net_manager.runtime_projection_reports.clear()
	_fake_net_manager.terminated_projection_peers.clear()
	_fake_net_manager.terminated_membership_projection_reasons.clear()
	_fake_net_manager.accepted_projection_outcomes.clear()
	_fake_net_manager.host_role = true
	_fake_net_manager.local_peer_id = 1
	_coordinator._session_projection_owner = (
		RogueCombatMultiplayerCoordinator.SessionProjectionOwner.THIS_COORDINATOR
	)
	_route.hide_combat_result()
	_route._clear_normal_combat_state()
	_route.set_route_presentation_enabled(true)


func _seed_route_combat(
	node_id: int,
	content_seed: int,
	occurrence_key: String
) -> void:
	_route._normal_combat_active = true
	_route._normal_combat_node_id = node_id
	_route._normal_combat_content_seed = content_seed
	_route._normal_combat_visit_count = 1
	_route._normal_combat_occurrence_key = occurrence_key


func _set_entry_transition_covered() -> void:
	_route.combat_scene_transition.visible = true
	_route.combat_scene_transition.call(&"_set_progress", 1.0)


func _inventory_contents(snapshot: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for slot_variant in snapshot.get("slots", []) as Array:
		var slot := slot_variant as Dictionary
		result.append({
			"slot_index": int(slot.get("slot_index", -1)),
			"config_path": str(slot.get("config_path", "")),
			"stack_count": int(slot.get("stack_count", 0)),
		})
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
