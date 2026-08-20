extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/peer_ledger/mp_peer_ledger_coordinator.tscn"
)
const MpPeerLedgerCoordinatorScript := preload(
	"res://scene/multiplayer/peer_ledger/mp_peer_ledger_coordinator.gd"
)
const MpGameScript := preload("res://scene/multiplayer/mp_game.gd")
const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const MP_GAME_SCENE_PATH := "res://scene/multiplayer/mp_game.tscn"
const PEER_LEDGER_SOURCE_PATH := (
	"res://scene/multiplayer/peer_ledger/mp_peer_ledger_coordinator.gd"
)
const SESSION_INCARNATION := 37


class TransactionsReceiverProbe:
	extends MpTransactionsCoordinator

	var crafting_calls: Array[Dictionary] = []

	func receive_simple_crafting_result(
		peer_id: int,
		request_id: int,
		recipe_id: String,
		result: String,
		inventory_snapshot: Dictionary,
		force_inventory_repair: bool = false
	) -> bool:
		crafting_calls.append({
			"peer_id": peer_id,
			"request_id": request_id,
			"recipe_id": recipe_id,
			"result": result,
			"inventory_snapshot": inventory_snapshot.duplicate(true),
			"force_inventory_repair": force_inventory_repair,
		})
		return true


class ClientNetManager:
	extends NetManagerStore

	func is_client() -> bool:
		return true

	func seed_session_member(
		peer_id: int,
		participant_incarnation: int
	) -> void:
		_session_members[peer_id] = {
			"player_name": "Fixture",
			"character_id": PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
			"character_confirmed": true,
			"state": int(SessionMemberState.ACTIVE),
			"participant_incarnation": participant_incarnation,
			"reconnect_token": "",
			"grace_expires_msec": 0,
		}

	func remove_session_member(peer_id: int) -> void:
		_session_members.erase(peer_id)


class ProjectionRuntimeProbe:
	extends CombatRuntimeBase

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return peer_players.get(peer_id) as Player

	func get_enemy_for_net_id(_net_id: int) -> Enemy:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(peer_id: int) -> void:
		peer_players.erase(peer_id)

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass


var failures: Array[String] = []
var registered_peer_ids: Dictionary = {}
var unready_result_types: Dictionary = {}
var rejected_stream_ids: Dictionary = {}
var committed_envelopes: Array[Dictionary] = []
var rejection_reasons: Array[StringName] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var owner := Node.new()
	owner.name = "PeerLedgerSmokeOwner"
	root.add_child(owner)
	var coordinator := COORDINATOR_SCENE.instantiate() as MpPeerLedgerCoordinatorScript
	_expect(coordinator != null, "协调器场景必须实例化为 MpPeerLedgerCoordinator。")
	if coordinator == null:
		_finish(owner, null)
		return
	root.add_child(coordinator)
	coordinator.envelope_rejected.connect(_on_envelope_rejected)
	await process_frame

	_test_static_mp_game_node()
	_test_mp_game_projection_readiness()
	_test_subject_identity_codec()
	_test_outbound_session_envelope()
	_test_participant_incarnation_resolves_canonical_peer(coordinator)
	_test_prebind_repair_debt()
	_test_session_incarnation_boundary(coordinator, owner)
	_test_client_pending_and_claim(coordinator, owner)
	_test_registered_identity_waits_for_projection(coordinator, owner)
	_test_transaction_streams_preserve_ui_tokens(coordinator, owner)
	_test_pending_result_returns_to_domain_receiver(coordinator, owner)
	_test_timeout_and_generation(coordinator, owner)
	_test_reconnect_record_remap(coordinator, owner)
	_test_remap_lifecycle(coordinator, owner)
	_test_remap_stream_capacity(coordinator, owner)
	_test_capacity_limits(coordinator, owner)
	_test_host_unknown_peer_boundary(coordinator, owner)
	_test_owner_scoped_unbind(coordinator, owner)

	_finish(owner, coordinator)


