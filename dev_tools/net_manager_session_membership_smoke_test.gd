extends SceneTree

const TOKEN_A := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const TOKEN_B := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const RELAY_SERVER_SCRIPT := preload(
	"res://relay_servers/relay_godot_project/relay_server.gd"
)


class HostProbe:
	extends NetManagerStore
	var roster_broadcast_count := 0
	var reconnect_ready_count := 0
	var reconnect_preparation_count := 0
	var reconnect_preparation_should_succeed := true
	var preparation_observed_reconnecting := false
	var preparation_observed_ingress_closed := false
	var publication_events: Array[StringName] = []
	var host_role := true
	var relay_kick_targets := PackedInt32Array()
	var disconnect_on_relay_kick := false

	func is_host() -> bool:
		return host_role

	func is_client() -> bool:
		return false

	func get_local_peer_id() -> int:
		return 1

	func _request_relay_peer_disconnect(peer_id: int) -> bool:
		if peer_id <= 0:
			return false
		relay_kick_targets.append(peer_id)
		if disconnect_on_relay_kick:
			call_deferred("_on_peer_disconnected", peer_id)
		return true

	func seed_peer_token(peer_id: int, token: String) -> void:
		_peer_reconnect_tokens[peer_id] = token

	func seed_pending_reconnect(new_peer_id: int, old_peer_id: int, token: String) -> void:
		_pending_reconnect_loads[new_peer_id] = {
			"old_peer_id": old_peer_id,
			"token": token,
			"deadline_msec": Time.get_ticks_msec() + 10_000,
			"grace_expires_msec": Time.get_ticks_msec() + 20_000,
			"phase": int(ReconnectPendingPhase.LOADING),
		}

	func _broadcast_player_list_to_clients() -> void:
		roster_broadcast_count += 1
		publication_events.append(&"roster")

	func _can_send_reconnect_game_ready_to_peer(_peer_id: int) -> bool:
		return true

	func _send_reconnect_game_ready_to_peer(_peer_id: int) -> void:
		reconnect_ready_count += 1
		publication_events.append(&"host_ready")

	func _activate_reconnecting_session_member(peer_id: int) -> bool:
		publication_events.append(&"active")
		return super._activate_reconnecting_session_member(peer_id)

	func prepare_reconnect_delivery(
		_old_peer_id: int,
		new_peer_id: int,
		_outcome: MultiplayerReconnectTypes.RuntimeProjectionOutcome,
		_membership_revision: int
	) -> bool:
		reconnect_preparation_count += 1
		publication_events.append(&"prepare")
		preparation_observed_reconnecting = is_session_member_reconnecting(
			new_peer_id
		)
		preparation_observed_ingress_closed = (
			not is_gameplay_ingress_admitted(new_peer_id)
			and not is_peer_send_ready(new_peer_id)
		)
		return reconnect_preparation_should_succeed

	func is_peer_control_send_ready(peer_id: int) -> bool:
		var pending := _pending_reconnect_loads.get(peer_id, {}) as Dictionary
		return (
			not pending.is_empty()
			and not _forced_final_departure_peer_ids.has(peer_id)
			and int(pending.get("phase", -1))
			== int(ReconnectPendingPhase.PREPARING_DELIVERY)
			and bool(pending.get("delivery_preparation_active", false))
		)


class ClientProbe:
	extends NetManagerStore

	func is_host() -> bool:
		return false

	func is_client() -> bool:
		return true

	func get_local_peer_id() -> int:
		return 4


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_game_session_incarnation_is_monotonic()
	_test_participant_incarnation_is_monotonic_and_never_reused()
	_test_gameplay_ingress_admission_lifecycle()
	_test_reconnect_delivery_preparer_has_unique_owner()
	_test_loading_disconnect_is_final()
	_test_ingame_disconnect_enters_single_grace()
	_test_reconnect_setup_contains_other_grace_members()
	_test_same_transport_id_reconnect_fails_before_consuming_slot()
	_test_cross_suspended_transport_id_reconnect_is_rejected()
	_test_same_membership_revision_still_applies_room_context()
	_test_reconnect_identity_application_is_atomic()
	_test_reconnect_ready_waits_for_runtime_projection()
	_test_reconnect_delivery_preparation_failure_is_fail_closed()
	_test_missed_identity_is_inferred_from_participant()
	_test_timed_out_projection_cannot_extend_grace()
	_test_stale_deadline_cannot_expire_new_phase()
	await _test_relay_host_kick_control()
	await _test_relay_timeout_finalizes_member()
	_test_invalid_participant_rosters_are_rejected()
	_test_grace_expiry_is_final()
	_test_projection_failure_cannot_create_new_grace()
	call_deferred("_finish")


func _test_game_session_incarnation_is_monotonic() -> void:
	var manager := NetManagerStore.new()
	root.add_child(manager)
	var first := int(manager.call("_issue_next_game_session_incarnation"))
	# 模拟 disconnect 只清当前会话；隐藏分配水位必须继续保留。
	manager.loading_session_id = 0
	var second := int(manager.call("_issue_next_game_session_incarnation"))
	manager.loading_session_id = 100
	var after_observed_remote := int(
		manager.call("_issue_next_game_session_incarnation")
	)
	_expect(
		first == 1
		and second == 2
		and after_observed_remote == 101
		and manager.get_game_session_incarnation() == 100,
		"Host 会话世代必须跨断线单调递增，并高于本进程见过的当前世代。"
	)
	manager.free()


