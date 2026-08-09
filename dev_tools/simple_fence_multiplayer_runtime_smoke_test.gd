extends SceneTree

const TOWER_DEFENSE_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const SIMPLE_FENCE_CONFIG := preload(
	"res://resources/config/plant_defense/simple_fence.tres"
)
const BASIC_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")

const FIRST_FENCE_NET_ID := 82_100
const RETARGET_TIME_SENTINEL := 73.25
const RETARGET_SWEEP_SENTINEL := 11
const NONLETHAL_DAMAGE := 73
const CARDINAL_OFFSETS := [
	Vector2i.UP,
	Vector2i.RIGHT,
	Vector2i.DOWN,
	Vector2i.LEFT,
]
const CARDINAL_BITS := [1, 2, 4, 8]
const EXPECTED_ROSTER_KEYS := [
	"anchor",
	"current_health",
	"health_revision",
	"maximum_health",
	"net_id",
	"owner_peer_id",
	"plant_id",
]
const EXPECTED_SPAWN_RPC_ARGUMENTS := [
	"request_id",
	"owner_peer_id",
	"net_id",
	"plant_id",
	"anchor",
	"current_health",
	"maximum_health",
	"health_revision",
	"runtime_state",
	"host_sample_time",
]

var failures: Array[String] = []
var host_game: TowerDefenseGame = null
var client_fixtures: Array[Dictionary] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_expect(
		NET_CONSTANTS.PROTOCOL_VERSION == 48,
		"多人运行时协议v48必须保留既有wire类型、忍者加速与重连确认，并隔离精英机器人资源。"
	)
	host_game = TOWER_DEFENSE_SCENE.instantiate() as TowerDefenseGame
	_expect(host_game != null, "围栏多人运行时测试必须能实例化真实塔防场景。")
	if host_game == null:
		_finish()
		return
	host_game.auto_start_waves = false
	root.add_child(host_game)
	current_scene = host_game
	await process_frame
	await process_frame

	host_game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	host_game.plant_runtime_coordinator.next_multiplayer_plant_net_id = FIRST_FENCE_NET_ID
	var owner_peer_id := maxi(host_game.player.peer_id, 1)
	host_game.peer_players[owner_peer_id] = host_game.player
	var run_state := root.get_node("RunState") as RunStateStore
	var fence_item := BuildingItemRegistry.get_item(SIMPLE_FENCE_CONFIG.plant_id)
	run_state.ensure_multiplayer_peer_state(owner_peer_id)
	_expect(
		fence_item != null
		and run_state.try_add_item_count_for_peer(owner_peer_id, fence_item, 3),
		"围栏多人运行时夹具必须为权威玩家准备三件正式建筑物品。"
	)

	var connected_anchors := _find_connected_anchor_triple(
		host_game.plant_system.get_valid_anchors_for_player(
			SIMPLE_FENCE_CONFIG,
			host_game.player
		)
	)
	_expect(
		connected_anchors.size() == 3,
		"真实塔防地图必须能提供一个中心格带两个四向邻居的围栏放置夹具。"
	)
	if connected_anchors.size() != 3:
		await _cleanup()
		_finish()
		return

	var spawn_records: Array[Dictionary] = []
	var health_records: Array[Dictionary] = []
	var removal_records: Array[Dictionary] = []
	var host_tower_adapter := (
		host_game.get_multiplayer_mode_adapter()
		as TowerDefenseMultiplayerModeAdapter
	)
	_expect(host_tower_adapter != null, "真实塔防场景必须预置多人模式适配器。")
	if host_tower_adapter == null:
		await _cleanup()
		_finish()
		return
	host_tower_adapter.plant_spawned.connect(
		func(
			request_id: int,
			record_owner_peer_id: int,
			net_id: int,
			plant_id: StringName,
			anchor: Vector2i,
			current_health: int,
			maximum_health: int,
			health_revision: int
		) -> void:
			spawn_records.append({
				"request_id": request_id,
				"owner_peer_id": record_owner_peer_id,
				"net_id": net_id,
				"plant_id": plant_id,
				"anchor": anchor,
				"current_health": current_health,
				"maximum_health": maximum_health,
				"health_revision": health_revision,
			})
	)
	host_tower_adapter.plant_health_changed.connect(
		func(
			net_id: int,
			current_health: int,
			maximum_health: int,
			health_revision: int
		) -> void:
			health_records.append({
				"net_id": net_id,
				"current_health": current_health,
				"maximum_health": maximum_health,
				"health_revision": health_revision,
			})
	)
	host_tower_adapter.plant_removed.connect(
		func(net_id: int, was_destroyed: bool) -> void:
			removal_records.append({
				"net_id": net_id,
				"was_destroyed": was_destroyed,
			})
	)

	var enemy_index_count_before := int(
		host_game.plant_system.get_enemy_target_spatial_index_metrics().get(
			"registered_count",
			-1
		)
	)
	host_game.enemy_coordinator.enemy_retarget_time_left = RETARGET_TIME_SENTINEL
	host_game.enemy_coordinator.enemy_retarget_sweep_remaining = RETARGET_SWEEP_SENTINEL
	for placement_index in range(connected_anchors.size()):
		var slot_index := _find_peer_item_slot(
			run_state,
			owner_peer_id,
			fence_item
		)
		_expect(slot_index >= 0, "每次正式围栏放置前必须能解析建筑物品槽位。")
		if slot_index < 0:
			continue
		host_game.tower_multiplayer_mode_adapter.request_authoritative_inventory_plant_placement(
			owner_peer_id,
			placement_index + 1,
			SIMPLE_FENCE_CONFIG.plant_id,
			connected_anchors[placement_index],
			slot_index,
			run_state.get_inventory_revision_for_peer(owner_peer_id),
			fence_item.resource_path
		)
		_expect(
			host_game.enemy_coordinator.enemy_retarget_time_left == RETARGET_TIME_SENTINEL
			and host_game.enemy_coordinator.enemy_retarget_sweep_remaining
			== RETARGET_SWEEP_SENTINEL,
			"CONTACT_ONLY 围栏放置不得请求全敌重索敌或改写既有预算。"
		)

	_expect(
		spawn_records.size() == 3
		and run_state.get_inventory_item_total_for_peer(owner_peer_id, fence_item) == 0,
		"Host 正式多人库存入口必须生成三份围栏 spawn 并原子扣除三件物品。"
	)
	var enemy_index_count_after := int(
		host_game.plant_system.get_enemy_target_spatial_index_metrics().get(
			"registered_count",
			-1
		)
	)
	_expect(
		enemy_index_count_after == enemy_index_count_before,
		"CONTACT_ONLY 围栏不得增加敌人主动候选索引 membership。"
	)
	if spawn_records.size() != 3:
		await _cleanup()
		_finish()
		return

	var anchor_by_net_id: Dictionary[int, Vector2i] = {}
	var active_net_ids: Array[int] = []
	for spawn_record in spawn_records:
		var net_id := int(spawn_record["net_id"])
		anchor_by_net_id[net_id] = spawn_record["anchor"] as Vector2i
		active_net_ids.append(net_id)

	var live_client := _create_client_fixture("LiveClient", owner_peer_id)
	for spawn_record in spawn_records:
		_apply_spawn_record(live_client["runtime"] as TowerDefenseGame, spawn_record)
	_assert_topology(
		"实时 Client",
		host_game,
		live_client["runtime"] as TowerDefenseGame,
		active_net_ids,
		anchor_by_net_id
	)

	var center_net_id := int(spawn_records[1]["net_id"])
	var host_center := host_game.tower_multiplayer_mode_adapter.get_multiplayer_plant_node(
		center_net_id
	)
	_expect(host_center is CardinalConnectedPlant, "中心围栏必须是四向连接建筑实例。")
	if host_center == null:
		await _cleanup()
		_finish()
		return

	var health_before := host_center.current_health
	var revision_before := host_center.health_revision
	_expect(
		host_center.receive_damage(
			NONLETHAL_DAMAGE,
			null,
			Vector2.LEFT,
			EnemyConfig.DamageType.MAGIC
		),
		"Host 围栏必须接受权威非致命伤害。"
	)
	_expect(
		host_center.current_health == health_before - NONLETHAL_DAMAGE
		and host_center.health_revision == revision_before + 1
		and not health_records.is_empty(),
		"Host 围栏伤害必须推进一次血量 revision 并广播正式 health 事件。"
	)
	var damage_record: Dictionary = health_records.back()
	_apply_health_record(
		live_client["runtime"] as TowerDefenseGame,
		damage_record
	)
	var live_center := (
		live_client["runtime"] as TowerDefenseGame
	).tower_multiplayer_mode_adapter.get_multiplayer_plant_node(center_net_id)
	_expect(
		live_center != null
		and live_center.current_health == host_center.current_health
		and live_center.health_revision == host_center.health_revision,
		"实时 Client 必须按 Host revision 收敛围栏血量。"
	)

	var roster := host_game.tower_multiplayer_mode_adapter.get_multiplayer_plant_snapshots()
	_expect(roster.size() == 3, "Host 晚加入 roster 必须包含三份在场围栏。")
	for snapshot in roster:
		_expect_roster_has_no_texture_state(snapshot)
	var late_client := _create_client_fixture("LateClient", owner_peer_id)
	for snapshot_index in range(roster.size() - 1, -1, -1):
		var late_snapshot := roster[snapshot_index].duplicate(true)
		late_snapshot["request_id"] = 0
		_apply_spawn_record(
			late_client["runtime"] as TowerDefenseGame,
			late_snapshot
		)
	_assert_topology(
		"逆序晚加入 Client",
		host_game,
		late_client["runtime"] as TowerDefenseGame,
		active_net_ids,
		anchor_by_net_id
	)
	var late_center := (
		late_client["runtime"] as TowerDefenseGame
	).tower_multiplayer_mode_adapter.get_multiplayer_plant_node(center_net_id)
	_expect(
		late_center != null
		and late_center.current_health == host_center.current_health
		and late_center.health_revision == host_center.health_revision,
		"逆序晚加入 Client 必须直接获得 Host 当前围栏血量 revision。"
	)
	if late_center != null:
		var late_health_before_stale := late_center.current_health
		var late_revision_before_stale := late_center.health_revision
		(late_client["runtime"] as TowerDefenseGame).tower_multiplayer_mode_adapter.apply_remote_plant_health(
			center_net_id,
			late_center.max_health,
			late_center.max_health,
			maxi(late_center.health_revision - 1, 0)
		)
		_expect(
			late_center.current_health == late_health_before_stale
			and late_center.health_revision == late_revision_before_stale,
			"Client 必须拒绝旧 revision 围栏血量包。"
		)

	_assert_fence_runtime_state_has_no_texture_payload(host_center)
	_assert_spawn_rpc_schema_has_no_texture_payload()

	var scan_probe_enemy := BASIC_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(scan_probe_enemy != null, "全敌引用扫描隔离测试必须能实例化真实敌人。")
	if scan_probe_enemy != null:
		scan_probe_enemy.set_process(false)
		scan_probe_enemy.set_physics_process(false)
		host_game.enemy_container.add_child(scan_probe_enemy)
		scan_probe_enemy.setup(
			BASIC_ENEMY_CONFIG,
			host_game.player,
			host_game.grid_pathfinder
		)
		scan_probe_enemy.set_process(false)
		scan_probe_enemy.set_physics_process(false)
		host_game.call(
			"_assign_enemy_targets",
			scan_probe_enemy,
			host_center.global_position
		)
		_expect(
			not _is_any_fence_target(scan_probe_enemy.objective_target, active_net_ids),
			"敌人正式主动目标分配不得把任何围栏写入 objective_target。"
		)
		# Deliberately inject an impossible stale reference. If the contact-only
		# removal path regresses to the legacy global scan, it will clear this value.
		scan_probe_enemy.set_objective_target(host_center)

	host_game.enemy_coordinator.enemy_retarget_time_left = RETARGET_TIME_SENTINEL
	host_game.enemy_coordinator.enemy_retarget_sweep_remaining = RETARGET_SWEEP_SENTINEL
	var lethal_health_revision := host_center.health_revision
	_expect(
		host_center.receive_unmitigated_damage(
			host_center.current_health,
			scan_probe_enemy
		),
		"Host 必须能通过正式伤害生命周期摧毁中心围栏。"
	)
	_expect(
		host_game.enemy_coordinator.enemy_retarget_time_left == RETARGET_TIME_SENTINEL
		and host_game.enemy_coordinator.enemy_retarget_sweep_remaining
		== RETARGET_SWEEP_SENTINEL,
		"CONTACT_ONLY 围栏摧毁不得请求全敌重索敌或改写预算。"
	)
	_expect(
		scan_probe_enemy == null
		or scan_probe_enemy.objective_target == host_center,
		"CONTACT_ONLY 围栏移除不得执行旧式全敌 objective 引用扫描。"
	)
	_expect(
		host_center.is_dead
		and host_center.health_revision == lethal_health_revision + 1
		and host_game.tower_multiplayer_mode_adapter.get_multiplayer_plant_node(
			center_net_id
		) == null
		and not removal_records.is_empty()
		and int(removal_records.back().get("net_id", 0)) == center_net_id
		and bool(removal_records.back().get("was_destroyed", false)),
		"Host 致命伤害必须先推进 revision，再权威移除围栏并广播 destroyed。"
	)

	(live_client["runtime"] as TowerDefenseGame).tower_multiplayer_mode_adapter.apply_remote_plant_removed(
		center_net_id,
		true
	)
	(late_client["runtime"] as TowerDefenseGame).tower_multiplayer_mode_adapter.apply_remote_plant_removed(
		center_net_id,
		true
	)
	active_net_ids.erase(center_net_id)
	_assert_topology(
		"中心移除后的实时 Client",
		host_game,
		live_client["runtime"] as TowerDefenseGame,
		active_net_ids,
		anchor_by_net_id
	)
	_assert_topology(
		"中心移除后的晚加入 Client",
		host_game,
		late_client["runtime"] as TowerDefenseGame,
		active_net_ids,
		anchor_by_net_id
	)
	_expect(
		(live_client["runtime"] as TowerDefenseGame).tower_multiplayer_mode_adapter.get_multiplayer_plant_node(
			center_net_id
		) == null
		and (late_client["runtime"] as TowerDefenseGame).tower_multiplayer_mode_adapter.get_multiplayer_plant_node(
			center_net_id
		) == null,
		"两类 Client 都必须在可靠 remove 调用栈内释放中心围栏索引。"
	)

	if scan_probe_enemy != null:
		scan_probe_enemy.set_objective_target(null)
		scan_probe_enemy.queue_free()
	await _cleanup()
	_finish()


