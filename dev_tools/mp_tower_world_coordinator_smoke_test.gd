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
