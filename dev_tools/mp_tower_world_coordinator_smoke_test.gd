extends SceneTree

const TOWER_WORLD_SCENE := preload(
	"res://scene/multiplayer/tower_world/mp_tower_world_coordinator.tscn"
)
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


class HostNetManager:
	extends NetManagerStore

	func is_host() -> bool:
		return true

	func is_client() -> bool:
		return false

	func get_local_peer_id() -> int:
		return 1


class ClientNetManager:
	extends NetManagerStore

	func is_host() -> bool:
		return false

	func is_client() -> bool:
		return true

	func get_local_peer_id() -> int:
		return 2


class TestTowerModeAdapter:
	extends TowerDefenseMultiplayerModeAdapter

	var plants: Dictionary[int, PlantDefense] = {}
	var placement_requests: Array[Dictionary] = []
	var next_net_id := 77
	var terrain_snapshot_revision := 7
	var terrain_snapshot_cell_xy := PackedInt32Array()
	var terrain_snapshot_types := PackedInt32Array()
	var applied_terrain_revision := -1
	var applied_terrain_cell_xy := PackedInt32Array()
	var applied_terrain_types := PackedInt32Array()
	var base_current_health := 8
	var base_maximum_health := 12
	var base_health_revision := 3
	var applied_base_current_health := 0
	var applied_base_maximum_health := 1
	var applied_base_health_revision := -1
	var manual_night_enabled := false

	func supports_terrain_state() -> bool:
		return true

	func get_terrain_snapshot() -> Dictionary:
		return {
			"revision": terrain_snapshot_revision,
			"cell_xy": terrain_snapshot_cell_xy.duplicate(),
			"terrain_types": terrain_snapshot_types.duplicate(),
		}

	func apply_remote_terrain_snapshot(
		revision: int,
		cell_xy: PackedInt32Array,
		terrain_types: PackedInt32Array
	) -> bool:
		applied_terrain_revision = revision
		applied_terrain_cell_xy = cell_xy.duplicate()
		applied_terrain_types = terrain_types.duplicate()
		return true

	func apply_remote_terrain_delta(
		revision: int,
		cell_xy: PackedInt32Array,
		terrain_types: PackedInt32Array
	) -> bool:
		applied_terrain_revision = revision
		applied_terrain_cell_xy.append_array(cell_xy)
		applied_terrain_types.append_array(terrain_types)
		return true

	func get_base_health_snapshot() -> Dictionary:
		return {
			"current_health": base_current_health,
			"maximum_health": base_maximum_health,
			"revision": base_health_revision,
		}

	func apply_remote_base_health(
		current_health: int,
		maximum_health: int,
		revision: int
	) -> void:
		if revision <= applied_base_health_revision:
			return
		applied_base_current_health = current_health
		applied_base_maximum_health = maximum_health
		applied_base_health_revision = revision

	func supports_test_arena_manual_night_sync() -> bool:
		return true

	func get_test_arena_manual_night_enabled() -> bool:
		return manual_night_enabled

	func apply_remote_test_arena_manual_night(enabled: bool) -> void:
		manual_night_enabled = enabled

	func get_authoritative_team_plant_count() -> int:
		return plants.size()

	func request_authoritative_plant_placement(
		requester_peer_id: int,
		request_id: int,
		plant_id: StringName,
		anchor: Vector2i
	) -> void:
		placement_requests.append({
			"requester_peer_id": requester_peer_id,
			"request_id": request_id,
			"plant_id": plant_id,
			"anchor": anchor,
		})
		var plant := _create_proxy(next_net_id, 10, 10, 1)
		plants[next_net_id] = plant
		plant_spawned.emit(
			request_id,
			requester_peer_id,
			next_net_id,
			plant_id,
			anchor,
			10,
			10,
			1
		)

	func apply_remote_plant_spawn(
		_request_id: int,
		_owner_peer_id: int,
		net_id: int,
		_plant_id: StringName,
		_anchor: Vector2i,
		current_health: int,
		maximum_health: int,
		health_revision: int
	) -> void:
		plants[net_id] = _create_proxy(
			net_id,
			current_health,
			maximum_health,
			health_revision
		)

	func apply_remote_plant_health(
		net_id: int,
		current_health: int,
		maximum_health: int,
		health_revision: int
	) -> void:
		var plant := get_multiplayer_plant_node(net_id)
		if plant != null:
			plant.apply_remote_health(
				current_health,
				maximum_health,
				health_revision
			)

	func apply_remote_plant_removed(
		net_id: int,
		_was_destroyed: bool = false,
		_silent: bool = false
	) -> void:
		var plant := plants.get(net_id) as PlantDefense
		plants.erase(net_id)
		if plant != null and is_instance_valid(plant):
			plant.free()

	func get_multiplayer_plant_node(net_id: int) -> PlantDefense:
		return plants.get(net_id) as PlantDefense

	func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
		var snapshots: Array[Dictionary] = []
		for net_id in plants:
			var plant := plants[net_id]
			snapshots.append({
				"net_id": net_id,
				"owner_peer_id": 2,
				"plant_id": &"agave_cannon",
				"anchor": Vector2i(3, 4),
				"current_health": plant.current_health,
				"maximum_health": plant.max_health,
				"health_revision": plant.health_revision,
			})
		return snapshots

	func clear_plants() -> void:
		for plant: PlantDefense in plants.values():
			if plant != null and is_instance_valid(plant):
				plant.free()
		plants.clear()

	func _create_proxy(
		net_id: int,
		current_health: int,
		maximum_health: int,
		health_revision: int
	) -> PlantDefense:
		var plant := PlantDefense.new()
		plant.set_meta(&"net_id", net_id)
		plant.configure_multiplayer_proxy(
			current_health,
			maximum_health,
			health_revision
		)
		return plant


