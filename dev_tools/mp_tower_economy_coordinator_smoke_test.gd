extends SceneTree

const ECONOMY_SCENE := preload(
	"res://scene/game_modes/tower_defense/multiplayer/economy/mp_tower_economy_coordinator.tscn"
)
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const MP_GAME_SOURCE_PATH := "res://scene/multiplayer/mp_game.gd"
const WOOD_CONFIG := preload("res://resources/config/materials/material_wood.tres")


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

	func ensure_reconnected_multiplayer_player(
		_old_peer_id: int,
		_new_peer_id: int,
		_player_name: String,
		_character_id: StringName,
		_state: SnapshotManager.PlayerState,
		_spawn_slot_index: int,
		_reconnect_state: Dictionary = {}
	) -> CombatRuntimeBase.ReconnectedPlayerProjection:
		return CombatRuntimeBase.ReconnectedPlayerProjection.new(
			CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATE_FAILED
		)

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass


class HostNetManager:
	extends NetManagerStore

	func get_local_peer_id() -> int:
		return 1

	func is_peer_send_ready(peer_id: int) -> bool:
		return peer_id > 0


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := ECONOMY_SCENE.instantiate() as MpTowerEconomyCoordinator
	_expect(coordinator != null, "TowerEconomyCoordinator scene must instantiate.")
	if coordinator == null:
		_finish()
		return
	_test_static_boundary(coordinator)
	_test_warehouse_pending_snapshot(coordinator)
	_test_warehouse_transaction_rechecks_both_ledgers()
	_test_production_pending_state(coordinator)
	_test_research_rejection_result(coordinator)
	coordinator.free()
	_finish()


func _test_static_boundary(coordinator: MpTowerEconomyCoordinator) -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(
		mp_game != null
		and mp_game.get_node_or_null("TowerEconomyCoordinator")
		is MpTowerEconomyCoordinator,
		"MpGame must statically contain TowerEconomyCoordinator."
	)
	if mp_game != null:
		mp_game.free()
	var source := FileAccess.get_file_as_string(MP_GAME_SOURCE_PATH)
	var rpc_pattern := RegEx.new()
	rpc_pattern.compile("(?m)^@rpc\\(")
	_expect(
		rpc_pattern.search_all(source).size() == 145,
		"Tower economy extraction must preserve all 145 protocol-v86 MpGame RPC facades."
	)
	for function_name in [
		"net_warehouse_command_requested",
		"net_warehouse_snapshot_requested",
		"net_production_command_requested",
		"net_research_command_requested",
		"net_production_snapshot_requested",
	]:
		_expect(
			_rpc_entry_captures_sender_first(source, function_name),
			"%s must capture sender in its first executable line." % function_name
		)
	for function_name in [
		"net_warehouse_command_requested",
		"net_production_command_requested",
		"net_research_command_requested",
	]:
		_expect(
			_rpc_entry_uses_shared_admission_before_economy(source, function_name),
			"%s must use shared transaction admission before domain handling."
			% function_name
		)
	var coordinator_source := coordinator.get_script().source_code as String
	_expect(
		not coordinator_source.contains("current_scene")
		and not coordinator_source.contains("has_method")
		and not coordinator_source.contains(".call("),
		"TowerEconomyCoordinator must use typed dependencies without dynamic guessing."
	)


func _test_warehouse_pending_snapshot(
	coordinator: MpTowerEconomyCoordinator
) -> void:
	coordinator.cache_pending_warehouse_snapshot(21, {"schema": 1, "revision": 1})
	coordinator.cache_pending_warehouse_snapshot(21, {"schema": 1, "revision": 2})
	var pending := coordinator.get("_pending_warehouse_snapshots") as Dictionary
	_expect(
		pending.size() == 1
		and int((pending.get(21, {}) as Dictionary).get("revision", 0)) == 2,
		"Warehouse pending snapshots must coalesce by net id."
	)
	coordinator.notify_plant_removed(21)
	coordinator.cache_pending_warehouse_snapshot(21, {"schema": 1, "revision": 3})
	_expect(
		not pending.has(21),
		"Removed warehouses must reject late pending snapshots."
	)
	coordinator.notify_plant_available(21)


