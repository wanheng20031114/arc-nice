extends SceneTree

const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const PRESSURE_INSERT_COUNT := 10_000


class ClientNetManagerStub:
	extends Node

	func is_host() -> bool:
		return false

	func is_client() -> bool:
		return true

	func get_local_peer_id() -> int:
		return 2


class TestMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	func cache_pending_snapshot_pressure(
		first_net_id: int,
		insert_count: int,
		payload: Dictionary
	) -> void:
		for offset in range(insert_count):
			_cache_pending_warehouse_snapshot(
				first_net_id + offset,
				payload
			)


class RuntimeStub:
	extends GameRuntimeBase

	var plants: Dictionary = {}
	var removed_ids: Array[int] = []

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

	func apply_remote_flow_state(
		_step_id: StringName,
		_state: int,
		_seconds: int
	) -> void:
		pass

	func get_flow_state_snapshot() -> Dictionary:
		return {}

	func apply_remote_boss_started(
		_net_id: int,
		_boss_config: BossConfig,
		_spawn_position: Vector2
	) -> void:
		pass

	func apply_remote_defeat() -> void:
		pass

	func apply_remote_victory() -> void:
		pass

	func apply_remote_enemy_count(_alive_count: int) -> void:
		pass

	func apply_remote_merchant_active(_active: bool) -> void:
		pass

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass

	func try_purchase_skill1_for_peer(_peer_id: int) -> int:
		return 0

	func apply_skill1_purchase_state(
		_peer_id: int,
		_current_xirang: int,
		_skill1_unlocked: bool,
		_skill1_upgrade_level: int = -1,
		_skill1_charge_duration: float = -1.0
	) -> void:
		pass

	func show_local_skill1_purchase_result(_result_code: int) -> void:
		pass

	func try_refresh_luoxi_collectibles_for_peer(_peer_id: int) -> int:
		return 0

	func get_luoxi_collectible_refresh_count(_peer_id: int) -> int:
		return 0

	func try_claim_luoxi_collectible_for_peer(
		_peer_id: int,
		_config_path_or_choice: Variant
	) -> int:
		return 0

	func has_luoxi_collectible_claimed(_peer_id: int) -> bool:
		return false

	func record_luoxi_collectible_claim(_peer_id: int) -> void:
		pass

	func mark_luoxi_collectible_claimed(_peer_id: int) -> void:
		pass

	func show_local_luoxi_collectible_result(_result_code: int) -> void:
		pass

	func show_local_luoxi_refresh_result(
		_result_code: int,
		_refresh_count: int,
		_current_xirang: int
	) -> void:
		pass

	func show_debug_collectible_grant_result(
		_config_path: String,
		_success: bool
	) -> void:
		pass

	func supports_tower_defense() -> bool:
		return true

	func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
		var snapshots: Array[Dictionary] = []
		for net_id_variant in plants.keys():
			snapshots.append({"net_id": int(net_id_variant)})
		return snapshots

	func get_multiplayer_plant_node(net_id: int) -> PlantDefense:
		return plants.get(net_id) as PlantDefense

	func apply_remote_plant_removed(net_id: int) -> void:
		removed_ids.append(net_id)
		plants.erase(net_id)


var failures: Array[String] = []
var runtime := RuntimeStub.new()
var net_manager := ClientNetManagerStub.new()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_remove_then_snapshot_is_rejected()
	await _test_snapshot_before_spawn_is_consumed()
	_test_repeated_snapshot_replaces_in_place()
	_test_bounded_fifo_removal_and_wraparound()
	_test_session_cleanup_paths()
	_test_ten_thousand_insert_ab()

	if failures.is_empty():
		print("WAREHOUSE_PENDING_SNAPSHOT_LIFECYCLE_SMOKE_TEST_OK")
		runtime.free()
		net_manager.free()
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	runtime.free()
	net_manager.free()
	quit(1)


func _new_mp_game() -> TestMpGame:
	var mp_game := TestMpGame.new()
	mp_game.set("game", runtime)
	mp_game.set("net_manager", net_manager)
	return mp_game