func _find_connected_anchor_triple(
	valid_anchors: Array[Vector2i]
) -> Array[Vector2i]:
	var valid_anchor_set: Dictionary[Vector2i, bool] = {}
	for anchor in valid_anchors:
		valid_anchor_set[anchor] = true
	for center in valid_anchors:
		var neighbors: Array[Vector2i] = []
		for offset in CARDINAL_OFFSETS:
			var neighbor: Vector2i = center + offset
			if valid_anchor_set.has(neighbor):
				neighbors.append(neighbor)
		if neighbors.size() >= 2:
			return [neighbors[0], center, neighbors[1]]
	return []


func _create_client_fixture(label: String, owner_peer_id: int) -> Dictionary:
	var plant_system := PlantSystem.new()
	plant_system.name = "%sPlantSystem" % label
	root.add_child(plant_system)
	var plant_container := Node2D.new()
	plant_container.name = "%sPlantContainer" % label
	root.add_child(plant_container)
	plant_system.setup(
		host_game.ground_tile_map_layer,
		host_game.player,
		plant_container,
		host_game.plant_system.placement_area
	)
	var runtime := TowerDefenseGame.new()
	runtime.name = "%sRuntime" % label
	_bind_tower_multiplayer_mode_adapter(runtime)
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	runtime.plant_system = plant_system
	runtime.peer_players = {owner_peer_id: host_game.player}
	var plant_runtime := TowerDefensePlantRuntimeCoordinator.new()
	plant_runtime.name = "PlantRuntimeCoordinator"
	runtime.add_child(plant_runtime)
	runtime.plant_runtime_coordinator = plant_runtime
	plant_runtime.setup(runtime.runtime_mode, null, null, plant_system, null)
	var fixture := {
		"runtime": runtime,
		"plant_system": plant_system,
		"plant_container": plant_container,
	}
	client_fixtures.append(fixture)
	return fixture


