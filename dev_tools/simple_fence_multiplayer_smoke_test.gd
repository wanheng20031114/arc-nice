extends SceneTree

const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")
const WOOD := preload("res://resources/config/materials/material_wood.tres")
const SIMPLE_FENCE_ITEM := preload(
	"res://resources/config/buildings/building_simple_fence.tres"
)
const REMOTE_PEER_ID := 2

var failures: Array[String] = []


class HostNetManagerStub:
	extends NetManagerStore

	func is_host() -> bool:
		return true

	func is_client() -> bool:
		return false

	func get_local_peer_id() -> int:
		return 1


class CapturingMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var simple_crafting_results: Array[Dictionary] = []
	var placement_rejections: Array[Dictionary] = []

	func _ready() -> void:
		pass

	func _exit_tree() -> void:
		pass

	func _send_simple_crafting_result(result: Dictionary) -> void:
		simple_crafting_results.append(result.duplicate(true))

	func _send_plant_placement_rejected(
		requester_peer_id: int,
		request_id: int,
		reason: StringName
	) -> void:
		placement_rejections.append({
			"peer_id": requester_peer_id,
			"request_id": request_id,
			"reason": reason,
		})


class PlacementCaptureRuntime:
	extends CombatRuntimeBase

	var inventory_placement_requests: Array[Dictionary] = []

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

	func request_multiplayer_inventory_plant_placement(
		requester_peer_id: int,
		request_id: int,
		plant_id: StringName,
		anchor: Vector2i,
		slot_index: int,
		expected_inventory_revision: int,
		item_config_path: String
	) -> void:
		inventory_placement_requests.append({
			"peer_id": requester_peer_id,
			"request_id": request_id,
			"plant_id": plant_id,
			"anchor": anchor,
			"slot_index": slot_index,
			"revision": expected_inventory_revision,
			"item_path": item_config_path,
		})