var failures: Array[String] = []
var _spawn_record: Dictionary = {}
var _terrain_chunk_records: Array[Dictionary] = []
var _terrain_repair_revisions: Array[int] = []
var _base_health_send_records: Array[Dictionary] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var mp_game := MP_GAME_SCENE.instantiate() as MultiplayerGameplaySession
	_expect(mp_game != null, "MpGame 场景必须可实例化。")
	if mp_game == null:
		_finish()
		return
	_test_static_boundary(mp_game)
	_test_placement_spawn_pending_health_remove_chain(mp_game)
	_test_terrain_repair_and_base_revision(mp_game)
	mp_game.free()
	_finish()


func _test_static_boundary(mp_game: MultiplayerGameplaySession) -> void:
	_expect(
		mp_game.get_node_or_null("TowerWorldCoordinator")
		is MpTowerWorldCoordinator,
		"MpGame 必须静态搭建 TowerWorldCoordinator 子节点。"
	)
	var source := FileAccess.get_file_as_string(MP_GAME_SOURCE_PATH)
	var rpc_pattern := RegEx.new()
	rpc_pattern.compile("(?m)^@rpc\\(")
	_expect(
		rpc_pattern.search_all(source).size() == 126,
		"TowerWorld 提取不得改变 MpGame 的 126 个 RPC 门面。"
	)
	for function_name in [
		"net_plant_placement_requested",
		"net_inventory_plant_placement_requested",
		"net_terrain_snapshot_requested",
	]:
		_expect(
			_rpc_entry_captures_sender_first(source, function_name),
			"%s 必须在 RPC 入口首行捕获 sender。" % function_name
		)
	var coordinator_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/tower_world/mp_tower_world_coordinator.gd"
	)
	_expect(
		not coordinator_source.contains("current_scene")
		and not coordinator_source.contains("has_method")
		and not coordinator_source.contains(".call("),
		"TowerWorldCoordinator 不得通过动态能力探测访问运行时。"
	)
	_expect(
		not source.contains("func _send_terrain_snapshot_to_peer")
		and not source.contains("func _request_terrain_snapshot_repair")
		and not source.contains("_pending_terrain_snapshot_batches"),
		"MpGame 不得继续持有地形快照组装或修复状态。"
	)


