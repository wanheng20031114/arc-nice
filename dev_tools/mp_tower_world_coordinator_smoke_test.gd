extends SceneTree

const TOWER_WORLD_SCENE := preload(
	"res://scene/game_modes/tower_defense/multiplayer/world/mp_tower_world_coordinator.tscn"
)
const TRANSACTIONS_SCENE := preload(
	"res://scene/multiplayer/transactions/mp_transactions_coordinator.tscn"
)
const ENEMY_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/enemy/mp_enemy_coordinator.tscn"
)
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const MP_GAME_SOURCE_PATH := "res://scene/multiplayer/mp_game.gd"


class TestRuntime:
	extends CombatRuntimeBase

	var fixture_pooled_session_object: Node = null

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

	func has_session_object_pool_scene(_scene: PackedScene) -> bool:
		return fixture_pooled_session_object != null

	func acquire_session_object(
		_scene: PackedScene,
		_strict: bool = false
	) -> Node:
		var instance := fixture_pooled_session_object
		fixture_pooled_session_object = null
		return instance


class HostNetManager:
	extends NetManagerStore

	func is_host() -> bool:
		return true

	func is_client() -> bool:
		return false

	func get_local_peer_id() -> int:
		return 1

	func is_gameplay_ingress_admitted(peer_id: int) -> bool:
		return peer_id == 2


class ClientNetManager:
	extends NetManagerStore

	func is_host() -> bool:
		return false

	func is_client() -> bool:
		return true

	func get_local_peer_id() -> int:
		return 2


class TestSessionCoordinator:
	extends MpSessionCoordinator

	func get_net_time() -> float:
		return 50.0

	func map_host_timestamp_to_client_time(
		host_timestamp: float,
		_update_offset: bool = true
	) -> float:
		return host_timestamp + 3.0


class TestProductionBuilding:
	extends ProductionBuilding

	var lifecycle_records: Array[String] = []
	var applied_runtime_state: Dictionary = {}
	var applied_host_sample_time := -1.0

	func request_multiplayer_production_snapshot() -> bool:
		lifecycle_records.append("production_snapshot")
		return true

	func apply_multiplayer_runtime_state_with_host_sample(
		state: Dictionary,
		_mapped_sample_time: float,
		host_sample_time: float
	) -> void:
		lifecycle_records.append("runtime_state")
		applied_runtime_state = state.duplicate(true)
		applied_host_sample_time = host_sample_time


class TestRuntimeStatePlant:
	extends PlantDefense

	var apply_count := 0
	var applied_runtime_state: Dictionary = {}
	var applied_mapped_sample_time := -1.0

	func apply_multiplayer_runtime_state(
		state: Dictionary,
		mapped_sample_time: float
	) -> void:
		apply_count += 1
		applied_runtime_state = state.duplicate(true)
		applied_mapped_sample_time = mapped_sample_time


class TestTowerEconomyCoordinator:
	extends MpTowerEconomyCoordinator

	var lifecycle_records: Array[String] = []

	func notify_plant_available(_net_id: int) -> void:
		lifecycle_records.append("economy_available")

	func configure_production_network(
		plant: PlantDefense,
		_snapshot_ready: bool
	) -> void:
		lifecycle_records.append("production_config")
		var building := plant as TestProductionBuilding
		if building != null:
			building.lifecycle_records = lifecycle_records
			building.multiplayer_production_snapshot_ready = false

	func configure_research_network(_plant: PlantDefense) -> void:
		lifecycle_records.append("research_config")

	func request_plant_runtime_state_apply(
		_plant: PlantDefense,
		_state: Dictionary,
		_host_sample_time: float
	) -> void:
		lifecycle_records.append("runtime_state")

	func configure_warehouse_network(
		_plant: PlantDefense,
		_snapshot_ready: bool,
		_apply_pending_snapshots: bool = true
	) -> void:
		lifecycle_records.append("warehouse_config")

	func notify_plant_removed(_net_id: int) -> void:
		lifecycle_records.append("economy_removed")

	func try_apply_pending_warehouse_snapshots_atomically() -> bool:
		lifecycle_records.append("warehouse_retry")
		return true