class PlacementCaptureTowerModeAdapter:
	extends TowerDefenseMultiplayerModeAdapter

	func get_authoritative_team_plant_count() -> int:
		return 0

	func get_completed_global_research_ids() -> Array[StringName]:
		return []

	func request_authoritative_inventory_plant_placement(
		requester_peer_id: int,
		request_id: int,
		plant_id: StringName,
		anchor: Vector2i,
		slot_index: int,
		expected_inventory_revision: int,
		item_config_path: String
	) -> void:
		var placement_runtime := runtime as PlacementCaptureRuntime
		if placement_runtime == null:
			return
		placement_runtime.request_multiplayer_inventory_plant_placement(
			requester_peer_id,
			request_id,
			plant_id,
			anchor,
			slot_index,
			expected_inventory_revision,
			item_config_path
		)


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_expect(
		NET_CONSTANTS.PROTOCOL_VERSION == 56,
		"协议v56必须保留狭路相逢波次资源合同、稀有宝箱私人快照、既有wire类型、忍者加速与重连确认，并隔离精英战斗机器人、精英枪手弹丸、消耗品、精英操作员无人机、精英盾兵、精英忍者资源及物资节点状态。"
	)
	var authoritative_snapshot := _test_host_authoritative_fence_crafting()
	_test_inventory_placement_replay_admission(authoritative_snapshot)

	if failures.is_empty():
		print("SIMPLE_FENCE_MULTIPLAYER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_host_authoritative_fence_crafting() -> Dictionary:
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	run_state.ensure_multiplayer_peer_state(REMOTE_PEER_ID)
	_expect(
		run_state.try_add_item_count_for_peer(REMOTE_PEER_ID, WOOD, 3),
		"Host围栏制造夹具必须能为远端Peer准备3份木头。"
	)
	var net_manager := HostNetManagerStub.new()
	var player := Player.new()
	var runtime := PlacementCaptureRuntime.new()
	var tower_adapter := _bind_tower_multiplayer_mode_adapter(runtime)
	runtime.peer_players = {REMOTE_PEER_ID: player}
	var mp_game := CapturingMpGame.new()
	mp_game.net_manager = net_manager
	mp_game.run_state = run_state
	mp_game.game = runtime
	mp_game._mode_adapter = tower_adapter
	mp_game.tower_mode_adapter = tower_adapter
	tower_adapter.attach_multiplayer_session(mp_game)

	var first_revision := run_state.get_inventory_revision_for_peer(
		REMOTE_PEER_ID
	)
	mp_game.call(
		"_apply_authoritative_simple_crafting_request",
		REMOTE_PEER_ID,
		41,
		String(SimpleCraftingRegistry.SIMPLE_FENCE_ID),
		first_revision
	)
	var committed_revision := run_state.get_inventory_revision_for_peer(
		REMOTE_PEER_ID
	)
	var success := _result_at(mp_game.simple_crafting_results, 0)
	_expect(
		str(success.get("recipe_id", "")) == "simple_fence"
		and str(success.get("result", ""))
		== String(RunStateStore.CRAFT_RESULT_SUCCESS)
		and committed_revision == first_revision + 1
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			WOOD
		) == 2
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			SIMPLE_FENCE_ITEM
		) == 1,
		"Host必须原子扣除1木头、立即制造1围栏并只推进一次远端背包revision。"
	)

	mp_game.call(
		"_apply_authoritative_simple_crafting_request",
		REMOTE_PEER_ID,
		41,
		String(SimpleCraftingRegistry.SIMPLE_FENCE_ID),
		first_revision
	)
	var replay := _result_at(mp_game.simple_crafting_results, 1)
	_expect(
		run_state.get_inventory_revision_for_peer(REMOTE_PEER_ID)
		== committed_revision
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			WOOD
		) == 2
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			SIMPLE_FENCE_ITEM
		) == 1
		and str(replay.get("result", ""))
		== String(RunStateStore.CRAFT_RESULT_SUCCESS),
		"重复围栏制造request_id必须仅重放Host结果，不能重复扣木头、产出或推进revision。"
	)

	mp_game.call(
		"_apply_authoritative_simple_crafting_request",
		REMOTE_PEER_ID,
		42,
		String(SimpleCraftingRegistry.SIMPLE_FENCE_ID),
		committed_revision
	)
	var second_revision := run_state.get_inventory_revision_for_peer(
		REMOTE_PEER_ID
	)
	var second_success := _result_at(mp_game.simple_crafting_results, 2)
	var authoritative_snapshot := (
		second_success.get("inventory_snapshot", {}) as Dictionary
	).duplicate(true)
	_expect(
		second_revision == committed_revision + 1
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			WOOD
		) == 1
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			SIMPLE_FENCE_ITEM
		) == 2
		and _snapshot_contains_exact_item_path(
			authoritative_snapshot,
			SIMPLE_FENCE_ITEM.resource_path,
			2
		),
		"第二次Host制造必须把围栏合并到同一规范资源路径的数量2堆栈。"
	)

	mp_game.call(
		"_apply_authoritative_simple_crafting_request",
		REMOTE_PEER_ID,
		43,
		String(SimpleCraftingRegistry.SIMPLE_FENCE_ID),
		committed_revision
	)
	var stale := _result_at(mp_game.simple_crafting_results, 3)
	_expect(
		str(stale.get("result", ""))
		== String(RunStateStore.CRAFT_RESULT_STALE_REVISION)
		and bool(stale.get("force_inventory_repair", false))
		and run_state.get_inventory_revision_for_peer(REMOTE_PEER_ID)
		== second_revision
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			SIMPLE_FENCE_ITEM
		) == 2,
		"新的围栏制造请求携带旧revision时必须原子拒绝并要求权威快照修复。"
	)

	mp_game.call(
		"_apply_authoritative_simple_crafting_request",
		REMOTE_PEER_ID,
		44,
		"res://resources/config/production/simple_simple_fence.tres",
		second_revision
	)
	var forged := _result_at(mp_game.simple_crafting_results, 4)
	_expect(
		str(forged.get("recipe_id", "")) == ""
		and str(forged.get("result", ""))
		== String(RunStateStore.CRAFT_RESULT_INVALID_RECIPE)
		and run_state.get_inventory_revision_for_peer(REMOTE_PEER_ID)
		== second_revision,
		"Host只能接受围栏配方wire id，伪造recipe资源路径必须在事务前拒绝。"
	)

	var round_trip := RunStateStore.new()
	round_trip.begin_new_run(&"weishidaier", false)
	_expect(
		round_trip.apply_inventory_snapshot_for_peer(
			REMOTE_PEER_ID,
			authoritative_snapshot
		)
		and round_trip.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			SIMPLE_FENCE_ITEM
		) == 2,
		"同协议客户端必须从Host快照按规范资源路径恢复围栏数量2堆栈。"
	)

	mp_game.free()
	net_manager.free()
	runtime.free()
	player.free()
	round_trip.free()
	run_state.free()
	return authoritative_snapshot