func _test_placement_spawn_pending_health_remove_chain(
	session: MultiplayerGameplaySession
) -> void:
	var host := _make_fixture(session, true)
	var client := _make_fixture(session, false)
	var host_coordinator := host.coordinator as MpTowerWorldCoordinator
	var client_coordinator := client.coordinator as MpTowerWorldCoordinator
	var host_adapter := host.adapter as TestTowerModeAdapter
	var client_adapter := client.adapter as TestTowerModeAdapter
	host_coordinator.plant_spawn_broadcast_requested.connect(_capture_spawn)
	host_coordinator.handle_remote_plant_placement_request(
		2,
		1,
		"agave_cannon",
		Vector2i(3, 4)
	)
	_expect(
		host_adapter.placement_requests.size() == 1
		and int(_spawn_record.get("net_id", 0)) == 77,
		"合法放置请求必须进入权威适配器并产生植物生成记录。"
	)

	# CH7 may overtake reliable CH5. Cache revision 2 before consuming spawn 1.
	client_coordinator.receive_plant_health_changed(77, 4, 10, 2)
	var pending_before_spawn := client_coordinator.get(
		"_pending_remote_plant_health_updates"
	) as Dictionary
	_expect(
		pending_before_spawn.has(77),
		"生成前到达的植物生命更新必须进入有界 pending 缓存。"
	)
	var plant := client_coordinator.receive_plant_spawn(
		int(_spawn_record.get("request_id", 0)),
		int(_spawn_record.get("owner_peer_id", 0)),
		int(_spawn_record.get("net_id", 0)),
		str(_spawn_record.get("plant_id", "")),
		_spawn_record.get("anchor", Vector2i.ZERO) as Vector2i,
		int(_spawn_record.get("current_health", 0)),
		int(_spawn_record.get("maximum_health", 1)),
		int(_spawn_record.get("health_revision", 0))
	)
	client_coordinator.apply_pending_remote_plant_health(77)
	_expect(
		plant != null
		and plant.current_health == 4
		and plant.health_revision == 2,
		"生成后必须把提前到达的较新生命 revision 应用到真实植物代理。"
	)
	client_coordinator.receive_plant_removed(77, true)
	client_coordinator.receive_plant_health_changed(77, 9, 10, 3)
	_expect(
		client_adapter.get_multiplayer_plant_node(77) == null
		and client_coordinator.is_remote_plant_removed(77)
		and not (
			client_coordinator.get("_pending_remote_plant_health_updates")
			as Dictionary
		).has(77),
		"移除必须建立 tombstone，并拒绝随后到达的陈旧生命更新。"
	)
	_dispose_fixture(session, host)
	_dispose_fixture(session, client)


func _test_terrain_repair_and_base_revision(
	session: MultiplayerGameplaySession
) -> void:
	var host := _make_fixture(session, true)
	var client := _make_fixture(session, false)
	var host_coordinator := host.coordinator as MpTowerWorldCoordinator
	var client_coordinator := client.coordinator as MpTowerWorldCoordinator
	var host_adapter := host.adapter as TestTowerModeAdapter
	var client_adapter := client.adapter as TestTowerModeAdapter
	_terrain_chunk_records.clear()
	_terrain_repair_revisions.clear()
	_base_health_send_records.clear()
	host_coordinator.terrain_snapshot_chunk_send_requested.connect(
		_capture_terrain_chunk
	)
	host_coordinator.base_health_send_requested.connect(_capture_base_health_send)
	client_coordinator.terrain_snapshot_request_to_host.connect(
		_capture_terrain_repair_request
	)
	for cell_index in range(97):
		host_adapter.terrain_snapshot_cell_xy.append(cell_index)
		host_adapter.terrain_snapshot_cell_xy.append(cell_index % 7)
		host_adapter.terrain_snapshot_types.append(
			1 if cell_index % 2 == 0 else 2
		)
	host_coordinator.request_terrain_snapshot_for_peer(2)
	_expect(
		_terrain_chunk_records.size() == 2
		and int(_terrain_chunk_records[0].get("chunk_index", -1)) == 0
		and int(_terrain_chunk_records[1].get("chunk_index", -1)) == 1,
		"97 格权威地形必须按稳定顺序拆成两个快照分片。"
	)
	if _terrain_chunk_records.size() == 2:
		client_coordinator.begin_runtime_state_request()
		_deliver_terrain_chunk(client_coordinator, _terrain_chunk_records[1])
		_deliver_terrain_chunk(client_coordinator, _terrain_chunk_records[0])
	_expect(
		client_adapter.applied_terrain_revision == 7
		and client_adapter.applied_terrain_cell_xy
		== host_adapter.terrain_snapshot_cell_xy
		and client_adapter.applied_terrain_types
		== host_adapter.terrain_snapshot_types,
		"客户端必须按 chunk_index 重组乱序地形分片，并保留 revision。"
	)

	host_coordinator.broadcast_base_health_snapshot()
	_expect(
		_base_health_send_records.size() == 1
		and int(_base_health_send_records[0].get("target_peer_id", -1)) == 0,
		"基地生命变化必须由 TowerWorldCoordinator 请求根门面广播。"
	)
	client_coordinator.receive_base_health_changed(8, 12, 3)
	client_coordinator.receive_base_health_changed(1, 12, 2)
	_expect(
		client_adapter.applied_base_current_health == 8
		and client_adapter.applied_base_maximum_health == 12
		and client_adapter.applied_base_health_revision == 3,
		"基地生命旧 revision 必须由模式适配器拒绝。"
	)

	client_coordinator.receive_terrain_delta(
		9,
		PackedInt32Array([200, 3]),
		PackedInt32Array([1])
	)
	client_coordinator.update_client(2.0)
	_expect(
		_terrain_repair_revisions == [7, 7],
		"地形 revision 缺口必须立即请求修复，并在看门狗超时后限频重试。"
	)
	_dispose_fixture(session, host)
	_dispose_fixture(session, client)