class TestBambooMortar:
	extends BambooMortar

	var playback_records: Array[Dictionary] = []

	func play_multiplayer_action(
		stage: int,
		action_id: int,
		spawn_position: Vector2,
		landing_position: Vector2,
		elapsed_seconds: float,
		action_windup_duration_seconds: float
	) -> void:
		playback_records.append({
			"stage": stage,
			"action_id": action_id,
			"spawn_position": spawn_position,
			"landing_position": landing_position,
			"elapsed_seconds": elapsed_seconds,
			"windup_duration": action_windup_duration_seconds,
		})


class TestHydrangeaRainTower:
	extends HydrangeaRainTower

	var playback_records: Array[Dictionary] = []

	func play_multiplayer_rain_action(
		action_id: int,
		target_position: Vector2,
		elapsed_seconds: float
	) -> void:
		playback_records.append({
			"action_id": action_id,
			"target_position": target_position,
			"elapsed_seconds": elapsed_seconds,
		})


class TestCornMachineGun:
	extends CornMachineGun

	var playback_records: Array[Dictionary] = []

	func play_multiplayer_burst(
		direction: Vector2,
		action_id: int,
		elapsed_seconds: float,
		shot_count: int = 0
	) -> void:
		playback_records.append({
			"direction": direction,
			"action_id": action_id,
			"elapsed_seconds": elapsed_seconds,
			"shot_count": shot_count,
		})


class TestEnemy:
	extends Enemy

	var received_requests: Array[DamageRequest] = []
	var fixture_health := 100
	var last_fixture_result: DamageResult = null

	func apply_combat_damage(request: DamageRequest) -> DamageResult:
		received_requests.append(request)
		var result := DamageResult.new()
		result.request = request
		result.accepted = true
		result.requested_amount = request.amount
		result.resolved_damage = request.amount
		result.applied_damage = mini(request.amount, fixture_health)
		result.health_before = fixture_health
		fixture_health -= result.applied_damage
		result.health_after = fixture_health
		result.lethal = false
		last_fixture_result = result
		health_revision += 1
		return result