func _test_remove_then_snapshot_is_rejected() -> void:
	var mp_game := _new_mp_game()
	mp_game.call("net_plant_removed", 101)
	mp_game.call(
		"_apply_warehouse_storage_snapshot",
		101,
		{"revision": 1}
	)
	_expect(
		(mp_game.get("_pending_warehouse_snapshots") as Dictionary).is_empty()
		and int(mp_game.get("_pending_warehouse_snapshot_oldest_id")) == 0
		and (mp_game.get("_removed_remote_plant_ids") as Dictionary).has(101),
		"remove→snapshot 乱序必须由 tombstone 拒绝，不能重新积累完整仓库载荷。"
	)
	mp_game.free()


func _test_snapshot_before_spawn_is_consumed() -> void:
	var mp_game := _new_mp_game()
	var warehouse_net_id := 102
	var snapshot := _make_valid_snapshot(warehouse_net_id, 7)
	mp_game.call(
		"_apply_warehouse_storage_snapshot",
		warehouse_net_id,
		snapshot
	)
	mp_game.call(
		"net_runtime_world_manifest",
		PackedInt32Array(),
		PackedInt32Array(),
		PackedInt32Array()
	)
	_expect(
		(mp_game.get("_pending_warehouse_snapshots") as Dictionary).has(
			warehouse_net_id
		)
		and not (mp_game.get("_removed_remote_plant_ids") as Dictionary).has(
			warehouse_net_id
		),
		"snapshot→旧 manifest→spawn 的合法跨通道乱序必须保留快照，且不得伪造 tombstone。"
	)

	var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	root.add_child(warehouse)
	await process_frame
	warehouse.set_meta("net_id", warehouse_net_id)
	runtime.plants[warehouse_net_id] = warehouse
	mp_game.call("_configure_warehouse_network", warehouse, false)
	_expect(
		warehouse.storage_revision == 7
		and warehouse.multiplayer_storage_snapshot_ready
		and (mp_game.get("_pending_warehouse_snapshots") as Dictionary).is_empty()
		and (
			mp_game.get("_pending_warehouse_snapshot_previous_ids")
			as Dictionary
		).is_empty()
		and (
			mp_game.get("_pending_warehouse_snapshot_next_ids")
			as Dictionary
		).is_empty()
		and int(mp_game.get("_pending_warehouse_snapshot_oldest_id")) == 0
		and int(mp_game.get("_pending_warehouse_snapshot_newest_id")) == 0,
		"仓库 spawn/configure 必须消费快照并同步 O(1) 摘除 FIFO 链接。"
	)
	runtime.plants.erase(warehouse_net_id)
	warehouse.free()
	mp_game.free()


func _test_repeated_snapshot_replaces_in_place() -> void:
	var mp_game := _new_mp_game()
	var first_snapshot := {"revision": 1, "payload": {"value": 10}}
	mp_game.call("_apply_warehouse_storage_snapshot", 103, first_snapshot)
	first_snapshot["payload"]["value"] = 99
	mp_game.call(
		"_apply_warehouse_storage_snapshot",
		103,
		{"revision": 2, "payload": {"value": 20}}
	)
	var pending := mp_game.get("_pending_warehouse_snapshots") as Dictionary
	var stored := pending.get(103, {}) as Dictionary
	_expect(
		pending.size() == 1
		and int(stored.get("revision", 0)) == 2
		and int((stored.get("payload", {}) as Dictionary).get("value", 0)) == 20
		and int(mp_game.get("_pending_warehouse_snapshot_oldest_id")) == 103
		and int(mp_game.get("_pending_warehouse_snapshot_newest_id")) == 103
		and (
			mp_game.get("_pending_warehouse_snapshot_previous_ids")
			as Dictionary
		).size() == 1
		and (
			mp_game.get("_pending_warehouse_snapshot_next_ids")
			as Dictionary
		).size() == 1,
		"同一 net id 更新必须深拷贝替换载荷，不能重复占用 FIFO 槽位。"
	)
	mp_game.free()