func _test_reconnect_delivery_preparer_has_unique_owner() -> void:
	var manager := HostProbe.new()
	root.add_child(manager)
	var first := Callable(self, "_fixture_reconnect_preparer_true")
	var second := Callable(self, "_fixture_reconnect_preparer_false")
	_expect(
		manager.register_reconnect_delivery_preparer(first)
		and manager.register_reconnect_delivery_preparer(first)
		and not manager.register_reconnect_delivery_preparer(second)
		and not manager.unregister_reconnect_delivery_preparer(second)
		and manager.unregister_reconnect_delivery_preparer(first)
		and manager.register_reconnect_delivery_preparer(second),
		"重连 prepare 能力必须单一所有、同 owner 幂等，并且只能由 owner 释放。"
	)
	manager.free()


func _fixture_reconnect_preparer_true(
	_old_peer_id: int,
	_new_peer_id: int,
	_outcome: MultiplayerReconnectTypes.RuntimeProjectionOutcome,
	_membership_revision: int
) -> bool:
	return true


func _fixture_reconnect_preparer_false(
	_old_peer_id: int,
	_new_peer_id: int,
	_outcome: MultiplayerReconnectTypes.RuntimeProjectionOutcome,
	_membership_revision: int
) -> bool:
	return false


func _test_participant_incarnation_is_monotonic_and_never_reused() -> void:
	var host := _make_host_fixture(NetManagerStore.ConnectionState.IN_GAME)
	var retired_incarnation := host.get_session_participant_incarnation(2)
	_expect(
		retired_incarnation > 0
		and host.resolve_session_participant_peer_id(retired_incarnation) == 2,
		"Host 必须为成员分配可反查当前 peer 的正数 participant incarnation。"
	)
	# LOADING 断线是无宽限的真实 final departure，随后复用同一个 raw ID。
	host.connection_state = NetManagerStore.ConnectionState.LOADING_GAME
	host.call("_on_peer_disconnected", 2)
	host.connected_players[2] = "Replacement"
	host.connected_player_characters[2] = PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	host.confirmed_character_peers[2] = true
	_expect(
		host.call(
			"_register_active_session_member",
			2,
			"Replacement",
			PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
			true,
			TOKEN_B
		),
		"最终离场后必须允许一个新成员重新占用同一 transport ID。"
	)
	var replacement_incarnation := host.get_session_participant_incarnation(2)
	_expect(
		replacement_incarnation > retired_incarnation
		and host.resolve_session_participant_peer_id(retired_incarnation) == 0
		and host.resolve_session_participant_peer_id(replacement_incarnation) == 2,
		"transport ID 复用后必须分配新成员世代，旧世代不得解析到新人。"
	)
	host.call("_reset_session_membership")
	_expect(
		host.call(
			"_register_active_session_member",
			9,
			"AfterReset",
			PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
			true,
			TOKEN_A
		)
		and host.get_session_participant_incarnation(9) > replacement_incarnation,
		"成员表 reset 只能清当前租约，不得回退 Host 的成员世代水位。"
	)
	host.free()


func _test_gameplay_ingress_admission_lifecycle() -> void:
	var host := _make_host_fixture(NetManagerStore.ConnectionState.IN_GAME)
	_expect(
		host.is_gameplay_ingress_admitted(2),
		"IN_GAME 的 ACTIVE transport 必须允许玩法入站。"
	)
	host.host_role = false
	_expect(
		not host.is_gameplay_ingress_admitted(2),
		"非 Host 节点不得把收到的包当作权威玩法入站。"
	)
	host.host_role = true
	host.connection_state = NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY
	_expect(
		not host.is_gameplay_ingress_admitted(2),
		"Host 尚未进入 IN_GAME 时不得接受玩法入站。"
	)
	host.connection_state = NetManagerStore.ConnectionState.IN_GAME
	host.connected_players.erase(2)
	_expect(
		not host.is_gameplay_ingress_admitted(2),
		"成员 ACTIVE 但 transport 已断开时不得接受玩法入站。"
	)
	host.connected_players[2] = "Alpha"
	var member := (host._session_members[2] as Dictionary).duplicate(true)
	member["state"] = int(NetManagerStore.SessionMemberState.RECONNECTING)
	host._session_members[2] = member
	_expect(
		not host.is_gameplay_ingress_admitted(2),
		"RECONNECTING 成员在 Player ready 前必须拒绝玩法入站。"
	)
	member["state"] = int(NetManagerStore.SessionMemberState.SUSPENDED_GRACE)
	host._session_members[2] = member
	_expect(
		not host.is_gameplay_ingress_admitted(2),
		"SUSPENDED_GRACE 成员即使 transport 字典残留也不得进入玩法。"
	)
	member["state"] = int(NetManagerStore.SessionMemberState.ACTIVE)
	host._session_members[2] = member
	host._pending_reconnect_loads[2] = {"old_peer_id": 9}
	_expect(
		not host.is_gameplay_ingress_admitted(2),
		"pending reconnect 必须优先于 ACTIVE 投影关闭玩法入站。"
	)
	host._pending_reconnect_loads.erase(2)
	host._forced_final_departure_peer_ids[2] = true
	_expect(
		not host.is_gameplay_ingress_admitted(2),
		"投影失败进入 forced final 后必须立即关闭玩法入站。"
	)
	host._forced_final_departure_peer_ids.erase(2)
	host._session_projection_failure_active = true
	_expect(
		not host.is_gameplay_ingress_admitted(2),
		"会话投影故障必须统一关闭所有玩法入站。"
	)
	host._session_projection_failure_active = false
	host._session_members.erase(2)
	_expect(
		not host.is_gameplay_ingress_admitted(2),
		"final departure 后不得仅凭 connected transport 重新进入玩法。"
	)
	host.free()