func _bind_tower_multiplayer_mode_adapter(
	runtime: TowerDefenseGame
) -> TowerDefenseMultiplayerModeAdapter:
	var adapter := TowerDefenseMultiplayerModeAdapter.new()
	adapter.name = "MultiplayerModeAdapter"
	runtime.add_child(adapter)
	adapter.bind_runtime(runtime)
	runtime.multiplayer_mode_adapter = adapter
	runtime.tower_multiplayer_mode_adapter = adapter
	return adapter


func _apply_spawn_record(
	runtime: TowerDefenseGame,
	record: Dictionary
) -> void:
	runtime.tower_multiplayer_mode_adapter.apply_remote_plant_spawn(
		int(record.get("request_id", 0)),
		int(record.get("owner_peer_id", 0)),
		int(record.get("net_id", 0)),
		StringName(record.get("plant_id", &"")),
		record.get("anchor", Vector2i.ZERO) as Vector2i,
		int(record.get("current_health", 0)),
		int(record.get("maximum_health", 1)),
		int(record.get("health_revision", 0))
	)


func _apply_health_record(
	runtime: TowerDefenseGame,
	record: Dictionary
) -> void:
	runtime.tower_multiplayer_mode_adapter.apply_remote_plant_health(
		int(record.get("net_id", 0)),
		int(record.get("current_health", 0)),
		int(record.get("maximum_health", 1)),
		int(record.get("health_revision", 0))
	)