class TestTowerModeAdapter:
	extends TowerDefenseMultiplayerModeAdapter

	var plants: Dictionary[int, PlantDefense] = {}
	var lifecycle_records: Array[String] = []
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
	var target_request_records: Array[Dictionary] = []
	var canceled_target_owner: Node = null
	var selected_fixture_target: Enemy = null
	var explosion_records: Array[Dictionary] = []

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

	func request_runtime_bamboo_mortar_target(
		owner: Node2D,
		minimum_range: float,
		maximum_range: float,
		callback: Callable
	) -> bool:
		target_request_records.append({
			"owner": owner,
			"minimum_range": minimum_range,
			"maximum_range": maximum_range,
			"callback_valid": callback.is_valid(),
		})
		return true

	func cancel_runtime_bamboo_mortar_target_request(owner: Node) -> void:
		canceled_target_owner = owner

	func select_runtime_bamboo_mortar_target_sync_for_fixture(
		_center: Vector2,
		_minimum_range: float,
		_maximum_range: float
	) -> Enemy:
		return selected_fixture_target

	func queue_runtime_bamboo_mortar_explosion(
		landing_position: Vector2,
		inner_radius: float,
		outer_radius: float,
		inner_damage: int,
		outer_damage: int,
		damage_source_id: int
	) -> bool:
		explosion_records.append({
			"landing_position": landing_position,
			"inner_radius": inner_radius,
			"outer_radius": outer_radius,
			"inner_damage": inner_damage,
			"outer_damage": outer_damage,
			"damage_source_id": damage_source_id,
		})
		return true

	func get_runtime_bamboo_mortar_combat_metrics() -> Dictionary:
		return {"queued_explosions": explosion_records.size()}

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
		plant_id: StringName,
		_anchor: Vector2i,
		current_health: int,
		maximum_health: int,
		health_revision: int
	) -> void:
		lifecycle_records.append("spawn")
		plants[net_id] = _create_proxy(
			net_id,
			current_health,
			maximum_health,
			health_revision,
			plant_id == &"test_production"
		)

	func apply_remote_plant_health(
		net_id: int,
		current_health: int,
		maximum_health: int,
		health_revision: int
	) -> void:
		var plant := get_multiplayer_plant_node(net_id)
		if plant != null:
			lifecycle_records.append("health")
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
		lifecycle_records.append("world_removed")
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
		health_revision: int,
		production_building: bool = false
	) -> PlantDefense:
		var plant: PlantDefense = null
		if production_building:
			plant = TestProductionBuilding.new()
		else:
			plant = PlantDefense.new()
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
var _plant_projectile_visual_records: Array[Dictionary] = []
var _bamboo_visual_batches: Array[Dictionary] = []
var _hydrangea_visual_records: Array[Dictionary] = []
var _corn_visual_batches: Array[Dictionary] = []


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
	_test_vegetation_spread_sample_age_correction(mp_game)
	_test_terrain_repair_and_base_revision(mp_game)
	_test_plant_combat_network(mp_game)
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
		rpc_pattern.search_all(source).size() == 145,
		"TowerWorld 提取必须保留 protocol-v87 的 145 个 MpGame RPC 门面。"
	)
	for function_name in [
		"net_plant_placement_requested",
		"net_nearest_plant_destruction_requested",
		"net_inventory_plant_placement_requested",
		"net_terrain_snapshot_requested",
	]:
		_expect(
			_rpc_entry_captures_sender_first(source, function_name),
			"%s 必须在 RPC 入口首行捕获 sender。" % function_name
		)
	var coordinator_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/multiplayer/world/mp_tower_world_coordinator.gd"
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
	_expect(
		not source.contains("_pending_bamboo_mortar_visuals")
		and not source.contains("_pending_corn_machine_gun_burst_visuals")
		and not source.contains("func _is_valid_bamboo_mortar_visual_payload")
		and not source.contains("func _is_valid_corn_machine_gun_burst_payload")
		and not source.contains("\"play_multiplayer_rain_action\"")
		and not source.contains("\"play_multiplayer_burst\""),
		"MpGame 不得继续持有植物战斗表现队列、校验或动态播放逻辑。"
	)
	var plant_spawn_body := _get_rpc_body(source, "net_plant_spawned")
	_expect(
		plant_spawn_body.count("tower_world_coordinator.receive_plant_spawn(") == 1
		and not plant_spawn_body.contains("tower_economy_coordinator")
		and not plant_spawn_body.contains("_configure_")
		and not plant_spawn_body.contains("_apply_plant_runtime_state")
		and not plant_spawn_body.contains("\tif "),
		"net_plant_spawned 必须仅向 TowerWorldCoordinator 参数委托。"
	)
	var plant_removed_body := _get_rpc_body(source, "net_plant_removed")
	_expect(
		plant_removed_body.strip_edges()
		== "tower_world_coordinator.receive_plant_removed(net_id, was_destroyed)",
		"net_plant_removed 必须仅向 TowerWorldCoordinator 参数委托。"
	)
	_expect(
		coordinator_source.contains(
			"var _tower_economy: MpTowerEconomyCoordinator = null"
		),
		"TowerWorldCoordinator 必须以强类型依赖协调塔防经济。"
	)
	_expect(
		not source.contains("func _export_plant_runtime_state(")
		and not source.contains("func _apply_plant_runtime_state(")
		and not source.contains("func _send_plant_placement_rejected(")
		and coordinator_source.contains("func export_plant_runtime_state(")
		and coordinator_source.contains("func apply_plant_runtime_state(")
		and coordinator_source.contains("func send_live_plant_roster_to_peer("),
		"MpGame 不得继续持有植物 runtime state、拒绝发送或迟加入 roster 算法。"
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
	host_coordinator.rpc_broadcast_requested.connect(_capture_world_rpc_broadcast)
	host_coordinator.handle_remote_plant_placement_request(
		2,
		1,
		"test_production",
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
		int(_spawn_record.get("health_revision", 0)),
		{"revision": 1, "cycle_elapsed_seconds": 2.0},
		42.0
	)
	_expect(
		plant != null
		and plant.current_health == 4
		and plant.health_revision == 2,
		"生成后必须把提前到达的较新生命 revision 应用到真实植物代理。"
	)
	var client_lifecycle := client.lifecycle_records as Array[String]
	_expect(
		client_lifecycle == [
			"spawn",
			"economy_available",
			"production_config",
			"research_config",
			"runtime_state",
			"production_snapshot",
			"warehouse_config",
			"health",
		],
		"植物生成必须保持世界生成、经济配置、状态、补包与 pending 生命的原顺序。"
	)
	var production_building := plant as TestProductionBuilding
	_expect(
		production_building != null
		and is_equal_approx(
			float(production_building.applied_runtime_state.get(
				"cycle_elapsed_seconds",
				-1.0
			)),
			7.0
		)
		and is_equal_approx(production_building.applied_host_sample_time, 42.0),
		"植物 runtime state 必须按会话时钟补偿 5 秒传输年龄，并保留 Host sample time。"
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
	_expect(
		client_lifecycle.slice(-3) == [
			"economy_removed",
			"world_removed",
			"warehouse_retry",
		],
		"植物移除必须先清理经济 pending，再移除世界实体，最后原子补应用仓库快照。"
	)
	_dispose_fixture(session, host)
	_dispose_fixture(session, client)


func _test_vegetation_spread_sample_age_correction(
	session: MultiplayerGameplaySession
) -> void:
	var client := _make_fixture(session, false)
	var coordinator := client.coordinator as MpTowerWorldCoordinator
	var plant := TestRuntimeStatePlant.new()
	coordinator.apply_plant_runtime_state(
		plant,
		{
			"schema": VegetationStake.RUNTIME_STATE_SCHEMA,
			"spread_elapsed_seconds": 20.0,
			"spread_speed_multiplier": 2.0,
		},
		42.0
	)
	_expect(
		plant.apply_count == 1
		and is_equal_approx(
			float(plant.applied_runtime_state.get(
				"spread_elapsed_seconds",
				-1.0
			)),
			30.0
		)
		and is_equal_approx(
			float(plant.applied_runtime_state.get(
				"spread_speed_multiplier",
				-1.0
			)),
			2.0
		),
		"植被桩迟加入快照必须按2倍传播速率补偿5秒传输年龄，基础进度应从20推进到30。"
	)
	coordinator.apply_plant_runtime_state(
		plant,
		{
			"schema": VegetationStake.RUNTIME_STATE_SCHEMA,
			"spread_elapsed_seconds": 30.0,
		},
		42.0
	)
	_expect(
		plant.apply_count == 1,
		"缺少权威传播倍率的植被桩快照必须被拒绝，不能按隐式1倍伪造迟加入进度。"
	)
	plant.free()
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


func _test_plant_combat_network(session: MultiplayerGameplaySession) -> void:
	var host := _make_fixture(session, true)
	var client := _make_fixture(session, false)
	var host_coordinator := host.coordinator as MpTowerWorldCoordinator
	var client_coordinator := client.coordinator as MpTowerWorldCoordinator
	var host_adapter := host.adapter as TestTowerModeAdapter
	var client_adapter := client.adapter as TestTowerModeAdapter
	var host_bamboo := TestBambooMortar.new()
	var client_bamboo := TestBambooMortar.new()
	var host_hydrangea := TestHydrangeaRainTower.new()
	var client_hydrangea := TestHydrangeaRainTower.new()
	var host_corn := TestCornMachineGun.new()
	var client_corn := TestCornMachineGun.new()
	host_adapter.plants[201] = host_bamboo
	host_adapter.plants[202] = host_hydrangea
	host_adapter.plants[203] = host_corn
	client_adapter.plants[201] = client_bamboo
	client_adapter.plants[202] = client_hydrangea
	client_adapter.plants[203] = client_corn
	_plant_projectile_visual_records.clear()
	_bamboo_visual_batches.clear()
	_hydrangea_visual_records.clear()
	_corn_visual_batches.clear()
	host_coordinator.plant_projectile_visual_broadcast_requested.connect(
		_capture_plant_projectile_visual
	)
	host_coordinator.bamboo_mortar_visual_batch_broadcast_requested.connect(
		_capture_bamboo_visual_batch
	)
	host_coordinator.hydrangea_rain_visual_broadcast_requested.connect(
		_capture_hydrangea_visual
	)
	host_coordinator.corn_machine_gun_burst_batch_broadcast_requested.connect(
		_capture_corn_visual_batch
	)
	host_coordinator.broadcast_plant_projectile_visual(
		201,
		Vector2(3.0, 4.0),
		Vector2(4.0, 0.0),
		180.0,
		18.0,
		1.25
	)
	for record_index in range(25):
		host_coordinator.queue_bamboo_mortar_visual(
			201,
			record_index + 1,
			record_index % 2,
			Vector2(record_index, 1.0),
			Vector2(record_index, 2.0),
			BambooMortar.WINDUP_DURATION_SECONDS,
			5.0 + record_index
		)
	host_coordinator.queue_hydrangea_rain_visual(
		202,
		31,
		Vector2(8.0, 9.0),
		0.25,
		12.0
	)
	for record_index in range(33):
		host_coordinator.queue_corn_machine_gun_burst_visual(
			203,
			record_index + 1,
			Vector2(2.0, 0.0),
			6 + (record_index % 2) * 2,
			6.0 + record_index
		)
	host_coordinator.update_host(0.05)
	_expect(
		_plant_projectile_visual_records.size() == 1
		and (
			_plant_projectile_visual_records[0].get("direction", Vector2.ZERO)
			as Vector2
		) == Vector2.RIGHT,
		"植物弹体视觉必须由 TowerWorld 请求根门面广播并规范化方向。"
	)
	var projectile_scene := load(
		"res://scene/plant_defense/agave_cannonball.tscn"
	) as PackedScene
	var pooled_projectile := projectile_scene.instantiate() as AgaveCannonball
	root.add_child(pooled_projectile)
	root.remove_child(pooled_projectile)
	var client_runtime := client.runtime as TestRuntime
	client_runtime.fixture_pooled_session_object = pooled_projectile
	var session_child_count_before := session.get_child_count()
	client_coordinator.receive_plant_projectile_visual(
		Vector2(3.0, 4.0),
		Vector2(4.0, 0.0),
		180.0,
		18.0,
		1.25
	)
	var remote_projectile := session.get_child(
		session_child_count_before
	) as AgaveCannonball
	_expect(
		remote_projectile == pooled_projectile
		and remote_projectile.direction == Vector2.RIGHT
		and remote_projectile.damage == 0
		and not remote_projectile.authoritative_damage,
		"客户端必须通过运行时对象池复用并强类型初始化植物弹体视觉。"
	)
	_expect(
		_bamboo_visual_batches.size() == 2
		and (
			_bamboo_visual_batches[0].get("plant_net_ids", PackedInt32Array())
			as PackedInt32Array
		).size() == 24
		and (
			_bamboo_visual_batches[1].get("plant_net_ids", PackedInt32Array())
			as PackedInt32Array
		).size() == 1,
		"25 条竹迫击炮视觉必须按 24 条上限稳定拆为两个批次。"
	)
	_expect(
		_corn_visual_batches.size() == 2
		and (
			_corn_visual_batches[0].get("plant_net_ids", PackedInt32Array())
			as PackedInt32Array
		).size() == 32
		and (
			_corn_visual_batches[1].get("plant_net_ids", PackedInt32Array())
			as PackedInt32Array
		).size() == 1
		and (
			_corn_visual_batches[0].get("shot_counts", PackedByteArray())
			as PackedByteArray
		).size() == 32
		and (
			_corn_visual_batches[1].get("shot_counts", PackedByteArray())
			as PackedByteArray
		) == PackedByteArray([6]),
		"33 条玉米 burst 必须按 32 条上限稳定拆为两个批次。"
	)
	for batch in _bamboo_visual_batches:
		_deliver_bamboo_visual_batch(client_coordinator, batch)
	for record in _hydrangea_visual_records:
		client_coordinator.receive_hydrangea_rain_visual(
			int(record.get("plant_net_id", 0)),
			int(record.get("action_id", 0)),
			record.get("target_position", Vector2.ZERO) as Vector2,
			float(record.get("host_action_time", 0.0)),
			50.0,
			true,
			0.0
		)
	for batch in _corn_visual_batches:
		_deliver_corn_visual_batch(client_coordinator, batch)
	_expect(
		client_bamboo.playback_records.size() == 25
		and client_hydrangea.playback_records.size() == 1
		and client_corn.playback_records.size() == 33
		and int(client_corn.playback_records[0].get("shot_count", 0)) == 6
		and int(client_corn.playback_records[1].get("shot_count", 0)) == 8,
		"客户端必须通过强类型植物索引播放视觉，并保留每轮玉米 burst 的6/8发快照。"
	)

	var owner := Node2D.new()
	var target := TestEnemy.new()
	host_adapter.selected_fixture_target = target
	var callback := Callable(self, "_noop_target_callback")
	var target_requested := host_coordinator.request_bamboo_mortar_target(
		owner,
		64.0,
		224.0,
		callback
	)
	host_coordinator.cancel_bamboo_mortar_target_request(owner)
	var selected_target := (
		host_coordinator.select_bamboo_mortar_target_sync_for_fixture(
			Vector2.ZERO,
			64.0,
			224.0
		)
	)
	var explosion_queued := host_coordinator.queue_bamboo_mortar_explosion(
		Vector2(7.0, 8.0),
		32.0,
		64.0,
		140,
		70,
		201
	)
	_expect(
		target_requested
		and host_adapter.target_request_records.size() == 1
		and host_adapter.canceled_target_owner == owner
		and selected_target == target
		and explosion_queued
		and int(
			host_coordinator.get_bamboo_mortar_combat_metrics().get(
				"queued_explosions",
				0
			)
		) == 1,
		"竹迫击炮目标、取消、同步选择、爆炸队列与指标必须完整委托适配器。"
	)

	var host_runtime := host.runtime as TestRuntime
	var host_enemy_coordinator := host.enemy_coordinator as MpEnemyCoordinator
	host_runtime.register_network_enemy(901, target)
	var single_damage_applied := (
		host_coordinator.apply_authoritative_plant_enemy_damage(
			201,
			target,
			10,
			Vector2.RIGHT,
			EnemyConfig.DamageType.PHYSICAL
		)
	)
	var batch_damage_applied := (
		host_coordinator.apply_authoritative_plant_enemy_damage_batch(
			201,
			target,
			PackedInt64Array([3, 4]),
			PackedInt32Array([2, 1]),
			Vector2.UP,
			EnemyConfig.DamageType.PHYSICAL
		)
	)
	var pending_feedback := (
		host_enemy_coordinator.pending_enemy_damage_feedback.get(901, {})
		as Dictionary
	)
	_expect(
		single_damage_applied
		and batch_damage_applied
		and target.received_requests.size() == 2
		and target.received_requests[1] is DamageBatchRequest
		and int(pending_feedback.get("damage", 0)) == 20
		and not host_enemy_coordinator.active_enemy_damage_feedback_context.has(901),
		"植物单次与批次伤害必须通过 EnemyCoordinator 聚合确认反馈并清理上下文。"
	)
	host_enemy_coordinator.pending_enemy_damage_feedback.clear()
	target.fixture_health = 1
	var overkill_damage_applied := (
		host_coordinator.apply_authoritative_plant_enemy_damage(
			201,
			target,
			10000,
			Vector2.RIGHT,
			EnemyConfig.DamageType.PHYSICAL
		)
	)
	var overkill_feedback := (
		host_enemy_coordinator.pending_enemy_damage_feedback.get(901, {})
		as Dictionary
	)
	_expect(
		overkill_damage_applied
		and target.last_fixture_result != null
		and target.last_fixture_result.resolved_damage == 10000
		and target.last_fixture_result.applied_damage == 1
		and int(overkill_feedback.get("damage", 0)) == 10000,
		"塔造成过量伤害时，联机反馈必须保留完整结算伤害而不是剩余生命值。"
	)

	host_coordinator.queue_bamboo_mortar_visual(
		201,
		99,
		0,
		Vector2.ZERO,
		Vector2.ONE,
		BambooMortar.WINDUP_DURATION_SECONDS,
		20.0
	)
	host_coordinator.reset_session_state()
	_expect(
		(
			host_coordinator.get("_pending_bamboo_mortar_visuals")
			as PackedInt32Array
		).is_empty()
		and (
			host_coordinator.get("_pending_corn_machine_gun_burst_visuals")
			as PackedInt32Array
		).is_empty(),
		"会话 reset 必须清空植物战斗网络聚合队列。"
	)
	host_runtime.unregister_network_enemy(901, target)
	session.remove_child(remote_projectile)
	remote_projectile.free()
	target.free()
	owner.free()
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
	var enemy_coordinator := (
		ENEMY_COORDINATOR_SCENE.instantiate() as MpEnemyCoordinator
	)
	var tower_economy := TestTowerEconomyCoordinator.new()
	var session_coordinator := TestSessionCoordinator.new()
	var runtime := TestRuntime.new()
	var adapter := TestTowerModeAdapter.new()
	var net_manager: NetManagerStore = (
		HostNetManager.new() if is_host else ClientNetManager.new()
	)
	var run_state := RunStateStore.new()
	var lifecycle_records: Array[String] = []
	root.add_child(coordinator)
	root.add_child(tower_economy)
	root.add_child(session_coordinator)
	tower_economy.lifecycle_records = lifecycle_records
	adapter.lifecycle_records = lifecycle_records
	adapter.bind_runtime(runtime)
	enemy_coordinator.bind_runtime(runtime)
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
		session_coordinator,
		runtime,
		adapter,
		net_manager,
		transactions,
		enemy_coordinator,
		tower_economy
	)
	return {
		"coordinator": coordinator,
		"transactions": transactions,
		"enemy_coordinator": enemy_coordinator,
		"tower_economy": tower_economy,
		"session_coordinator": session_coordinator,
		"lifecycle_records": lifecycle_records,
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
	var enemy_coordinator := fixture.enemy_coordinator as MpEnemyCoordinator
	var tower_economy := fixture.tower_economy as TestTowerEconomyCoordinator
	var session_coordinator := (
		fixture.session_coordinator as TestSessionCoordinator
	)
	var adapter := fixture.adapter as TestTowerModeAdapter
	coordinator.unbind_session(session)
	transactions.unbind_session(session)
	enemy_coordinator.unbind_runtime(fixture.runtime as TestRuntime)
	adapter.clear_plants()
	coordinator.free()
	tower_economy.free()
	session_coordinator.free()
	transactions.free()
	enemy_coordinator.free()
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


func _capture_plant_projectile_visual(
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> void:
	_plant_projectile_visual_records.append({
		"spawn_position": spawn_position,
		"direction": direction,
		"speed": speed,
		"explosion_radius": explosion_radius,
		"lifetime": lifetime,
	})


func _capture_bamboo_visual_batch(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	stages: PackedByteArray,
	spawn_positions: PackedVector2Array,
	landing_positions: PackedVector2Array,
	committed_windup_durations: PackedFloat32Array,
	host_action_times: PackedFloat64Array
) -> void:
	_bamboo_visual_batches.append({
		"plant_net_ids": plant_net_ids.duplicate(),
		"action_ids": action_ids.duplicate(),
		"stages": stages.duplicate(),
		"spawn_positions": spawn_positions.duplicate(),
		"landing_positions": landing_positions.duplicate(),
		"committed_windup_durations": committed_windup_durations.duplicate(),
		"host_action_times": host_action_times.duplicate(),
	})


func _capture_hydrangea_visual(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	host_action_time: float
) -> void:
	_hydrangea_visual_records.append({
		"plant_net_id": plant_net_id,
		"action_id": action_id,
		"target_position": target_position,
		"host_action_time": host_action_time,
	})


func _capture_corn_visual_batch(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	shot_counts: PackedByteArray,
	directions: PackedVector2Array,
	host_action_times: PackedFloat64Array
) -> void:
	_corn_visual_batches.append({
		"plant_net_ids": plant_net_ids.duplicate(),
		"action_ids": action_ids.duplicate(),
		"shot_counts": shot_counts.duplicate(),
		"directions": directions.duplicate(),
		"host_action_times": host_action_times.duplicate(),
	})


func _deliver_bamboo_visual_batch(
	coordinator: MpTowerWorldCoordinator,
	record: Dictionary
) -> void:
	coordinator.receive_bamboo_mortar_visual_batch(
		record.get("plant_net_ids", PackedInt32Array()) as PackedInt32Array,
		record.get("action_ids", PackedInt32Array()) as PackedInt32Array,
		record.get("stages", PackedByteArray()) as PackedByteArray,
		record.get("spawn_positions", PackedVector2Array()) as PackedVector2Array,
		record.get("landing_positions", PackedVector2Array()) as PackedVector2Array,
		record.get("committed_windup_durations", PackedFloat32Array()) as PackedFloat32Array,
		record.get("host_action_times", PackedFloat64Array()) as PackedFloat64Array,
		50.0,
		true,
		0.0
	)


func _deliver_corn_visual_batch(
	coordinator: MpTowerWorldCoordinator,
	record: Dictionary
) -> void:
	coordinator.receive_corn_machine_gun_burst_batch(
		record.get("plant_net_ids", PackedInt32Array()) as PackedInt32Array,
		record.get("action_ids", PackedInt32Array()) as PackedInt32Array,
		record.get("shot_counts", PackedByteArray()) as PackedByteArray,
		record.get("directions", PackedVector2Array()) as PackedVector2Array,
		record.get("host_action_times", PackedFloat64Array()) as PackedFloat64Array,
		50.0,
		true,
		0.0
	)


func _noop_target_callback(_target: Enemy) -> void:
	pass


func _capture_world_rpc_broadcast(
	method_name: StringName,
	args: Array
) -> void:
	if method_name != &"net_plant_spawned" or args.size() != 10:
		return
	_spawn_record = {
		"request_id": int(args[0]),
		"owner_peer_id": int(args[1]),
		"net_id": int(args[2]),
		"plant_id": StringName(args[3]),
		"anchor": args[4] as Vector2i,
		"current_health": int(args[5]),
		"maximum_health": int(args[6]),
		"health_revision": int(args[7]),
		"runtime_state": args[8] as Dictionary,
		"host_sample_time": float(args[9]),
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
	var first_line := source.substr(
		body_offset,
		line_end - body_offset
	).strip_edges()
	return first_line in [
		"var sender_id := multiplayer.get_remote_sender_id()",
		"var sender_id := _get_rpc_sender_id()",
	]


func _get_rpc_body(source: String, function_name: String) -> String:
	var function_offset := source.find("func %s" % function_name)
	if function_offset < 0:
		return ""
	var body_offset := source.find(") -> void:\n", function_offset)
	if body_offset < 0:
		return ""
	body_offset += ") -> void:\n".length()
	var body_end := source.find("\n\n@rpc(", body_offset)
	if body_end < 0:
		return source.substr(body_offset)
	return source.substr(body_offset, body_end - body_offset)


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