func _test_bounded_fifo_removal_and_wraparound() -> void:
	var mp_game := _new_mp_game()
	var limit := MP_GAME_SCRIPT.CLIENT_PENDING_WAREHOUSE_SNAPSHOT_MAX_ENTRIES
	for offset in range(limit):
		mp_game.call(
			"_cache_pending_warehouse_snapshot",
			1000 + offset,
			{"revision": offset}
		)
	mp_game.call("net_plant_removed", 1100)
	mp_game.call(
		"_cache_pending_warehouse_snapshot",
		1000 + limit,
		{"revision": limit}
	)
	var pending := mp_game.get("_pending_warehouse_snapshots") as Dictionary
	_expect(
		pending.size() == limit
		and not pending.has(1100)
		and pending.has(1000)
		and pending.has(1000 + limit),
		"移除队列中项后必须 O(1) 回收容量，下一项不能误淘汰仍有效的最老快照。"
	)
	mp_game.call(
		"_cache_pending_warehouse_snapshot",
		1001 + limit,
		{"revision": limit + 1}
	)
	_expect(
		not pending.has(1000)
		and int(mp_game.get("_pending_warehouse_snapshot_oldest_id")) == 1001,
		"满容量后必须严格 FIFO 淘汰最老快照。"
	)

	# Drive several complete capacity turnovers. A fixed linked FIFO has no
	# growing historical array: every insertion reuses the same bounded state.
	var wrap_start := 2000
	var wrap_count := limit * 3 + 17
	for offset in range(wrap_count):
		mp_game.call(
			"_cache_pending_warehouse_snapshot",
			wrap_start + offset,
			{"revision": offset}
		)
	var expected_oldest := wrap_start + wrap_count - limit
	var order := _collect_pending_order(mp_game)
	_expect(
		pending.size() == limit
		and order.size() == limit
		and order[0] == expected_oldest
		and order[-1] == wrap_start + wrap_count - 1
		and (
			mp_game.get("_pending_warehouse_snapshot_previous_ids")
			as Dictionary
		).size() == limit
		and (
			mp_game.get("_pending_warehouse_snapshot_next_ids")
			as Dictionary
		).size() == limit,
		"多轮环绕后 FIFO、载荷和双向链接都必须固定为 256 项且顺序连续。"
	)
	mp_game.free()


func _test_session_cleanup_paths() -> void:
	var lobby_mp_game := _new_mp_game()
	for net_id in range(300, 308):
		lobby_mp_game.call(
			"_cache_pending_warehouse_snapshot",
			net_id,
			{"revision": net_id}
		)
	lobby_mp_game.call("_clear_pending_warehouse_snapshots")
	var source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_game.gd"
	)
	var return_to_lobby_body := _get_function_body(
		source,
		"func _return_to_lobby()"
	)
	_expect(
		_is_pending_state_empty(lobby_mp_game)
		and return_to_lobby_body.contains(
			"_clear_pending_warehouse_snapshots()"
		),
		"返回大厅必须同时清空仓库快照载荷、链接和首尾游标。"
	)
	lobby_mp_game.free()

	var exit_mp_game := _new_mp_game()
	for net_id in range(400, 408):
		exit_mp_game.call(
			"_cache_pending_warehouse_snapshot",
			net_id,
			{"revision": net_id}
		)
	exit_mp_game.set("game", null)
	exit_mp_game.set("net_manager", null)
	exit_mp_game.call("_exit_tree")
	var exit_tree_body := _get_function_body(source, "func _exit_tree()")
	_expect(
		_is_pending_state_empty(exit_mp_game)
		and exit_tree_body.contains(
			"_clear_pending_warehouse_snapshots()"
		),
		"异常场景退出也必须清空仓库快照载荷、链接和首尾游标。"
	)
	exit_mp_game.free()