func _assert_topology(
	label: String,
	authority: TowerDefenseGame,
	replica: TowerDefenseGame,
	active_net_ids: Array[int],
	anchor_by_net_id: Dictionary[int, Vector2i]
) -> void:
	for net_id in active_net_ids:
		var host_plant := authority.tower_multiplayer_mode_adapter.get_multiplayer_plant_node(
			net_id
		)
		var client_plant := replica.tower_multiplayer_mode_adapter.get_multiplayer_plant_node(
			net_id
		)
		var expected_mask := _calculate_expected_mask(
			net_id,
			active_net_ids,
			anchor_by_net_id
		)
		_expect(
			host_plant is CardinalConnectedPlant
			and client_plant is CardinalConnectedPlant,
			"%s 的 net_id=%d 必须在 Host/Client 都是 CardinalConnectedPlant。"
			% [label, net_id]
		)
		if not host_plant is CardinalConnectedPlant or not client_plant is CardinalConnectedPlant:
			continue
		var host_mask := (
			host_plant as CardinalConnectedPlant
		).get_cardinal_connection_mask()
		var client_mask := (
			client_plant as CardinalConnectedPlant
		).get_cardinal_connection_mask()
		_expect(
			host_mask == expected_mask and client_mask == expected_mask,
			"%s 的 net_id=%d 连接 mask 必须仅由相同占格图推导为 %d（Host=%d, Client=%d）。"
			% [label, net_id, expected_mask, host_mask, client_mask]
		)