func _test_loading_disconnect_is_final() -> void:
	var host := _make_host_fixture(NetManagerStore.ConnectionState.LOADING_GAME)
	var final_events: Array[Dictionary] = []
	var lifecycle_order: Array[StringName] = []
	host.player_left.connect(
		func(_peer_id: int) -> void:
			lifecycle_order.append(&"transport_left")
	)
	host.session_member_final_departed.connect(
		func(peer_id: int, revision: int, reason: StringName) -> void:
			lifecycle_order.append(&"final_departure")
			final_events.append({
				"peer_id": peer_id,
				"revision": revision,
				"reason": reason,
			})
	)
	host.call("_on_peer_disconnected", 2)
	_expect(
		not host.has_session_member(2)
		and host.get_session_member_peer_ids() == PackedInt32Array([1])
		and final_events.size() == 1
		and int(final_events[0].get("peer_id", 0)) == 2
		and StringName(final_events[0].get("reason", &""))
		== NetManagerStore.FINAL_DEPARTURE_DISCONNECTED
		and lifecycle_order == [&"transport_left", &"final_departure"],
		"LOADING_GAME 断线没有重连宽限，必须立即发布 final departure。"
	)
	host.free()


func _test_ingame_disconnect_enters_single_grace() -> void:
	var host := _make_host_fixture(NetManagerStore.ConnectionState.IN_GAME)
	var counters := {"final": 0}
	host.session_member_final_departed.connect(
		func(_peer_id: int, _revision: int, _reason: StringName) -> void:
			counters["final"] = int(counters["final"]) + 1
	)
	var revision_before := host.get_session_membership_revision()
	host.call("_on_peer_disconnected", 2)
	var reconnect_slots := host.get("_disconnected_reconnect_slots") as Dictionary
	_expect(
		host.has_session_member(2)
		and host.is_session_member_suspended(2)
		and not host.connected_players.has(2)
		and host.get_session_membership_revision() == revision_before + 1
		and int(reconnect_slots.get(TOKEN_A, 0)) == 2
		and int(counters["final"]) == 0,
		"IN_GAME 合法断线必须只产生一个 SUSPENDED_GRACE 成员，不能提前离场。"
	)
	host.free()


func _test_reconnect_setup_contains_other_grace_members() -> void:
	var host := _make_host_fixture(NetManagerStore.ConnectionState.IN_GAME, true)
	host.call("_on_peer_disconnected", 2)
	host.call("_on_peer_disconnected", 3)
	host.connected_players[4] = "Alpha"
	host.connected_player_characters[4] = PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	host.confirmed_character_peers[4] = true
	host.seed_pending_reconnect(4, 2, TOKEN_A)
	var setup_roster := host.call("_build_session_member_list_array", 4) as Array
	var old_participant_incarnation := host.get_session_participant_incarnation(2)
	var reconnect_wire_incarnation := 0
	for entry_variant in setup_roster:
		var entry := entry_variant as Dictionary
		if int(entry.get("id", 0)) == 4:
			reconnect_wire_incarnation = int(
				entry.get("participant_incarnation", 0)
			)
	var client := ClientProbe.new()
	root.add_child(client)
	client.call(
		"_rpc_sync_player_list",
		setup_roster,
		1,
		int(NetManagerStore.GameMode.STANDARD),
		8,
		host.get_session_membership_revision()
	)
	_expect(
		client.get_session_member_peer_ids() == PackedInt32Array([1, 3, 4])
		and client.is_session_member_active(4)
		and client.is_session_member_suspended(3)
		and not client.has_session_member(2)
		and reconnect_wire_incarnation == old_participant_incarnation
		and client.get_session_participant_incarnation(4)
		== old_participant_incarnation,
		"重连者 CH0 roster 必须用 new 表示自身，并保留其他宽限成员。"
	)
	_expect(
		client.connected_players.keys().size() == 2
		and client.connected_players.has(1)
		and client.connected_players.has(4)
		and not client.connected_players.has(3),
		"SUSPENDED_GRACE 只能进入会话成员表，绝不能污染 transport connected_players。"
	)
	client.free()
	host.free()


func _test_same_membership_revision_still_applies_room_context() -> void:
	var client := ClientProbe.new()
	root.add_child(client)
	var roster := _make_client_roster(2, false)
	client.call(
		"_rpc_sync_player_list",
		roster,
		1,
		int(NetManagerStore.GameMode.STANDARD),
		8,
		5
	)
	client.call(
		"_rpc_sync_player_list",
		roster,
		1,
		int(NetManagerStore.GameMode.TOWER_DEFENSE),
		6,
		5
	)
	_expect(
		client.get_session_membership_revision() == 5
		and client.get_current_game_mode()
		== NetManagerStore.GameMode.TOWER_DEFENSE
		and client.room_max_players == 6
		and client.get_session_member_peer_ids() == PackedInt32Array([1, 2]),
		"同成员同 revision 的 CH0 信封仍必须收敛独立的模式与容量上下文。"
	)
	var conflicting_roster := roster.duplicate(true)
	(conflicting_roster[1] as Dictionary)["name"] = "ConflictingName"
	client.call(
		"_rpc_sync_player_list",
		conflicting_roster,
		1,
		int(NetManagerStore.GameMode.STANDARD),
		4,
		5
	)
	_expect(
		str(client.get_session_player_name_map().get(2, "")) == "Alpha"
		and client.get_current_game_mode()
		== NetManagerStore.GameMode.TOWER_DEFENSE
		and client.room_max_players == 6,
		"同 revision 的成员内容冲突必须整包拒绝，不能顺带改写房间上下文。"
	)
	client.free()