func _test_static_mp_game_node() -> void:
	var scene_source := FileAccess.get_file_as_string(MP_GAME_SCENE_PATH)
	var script_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_game.gd"
	)
	var ledger_source := FileAccess.get_file_as_string(PEER_LEDGER_SOURCE_PATH)
	_expect(
		scene_source.contains(
			"res://scene/multiplayer/peer_ledger/mp_peer_ledger_coordinator.tscn"
		)
		and scene_source.contains("[node name=\"PeerLedgerCoordinator\""),
		"MpGame 必须在场景中静态持有 peer 账本协调器。"
	)
	_expect(
		not script_source.contains("_buffer_inventory_ledger_if_unregistered")
		and not script_source.contains("_buffer_upgrade_ledger_if_unregistered")
		and not script_source.contains("_buffer_warehouse_ledger_if_unregistered")
		and script_source.contains("receive_authoritative_result"),
		"CH6 结果必须统一经过 typed 权威结果边界，不能保留只缓存账本的布尔旁路。"
	)
	var peer_result_rpcs := PackedStringArray([
		"net_warehouse_command_result",
		"net_inventory_snapshot",
		"net_research_state_updated",
		"net_pickup_collected",
		"net_upgrade_confirmed",
		"net_inventory_item_used",
		"net_inventory_item_discarded",
		"net_simple_crafting_result",
		"net_skill1_purchase_confirmed",
		"net_luoxi_collectible_offer_state",
		"net_luoxi_collectible_confirmed",
		"net_luoxi_collectible_refresh_confirmed",
		"net_luoxi_special_game_started",
		"net_luoxi_special_game_card_revealed",
		"net_luoxi_special_game_finished",
		"net_cheat_xirang_confirmed",
		"net_debug_collectible_granted",
	])
	var all_peer_results_use_typed_ingress := true
	var all_peer_results_carry_identity_trailer := true
	for function_name in peer_result_rpcs:
		all_peer_results_use_typed_ingress = (
			all_peer_results_use_typed_ingress
			and _function_body_contains(
				script_source,
				function_name,
				"_receive_authoritative_peer_result("
			)
		)
		all_peer_results_carry_identity_trailer = (
			all_peer_results_carry_identity_trailer
			and _function_body_contains(
				script_source,
				function_name,
				"participant_incarnation: int = 0"
			)
			and _function_body_contains(
				script_source,
				function_name,
				"session_incarnation: int = 0"
			)
		)
	_expect(
		peer_result_rpcs.size() == 17
		and all_peer_results_use_typed_ingress
		and all_peer_results_carry_identity_trailer
		and script_source.contains("PEER_RESULT_RPC_METHODS")
		and script_source.contains("wire_args.append(participant_incarnation)")
		and script_source.contains("wire_args.append(session_incarnation)"),
		"全部17类 peer-bearing CH6 结果都必须携带成员/游戏世代并经过同一个入口。"
	)
	_expect(
		script_source.contains("pending_envelope_expired")
		and not script_source.contains("peer_alias_expired")
		and script_source.contains("ledger_remap.get(\"conflicts\", 0)")
		and script_source.contains("_request_peer_result_full_repair"),
		"结果拒绝、pending 过期和 remap 冲突必须汇入现有完整状态修复出口。"
	)
	_expect(
		not ledger_source.contains("PEER_ALIAS_TTL_MSEC")
		and not ledger_source.contains("_peer_aliases")
		and not ledger_source.contains("func resolve_peer_id")
		and ledger_source.contains("func remap_authenticated_peer"),
		"PeerLedger 只能迁移既有 pending/applied，不能保留未来入站 alias 真源。"
	)
	var readiness_function := _get_function_body(
		script_source,
		"_is_peer_result_envelope_ready"
	)
	var player_projection_result_constants := PackedStringArray([
		"PEER_RESULT_RESEARCH_STATE",
		"PEER_RESULT_LUOXI_OFFER_STATE",
		"PEER_RESULT_LUOXI_REFRESH",
		"PEER_RESULT_CHEAT_XIRANG",
		"PEER_RESULT_PICKUP_COLLECTED",
		"PEER_RESULT_LUOXI_SPECIAL_FINISHED",
	])
	var has_complete_projection_classification := true
	for result_constant in player_projection_result_constants:
		has_complete_projection_classification = (
			has_complete_projection_classification
			and readiness_function.contains(result_constant)
		)
	_expect(
		has_complete_projection_classification
		and readiness_function.contains("applied_immediately")
		and readiness_function.contains("current_xirang")
		and readiness_function.contains("get_player_for_peer")
		and script_source.contains("_is_peer_result_envelope_ready,")
		and _function_body_contains(
			script_source,
			"_attempt_reconnected_player_projection",
			"_finalize_reconnected_projection_and_claim("
		)
		and _function_body_contains(
			script_source,
			"_finalize_reconnected_projection_and_claim",
			"_claim_pending_peer_ledgers(new_peer_id)"
		),
		"Player 投影型 CH6 结果必须显式分类，并在重连投影完成后再认领。"
	)


func _test_mp_game_projection_readiness() -> void:
	const PEER_ID := 41
	var mp_game := MpGameScript.new()
	var runtime := ProjectionRuntimeProbe.new()
	mp_game.game = runtime
	var player_required_cases: Array[Dictionary] = [
		{"type": &"research_state", "payload": {}},
		{"type": &"luoxi_offer_state", "payload": {"current_xirang": 10}},
		{"type": &"luoxi_refresh", "payload": {}},
		{"type": &"cheat_xirang", "payload": {}},
		{
			"type": &"luoxi_special_finished",
			"payload": {"result": {"current_xirang": 10}},
		},
		{
			"type": &"pickup_collected",
			"payload": {"applied_immediately": true},
		},
	]
	var all_deferred_without_player := true
	for test_case in player_required_cases:
		all_deferred_without_player = (
			all_deferred_without_player
			and not mp_game._is_peer_result_envelope_ready(
				PEER_ID,
				StringName(test_case["type"]),
				test_case["payload"] as Dictionary
			)
		)
	_expect(
		all_deferred_without_player,
		"科研、洛曦与即时拾取等瞬时 Player 结果在投影缺席时必须延后。"
	)
	_expect(
		mp_game._is_peer_result_envelope_ready(
			PEER_ID,
			&"upgrade_confirmed",
			{}
		)
		and mp_game._is_peer_result_envelope_ready(
			PEER_ID,
			&"skill1_purchase",
			{}
		)
		and mp_game._is_peer_result_envelope_ready(
			PEER_ID,
			&"inventory_snapshot",
			{}
		)
		and mp_game._is_peer_result_envelope_ready(
			PEER_ID,
			&"pickup_collected",
			{"applied_immediately": false}
		)
		and mp_game._is_peer_result_envelope_ready(
			PEER_ID,
			&"luoxi_special_finished",
			{"result": {"score": 2}}
		),
		(
			"成长、库存等持久账本或不含瞬时息壤的结果必须在 Player 缺席时"
			+ "仍可提交。"
		)
	)
	var player := Player.new()
	player.peer_id = PEER_ID
	runtime.peer_players[PEER_ID] = player
	var all_ready_with_player := true
	for test_case in player_required_cases:
		all_ready_with_player = (
			all_ready_with_player
			and mp_game._is_peer_result_envelope_ready(
				PEER_ID,
				StringName(test_case["type"]),
				test_case["payload"] as Dictionary
			)
		)
	_expect(
		all_ready_with_player,
		"Player 投影建立后，所有投影型 CH6 结果必须可被再次 claim。"
	)
	runtime.peer_players.clear()
	player.free()
	mp_game.game = null
	runtime.free()
	mp_game.free()


func _test_subject_identity_codec() -> void:
	var mp_game := MpGameScript.new()
	var encoded: Dictionary = mp_game._encode_subject_dictionary(
		10,
		{
			"nested": [
				{"peer_id": 10, "value": "subject"},
				{"deeper": {"peer_id": 10}},
			],
		}
	)
	var encoded_value := encoded.get("value", {}) as Dictionary
	_expect(
		bool(encoded.get("accepted", false))
		and not _contains_peer_id_key(encoded_value),
		"typed codec 必须递归移除 payload 中的 subject peer_id。"
	)
	var decoded := mp_game._decode_subject_dictionary(20, encoded_value)
	var nested := decoded.get("nested", []) as Array
	_expect(
		nested.size() == 2
		and int((nested[0] as Dictionary).get("peer_id", 0)) == 20
		and int(
			((nested[1] as Dictionary).get("deeper", {}) as Dictionary).get(
				"peer_id",
				0
			)
		) == 20,
		"codec 解码必须只回填 participant 解析后的 canonical peer。"
	)
	_expect(
		not bool(
			mp_game._encode_subject_dictionary(
				10,
				{"nested": {"peer_id": 11}}
			).get("accepted", true)
		),
		"嵌套身份与 envelope subject 冲突时必须拒绝整包。"
	)
	mp_game.free()