func _test_inventory_placement_replay_admission(
	authoritative_snapshot: Dictionary
) -> void:
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.apply_inventory_snapshot_for_peer(
			REMOTE_PEER_ID,
			authoritative_snapshot
		),
		"围栏放置重放夹具必须先应用Host数量2权威快照。"
	)
	var slot_index := _find_peer_item_slot(
		run_state,
		REMOTE_PEER_ID,
		SIMPLE_FENCE_ITEM
	)
	var revision := run_state.get_inventory_revision_for_peer(REMOTE_PEER_ID)
	var runtime := PlacementCaptureRuntime.new()
	var tower_adapter := _bind_tower_multiplayer_mode_adapter(runtime)
	var net_manager := HostNetManagerStub.new()
	var mp_game := CapturingMpGame.new()
	mp_game.net_manager = net_manager
	mp_game.run_state = run_state
	mp_game.game = runtime
	mp_game._mode_adapter = tower_adapter
	mp_game.tower_mode_adapter = tower_adapter
	tower_adapter.attach_multiplayer_session(mp_game)

	mp_game.call(
		"_handle_authoritative_inventory_plant_placement_request",
		REMOTE_PEER_ID,
		100,
		"simple_fence",
		Vector2i(3, 4),
		slot_index,
		revision,
		SIMPLE_FENCE_ITEM.resource_path
	)
	mp_game.call(
		"_handle_authoritative_inventory_plant_placement_request",
		REMOTE_PEER_ID,
		100,
		"simple_fence",
		Vector2i(3, 4),
		slot_index,
		revision,
		SIMPLE_FENCE_ITEM.resource_path
	)
	mp_game.call(
		"_handle_authoritative_inventory_plant_placement_request",
		REMOTE_PEER_ID,
		99,
		"simple_fence",
		Vector2i(4, 4),
		slot_index,
		revision,
		SIMPLE_FENCE_ITEM.resource_path
	)
	var forwarded := _result_at(runtime.inventory_placement_requests, 0)
	_expect(
		slot_index >= 0
		and runtime.inventory_placement_requests.size() == 1
		and int(forwarded.get("request_id", 0)) == 100
		and forwarded.get("plant_id") == &"simple_fence"
		and str(forwarded.get("item_path", ""))
		== SIMPLE_FENCE_ITEM.resource_path
		and mp_game.placement_rejections.size() == 2
		and mp_game.placement_rejections[0].get("reason") == &"stale_request"
		and mp_game.placement_rejections[1].get("reason") == &"stale_request"
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			SIMPLE_FENCE_ITEM
		) == 2
		and run_state.get_inventory_revision_for_peer(REMOTE_PEER_ID)
		== revision,
		"Host放置入口必须只转发严格递增request id；重复/倒退请求均拒绝且在游戏事务前不触碰围栏堆栈。"
	)

	mp_game.free()
	net_manager.free()
	runtime.free()
	run_state.free()


func _bind_tower_multiplayer_mode_adapter(
	runtime: PlacementCaptureRuntime
) -> TowerDefenseMultiplayerModeAdapter:
	var adapter := PlacementCaptureTowerModeAdapter.new()
	adapter.name = "MultiplayerModeAdapter"
	runtime.add_child(adapter)
	adapter.bind_runtime(runtime)
	runtime.multiplayer_mode_adapter = adapter
	return adapter


func _find_peer_item_slot(
	run_state: RunStateStore,
	peer_id: int,
	item: PickupConfig
) -> int:
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		if PickupConfig.inventory_identity_matches(
			run_state.get_item_for_peer(peer_id, slot_index),
			item
		):
			return slot_index
	return -1


func _snapshot_contains_exact_item_path(
	snapshot: Dictionary,
	item_config_path: String,
	stack_count: int
) -> bool:
	var slots := snapshot.get("slots", []) as Array
	for slot_value in slots:
		var slot := slot_value as Dictionary
		if str(slot.get("config_path", "")) != item_config_path:
			continue
		return int(slot.get("stack_count", 0)) == stack_count
	return false


func _result_at(results: Array[Dictionary], index: int) -> Dictionary:
	if index < 0 or index >= results.size():
		return {}
	return results[index]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