func _make_fixture(
	session: MultiplayerGameplaySession,
	is_host: bool
) -> Dictionary:
	var coordinator := (
		TOWER_WORLD_SCENE.instantiate() as MpTowerWorldCoordinator
	)
	var transactions := (
		TRANSACTIONS_SCENE.instantiate() as MpTransactionsCoordinator
	)
	var runtime := TestRuntime.new()
	var adapter := TestTowerModeAdapter.new()
	var net_manager: NetManagerStore = (
		HostNetManager.new() if is_host else ClientNetManager.new()
	)
	var run_state := RunStateStore.new()
	adapter.bind_runtime(runtime)
	transactions.bind_session(
		session,
		runtime,
		adapter,
		net_manager,
		run_state,
		{}
	)
	coordinator.bind_session(
		session,
		runtime,
		adapter,
		net_manager,
		transactions
	)
	return {
		"coordinator": coordinator,
		"transactions": transactions,
		"runtime": runtime,
		"adapter": adapter,
		"net_manager": net_manager,
		"run_state": run_state,
	}


func _dispose_fixture(
	session: MultiplayerGameplaySession,
	fixture: Dictionary
) -> void:
	var coordinator := fixture.coordinator as MpTowerWorldCoordinator
	var transactions := fixture.transactions as MpTransactionsCoordinator
	var adapter := fixture.adapter as TestTowerModeAdapter
	coordinator.unbind_session(session)
	transactions.unbind_session(session)
	adapter.clear_plants()
	coordinator.free()
	transactions.free()
	adapter.free()
	(fixture.runtime as TestRuntime).free()
	(fixture.net_manager as NetManagerStore).free()
	(fixture.run_state as RunStateStore).free()


func _capture_terrain_chunk(
	target_peer_id: int,
	snapshot_id: int,
	revision: int,
	chunk_index: int,
	chunk_count: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	_terrain_chunk_records.append({
		"target_peer_id": target_peer_id,
		"snapshot_id": snapshot_id,
		"revision": revision,
		"chunk_index": chunk_index,
		"chunk_count": chunk_count,
		"cell_xy": cell_xy.duplicate(),
		"terrain_types": terrain_types.duplicate(),
	})


func _capture_terrain_repair_request(known_revision: int) -> void:
	_terrain_repair_revisions.append(known_revision)


func _capture_base_health_send(
	target_peer_id: int,
	current_health: int,
	maximum_health: int,
	revision: int
) -> void:
	_base_health_send_records.append({
		"target_peer_id": target_peer_id,
		"current_health": current_health,
		"maximum_health": maximum_health,
		"revision": revision,
	})


func _deliver_terrain_chunk(
	coordinator: MpTowerWorldCoordinator,
	record: Dictionary
) -> void:
	coordinator.receive_terrain_snapshot_chunk(
		int(record.get("snapshot_id", 0)),
		int(record.get("revision", -1)),
		int(record.get("chunk_index", -1)),
		int(record.get("chunk_count", 0)),
		record.get("cell_xy", PackedInt32Array()) as PackedInt32Array,
		record.get("terrain_types", PackedInt32Array()) as PackedInt32Array
	)


func _capture_spawn(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	_spawn_record = {
		"request_id": request_id,
		"owner_peer_id": owner_peer_id,
		"net_id": net_id,
		"plant_id": plant_id,
		"anchor": anchor,
		"current_health": current_health,
		"maximum_health": maximum_health,
		"health_revision": health_revision,
	}


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
		print("MP_TOWER_WORLD_COORDINATOR_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
