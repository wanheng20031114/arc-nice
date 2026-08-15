extends SceneTree

const TRANSACTIONS_SCENE := preload(
	"res://scene/multiplayer/transactions/mp_transactions_coordinator.tscn"
)
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const MP_GAME_SOURCE_PATH := "res://scene/multiplayer/mp_game.gd"
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const ROCK_POTION: PickupConfig = preload(
	"res://resources/config/consumables/rock_potion.tres"
)


class TestRuntime:
	extends CombatRuntimeBase
	var players: Dictionary = {}

	func _ready() -> void:
		pass

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return players.get(peer_id) as Player

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
	_test_consumable_single_settlement(coordinator)
	_test_inventory_results_survive_player_lifecycle_gap(coordinator)
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
		rpc_pattern.search_all(source).size() == 144,
		"Transactions 提取必须保留 protocol-v72 的 144 个 MpGame RPC 门面。"
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


func _test_consumable_single_settlement(
	coordinator: MpTransactionsCoordinator
) -> void:
	const PEER_ID := 7
	var session := MP_GAME_SCENE.instantiate() as MultiplayerGameplaySession
	var runtime := TestRuntime.new()
	var adapter := MultiplayerModeAdapter.new()
	var net_manager := NetManagerStore.new()
	var host_run_state := RunStateStore.new()
	var suspended_peers: Dictionary[int, bool] = {}
	var host_player := PLAYER_SCENE.instantiate() as Player
	root.add_child(net_manager)
	root.add_child(host_player)
	host_player.set_physics_process(false)
	runtime.players[PEER_ID] = host_player
	net_manager.net_role = NetManagerStore.NetRole.HOST
	coordinator.bind_session(
		session,
		runtime,
		adapter,
		net_manager,
		host_run_state,
		suspended_peers
	)
	var broadcasts: Array[Dictionary] = []
	coordinator.inventory_item_used_broadcast_requested.connect(
		func(
			peer_id: int,
			slot_index: int,
			config_path: String,
			success: bool,
			inventory_snapshot: Dictionary,
			force_inventory_repair: bool
		) -> void:
			broadcasts.append({
				"peer_id": peer_id,
				"slot_index": slot_index,
				"config_path": config_path,
				"success": success,
				"inventory_snapshot": inventory_snapshot.duplicate(true),
				"force_inventory_repair": force_inventory_repair,
			})
	)
	_expect(
		host_run_state.try_add_item_count_for_peer(PEER_ID, ROCK_POTION, 2),
		"多人药水事务测试必须建立两瓶岩石药水。"
	)
	var potion_slot := _find_item_slot_for_peer(
		host_run_state,
		PEER_ID,
		ROCK_POTION
	)
	var expected_revision := host_run_state.get_inventory_revision_for_peer(
		PEER_ID
	)
	var base_physical_defense := host_player.physical_defense
	coordinator.apply_authoritative_inventory_item_use(
		PEER_ID,
		potion_slot,
		expected_revision
	)
	_expect(
		broadcasts.size() == 1
		and bool(broadcasts[0].get("success", false))
		and str(broadcasts[0].get("config_path", ""))
		== ROCK_POTION.resource_path
		and host_run_state.get_item_count_for_peer(PEER_ID, potion_slot) == 1
		and host_player.physical_defense == base_physical_defense + 15
		and is_equal_approx(host_player.potion_physical_defense_time_left, 10.0),
		"Host 权威药水事务必须只扣一瓶、应用一次并广播新 revision。"
	)
	var successful_snapshot := (
		broadcasts[0].get("inventory_snapshot", {}) as Dictionary
	).duplicate(true)
	host_player.call("_update_pickup_effects", 2.0)
	coordinator.apply_authoritative_inventory_item_use(
		PEER_ID,
		potion_slot,
		expected_revision
	)
	_expect(
		broadcasts.size() == 2
		and not bool(broadcasts[1].get("success", true))
		and bool(broadcasts[1].get("force_inventory_repair", false))
		and host_run_state.get_item_count_for_peer(PEER_ID, potion_slot) == 1
		and is_equal_approx(host_player.potion_physical_defense_time_left, 8.0),
		"重复的旧 revision 使用请求必须失败，不能再次扣除或刷新药水。"
	)
	coordinator.unbind_session(session)

	var client_run_state := RunStateStore.new()
	var client_player := PLAYER_SCENE.instantiate() as Player
	root.add_child(client_player)
	client_player.set_physics_process(false)
	runtime.players[PEER_ID] = client_player
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	coordinator.bind_session(
		session,
		runtime,
		adapter,
		net_manager,
		client_run_state,
		suspended_peers
	)
	var client_base_physical_defense := client_player.physical_defense
	coordinator.receive_inventory_item_used(
		PEER_ID,
		potion_slot,
		ROCK_POTION.resource_path,
		true,
		successful_snapshot
	)
	_expect(
		client_player.physical_defense == client_base_physical_defense + 15
		and is_equal_approx(client_player.potion_physical_defense_time_left, 10.0)
		and client_run_state.get_item_count_for_peer(PEER_ID, potion_slot) == 1,
		"客户端必须在新背包 revision 首次到达时重放一次药水效果。"
	)
	client_player.call("_update_pickup_effects", 2.0)
	coordinator.receive_inventory_item_used(
		PEER_ID,
		potion_slot,
		ROCK_POTION.resource_path,
		true,
		successful_snapshot
	)
	_expect(
		client_run_state.get_item_count_for_peer(PEER_ID, potion_slot) == 1
		and is_equal_approx(client_player.potion_physical_defense_time_left, 8.0),
		"重复确认的相同 revision 不得在客户端二次重放或刷新药水。"
	)
	coordinator.unbind_session(session)
	_stop_audio_players(host_player)
	_stop_audio_players(client_player)
	host_player.free()
	client_player.free()
	net_manager.free()
	adapter.free()
	runtime.free()
	session.free()
	host_run_state.free()
	client_run_state.free()