func _test_ten_thousand_insert_ab() -> void:
	var limit := MP_GAME_SCRIPT.CLIENT_PENDING_WAREHOUSE_SNAPSHOT_MAX_ENTRIES
	var unbounded_legacy: Dictionary = {}
	var payload := {"revision": 1}
	var unbounded_started_usec := Time.get_ticks_usec()
	for offset in range(PRESSURE_INSERT_COUNT):
		unbounded_legacy[10_000 + offset] = payload.duplicate(true)
	var unbounded_usec := Time.get_ticks_usec() - unbounded_started_usec

	var keys_fifo: Dictionary = {}
	var keys_array_elements_allocated := 0
	var keys_fifo_started_usec := Time.get_ticks_usec()
	for offset in range(PRESSURE_INSERT_COUNT):
		if keys_fifo.size() >= limit:
			var keys := keys_fifo.keys()
			keys_array_elements_allocated += keys.size()
			keys_fifo.erase(keys[0])
		keys_fifo[20_000 + offset] = payload.duplicate(true)
	var keys_fifo_usec := Time.get_ticks_usec() - keys_fifo_started_usec

	var linked_fifo_mp_game := _new_mp_game()
	var linked_fifo_started_usec := Time.get_ticks_usec()
	linked_fifo_mp_game.cache_pending_snapshot_pressure(
		30_000,
		PRESSURE_INSERT_COUNT,
		payload
	)
	var linked_fifo_usec := Time.get_ticks_usec() - linked_fifo_started_usec
	var linked_pending := (
		linked_fifo_mp_game.get("_pending_warehouse_snapshots") as Dictionary
	)
	var slot_count := OakWarehouse.STORAGE_CAPACITY
	print((
		"WAREHOUSE_PENDING_SNAPSHOT_AB inserts=%d unbounded_usec=%d "
		+ "keys_fifo_usec=%d linked_fifo_usec=%d retained=%d_to_%d "
		+ "full_slot_records=%d_to_%d keys_array_elements=%d"
	) % [
		PRESSURE_INSERT_COUNT,
		unbounded_usec,
		keys_fifo_usec,
		linked_fifo_usec,
		unbounded_legacy.size(),
		linked_pending.size(),
		unbounded_legacy.size() * slot_count,
		linked_pending.size() * slot_count,
		keys_array_elements_allocated
	])
	_expect(
		unbounded_legacy.size() == PRESSURE_INSERT_COUNT
		and linked_pending.size() == limit
		and keys_fifo.size() == limit
		and keys_array_elements_allocated
		== (PRESSURE_INSERT_COUNT - limit) * limit,
		"10k A/B 必须证明旧缓存保留 10k 载荷，而新 FIFO 只保留 256，且不产生 keys()[0] 数组工作量。"
	)
	var source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_game.gd"
	)
	var cache_body := _get_function_body(
		source,
		"func _cache_pending_warehouse_snapshot("
	)
	_expect(
		not cache_body.contains(".keys()")
		and not cache_body.contains("pop_front()")
		and not cache_body.contains("Array.erase"),
		"生产缓存入口不得退化为 keys()[0]、pop_front 或数组擦除。"
	)
	linked_fifo_mp_game.free()


func _make_valid_snapshot(warehouse_net_id: int, revision: int) -> Dictionary:
	var slots: Array[Dictionary] = []
	for slot_index in range(OakWarehouse.STORAGE_CAPACITY):
		slots.append({
			"slot_index": slot_index,
			"config_path": "",
			"stack_count": 0,
		})
	return {
		"warehouse_net_id": warehouse_net_id,
		"revision": revision,
		"slots": slots,
	}


func _collect_pending_order(mp_game: Node) -> Array[int]:
	var order: Array[int] = []
	var seen: Dictionary = {}
	var previous_id := 0
	var net_id := int(mp_game.get("_pending_warehouse_snapshot_oldest_id"))
	var previous_ids := (
		mp_game.get("_pending_warehouse_snapshot_previous_ids") as Dictionary
	)
	var next_ids := (
		mp_game.get("_pending_warehouse_snapshot_next_ids") as Dictionary
	)
	while net_id > 0 and not seen.has(net_id):
		seen[net_id] = true
		if int(previous_ids.get(net_id, -1)) != previous_id:
			failures.append("仓库 pending FIFO 的反向链接与正向遍历不一致。")
			break
		order.append(net_id)
		previous_id = net_id
		net_id = int(next_ids.get(net_id, 0))
	if net_id > 0:
		failures.append("仓库 pending FIFO 出现循环链接。")
	return order


func _is_pending_state_empty(mp_game: Node) -> bool:
	return (
		(mp_game.get("_pending_warehouse_snapshots") as Dictionary).is_empty()
		and (
			mp_game.get("_pending_warehouse_snapshot_previous_ids")
			as Dictionary
		).is_empty()
		and (
			mp_game.get("_pending_warehouse_snapshot_next_ids")
			as Dictionary
		).is_empty()
		and int(mp_game.get("_pending_warehouse_snapshot_oldest_id")) == 0
		and int(mp_game.get("_pending_warehouse_snapshot_newest_id")) == 0
	)


func _get_function_body(source: String, signature: String) -> String:
	var start := source.find(signature)
	if start < 0:
		return ""
	var end := source.find("\n\nfunc ", start + signature.length())
	if end < 0:
		end = source.length()
	return source.substr(start, end - start)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
