extends SceneTree

const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const PEER_LEDGER_SCRIPT := preload(
	"res://scene/multiplayer/peer_ledger/mp_peer_ledger_coordinator.gd"
)

const OLD_PEER_ID := 20
const ACTIVE_PEER_ID := 30
const SESSION_INCARNATION := 11


class LifecycleNetManager:
	extends NetManagerStore

	var fixture_peer_ids := PackedInt32Array([ACTIVE_PEER_ID])
	var fixture_revision := 1


	func get_session_member_peer_ids() -> PackedInt32Array:
		return fixture_peer_ids.duplicate()


	func has_session_member(peer_id: int) -> bool:
		return fixture_peer_ids.has(peer_id)


	func get_session_membership_revision() -> int:
		return fixture_revision


class LifecycleMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var transport_capture_count := 0
	var transport_clear_count := 0


	func _capture_disconnected_player_reconnect_state(_peer_id: int) -> void:
		transport_capture_count += 1


	func _clear_peer_network_state(_peer_id: int) -> void:
		transport_clear_count += 1


var failures: Array[String] = []
var lifecycle_run_state: RunStateStore = null
var committed_envelopes := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_transport_left_preserves_session_ledgers_until_final_departure()
	_test_p3_pose_and_run_state_follow_final_departure()
	call_deferred("_finish")


func _test_transport_left_preserves_session_ledgers_until_final_departure() -> void:
	var run_state := RunStateStore.new()
	root.add_child(run_state)
	run_state.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	_expect(
		run_state.reconcile_multiplayer_session_membership(
			PackedInt32Array([ACTIVE_PEER_ID]),
			1
		),
		"生命周期夹具必须建立首份会话成员账本。"
	)
	lifecycle_run_state = run_state
	committed_envelopes = 0

	var net_manager := LifecycleNetManager.new()
	var mp_game := LifecycleMpGame.new()
	var peer_ledger := PEER_LEDGER_SCRIPT.new()
	mp_game.net_manager = net_manager
	mp_game.run_state = run_state
	mp_game.peer_ledger_coordinator = peer_ledger
	var generation := peer_ledger.bind_session(
		mp_game,
		PEER_LEDGER_SCRIPT.RuntimeRole.CLIENT,
		SESSION_INCARNATION,
		_is_lifecycle_peer_registered,
		_is_lifecycle_envelope_ready,
		_commit_lifecycle_envelope
	)
	mp_game.set("_peer_ledger_generation", generation)
	_expect(
		peer_ledger.receive_authoritative_result(
			generation,
			SESSION_INCARNATION,
			OLD_PEER_ID,
			&"inventory_snapshot",
			&"inventory",
			1,
			{"value": 7}
		) == PEER_LEDGER_SCRIPT.EnvelopeResult.BUFFERED,
		"CH6 先到的 old identity 结果必须先进入 pending。"
	)
	var ledger_remap := peer_ledger.remap_authenticated_peer(
		generation,
		OLD_PEER_ID,
		ACTIVE_PEER_ID
	)
	var claim_result := peer_ledger.claim_authenticated_peer(
		generation,
		ACTIVE_PEER_ID
	)
	_expect(
		bool(ledger_remap.get("accepted", false))
		and bool(claim_result.get("accepted", false))
		and committed_envelopes == 1
		and peer_ledger.get_applied_envelope_count() == 1,
		"old→new 必须迁移 pending，并在新身份下保留 applied 幂等水位。"
	)

	mp_game.call("_on_net_player_left", ACTIVE_PEER_ID)
	_expect(
		mp_game.transport_capture_count == 1
		and mp_game.transport_clear_count == 1
		and run_state.has_multiplayer_peer_state(ACTIVE_PEER_ID)
		and peer_ledger.get_applied_envelope_count() == 1,
		(
			"transport player_left 只能撤销实时投影；grace 期间必须保留 "
			+ "RunState 与 CH6 applied 历史。"
		)
	)

	net_manager.fixture_peer_ids = PackedInt32Array()
	net_manager.fixture_revision = 2
	mp_game.call(
		"_on_session_member_final_departed",
		ACTIVE_PEER_ID,
		2,
		NetManagerStore.FINAL_DEPARTURE_GRACE_EXPIRED
	)
	_expect(
		not run_state.has_multiplayer_peer_state(ACTIVE_PEER_ID)
		and run_state.get_multiplayer_session_membership_revision() == 2
		and peer_ledger.get_applied_envelope_count() == 0,
		"grace expiry 必须只在 final departure 边界清理持久成员与跨信道历史。"
	)
	# final 通知重放必须保持幂等，不能制造第二份状态或失败路径。
	mp_game.call(
		"_on_session_member_final_departed",
		ACTIVE_PEER_ID,
		2,
		NetManagerStore.FINAL_DEPARTURE_GRACE_EXPIRED
	)
	_expect(
		not run_state.has_multiplayer_peer_state(ACTIVE_PEER_ID)
		and peer_ledger.get_applied_envelope_count() == 0,
		"重复 final departure 必须幂等。"
	)
	mp_game.call("_on_net_player_left", ACTIVE_PEER_ID)
	_expect(
		mp_game.transport_capture_count == 1
		and mp_game.transport_clear_count == 2,
		"final 之后才到达的物理断线只能清实时态，不能重新创建 capture。"
	)

	peer_ledger.unbind_session(mp_game)
	peer_ledger.free()
	mp_game.free()
	net_manager.free()
	run_state.queue_free()
	lifecycle_run_state = null