func _test_reconnect_identity_application_is_atomic() -> void:
	var client := ClientProbe.new()
	root.add_child(client)
	client.call(
		"_rpc_sync_player_list",
		_make_client_roster(2, true),
		1,
		int(NetManagerStore.GameMode.STANDARD),
		8,
		7
	)
	var before_conflict := client.get_session_membership_snapshot()
	var old_participant_incarnation := client.get_session_participant_incarnation(2)
	_expect(
		not bool(client.call(
			"_apply_player_reconnected_identity",
			2,
			5,
			"WrongName",
			PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
			8
		))
		and client.get_session_membership_snapshot() == before_conflict
		and not client.connected_players.has(5),
		"重连认证字段冲突必须在写入任何 NetManager 字典前整包拒绝。"
	)
	var reconnect_events := {"count": 0}
	client.player_reconnected.connect(
		func(
			_old_peer_id: int,
			_new_peer_id: int,
			_player_name: String,
			_character_id: StringName,
			_membership_revision: int
		) -> void:
			reconnect_events["count"] = int(reconnect_events["count"]) + 1
	)
	_expect(
		bool(client.call(
			"_apply_player_reconnected_identity",
			2,
			5,
			"Alpha",
			PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
			8
		))
		and not client.has_session_member(2)
		and client.is_session_member_reconnecting(5)
		and not client.connected_players.has(5)
		and client.get_session_membership_revision() == 8
		and client.get_session_participant_incarnation(5)
		== old_participant_incarnation
		and client.resolve_session_participant_peer_id(
			old_participant_incarnation
		) == 5
		and int(reconnect_events["count"]) == 1,
		"合法 old→new 必须先提交 RECONNECTING 身份，不能提前暴露 ACTIVE transport。"
	)
	_expect(
		bool(client.call(
			"_apply_player_reconnected_identity",
			2,
			5,
			"Alpha",
			PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
			8
		))
		and int(reconnect_events["count"]) == 1,
		"完全一致的重连 RPC 重放必须幂等，不能重复发布身份事务。"
	)
	var active_roster := _make_client_roster(5, false)
	(active_roster[1] as Dictionary)["participant_incarnation"] = (
		old_participant_incarnation
	)
	client.call(
		"_rpc_sync_player_list",
		active_roster,
		1,
		int(NetManagerStore.GameMode.STANDARD),
		8,
		9
	)
	_expect(
		client.is_session_member_active(5)
		and client.connected_players.has(5)
		and client.get_session_membership_revision() == 9,
		"只有更高 revision 的 ACTIVE roster 才能开放重连 transport。"
	)
	client.free()

	var collision_client := ClientProbe.new()
	root.add_child(collision_client)
	var collision_roster := _make_client_roster(2, true)
	collision_roster.append({
		"id": 5,
		"participant_incarnation": 505,
		"name": "Other",
		"character_id": String(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID),
		"character_confirmed": true,
		"session_state": int(NetManagerStore.SessionMemberState.ACTIVE),
	})
	collision_client.call(
		"_rpc_sync_player_list",
		collision_roster,
		1,
		int(NetManagerStore.GameMode.STANDARD),
		8,
		9
	)
	var collision_before := collision_client.get_session_membership_snapshot()
	_expect(
		not bool(collision_client.call(
			"_apply_player_reconnected_identity",
			2,
			5,
			"Alpha",
			PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
			10
		))
		and collision_client.get_session_membership_snapshot() == collision_before,
		"new identity 已属于其他成员时必须零写拒绝 old→new 冲突。"
	)
	collision_client.free()