func _calculate_expected_mask(
	net_id: int,
	active_net_ids: Array[int],
	anchor_by_net_id: Dictionary[int, Vector2i]
) -> int:
	var occupied_anchors: Dictionary[Vector2i, bool] = {}
	for active_net_id in active_net_ids:
		occupied_anchors[anchor_by_net_id[active_net_id]] = true
	var anchor: Vector2i = anchor_by_net_id[net_id]
	var mask := 0
	for offset_index in range(CARDINAL_OFFSETS.size()):
		if occupied_anchors.has(anchor + CARDINAL_OFFSETS[offset_index]):
			mask |= CARDINAL_BITS[offset_index]
	return mask


func _expect_roster_has_no_texture_state(snapshot: Dictionary) -> void:
	var actual_keys: Array = snapshot.keys()
	actual_keys.sort()
	var expected_keys := EXPECTED_ROSTER_KEYS.duplicate()
	expected_keys.sort()
	_expect(
		actual_keys == expected_keys,
		"围栏晚加入 roster 只能传身份/占格/血量字段，不得传 mask、frame 或贴图状态：%s"
		% [actual_keys]
	)


func _assert_fence_runtime_state_has_no_texture_payload(
	plant: PlantDefense
) -> void:
	var mp_game := MP_GAME_SCRIPT.new()
	var runtime_state := mp_game.call(
		"_export_plant_runtime_state",
		plant
	) as Dictionary
	var runtime_keys: Array = runtime_state.keys()
	runtime_keys.sort()
	_expect(
		runtime_keys == ["damage_status_mask", "damage_status_revision"],
		"围栏通用 runtime_state 只能携带伤害状态，不得复制连接 mask 或 Sprite frame：%s"
		% [runtime_keys]
	)
	mp_game.free()