func _test_warehouse_transaction_rechecks_both_ledgers() -> void:
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.register_multiplayer_peer_state(7),
		"仓库原子事务夹具必须建立玩家持久账本。"
	)
	var incoming_inventory := run_state.export_inventory_snapshot_for_peer(7)
	incoming_inventory["revision"] = 1
	var incoming_slots: Array = []
	for raw_slot in incoming_inventory.get("slots", []) as Array:
		var slot := (raw_slot as Dictionary).duplicate(true)
		slot["revision"] = 1
		incoming_slots.append(slot)
	incoming_inventory["slots"] = incoming_slots
	var warehouse := OakWarehouse.new()
	warehouse.storage_items.resize(OakWarehouse.STORAGE_CAPACITY)
	warehouse.storage_stack_counts.resize(OakWarehouse.STORAGE_CAPACITY)
	warehouse.storage_stack_counts.fill(0)
	warehouse.configure_persistent_storage_identity(77)
	var incoming_storage := warehouse.export_storage_snapshot()
	incoming_storage["revision"] = 1
	var prepared_inventory := run_state.prepare_inventory_snapshot_for_peer(
		7,
		incoming_inventory
	)
	var prepared_storage := warehouse.prepare_storage_snapshot(incoming_storage)
	_expect(
		not prepared_inventory.is_empty() and not prepared_storage.is_empty(),
		"仓库原子事务夹具必须先成功 prepare 两侧账本。"
	)
	# 模拟 prepare 后被另一条可靠信道推进背包 revision；最终 CAS 必须在
	# 第一笔事务写入前发现竞争，不能先改仓库再失败。
	_expect(
		run_state.try_add_item_for_peer(7, WOOD_CONFIG),
		"竞争夹具必须真实推进玩家背包 revision。"
	)
	var raced_inventory := run_state.export_inventory_snapshot_for_peer(7)
	var storage_before := warehouse.export_storage_snapshot()
	_expect(
		not MpTowerEconomyCoordinator.commit_prepared_warehouse_transaction(
			run_state,
			warehouse,
			prepared_inventory,
			prepared_storage
		)
		and run_state.export_inventory_snapshot_for_peer(7) == raced_inventory
		and warehouse.export_storage_snapshot() == storage_before,
		"prepare 后背包 revision 改变时，两侧事务写入都必须为零。"
	)
	warehouse.free()
	run_state.free()


func _test_production_pending_state(
	coordinator: MpTowerEconomyCoordinator
) -> void:
	_expect(
		coordinator.cache_pending_remote_production_state(
			31,
			{"schema": 1, "revision": 2},
			5.0
		),
		"A production state must enter the pending cache."
	)
	_expect(
		not coordinator.cache_pending_remote_production_state(
			31,
			{"schema": 1, "revision": 1},
			6.0
		),
		"An older production revision must not replace the pending state."
	)
	_expect(
		coordinator.cache_pending_remote_production_state(
			31,
			{"schema": 1, "revision": 3},
			7.0
		),
		"A newer production revision must replace the pending state."
	)
	var taken := coordinator.take_pending_remote_production_state(31)
	_expect(
		int((taken.get("state", {}) as Dictionary).get("revision", 0)) == 3
		and coordinator.take_pending_remote_production_state(31).is_empty(),
		"Taking a production state must return the newest value exactly once."
	)


func _test_research_rejection_result(
	coordinator: MpTowerEconomyCoordinator
) -> void:
	var runtime := TestRuntime.new()
	var adapter := TowerDefenseMultiplayerModeAdapter.new()
	var run_state := RunStateStore.new()
	var net_manager := HostNetManager.new()
	net_manager.net_role = NetManagerStore.NetRole.HOST
	coordinator.bind_runtime(runtime, adapter, run_state, net_manager, 0.0)
	var outbound_results: Array[Dictionary] = []
	coordinator.rpc_to_peer_requested.connect(
		func(
			peer_id: int,
			method_name: StringName,
			args: Array,
			record_outbound: bool
		) -> void:
			outbound_results.append({
				"peer_id": peer_id,
				"method_name": method_name,
				"args": args,
				"record_outbound": record_outbound,
			})
	)
	coordinator.handle_authoritative_research_command(
		7,
		{
			"schema": ResearchCenter.MULTIPLAYER_RESEARCH_COMMAND_SCHEMA,
			"request_id": 41,
			"building_net_id": 51,
			"peer_id": 7,
			"operation": "player",
			"research_id": "",
		}
	)
	var outbound := (
		outbound_results[0]
		if not outbound_results.is_empty()
		else {}
	) as Dictionary
	var args := outbound.get("args", []) as Array
	_expect(
		outbound_results.size() == 1
		and int(outbound.get("peer_id", 0)) == 7
		and StringName(outbound.get("method_name", &""))
		== &"net_research_command_result"
		and args.size() == 4
		and int(args[0]) == 41
		and not bool(args[2])
		and StringName(args[3]) == ResearchCoordinator.RESULT_UNAVAILABLE,
		"A valid but unavailable research request must receive one deterministic result."
	)
	coordinator.unbind_runtime(runtime)
	net_manager.free()
	run_state.free()
	adapter.free()
	runtime.free()


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
	var first_line := source.substr(
		body_offset,
		line_end - body_offset
	).strip_edges()
	return first_line in [
		"var sender_id := multiplayer.get_remote_sender_id()",
		"var sender_id := _get_rpc_sender_id()",
	]


func _rpc_entry_uses_shared_admission_before_economy(
	source: String,
	function_name: String
) -> bool:
	var function_offset := source.find("func %s" % function_name)
	if function_offset < 0:
		return false
	var next_function := source.find("\nfunc ", function_offset + 1)
	var body := source.substr(
		function_offset,
		(next_function if next_function >= 0 else source.length()) - function_offset
	)
	var admission_offset := body.find(
		"transactions_coordinator.consume_remote_transaction_admission(sender_id)"
	)
	var delegate_offset := body.find("tower_economy_coordinator.handle_authoritative_")
	return admission_offset >= 0 and delegate_offset > admission_offset


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("MP_TOWER_ECONOMY_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