func _test_reconnect_ready_waits_for_runtime_projection() -> void:
	const NEW_PEER_ID := 5
	var host := _make_host_fixture(NetManagerStore.ConnectionState.IN_GAME)
	host.loading_session_id = 41
	host.call("_on_peer_disconnected", 2)
	var suspended_revision := host.get_session_membership_revision()
	var original_expiry := int(
		(host._session_members[2] as Dictionary).get("grace_expires_msec", 0)
	)
	host.connected_players[NEW_PEER_ID] = "Alpha"
	host.connected_player_characters[NEW_PEER_ID] = (
		PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	)
	host.confirmed_character_peers[NEW_PEER_ID] = true
	host._peer_reconnect_tokens[NEW_PEER_ID] = TOKEN_A
	var nearly_expired_load_deadline := Time.get_ticks_msec() + 100
	host._pending_reconnect_loads[NEW_PEER_ID] = {
		"old_peer_id": 2,
		"token": TOKEN_A,
		"deadline_msec": nearly_expired_load_deadline,
		"grace_expires_msec": original_expiry,
		"phase": int(NetManagerStore.ReconnectPendingPhase.LOADING),
		"identity_committed": false,
		"membership_revision": 0,
		"runtime_projection_outcome": -1,
		"completion_signal_active": false,
		"identity_announced": false,
	}
	host.call("_complete_peer_reconnect", NEW_PEER_ID)
	var identity_revision := host.get_session_membership_revision()
	var projecting_pending := host._pending_reconnect_loads[NEW_PEER_ID] as Dictionary
	_expect(
		host.is_session_member_reconnecting(NEW_PEER_ID)
		and not host.has_session_member(2)
		and host._pending_reconnect_loads.has(NEW_PEER_ID)
		and bool((host._pending_reconnect_loads[NEW_PEER_ID] as Dictionary).get(
			"identity_announced",
			false
		))
		and host.reconnect_ready_count == 0
		and int(projecting_pending.get("phase", -1))
		== int(NetManagerStore.ReconnectPendingPhase.PROJECTING)
		and int(projecting_pending.get("deadline_msec", 0))
		> nearly_expired_load_deadline
		and identity_revision == suspended_revision + 1
		and int((host._session_members[NEW_PEER_ID] as Dictionary).get(
			"grace_expires_msec",
			0
		)) == original_expiry,
		(
			"身份已提交但 Player 未报告终态时必须停在 RECONNECTING，保留原宽限，"
			+ "并取得独立于加载剩余时间的 Player 投影租约。"
		)
	)
	host.publication_events.clear()
	host.player_reconnect_ready.connect(
		func(
			_old_peer_id: int,
			_new_peer_id: int,
			_outcome: MultiplayerReconnectTypes.RuntimeProjectionOutcome,
			_membership_revision: int
		) -> void:
			host.publication_events.append(&"ready_notice")
	)
	_expect(
		host.report_reconnected_runtime_projection(
			2,
			NEW_PEER_ID,
			MultiplayerReconnectTypes.RuntimeProjectionOutcome.RESTORED
		)
		and host.is_session_member_active(NEW_PEER_ID)
		and not host._pending_reconnect_loads.has(NEW_PEER_ID)
		and host.reconnect_ready_count == 1
		and host.reconnect_preparation_count == 1
		and host.preparation_observed_reconnecting
		and host.preparation_observed_ingress_closed
		and host.publication_events == [
			&"prepare",
			&"active",
			&"roster",
			&"host_ready",
			&"ready_notice",
		]
		and host.get_session_membership_revision() == identity_revision + 1,
		(
			"RESTORED 必须先在 ingress 关闭时同步准备，再按 ACTIVE→roster→"
			+ "host-ready→最终通知的顺序恰好发布一次。"
		)
	)
	_expect(
		host.report_reconnected_runtime_projection(
			2,
			NEW_PEER_ID,
			MultiplayerReconnectTypes.RuntimeProjectionOutcome.RESTORED
		)
		and host.reconnect_ready_count == 1,
		"完成后的同值投影报告必须幂等，不能重复 ready。"
	)
	host.free()


func _test_reconnect_delivery_preparation_failure_is_fail_closed() -> void:
	const NEW_PEER_ID := 6
	var host := _make_host_fixture(NetManagerStore.ConnectionState.IN_GAME)
	host.loading_session_id = 44
	host.call("_on_peer_disconnected", 2)
	var original_expiry := int(
		(host._session_members[2] as Dictionary).get("grace_expires_msec", 0)
	)
	host.connected_players[NEW_PEER_ID] = "Alpha"
	host.connected_player_characters[NEW_PEER_ID] = (
		PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	)
	host.confirmed_character_peers[NEW_PEER_ID] = true
	host._peer_reconnect_tokens[NEW_PEER_ID] = TOKEN_A
	host._pending_reconnect_loads[NEW_PEER_ID] = {
		"old_peer_id": 2,
		"token": TOKEN_A,
		"deadline_msec": Time.get_ticks_msec() + 5_000,
		"grace_expires_msec": original_expiry,
		"phase": int(NetManagerStore.ReconnectPendingPhase.LOADING),
		"identity_committed": false,
		"membership_revision": 0,
		"runtime_projection_outcome": -1,
		"completion_signal_active": false,
		"identity_announced": false,
		"delivery_preparation_active": false,
	}
	host.call("_complete_peer_reconnect", NEW_PEER_ID)
	host.publication_events.clear()
	host.reconnect_preparation_should_succeed = false
	_expect(
		host.report_reconnected_runtime_projection(
			2,
			NEW_PEER_ID,
			MultiplayerReconnectTypes.RuntimeProjectionOutcome.RESTORED
		)
		and host.reconnect_preparation_count == 1
		and host.reconnect_ready_count == 0
		and not host.has_session_member(NEW_PEER_ID)
		and host._forced_final_departure_peer_ids.has(NEW_PEER_ID)
		and host.publication_events == [&"prepare", &"roster"],
		(
			"首帧 prepare 失败必须在 ACTIVE/host-ready 前 fail-close；"
			+ "只允许广播成员移除 roster。"
		)
	)
	host.free()


func _test_same_transport_id_reconnect_fails_before_consuming_slot() -> void:
	var host := _make_host_fixture(NetManagerStore.ConnectionState.IN_GAME)
	host.loading_session_id = 40
	host.call("_on_peer_disconnected", 2)
	var before_snapshot := host.get_session_membership_snapshot()
	_expect(
		not bool(host.call("_begin_peer_reconnect", 2, "Alpha", TOKEN_A))
		and host.get_session_membership_snapshot() == before_snapshot
		and host._disconnected_reconnect_slots.get(TOKEN_A, 0) == 2
		and not host._pending_reconnect_loads.has(2),
		(
			"当前协议无法区分同 raw peer 的新 transport 租约时，必须在消费 slot 前"
			+ "零写拒绝，不能进入永远无法提交的半重连。"
		)
	)
	host.call("_on_peer_disconnected", 2)
	_expect(
		host.get_session_membership_snapshot() == before_snapshot
		and host._disconnected_reconnect_slots.get(TOKEN_A, 0) == 2,
		(
			"被拒的新 transport 与 suspended 身份 raw ID 碰撞时，后续 disconnect"
			+ " 只能清 transport，不得误删合法成员或宽限槽。"
		)
	)
	host.free()