func _test_p3_pose_and_run_state_follow_final_departure() -> void:
	var run_state := RunStateStore.new()
	root.add_child(run_state)
	run_state.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	_expect(
		run_state.reconcile_multiplayer_session_membership(
			PackedInt32Array([ACTIVE_PEER_ID]),
			1
		),
		"P3 生命周期夹具必须建立首份会话成员账本。"
	)
	var net_manager := LifecycleNetManager.new()
	var route := MpRogueRoute.new()
	route.set("_net_manager", net_manager)
	route.set("_run_state", run_state)
	(route.get("_disconnected_avatar_poses") as Dictionary)[ACTIVE_PEER_ID] = {
		"position": Vector2(12.0, 34.0),
		"stored_at_msec": Time.get_ticks_msec(),
	}
	route.call("_on_player_left", ACTIVE_PEER_ID)
	_expect(
		(route.get("_disconnected_avatar_poses") as Dictionary).has(
			ACTIVE_PEER_ID
		)
		and run_state.has_multiplayer_peer_state(ACTIVE_PEER_ID),
		"P3 transport 断线必须保留宽限重连所需姿态与持久账本。"
	)
	net_manager.fixture_peer_ids = PackedInt32Array()
	net_manager.fixture_revision = 2
	route.call(
		"_on_session_member_final_departed",
		ACTIVE_PEER_ID,
		2,
		NetManagerStore.FINAL_DEPARTURE_GRACE_EXPIRED
	)
	_expect(
		not (route.get("_disconnected_avatar_poses") as Dictionary).has(
			ACTIVE_PEER_ID
		)
		and not run_state.has_multiplayer_peer_state(ACTIVE_PEER_ID),
		"P3 必须在 final departure 后一次性清除姿态捕获与 RunState。"
	)
	route.free()
	net_manager.free()
	run_state.queue_free()


func _is_lifecycle_peer_registered(peer_id: int) -> bool:
	return (
		lifecycle_run_state != null
		and lifecycle_run_state.has_multiplayer_peer_state(peer_id)
	)


func _is_lifecycle_envelope_ready(
	_peer_id: int,
	_result_type: StringName,
	_payload: Dictionary
) -> bool:
	return true


func _commit_lifecycle_envelope(
	_peer_id: int,
	_result_type: StringName,
	_stream_id: StringName,
	_revision: int,
	_payload: Dictionary
) -> bool:
	committed_envelopes += 1
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("SESSION_MEMBERSHIP_RUNTIME_LIFECYCLE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
