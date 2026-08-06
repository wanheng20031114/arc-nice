extends SceneTree

const TRANSACTIONS_SCENE := preload(
	"res://scene/multiplayer/transactions/mp_transactions_coordinator.tscn"
)
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const MP_GAME_SOURCE_PATH := "res://scene/multiplayer/mp_game.gd"


class TestRuntime:
	extends CombatRuntimeBase

	func _ready() -> void:
		pass

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(_peer_id: int) -> Player:
		return null

	func get_enemy_for_net_id(_net_id: int) -> Enemy:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(_peer_id: int) -> void:
		pass

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := (
		TRANSACTIONS_SCENE.instantiate() as MpTransactionsCoordinator
	)
	_expect(coordinator != null, "TransactionsCoordinator 场景必须可实例化。")
	if coordinator == null:
		_finish()
		return
	_test_static_mp_game_boundary(coordinator)
	_test_local_request_tracking(coordinator)
	_test_replay_cache(coordinator)
	_test_shared_ingress_budget(coordinator)
	coordinator.free()
	_finish()


func _test_static_mp_game_boundary(coordinator: MpTransactionsCoordinator) -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(
		mp_game != null
		and mp_game.get_node_or_null("TransactionsCoordinator")
		is MpTransactionsCoordinator,
		"MpGame 场景必须静态搭建 TransactionsCoordinator 子节点。"
	)
	if mp_game != null:
		mp_game.free()
	var source := FileAccess.get_file_as_string(MP_GAME_SOURCE_PATH)
	var rpc_pattern := RegEx.new()
	rpc_pattern.compile("(?m)^@rpc\\(")
	_expect(
		rpc_pattern.search_all(source).size() == 126,
		"Transactions 提取不得改变 MpGame 的 126 个 RPC 门面。"
	)
	for function_name in [
		"net_upgrade_selected",
		"net_inventory_item_use_requested",
		"net_inventory_item_discard_requested",
		"net_simple_crafting_requested",
		"net_skill1_purchase_requested",
	]:
		_expect(
			_rpc_entry_captures_sender_first(source, function_name),
			"%s 必须在 RPC 入口首行捕获 sender。" % function_name
		)
	_expect(
		not source.contains("func _apply_upgrade_for_peer")
		and not source.contains("func _apply_inventory_item_use_for_peer")
		and not source.contains("func _apply_authoritative_simple_crafting_request")
		and not source.contains("func _apply_skill1_purchase_for_peer")
		and source.contains("transactions_coordinator.handle_remote_upgrade_selection"),
		"共享事务实现必须归 TransactionsCoordinator，MpGame 仅保留薄 RPC 门面。"
	)
	_expect(
		not coordinator.get_script().source_code.contains("current_scene")
		and not coordinator.get_script().source_code.contains("has_method")
		and not coordinator.get_script().source_code.contains(".call("),
		"TransactionsCoordinator 不得通过动态能力探测访问运行时。"
	)


func _test_local_request_tracking(coordinator: MpTransactionsCoordinator) -> void:
	coordinator.track_local_simple_crafting_request(11, 101)
	coordinator.track_local_simple_crafting_request(12, 102)
	_expect(
		coordinator.take_local_simple_crafting_request_token(11) == 101,
		"制造结果必须按 request_id 精确取回本地 UI token。"
	)
	coordinator.cancel_simple_crafting_request(102)
	_expect(
		(coordinator.get(
			"_local_simple_crafting_ui_tokens_by_request_id"
		) as Dictionary).is_empty()
		and (coordinator.get(
			"_local_simple_crafting_request_ids_by_ui_token"
		) as Dictionary).is_empty(),
		"取消制造请求必须通过双向索引清理本地跟踪。"
	)


func _test_replay_cache(coordinator: MpTransactionsCoordinator) -> void:
	for request_id in range(1, 35):
		coordinator.cache_simple_crafting_result(
			7,
			request_id,
			{"request_id": request_id, "nested": {"value": request_id}}
		)
	var results := coordinator.get(
		"_simple_crafting_results_by_peer"
	) as Dictionary
	var peer_results := results.get(7, {}) as Dictionary
	_expect(
		peer_results.size() == 32
		and not peer_results.has(1)
		and not peer_results.has(2)
		and peer_results.has(34),
		"制造重放缓存必须维持每 Peer 32 条的 O(1) 有界窗口。"
	)
	var replay := coordinator.get_cached_simple_crafting_result(7, 34)
	(replay.get("nested") as Dictionary)["value"] = -1
	_expect(
		int((coordinator.get_cached_simple_crafting_result(7, 34).get(
			"nested"
		) as Dictionary).get("value", 0)) == 34,
		"重放结果必须深复制，调用方不得改写权威缓存。"
	)


func _test_shared_ingress_budget(coordinator: MpTransactionsCoordinator) -> void:
	var session := MP_GAME_SCENE.instantiate() as MultiplayerGameplaySession
	var runtime := TestRuntime.new()
	var adapter := MultiplayerModeAdapter.new()
	var net_manager := NetManagerStore.new()
	var run_state := RunStateStore.new()
	var suspended_peers: Dictionary[int, bool] = {8: true}
	root.add_child(net_manager)
	net_manager.net_role = NetManagerStore.NetRole.HOST
	coordinator.bind_session(
		session,
		runtime,
		adapter,
		net_manager,
		run_state,
		suspended_peers
	)
	var accepted := 0
	for _index in 48:
		if coordinator.consume_remote_transaction_admission(7, 100.0):
			accepted += 1
	_expect(
		accepted == 48
		and not coordinator.consume_remote_transaction_admission(7, 100.0),
		"共享事务入站预算必须保留每 Peer 48 次突发上限。"
	)
	_expect(
		not coordinator.consume_remote_transaction_admission(8, 100.0),
		"内嵌战斗中被暂停的参与者不得提交事务。"
	)
	coordinator.unbind_session(session)
	net_manager.free()
	adapter.free()
	runtime.free()
	session.free()
	run_state.free()


func _rpc_entry_captures_sender_first(source: String, function_name: String) -> bool:
	var function_offset := source.find("func %s" % function_name)
	if function_offset < 0:
		return false
	var body_offset := source.find(") -> void:\n", function_offset)
	if body_offset < 0:
		return false
	body_offset += ") -> void:\n".length()
	var line_end := source.find("\n", body_offset)
	if line_end < 0:
		return false
	return source.substr(body_offset, line_end - body_offset).strip_edges() == (
		"var sender_id := multiplayer.get_remote_sender_id()"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("MP_TRANSACTIONS_COORDINATOR_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