func _test_cross_suspended_transport_id_reconnect_is_rejected() -> void:
	var host := _make_host_fixture(NetManagerStore.ConnectionState.IN_GAME, true)
	host.loading_session_id = 41
	host.call("_on_peer_disconnected", 2)
	host.call("_on_peer_disconnected", 3)
	var before_snapshot := host.get_session_membership_snapshot()
	_expect(
		not bool(host.call("_begin_peer_reconnect", 3, "Alpha", TOKEN_A))
		and host.get_session_membership_snapshot() == before_snapshot
		and int(host._disconnected_reconnect_slots.get(TOKEN_A, 0)) == 2
		and int(host._disconnected_reconnect_slots.get(TOKEN_B, 0)) == 3
		and not host._pending_reconnect_loads.has(3),
		(
			"另一个宽限成员占用的 raw peer_id 不能成为重连目标；拒绝必须发生在"
			+ "消费任一 slot 或创建 pending 之前。"
		)
	)
	host.free()


func _test_missed_identity_is_inferred_from_participant() -> void:
	var client := ClientProbe.new()
	root.add_child(client)
	var initial_roster := _make_client_roster(2, true)
	initial_roster.append({
		"id": 3,
		"participant_incarnation": 103,
		"name": "Beta",
		"character_id": String(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID),
		"character_confirmed": true,
		"session_state": int(NetManagerStore.SessionMemberState.SUSPENDED_GRACE),
	})
	client.call(
		"_rpc_sync_player_list",
		initial_roster,
		1,
		int(NetManagerStore.GameMode.STANDARD),
		8,
		10
	)
	var reconnect_events: Array[PackedInt32Array] = []
	client.player_reconnected.connect(
		func(
			old_peer_id: int,
			new_peer_id: int,
			_player_name: String,
			_character_id: StringName,
			_membership_revision: int
		) -> void:
			reconnect_events.append(PackedInt32Array([old_peer_id, new_peer_id]))
	)
	var final_roster := [
		(initial_roster[0] as Dictionary).duplicate(true),
		{
			"id": 5,
			"participant_incarnation": 102,
			"name": "Alpha",
			"character_id": String(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID),
			"character_confirmed": true,
			"session_state": int(NetManagerStore.SessionMemberState.ACTIVE),
		},
		{
			"id": 6,
			"participant_incarnation": 103,
			"name": "Beta",
			"character_id": String(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID),
			"character_confirmed": true,
			"session_state": int(NetManagerStore.SessionMemberState.ACTIVE),
		},
	]
	client.call(
		"_rpc_sync_player_list",
		final_roster,
		1,
		int(NetManagerStore.GameMode.STANDARD),
		8,
		14
	)
	_expect(
		reconnect_events == [
			PackedInt32Array([2, 5]),
			PackedInt32Array([3, 6]),
		]
		and client.get_session_member_peer_ids() == PackedInt32Array([1, 5, 6])
		and client.is_session_member_active(5)
		and client.is_session_member_active(6)
		and client.connected_players.has(5)
		and client.connected_players.has(6)
		and client.get_session_membership_revision() == 14,
		"漏收旁路 RPC 的并发重连者必须按 participant 世代恢复全部身份事务。"
	)
	client.free()


func _test_timed_out_projection_cannot_extend_grace() -> void:
	const NEW_PEER_ID := 7
	var host := _make_host_fixture(NetManagerStore.ConnectionState.IN_GAME)
	host.loading_session_id = 42
	host.call("_on_peer_disconnected", 2)
	var original_expiry := int(
		(host._session_members[2] as Dictionary).get("grace_expires_msec", 0)
	)
	host.connected_players[NEW_PEER_ID] = "Alpha"
	host.connected_player_characters[NEW_PEER_ID] = (
		PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	)
	host.confirmed_character_peers[NEW_PEER_ID] = true
	host._peer_reconnect_tokens[NEW_PEER_ID] = TOKEN_A
	host._pending_reconnect_loads[NEW_PEER_ID] = {
		"old_peer_id": 2,
		"token": TOKEN_A,
		"deadline_msec": Time.get_ticks_msec() + 5_000,
		"grace_expires_msec": original_expiry,
		"phase": int(NetManagerStore.ReconnectPendingPhase.LOADING),
		"identity_committed": false,
		"membership_revision": 0,
		"runtime_projection_outcome": -1,
		"completion_signal_active": false,
		"identity_announced": false,
	}
	host.call("_complete_peer_reconnect", NEW_PEER_ID)
	var pending := host._pending_reconnect_loads[NEW_PEER_ID] as Dictionary
	pending["deadline_msec"] = Time.get_ticks_msec() - 1
	host._pending_reconnect_loads[NEW_PEER_ID] = pending
	_expect(
		not host.report_reconnected_runtime_projection(
			2,
			NEW_PEER_ID,
			MultiplayerReconnectTypes.RuntimeProjectionOutcome.RESTORED
		)
		and host.reconnect_ready_count == 0
		and host.is_session_member_reconnecting(NEW_PEER_ID)
		and bool((host._pending_reconnect_loads[NEW_PEER_ID] as Dictionary).get(
			"timed_out",
			false
		)),
		(
			"deadline 已过但 poll 尚未运行时，晚到 RESTORED 也必须先原子关闭"
			+ " completion 资格，不能先 ready 再踢人。"
		)
	)
	host.call("_on_peer_disconnected", NEW_PEER_ID)
	_expect(
		host.is_session_member_suspended(NEW_PEER_ID)
		and int((host._session_members[NEW_PEER_ID] as Dictionary).get(
			"grace_expires_msec",
			0
		)) == original_expiry,
		"重连加载超时后再次断线只能继承原宽限截止，不能重新获得完整宽限。"
	)
	host.free()