func _test_outbound_session_envelope() -> void:
	var mp_game := MpGameScript.new()
	var net_manager := ClientNetManager.new()
	net_manager.loading_session_id = SESSION_INCARNATION
	net_manager.seed_session_member(2, 202)
	mp_game.net_manager = net_manager
	var logical_args := [2, {"revision": 1}]
	var wire_args := mp_game._build_outbound_rpc_arguments(
		&"net_inventory_snapshot",
		logical_args
	)
	var ordinary_args := mp_game._build_outbound_rpc_arguments(
		&"net_player_healed",
		[2, 5]
	)
	var warehouse_args := mp_game._build_outbound_rpc_arguments(
		&"net_warehouse_command_result",
		[{"peer_id": 2, "request_id": 1}]
	)
	var research_args := mp_game._build_outbound_rpc_arguments(
		&"net_research_state_updated",
		[{}, 2, 10]
	)
	var pickup_args := mp_game._build_outbound_rpc_arguments(
		&"net_pickup_collected",
		[7, 2, "res://fixture.tres", false, {}]
	)
	var global_research_args := mp_game._build_outbound_rpc_arguments(
		&"net_research_state_updated",
		[{}, 0, 0]
	)
	_expect(
		logical_args.size() == 2
		and wire_args.size() == 4
		and int(wire_args[2]) == 202
		and int(wire_args[3]) == SESSION_INCARNATION
		and int(warehouse_args[-2]) == 202
		and int(research_args[-2]) == 202
		and int(pickup_args[-2]) == 202
		and int(global_research_args[-2]) == 0
		and int(global_research_args[-1]) == SESSION_INCARNATION
		and ordinary_args == [2, 5],
		"统一发送边界必须按正确 subject 追加 participant/session，且全局科研使用0。"
	)
	mp_game.free()
	net_manager.free()


func _test_participant_incarnation_resolves_canonical_peer(
	coordinator: MpPeerLedgerCoordinatorScript
) -> void:
	const OLD_PEER_ID := 41
	const NEW_PEER_ID := 42
	const REUSED_PEER_ID := 41
	const OLD_PARTICIPANT := 501
	const NEW_PARTICIPANT := 502
	registered_peer_ids = {OLD_PEER_ID: true}
	committed_envelopes.clear()
	var mp_game := MpGameScript.new()
	var net_manager := ClientNetManager.new()
	net_manager.loading_session_id = SESSION_INCARNATION
	net_manager.seed_session_member(OLD_PEER_ID, OLD_PARTICIPANT)
	mp_game.net_manager = net_manager
	mp_game.peer_ledger_coordinator = coordinator
	var generation := coordinator.bind_session(
		mp_game,
		MpPeerLedgerCoordinatorScript.RuntimeRole.CLIENT,
		SESSION_INCARNATION,
		_is_peer_registered,
		_is_envelope_ready,
		_commit_envelope
	)
	mp_game._peer_ledger_generation = generation
	_expect(
		mp_game._receive_authoritative_peer_result(
			OLD_PEER_ID,
			&"fixture",
			&"before-remap",
			1,
			{"step": 1},
			OLD_PARTICIPANT,
			SESSION_INCARNATION
		)
		and int(committed_envelopes[-1]["peer_id"]) == OLD_PEER_ID,
		"成员世代在重连前必须解析到当前 old peer。"
	)
	net_manager.remove_session_member(OLD_PEER_ID)
	net_manager.seed_session_member(NEW_PEER_ID, OLD_PARTICIPANT)
	registered_peer_ids = {NEW_PEER_ID: true}
	var remap := coordinator.remap_authenticated_peer(
		generation,
		OLD_PEER_ID,
		NEW_PEER_ID
	)
	_expect(
		bool(remap.get("accepted", false))
		and mp_game._receive_authoritative_peer_result(
			OLD_PEER_ID,
			&"fixture",
			&"after-remap",
			1,
			{"step": 2},
			OLD_PARTICIPANT,
			SESSION_INCARNATION
		)
		and int(committed_envelopes[-1]["peer_id"]) == NEW_PEER_ID,
		"迟到的 old-wire 结果必须按同一 participant 解析到重连后的 new peer。"
	)
	net_manager.remove_session_member(NEW_PEER_ID)
	net_manager.seed_session_member(REUSED_PEER_ID, NEW_PARTICIPANT)
	registered_peer_ids = {REUSED_PEER_ID: true}
	var committed_before_stale := committed_envelopes.size()
	_expect(
		not mp_game._receive_authoritative_peer_result(
			REUSED_PEER_ID,
			&"fixture",
			&"stale-participant",
			1,
			{"step": 3},
			OLD_PARTICIPANT,
			SESSION_INCARNATION
		)
		and committed_envelopes.size() == committed_before_stale
		and mp_game._peer_result_repair_queued,
		"raw peer ID 被新人复用后，迟到旧 participant 必须零写拒绝并申请修复。"
	)
	_expect(
		mp_game._receive_authoritative_peer_result(
			REUSED_PEER_ID,
			&"fixture",
			&"new-participant",
			1,
			{"step": 4},
			NEW_PARTICIPANT,
			SESSION_INCARNATION
		)
		and int(committed_envelopes[-1]["peer_id"]) == REUSED_PEER_ID,
		"复用 transport 的新成员只有携带自己的 participant 才能提交结果。"
	)
	coordinator.unbind_session(mp_game)
	mp_game.free()
	net_manager.free()