func _assert_spawn_rpc_schema_has_no_texture_payload() -> void:
	var spawn_argument_names: Array[String] = []
	var mp_game := MP_GAME_SCRIPT.new()
	for method_info_variant in mp_game.get_method_list():
		var method_info := method_info_variant as Dictionary
		if StringName(method_info.get("name", &"")) != &"net_plant_spawned":
			continue
		for argument_variant in method_info.get("args", []) as Array:
			var argument := argument_variant as Dictionary
			spawn_argument_names.append(String(argument.get("name", &"")))
		break
	mp_game.free()
	_expect(
		spawn_argument_names == EXPECTED_SPAWN_RPC_ARGUMENTS,
		"net_plant_spawned 协议字段必须保持身份/占格/血量/通用状态，不得新增围栏贴图状态：%s"
		% [spawn_argument_names]
	)


func _is_any_fence_target(target: Node2D, net_ids: Array[int]) -> bool:
	if target == null:
		return false
	for net_id in net_ids:
		if host_game.tower_multiplayer_mode_adapter.get_multiplayer_plant_node(
			net_id
		) == target:
			return true
	return false


func _find_peer_item_slot(
	run_state: RunStateStore,
	peer_id: int,
	item: PickupConfig
) -> int:
	if run_state == null or peer_id <= 0 or item == null:
		return -1
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		if (
			run_state.get_item_count_for_peer(peer_id, slot_index) > 0
			and PickupConfig.inventory_identity_matches(
				run_state.get_item_for_peer(peer_id, slot_index),
				item
			)
		):
			return slot_index
	return -1


func _cleanup() -> void:
	for fixture in client_fixtures:
		var runtime := fixture.get("runtime") as TowerDefenseGame
		var plant_system := fixture.get("plant_system") as PlantSystem
		var plant_container := fixture.get("plant_container") as Node2D
		if runtime != null and is_instance_valid(runtime):
			runtime.free()
		if plant_system != null and is_instance_valid(plant_system):
			plant_system.clear_all_plants()
			plant_system.queue_free()
		if plant_container != null and is_instance_valid(plant_container):
			plant_container.queue_free()
	client_fixtures.clear()
	if host_game != null and is_instance_valid(host_game):
		if host_game.plant_system != null:
			host_game.plant_system.clear_all_plants()
		host_game.queue_free()
	await process_frame
	await process_frame
	host_game = null


func _finish() -> void:
	if failures.is_empty():
		print("SIMPLE_FENCE_MULTIPLAYER_RUNTIME_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