func _test_stale_deadline_cannot_expire_new_phase() -> void:
	const NEW_PEER_ID := 8
	var host := _make_host_fixture(NetManagerStore.ConnectionState.IN_GAME)
	host._pending_reconnect_loads[NEW_PEER_ID] = {
		"old_peer_id": 2,
		"deadline_msec": 1_000,
		"phase": int(NetManagerStore.ReconnectPendingPhase.LOADING),
		"timed_out": false,
	}
	var pending := (
		host._pending_reconnect_loads[NEW_PEER_ID] as Dictionary
	).duplicate(true)
	pending["phase"] = int(NetManagerStore.ReconnectPendingPhase.PROJECTING)
	pending["deadline_msec"] = 2_000
	host._pending_reconnect_loads[NEW_PEER_ID] = pending
	_expect(
		not bool(host.call(
			"_expire_pending_reconnect",
			NEW_PEER_ID,
			int(NetManagerStore.ReconnectPendingPhase.LOADING),
			1_000
		))
		and not bool((host._pending_reconnect_loads[NEW_PEER_ID] as Dictionary).get(
			"timed_out",
			false
		))
		and int((host._pending_reconnect_loads[NEW_PEER_ID] as Dictionary).get(
			"phase",
			-1
		)) == int(NetManagerStore.ReconnectPendingPhase.PROJECTING),
		"旧 LOADING deadline 的超时 CAS 不得关闭已经进入 PROJECTING 的事务。"
	)
	host.free()


func _test_relay_host_kick_control() -> void:
	var host := _make_host_fixture(NetManagerStore.ConnectionState.IN_GAME)
	host.conn_mode = NetManagerStore.ConnMode.RELAY
	await host._disconnect_incompatible_peer(2)
	_expect(
		host.relay_kick_targets == PackedInt32Array([2]),
		"Relay Host 断开逻辑客户端时必须向 server peer 1 请求 target!=1 的服务端 kick。"
	)
	var room_peers := PackedInt32Array([2, 3, 4])
	_expect(
		RELAY_SERVER_SCRIPT.is_authorized_host_kick_request(
			2,
			2,
			3,
			room_peers
		)
		and not RELAY_SERVER_SCRIPT.is_authorized_host_kick_request(
			2,
			3,
			4,
			room_peers
		),
		"Relay 只能接受已登记 Host 的 kick；非法 sender 不能踢出同房成员。"
	)
	host.free()


func _test_relay_timeout_finalizes_member() -> void:
	const NEW_PEER_ID := 5
	var host := _make_host_fixture(NetManagerStore.ConnectionState.IN_GAME)
	host.conn_mode = NetManagerStore.ConnMode.RELAY
	host.disconnect_on_relay_kick = true
	host.loading_session_id = 43
	host.call("_on_peer_disconnected", 2)
	var original_expiry := int(
		(host._session_members[2] as Dictionary).get("grace_expires_msec", 0)
	)
	host.connected_players[NEW_PEER_ID] = "Alpha"
	host.connected_player_characters[NEW_PEER_ID] = (
		PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	)
	host.confirmed_character_peers[NEW_PEER_ID] = true
	host._peer_reconnect_tokens[NEW_PEER_ID] = TOKEN_A
	host._pending_reconnect_loads[NEW_PEER_ID] = {
		"old_peer_id": 2,
		"token": TOKEN_A,
		"deadline_msec": Time.get_ticks_msec() + 5_000,
		"grace_expires_msec": original_expiry,
		"phase": int(NetManagerStore.ReconnectPendingPhase.LOADING),
		"identity_committed": false,
		"membership_revision": 0,
		"runtime_projection_outcome": -1,
		"completion_signal_active": false,
		"identity_announced": false,
	}
	host.call("_complete_peer_reconnect", NEW_PEER_ID)
	var pending := host._pending_reconnect_loads[NEW_PEER_ID] as Dictionary
	pending["deadline_msec"] = Time.get_ticks_msec() - 1
	host._pending_reconnect_loads[NEW_PEER_ID] = pending
	host.call("_poll_reconnect_deadlines", Time.get_ticks_msec())
	await create_timer(0.15).timeout
	await process_frame
	_expect(
		host.relay_kick_targets == PackedInt32Array([NEW_PEER_ID])
		and host.is_session_member_suspended(NEW_PEER_ID)
		and not host._pending_reconnect_loads.has(NEW_PEER_ID),
		"Relay 超时必须服务端踢出目标 transport；RECONNECTING 只能回到原宽限，不能永久卡住。"
	)
	host.call("_poll_reconnect_deadlines", original_expiry)
	_expect(
		not host.has_session_member(NEW_PEER_ID)
		and not host._pending_reconnect_loads.has(NEW_PEER_ID),
		"被 Relay kick 的超时成员必须在原宽限截止后完成 canonical final departure。"
	)
	host.free()