func _test_inventory_results_survive_player_lifecycle_gap(
	coordinator: MpTransactionsCoordinator
) -> void:
	const PEER_ID := 7
	var authoritative_state := RunStateStore.new()
	_expect(
		authoritative_state.try_add_item_count_for_peer(PEER_ID, ROCK_POTION, 2),
		"事务乱序夹具必须建立权威背包。"
	)
	var potion_slot := _find_item_slot_for_peer(
		authoritative_state,
		PEER_ID,
		ROCK_POTION
	)
	var used_snapshot := (
		authoritative_state.export_inventory_snapshot_for_peer(PEER_ID)
	)
	_expect(
		authoritative_state.discard_item_for_peer(PEER_ID, potion_slot),
		"事务乱序夹具必须生成后续丢弃 revision。"
	)
	var discarded_snapshot := (
		authoritative_state.export_inventory_snapshot_for_peer(PEER_ID)
	)
	_expect(
		authoritative_state.try_add_item_for_peer(PEER_ID, ROCK_POTION),
		"事务乱序夹具必须生成后续制作结果 revision。"
	)
	var crafting_snapshot := (
		authoritative_state.export_inventory_snapshot_for_peer(PEER_ID)
	)

	var session := MP_GAME_SCENE.instantiate() as MultiplayerGameplaySession
	var runtime := TestRuntime.new()
	var adapter := MultiplayerModeAdapter.new()
	var net_manager := NetManagerStore.new()
	var client_state := RunStateStore.new()
	var suspended_peers: Dictionary[int, bool] = {}
	root.add_child(net_manager)
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	coordinator.bind_session(
		session,
		runtime,
		adapter,
		net_manager,
		client_state,
		suspended_peers
	)
	# 模拟 CH0 已经移除 Player，而 CH6 可靠事务结果随后抵达。
	_expect(runtime.get_player_for_peer(PEER_ID) == null, "夹具不得创建 Player。")
	coordinator.receive_inventory_item_used(
		PEER_ID,
		potion_slot,
		ROCK_POTION.resource_path,
		true,
		used_snapshot
	)
	_expect(
		client_state.get_inventory_revision_for_peer(PEER_ID)
		== int(used_snapshot.get("revision", -1))
		and client_state.get_inventory_item_total_for_peer(
			PEER_ID,
			ROCK_POTION
		) == 2,
		"Player 缺席时，使用结果仍必须提交权威背包快照。"
	)
	coordinator.receive_inventory_item_discarded(
		PEER_ID,
		potion_slot,
		true,
		discarded_snapshot
	)
	_expect(
		client_state.get_inventory_revision_for_peer(PEER_ID)
		== int(discarded_snapshot.get("revision", -1))
		and client_state.get_inventory_item_total_for_peer(
			PEER_ID,
			ROCK_POTION
		) == 0,
		"Player 缺席时，丢弃结果仍必须推进背包 revision。"
	)
	coordinator.receive_simple_crafting_result(
		PEER_ID,
		41,
		"test_recipe",
		String(RunStateStore.CRAFT_RESULT_SUCCESS),
		crafting_snapshot
	)
	var result_ids := coordinator.get(
		"_last_simple_crafting_result_ids"
	) as Dictionary
	_expect(
		client_state.get_inventory_revision_for_peer(PEER_ID)
		== int(crafting_snapshot.get("revision", -1))
		and client_state.get_inventory_item_total_for_peer(
			PEER_ID,
			ROCK_POTION
		) == 1
		and int(result_ids.get(PEER_ID, 0)) == 41,
		"Player 缺席时，制作结果必须原子收敛账本与去重游标。"
	)

	coordinator.unbind_session(session)
	net_manager.free()
	adapter.free()
	runtime.free()
	session.free()
	authoritative_state.free()
	client_state.free()


func _find_item_slot_for_peer(
	run_state: RunStateStore,
	peer_id: int,
	expected_item: PickupConfig
) -> int:
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		if run_state.get_item_for_peer(peer_id, slot_index) == expected_item:
			return slot_index
	return -1


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).stop()
	elif node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).stop()
	for child in node.get_children():
		_stop_audio_players(child)


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
		"var sender_id := _get_rpc_sender_id()"
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