func _test_prebind_repair_debt() -> void:
	var mp_game := MpGameScript.new()
	var net_manager := ClientNetManager.new()
	mp_game.net_manager = net_manager
	mp_game._peer_ledger_generation = 0
	mp_game._request_peer_result_full_repair()
	_expect(
		mp_game._peer_result_repair_needed
		and not mp_game._peer_result_repair_queued,
		"当前局 bind-window 的拒绝必须记为 repair 债务，不能用 generation=0 静默丢弃。"
	)
	mp_game._clear_peer_result_repair_state()
	_expect(
		not mp_game._peer_result_repair_needed
		and not mp_game._peer_result_repair_queued,
		"场景退出/reset 必须清理 bind-window repair 债务，避免污染下一局。"
	)
	mp_game.free()
	net_manager.free()


func _test_session_incarnation_boundary(
	coordinator: MpPeerLedgerCoordinatorScript,
	owner: Node
) -> void:
	registered_peer_ids = {2: true}
	committed_envelopes.clear()
	rejection_reasons.clear()
	var generation := coordinator.bind_session(
		owner,
		MpPeerLedgerCoordinatorScript.RuntimeRole.CLIENT,
		SESSION_INCARNATION,
		_is_peer_registered,
		_is_envelope_ready,
		_commit_envelope
	)
	for rejected_session in [
		0,
		NetConstants.MAX_GAME_SESSION_INCARNATION + 1,
		SESSION_INCARNATION - 1,
		SESSION_INCARNATION + 1,
	]:
		var expected_result := (
			MpPeerLedgerCoordinatorScript.EnvelopeResult.REJECTED_INVALID_SESSION_INCARNATION
			if (
				rejected_session <= 0
				or rejected_session > NetConstants.MAX_GAME_SESSION_INCARNATION
			)
			else MpPeerLedgerCoordinatorScript.EnvelopeResult.REJECTED_STALE_SESSION_INCARNATION
		)
		_expect(
			coordinator.receive_authoritative_result(
				generation,
				rejected_session,
				2,
				&"inventory_snapshot",
				&"session-boundary",
				1,
				{"value": rejected_session},
				10
			) == expected_result,
			"空、旧或未来 CH6 会话世代必须在领域提交前被明确拒绝。"
		)
	var metrics := coordinator.export_metrics()
	_expect(
		committed_envelopes.is_empty()
		and coordinator.get_pending_envelope_count() == 0
		and int(metrics.get("session_rejections", 0)) == 4
		and rejection_reasons.has(
			MpPeerLedgerCoordinatorScript.REASON_INVALID_SESSION_INCARNATION
		)
		and rejection_reasons.has(
			MpPeerLedgerCoordinatorScript.REASON_STALE_SESSION_INCARNATION
		),
		"世代拒绝必须零写入、零 pending，并通过 reason 与指标可观察。"
	)
	_expect(
		coordinator.receive_authoritative_result(
			generation,
			SESSION_INCARNATION,
			2,
			&"inventory_snapshot",
			&"session-boundary",
			1,
			{"value": 1},
			11
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.APPLIED
		and committed_envelopes.size() == 1,
		"只有当前绑定世代可以进入领域提交。"
	)


func _test_client_pending_and_claim(
	coordinator: MpPeerLedgerCoordinatorScript,
	owner: Node
) -> void:
	registered_peer_ids = {2: true}
	committed_envelopes.clear()
	rejected_stream_ids.clear()
	var generation := coordinator.bind_session(
		owner,
		MpPeerLedgerCoordinatorScript.RuntimeRole.CLIENT,
		SESSION_INCARNATION,
		_is_peer_registered,
		_is_envelope_ready,
		_commit_envelope
	)
	_expect(generation > 0, "客户端绑定必须生成正数 run generation。")
	_expect(
		MpPeerLedgerCoordinatorScript.is_accepted_result(
			MpPeerLedgerCoordinatorScript.EnvelopeResult.APPLIED
		),
		"已注册玩家即时提交的 APPLIED 必须被上层视为正常成功。"
	)
	_expect(
		coordinator.receive_authoritative_result(
			generation,
			SESSION_INCARNATION,
			3,
			&"",
			&"inventory",
			1,
			{"value": 10},
			98
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.REJECTED_INVALID,
		"完整权威结果必须携带明确 result_type。"
	)
	_expect(
		_receive(coordinator,
			generation,
			3,
			&"inventory",
			1,
			{"nested": [{"peer_id": 3, "value": 10}]},
			99
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.REJECTED_INVALID,
		"payload 必须移除内嵌 peer_id，由 envelope 身份作为唯一真源。"
	)
	var first_payload := {"value": 10, "nested": [1, 2]}
	_expect(
		_receive(coordinator,
			generation,
			3,
			&"inventory",
			1,
			first_payload,
			100
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.BUFFERED,
		"尚未认证的客户端 peer 必须暂存 CH6 权威信封。"
	)
	first_payload["value"] = 999
	_expect(
		_receive(coordinator,
			generation,
			3,
			&"inventory",
			1,
			{"value": 10, "nested": [1, 2]},
			101
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.IDEMPOTENT,
		"相同 revision 与内容的重复信封必须幂等。"
	)
	_expect(
		_receive(coordinator,
			generation,
			3,
			&"inventory",
			0,
			{"value": 0},
			102
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.REJECTED_STALE_REVISION,
		"较旧 revision 不得覆盖 pending。"
	)
	_expect(
		_receive(coordinator,
			generation,
			3,
			&"inventory",
			1,
			{"value": 11},
			103
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.REJECTED_REVISION_CONFLICT,
		"相同 revision 的不同内容必须被报告为冲突。"
	)
	var newest_payload := {"value": 20, "nested": [3, 4]}
	_expect(
		_receive(coordinator,
			generation,
			3,
			&"inventory",
			2,
			newest_payload,
			104
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.BUFFERED,
		"较新完整快照必须原位替换同一流的旧 pending。"
	)
	newest_payload["nested"] = [999]
	_expect(
		coordinator.get_pending_envelope_count() == 1
		and coordinator.get_pending_revision(3, &"inventory") == 2,
		"同一流只能保留一个最高 revision 信封。"
	)

	registered_peer_ids[3] = true
	var claim := coordinator.claim_authenticated_peer(generation, 3, 105)
	_expect(
		bool(claim.get("accepted", false))
		and int(claim.get("committed", -1)) == 1
		and int(claim.get("rejected", -1)) == 0
		and coordinator.get_pending_envelope_count() == 0,
		"CH0 认证后必须一次认领并清除该 peer 的 pending。"
	)
	_expect(
		committed_envelopes.size() == 1
		and int(committed_envelopes[0].get("revision", -1)) == 2
		and (
			committed_envelopes[0].get("payload", {}) as Dictionary
		).get("nested", []) == [3, 4],
		"pending 必须隔离调用方后续修改，只提交缓存时的不可变副本。"
	)
	_expect(
		_receive(coordinator,
			generation,
			3,
			&"inventory",
			2,
			{"value": 20, "nested": [3, 4]},
			105
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.IDEMPOTENT
		and committed_envelopes.size() == 1,
		"claim 已提交的可靠结果再次到达时不得第二次调用领域 receiver。"
	)
	_expect(
		_receive(coordinator,
			generation,
			2,
			&"upgrades/attack",
			3,
			{"level": 3},
			106
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.APPLIED,
		"已认证 peer 的权威信封必须直接交给持久账本提交回调。"
	)
	var committed_count_after_apply := committed_envelopes.size()
	_expect(
		_receive(coordinator,
			generation,
			2,
			&"upgrades/attack",
			3,
			{"level": 3},
			106
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.IDEMPOTENT
		and committed_envelopes.size() == committed_count_after_apply,
		"已注册 peer 的即时可靠重放必须由 applied 水位幂等吸收。"
	)
	var operation_commit_count := committed_envelopes.size()
	for _attempt in range(2):
		_expect(
			coordinator.receive_authoritative_result(
				generation,
				SESSION_INCARNATION,
				2,
				&"operation_without_id",
				&"skill1/maxed",
				0,
				{"result_code": 5},
				106,
				MpPeerLedgerCoordinatorScript.AppliedReplayPolicy.DOMAIN_OWNED
			) == MpPeerLedgerCoordinatorScript.EnvelopeResult.APPLIED,
			"缺少稳定操作 ID 的结果不得被长期 applied 水位误吞。"
		)
	_expect(
		committed_envelopes.size() == operation_commit_count + 2,
		"两次内容相同但无法证明同一事务的操作结果必须都回到领域 receiver。"
	)
	rejected_stream_ids[&"status"] = true
	_expect(
		_receive(coordinator,
			generation,
			2,
			&"status",
			1,
			{"health": 10},
			107
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.REJECTED_COMMIT,
		"唯一账本拒绝提交时，协调器必须把失败显式返回。"
	)
	rejected_stream_ids.clear()


func _test_registered_identity_waits_for_projection(
	coordinator: MpPeerLedgerCoordinatorScript,
	owner: Node
) -> void:
	registered_peer_ids = {}
	unready_result_types = {&"upgrade_confirmed": true}
	committed_envelopes.clear()
	rejection_reasons.clear()
	var generation := coordinator.bind_session(
		owner,
		MpPeerLedgerCoordinatorScript.RuntimeRole.CLIENT,
		SESSION_INCARNATION,
		_is_peer_registered,
		_is_envelope_ready,
		_commit_envelope
	)
	_expect(
		_receive(
			coordinator,
			generation,
			31,
			&"projection/a",
			1,
			{"value": "before-auth"},
			100,
			&"upgrade_confirmed"
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.BUFFERED,
		"身份到达前的 Player 投影结果必须保留完整信封。"
	)
	registered_peer_ids[31] = true
	var first_claim := coordinator.claim_authenticated_peer(generation, 31, 101)
	_expect(
		bool(first_claim.get("accepted", false))
		and int(first_claim.get("committed", -1)) == 0
		and int(first_claim.get("deferred", -1)) == 1
		and int(first_claim.get("rejected", -1)) == 0
		and rejection_reasons.is_empty()
		and coordinator.has_pending_envelope(31, &"projection/a"),
		"身份已认证但 Player 投影未就绪时，claim 必须报告 deferred 并保留原记录。"
	)
	_expect(
		_receive(
			coordinator,
			generation,
			31,
			&"projection/b",
			1,
			{"value": "after-auth"},
			102,
			&"upgrade_confirmed"
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.BUFFERED
		and committed_envelopes.is_empty()
		and coordinator.get_pending_envelope_count() == 2,
		"已注册身份也不能越过未就绪的 Player 投影抢先提交。"
	)
	_expect(
		_receive(
			coordinator,
			generation,
			31,
			&"identity/ready",
			1,
			{"value": "durable"},
			103,
			&"identity_ready"
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.APPLIED
		and committed_envelopes.size() == 1,
		"同一 peer 的持久身份结果不应被 Player 投影门误阻塞。"
	)
	unready_result_types.clear()
	var ready_claim := coordinator.claim_authenticated_peer(generation, 31, 104)
	_expect(
		int(ready_claim.get("committed", -1)) == 2
		and int(ready_claim.get("deferred", -1)) == 0
		and int(ready_claim.get("rejected", -1)) == 0
		and coordinator.get_pending_envelope_count() == 0
		and committed_envelopes.size() == 3
		and StringName(committed_envelopes[1]["result_type"])
		== &"upgrade_confirmed"
		and StringName(committed_envelopes[2]["result_type"])
		== &"upgrade_confirmed"
		and int(coordinator.export_metrics().get("deferred", -1)) == 1,
		"Player 投影成功后再次 claim 必须按原到达顺序各提交一次 deferred 升级结果。"
	)


func _test_transaction_streams_preserve_ui_tokens(
	coordinator: MpPeerLedgerCoordinatorScript,
	owner: Node
) -> void:
	registered_peer_ids = {}
	committed_envelopes.clear()
	var generation := coordinator.bind_session(
		owner,
		MpPeerLedgerCoordinatorScript.RuntimeRole.CLIENT,
		SESSION_INCARNATION,
		_is_peer_registered,
		_is_envelope_ready,
		_commit_envelope
	)
	for request_id in [41, 42]:
		_expect(
			coordinator.receive_authoritative_result(
				generation,
				SESSION_INCARNATION,
				9,
				&"simple_crafting",
				StringName("craft/%d" % request_id),
				request_id,
				{
					"request_id": request_id,
					"inventory_revision": 7,
				},
				500
			) == MpPeerLedgerCoordinatorScript.EnvelopeResult.BUFFERED,
			"不同 request_id 的制作结果必须保留为独立有界事务流。"
		)
	registered_peer_ids[9] = true
	var claim := coordinator.claim_authenticated_peer(generation, 9, 501)
	var committed_request_ids: Array[int] = []
	for committed in committed_envelopes:
		committed_request_ids.append(
			int((committed["payload"] as Dictionary)["request_id"])
		)
	_expect(
		int(claim.get("committed", 0)) == 2
		and committed_request_ids == [41, 42],
		"身份认领必须按到达顺序结算全部制作 request_id，不能只保留最新背包 revision。"
	)


func _test_pending_result_returns_to_domain_receiver(
	coordinator: MpPeerLedgerCoordinatorScript,
	owner: Node
) -> void:
	registered_peer_ids = {}
	var mp_game := MpGameScript.new()
	var transactions_probe := TransactionsReceiverProbe.new()
	mp_game.transactions_coordinator = transactions_probe
	var generation := coordinator.bind_session(
		owner,
		MpPeerLedgerCoordinatorScript.RuntimeRole.CLIENT,
		SESSION_INCARNATION,
		_is_peer_registered,
		_is_envelope_ready,
		Callable(mp_game, "_commit_pending_peer_ledger_envelope")
	)
	_expect(
		coordinator.receive_authoritative_result(
			generation,
			SESSION_INCARNATION,
			19,
			MpGameScript.PEER_RESULT_SIMPLE_CRAFTING,
			&"craft/73",
			73,
			{
				"request_id": 73,
				"recipe_id": "wood_bundle",
				"result": "success",
				"inventory_snapshot": {},
				"force_inventory_repair": false,
			},
			700
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.BUFFERED,
		"未认证制作结果必须先缓存完整领域参数。"
	)
	registered_peer_ids[19] = true
	var claim := coordinator.claim_authenticated_peer(generation, 19, 701)
	_expect(
		int(claim.get("committed", 0)) == 1
		and transactions_probe.crafting_calls.size() == 1
		and int(transactions_probe.crafting_calls[0]["peer_id"]) == 19
		and int(transactions_probe.crafting_calls[0]["request_id"]) == 73,
		"身份认领后必须调用原制作 receiver，并保留 request_id 对应的 UI token 语义。"
	)
	mp_game.free()
	transactions_probe.free()


func _test_timeout_and_generation(
	coordinator: MpPeerLedgerCoordinatorScript,
	owner: Node
) -> void:
	registered_peer_ids = {2: true}
	var generation := coordinator.bind_session(
		owner,
		MpPeerLedgerCoordinatorScript.RuntimeRole.CLIENT,
		SESSION_INCARNATION,
		_is_peer_registered,
		_is_envelope_ready,
		_commit_envelope
	)
	_expect(
		_receive(coordinator,
			generation,
			4,
			&"inventory",
			1,
			{"value": 1},
			1000
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.BUFFERED,
		"超时用例必须先建立 pending。"
	)
	_expect(
		coordinator.prune_expired_pending(
			generation,
			1000 + MpPeerLedgerCoordinatorScript.PENDING_ENVELOPE_TTL_MSEC - 1
		) == 0,
		"TTL 到达前不得提前清理 pending。"
	)
	_expect(
		coordinator.prune_expired_pending(
			generation,
			1000 + MpPeerLedgerCoordinatorScript.PENDING_ENVELOPE_TTL_MSEC
		) == 1
		and coordinator.get_pending_envelope_count() == 0,
		"TTL 到达时必须确定性清理未被认证认领的信封。"
	)
	_receive(coordinator,
		generation,
		5,
		&"inventory",
		1,
		{"value": 5},
		2000
	)
	var next_generation := coordinator.bind_session(
		owner,
		MpPeerLedgerCoordinatorScript.RuntimeRole.CLIENT,
		SESSION_INCARNATION + 1,
		_is_peer_registered,
		_is_envelope_ready,
		_commit_envelope
	)
	_expect(
		next_generation == generation + 1
		and coordinator.get_pending_envelope_count() == 0,
		"重新绑定必须推进 generation 并丢弃上一局 pending。"
	)
	_expect(
		_receive(coordinator,
			generation,
			5,
			&"inventory",
			2,
			{"value": 6},
			2001
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.REJECTED_STALE_GENERATION,
		"上一局捕获的延迟回调不得污染新 generation。"
	)


func _test_reconnect_record_remap(
	coordinator: MpPeerLedgerCoordinatorScript,
	owner: Node
) -> void:
	registered_peer_ids = {}
	committed_envelopes.clear()
	var generation := coordinator.bind_session(
		owner,
		MpPeerLedgerCoordinatorScript.RuntimeRole.CLIENT,
		SESSION_INCARNATION,
		_is_peer_registered,
		_is_envelope_ready,
		_commit_envelope
	)
	var old_peer_id := 10
	var new_peer_id := 20
	var old_envelopes := [
		[&"inventory", 2, {"side": "old_stale"}],
		[&"upgrade/attack", 1, {"level": 1}],
		[&"status", 5, {"side": "old_conflict"}],
		[&"upgrade/dodge", 2, {"level": 2}],
		[&"upgrade/health", 4, {"level": 4}],
	]
	var new_envelopes := [
		[&"inventory", 3, {"side": "new"}],
		[&"upgrade/attack", 1, {"level": 1}],
		[&"status", 5, {"side": "new_conflict_winner"}],
		[&"upgrade/health", 3, {"level": 3}],
	]
	for envelope in old_envelopes:
		_receive(coordinator,
			generation,
			old_peer_id,
			envelope[0],
			int(envelope[1]),
			envelope[2],
			5000
		)
	for envelope in new_envelopes:
		_receive(coordinator,
			generation,
			new_peer_id,
			envelope[0],
			int(envelope[1]),
			envelope[2],
			5001
		)
	registered_peer_ids[new_peer_id] = true
	var remap: Dictionary = coordinator.remap_authenticated_peer(
		generation,
		old_peer_id,
		new_peer_id,
		5002
	)
	_expect(
		bool(remap.get("accepted", false))
		and int(remap.get("resolved_peer_id", 0)) == new_peer_id
		and int(remap.get("migrated", -1)) == 2
		and int(remap.get("deduplicated", -1)) == 1
		and int(remap.get("stale_discarded", -1)) == 1
		and int(remap.get("conflicts", -1)) == 1,
		"old→new remap 必须按 revision 合并迁移、去重、丢弃 stale 并报告冲突。"
	)
	_expect(
		not coordinator.has_pending_envelope(old_peer_id, &"inventory")
		and coordinator.get_pending_envelope_count() == 5,
		"remap 后旧 pending 必须全部归并到新身份，且不建立未来入站路由。"
	)
	var claim := coordinator.claim_authenticated_peer(generation, new_peer_id, 5004)
	_expect(
		int(claim.get("committed", -1)) == 5
		and coordinator.get_pending_envelope_count() == 0,
		"新身份必须能一次认领合并后的五条独立完整快照流。"
	)
	var committed_by_stream: Dictionary = {}
	for committed in committed_envelopes:
		committed_by_stream[committed["stream_id"]] = committed["payload"]
	_expect(
		(committed_by_stream.get(&"status", {}) as Dictionary).get("side", "")
		== "new_conflict_winner"
		and int(
			(committed_by_stream.get(&"upgrade/health", {}) as Dictionary).get(
				"level",
				-1
			)
		) == 4,
		"冲突必须保留 new 侧内容，而更高 old revision 必须覆盖较低 new revision。"
	)
	# PeerLedger 不再猜测 transport 身份；上层传入 old 时必须严格留在 old，
	# participant incarnation 解析 canonical 的责任只属于 MpGame/NetManager。
	registered_peer_ids[old_peer_id] = true
	_expect(
		_receive(coordinator,
			generation,
			old_peer_id,
			&"inventory",
			4,
			{"side": "late_old_channel"},
			5005
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.APPLIED
		and int(committed_envelopes[-1]["peer_id"]) == old_peer_id,
		"PeerLedger 不得再把未来 old-wire 入站静默路由到 new peer。"
	)

	var newest_peer_id := 30
	registered_peer_ids.erase(old_peer_id)
	registered_peer_ids.erase(new_peer_id)
	registered_peer_ids[newest_peer_id] = true
	var chained_remap := coordinator.remap_authenticated_peer(
		generation,
		new_peer_id,
		newest_peer_id,
		5006
	)
	_expect(
		bool(chained_remap.get("accepted", false)),
		"连续重连必须把 new 侧既有 pending/applied 水位迁移到最新身份。"
	)
	var replay_result := _receive(coordinator,
		generation,
		newest_peer_id,
		&"inventory",
		3,
		{"side": "new"},
		5008
	)
	_expect(
		replay_result == MpPeerLedgerCoordinatorScript.EnvelopeResult.IDEMPOTENT,
		"迁移后的 applied 水位必须在最新身份下继续阻止可靠包重放。"
	)
	_expect(
		coordinator.clear_peer(generation, newest_peer_id)
		and coordinator.get_pending_envelope_count() == 0
		and coordinator.get_applied_envelope_count() == 1
		and coordinator.clear_peer(generation, old_peer_id)
		and coordinator.get_applied_envelope_count() == 0,
		"无 alias 后 clear_peer 只能清 canonical 记录，独立 old 记录必须显式清理。"
	)


func _test_remap_lifecycle(
	coordinator: MpPeerLedgerCoordinatorScript,
	owner: Node
) -> void:
	registered_peer_ids = {}
	var generation := coordinator.bind_session(
		owner,
		MpPeerLedgerCoordinatorScript.RuntimeRole.CLIENT,
		SESSION_INCARNATION,
		_is_peer_registered,
		_is_envelope_ready,
		_commit_envelope
	)
	registered_peer_ids[200] = true
	var first := coordinator.remap_authenticated_peer(
		generation,
		100,
		200,
		10_000
	)
	var duplicate := coordinator.remap_authenticated_peer(
		generation,
		100,
		200,
		20_000
	)
	_expect(
		bool(first.get("accepted", false))
		and bool(duplicate.get("accepted", false))
		and coordinator.get_pending_envelope_count() == 0
		and coordinator.get_applied_envelope_count() == 0,
		"没有待迁移记录的重复 CH0 remap 必须幂等且不能制造隐藏路由状态。"
	)
	var next_generation := coordinator.bind_session(
		owner,
		MpPeerLedgerCoordinatorScript.RuntimeRole.CLIENT,
		SESSION_INCARNATION + 1,
		_is_peer_registered,
		_is_envelope_ready,
		_commit_envelope
	)
	_expect(
		not bool(
			coordinator.remap_authenticated_peer(
				generation,
				400,
				200,
				50_001
			).get("accepted", true)
		)
		and next_generation == generation + 1,
		"换代后上一 generation 的记录迁移回调必须被拒绝。"
	)


func _test_remap_stream_capacity(
	coordinator: MpPeerLedgerCoordinatorScript,
	owner: Node
) -> void:
	registered_peer_ids = {}
	var generation := coordinator.bind_session(
		owner,
		MpPeerLedgerCoordinatorScript.RuntimeRole.CLIENT,
		SESSION_INCARNATION,
		_is_peer_registered,
		_is_envelope_ready,
		_commit_envelope
	)
	for stream_index in range(9):
		_receive(coordinator,
			generation,
			70,
			StringName("old/%d" % stream_index),
			1,
			{"value": stream_index},
			60_000
		)
	for stream_index in range(8):
		_receive(coordinator,
			generation,
			80,
			StringName("new/%d" % stream_index),
			1,
			{"value": stream_index},
			60_000
		)
	registered_peer_ids[80] = true
	var remap := coordinator.remap_authenticated_peer(
		generation,
		70,
		80,
		60_001
	)
	_expect(
		not bool(remap.get("accepted", true))
		and remap.get("reason")
		== MpPeerLedgerCoordinatorScript.REASON_CAPACITY_EXCEEDED
		and coordinator.get_pending_envelope_count() == 17,
		"合并后超过单 peer stream 上限时必须原子拒绝，不得留下半迁移记录。"
	)
	_expect(
		coordinator.abort_authenticated_peer_remap(generation, 70, 80)
		and coordinator.get_pending_envelope_count() == 0
		and coordinator.get_applied_envelope_count() == 0,
		"身份持久账本已迁移但别名预检失败时，必须能显式撤销 old/new 全部结果租约。"
	)


func _test_capacity_limits(
	coordinator: MpPeerLedgerCoordinatorScript,
	owner: Node
) -> void:
	registered_peer_ids = {}
	var generation := coordinator.bind_session(
		owner,
		MpPeerLedgerCoordinatorScript.RuntimeRole.CLIENT,
		SESSION_INCARNATION,
		_is_peer_registered,
		_is_envelope_ready,
		_commit_envelope
	)
	var inserted := 0
	for peer_offset in range(MpPeerLedgerCoordinatorScript.MAX_PENDING_PEERS):
		var peer_id := 100 + peer_offset
		for stream_offset in range(8):
			var result := _receive(coordinator,
				generation,
				peer_id,
				StringName("ledger_%d" % stream_offset),
				1,
				{"value": stream_offset},
				3000
			)
			if result == MpPeerLedgerCoordinatorScript.EnvelopeResult.BUFFERED:
				inserted += 1
	_expect(
		inserted == MpPeerLedgerCoordinatorScript.MAX_PENDING_ENVELOPES
		and coordinator.get_pending_envelope_count()
		== MpPeerLedgerCoordinatorScript.MAX_PENDING_ENVELOPES,
		"pending 总容量必须精确受限。"
	)
	_expect(
		_receive(coordinator,
			generation,
			999,
			&"overflow",
			1,
			{"value": 1},
			3001
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.REJECTED_CAPACITY,
		"超过 peer/总信封容量时必须拒绝，不得静默驱逐既有权威状态。"
	)
	_expect(
		coordinator.get_pending_envelope_count()
		== MpPeerLedgerCoordinatorScript.MAX_PENDING_ENVELOPES,
		"容量拒绝不得破坏已缓存的信封。"
	)


func _test_host_unknown_peer_boundary(
	coordinator: MpPeerLedgerCoordinatorScript,
	owner: Node
) -> void:
	registered_peer_ids = {1: true}
	committed_envelopes.clear()
	var generation := coordinator.bind_session(
		owner,
		MpPeerLedgerCoordinatorScript.RuntimeRole.HOST,
		SESSION_INCARNATION,
		_is_peer_registered,
		_is_envelope_ready,
		_commit_envelope
	)
	_expect(
		_receive(coordinator,
			generation,
			77,
			&"inventory",
			1,
			{"value": 77},
			4000
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.REJECTED_UNKNOWN_HOST_PEER
		and coordinator.get_pending_envelope_count() == 0,
		"Host 对未知 peer 必须直接拒绝，绝不能为其创建临时或持久账本。"
	)
	_expect(
		_receive(coordinator,
			generation,
			1,
			&"inventory",
			1,
			{"value": 1},
			4001
		) == MpPeerLedgerCoordinatorScript.EnvelopeResult.APPLIED,
		"Host 已登记 peer 仍可通过相同提交边界处理权威账本。"
	)
	registered_peer_ids[2] = true
	var forbidden_remap := coordinator.remap_authenticated_peer(
		generation,
		1,
		2,
		4002
	)
	_expect(
		not bool(forbidden_remap.get("accepted", true))
		and forbidden_remap.get("reason")
		== MpPeerLedgerCoordinatorScript.REASON_HOST_REMAP_FORBIDDEN,
		"Host 不得执行客户端记录迁移，身份解析只能服从 Host roster。"
	)


func _test_owner_scoped_unbind(
	coordinator: MpPeerLedgerCoordinatorScript,
	owner: Node
) -> void:
	var stranger := Node.new()
	root.add_child(stranger)
	_expect(
		not coordinator.unbind_session(stranger) and coordinator.is_bound(),
		"非当前 owner 的延迟解绑不得清理活跃会话。"
	)
	_expect(
		coordinator.unbind_session(owner) and not coordinator.is_bound(),
		"当前 owner 必须能完整释放协调器生命周期。"
	)
	stranger.free()


func _is_peer_registered(peer_id: int) -> bool:
	return registered_peer_ids.has(peer_id)


func _is_envelope_ready(
	_peer_id: int,
	result_type: StringName,
	_payload: Dictionary
) -> bool:
	return not unready_result_types.has(result_type)


func _receive(
	coordinator: MpPeerLedgerCoordinatorScript,
	generation: int,
	peer_id: int,
	stream_id: StringName,
	revision: int,
	payload: Dictionary,
	now_msec: int = -1,
	result_type: StringName = &"test_authoritative_result"
) -> int:
	return coordinator.receive_authoritative_result(
		generation,
		SESSION_INCARNATION,
		peer_id,
		result_type,
		stream_id,
		revision,
		payload,
		now_msec
	)


func _function_body_contains(
	source: String,
	function_name: String,
	needle: String
) -> bool:
	return _get_function_body(source, function_name).contains(needle)


func _get_function_body(source: String, function_name: String) -> String:
	var function_start := source.find("func %s(" % function_name)
	if function_start < 0:
		return ""
	var next_function := source.find("\nfunc ", function_start + 1)
	var function_end := source.length() if next_function < 0 else next_function
	return source.substr(function_start, function_end - function_start)


func _contains_peer_id_key(value: Variant) -> bool:
	if typeof(value) == TYPE_DICTIONARY:
		for key in (value as Dictionary).keys():
			if (
				typeof(key) in [TYPE_STRING, TYPE_STRING_NAME]
				and str(key) == "peer_id"
			):
				return true
			if _contains_peer_id_key((value as Dictionary)[key]):
				return true
	elif typeof(value) == TYPE_ARRAY:
		for child in value as Array:
			if _contains_peer_id_key(child):
				return true
	return false


func _commit_envelope(
	peer_id: int,
	result_type: StringName,
	stream_id: StringName,
	revision: int,
	payload: Dictionary
) -> bool:
	if rejected_stream_ids.has(stream_id):
		return false
	committed_envelopes.append({
		"peer_id": peer_id,
		"result_type": result_type,
		"stream_id": stream_id,
		"revision": revision,
		"payload": payload.duplicate(true),
	})
	return true


func _on_envelope_rejected(
	_peer_id: int,
	_stream_id: StringName,
	_revision: int,
	reason: StringName
) -> void:
	rejection_reasons.append(reason)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish(owner: Node, coordinator: MpPeerLedgerCoordinatorScript) -> void:
	if coordinator != null:
		coordinator.free()
	owner.free()
	if failures.is_empty():
		print("MP_PEER_LEDGER_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