func _test_invalid_participant_rosters_are_rejected() -> void:
	var client := ClientProbe.new()
	root.add_child(client)
	var valid_roster := _make_client_roster(2, false)
	client.call(
		"_rpc_sync_player_list",
		valid_roster,
		1,
		int(NetManagerStore.GameMode.STANDARD),
		8,
		3
	)
	var committed_snapshot := client.get_session_membership_snapshot()
	var missing := valid_roster.duplicate(true)
	(missing[1] as Dictionary).erase("participant_incarnation")
	var duplicate := valid_roster.duplicate(true)
	(duplicate[1] as Dictionary)["participant_incarnation"] = int(
		(duplicate[0] as Dictionary)["participant_incarnation"]
	)
	var zero := valid_roster.duplicate(true)
	(zero[1] as Dictionary)["participant_incarnation"] = 0
	for invalid_roster in [missing, duplicate, zero]:
		client.call(
			"_rpc_sync_player_list",
			invalid_roster,
			1,
			int(NetManagerStore.GameMode.TOWER_DEFENSE),
			6,
			4
		)
		_expect(
			client.get_session_membership_snapshot() == committed_snapshot,
			"缺失、重复或零 participant incarnation 的 roster 必须整包零写拒绝。"
		)
	client.free()


func _make_client_roster(peer_id: int, suspended: bool) -> Array:
	return [
		{
			"id": 1,
			"participant_incarnation": 1,
			"name": "Host",
			"character_id": String(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID),
			"character_confirmed": true,
			"session_state": int(NetManagerStore.SessionMemberState.ACTIVE),
		},
		{
			"id": peer_id,
			"participant_incarnation": 100 + peer_id,
			"name": "Alpha",
			"character_id": String(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID),
			"character_confirmed": true,
			"session_state": int(
				NetManagerStore.SessionMemberState.SUSPENDED_GRACE
				if suspended
				else NetManagerStore.SessionMemberState.ACTIVE
			),
		},
	]


func _test_grace_expiry_is_final() -> void:
	var host := _make_host_fixture(NetManagerStore.ConnectionState.IN_GAME)
	var final_events: Array[Dictionary] = []
	host.session_member_final_departed.connect(
		func(peer_id: int, revision: int, reason: StringName) -> void:
			final_events.append({
				"peer_id": peer_id,
				"revision": revision,
				"reason": reason,
			})
	)
	host.call("_on_peer_disconnected", 2)
	var members := host.get("_session_members") as Dictionary
	var expiry := int((members[2] as Dictionary).get("grace_expires_msec", 0))
	host.call("_poll_reconnect_deadlines", expiry)
	_expect(
		not host.has_session_member(2)
		and final_events.size() == 1
		and StringName(final_events[0].get("reason", &""))
		== NetManagerStore.FINAL_DEPARTURE_GRACE_EXPIRED,
		"宽限到期必须从唯一成员表移除身份并恰好发布一次 final departure。"
	)
	host.free()


func _test_projection_failure_cannot_create_new_grace() -> void:
	var host := _make_host_fixture(NetManagerStore.ConnectionState.IN_GAME)
	var counters := {"final": 0}
	host.session_member_final_departed.connect(
		func(_peer_id: int, _revision: int, reason: StringName) -> void:
			if reason == NetManagerStore.FINAL_DEPARTURE_PROJECTION_FAILED:
				counters["final"] = int(counters["final"]) + 1
	)
	_expect(
		host.terminate_for_runtime_projection_failure(2, "fixture failure"),
		"Host 必须接受对已认证远端成员的投影终止。"
	)
	host.call("_on_peer_disconnected", 2)
	_expect(
		int(counters["final"]) == 1
		and not host.has_session_member(2)
		and (host.get("_disconnected_reconnect_slots") as Dictionary).is_empty()
		and (host.get("_forced_final_departure_peer_ids") as Dictionary).is_empty(),
		"投影强制失败后的物理断线不得重新创建 grace，终止标记也必须消费。"
	)
	host.free()


func _make_host_fixture(
	connection_state: NetManagerStore.ConnectionState,
	include_third_member: bool = false
) -> HostProbe:
	var host := HostProbe.new()
	root.add_child(host)
	_expect(
		host.register_reconnect_delivery_preparer(
			host.prepare_reconnect_delivery
		),
		"Host 测试夹具必须登记唯一重连首帧准备入口。"
	)
	host.connection_state = connection_state
	host.host_peer_id = 1
	host.connected_players = {
		1: "Host",
		2: "Alpha",
	}
	host.connected_player_characters = {
		1: PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
		2: PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
	}
	host.confirmed_character_peers = {
		1: true,
		2: true,
	}
	if include_third_member:
		host.connected_players[3] = "Beta"
		host.connected_player_characters[3] = PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
		host.confirmed_character_peers[3] = true
	host.seed_peer_token(2, TOKEN_A)
	host.seed_peer_token(3, TOKEN_B)
	host.call(
		"_register_active_session_member",
		1,
		"Host",
		PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
		true,
		""
	)
	host.call(
		"_register_active_session_member",
		2,
		"Alpha",
		PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
		true,
		TOKEN_A
	)
	if include_third_member:
		host.call(
			"_register_active_session_member",
			3,
			"Beta",
			PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
			true,
			TOKEN_B
		)
	return host


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("NET_MANAGER_SESSION_MEMBERSHIP_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
