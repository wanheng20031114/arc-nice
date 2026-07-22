extends SceneTree

const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
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

	func cache_pending_state_pressure(
		first_net_id: int,
		insert_count: int,
		state: Dictionary
	) -> void:
		for offset in range(insert_count):
			_cache_pending_remote_production_state(
				first_net_id + offset,
				state,
				float(offset)
			)

	func _on_production_snapshot_requested(
		_building_net_id: int,
		building: ProductionBuilding
	) -> void:
		# Keep the actual net_plant_spawned path local to this smoke test: the
		# snapshot request itself is orthogonal to pending-state ordering.
		if building != null:
			building.set_multiplayer_production_snapshot_ready(true)


class RuntimeStub:
	extends GameRuntimeBase

	var plants: Dictionary = {}
	var removed_ids: Array[int] = []
	var silently_removed_ids: Array[int] = []

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

	func get_multiplayer_plant_node(net_id: int) -> PlantDefense:
		return plants.get(net_id) as PlantDefense

	func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
		var snapshots: Array[Dictionary] = []
		for net_id_variant in plants.keys():
			snapshots.append({"net_id": int(net_id_variant)})
		return snapshots

	func apply_remote_plant_spawn(
		_request_id: int,
		_owner_peer_id: int,
		_net_id: int,
		_plant_id: StringName,
		_anchor: Vector2i,
		_current_health: int,
		_maximum_health: int,
		_health_revision: int
	) -> void:
		# The test installs an initialized proxy before invoking net_plant_spawned
		# so its onready Timer and production signals match a real runtime spawn.
		pass

	func apply_remote_plant_removed(net_id: int) -> void:
		removed_ids.append(net_id)
		plants.erase(net_id)

	func apply_remote_plant_removed_silently(net_id: int) -> void:
		silently_removed_ids.append(net_id)
		plants.erase(net_id)


var failures: Array[String] = []
var runtime := RuntimeStub.new()
var net_manager := ClientNetManagerStub.new()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_remove_then_state_is_rejected()
	await _test_state_before_spawn_is_consumed()
	_test_revision_replacement_preserves_fifo_age()
	_test_bounded_fifo_removal_and_turnover()
	await _test_cross_channel_manifest_and_spawn_ordering()
	_test_session_cleanup_paths()
	_test_ten_thousand_insert_ab_and_source_guard()

	if failures.is_empty():
		print("PRODUCTION_PENDING_STATE_LIFECYCLE_SMOKE_TEST_OK")
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


func _test_remove_then_state_is_rejected() -> void:
	var mp_game := _new_mp_game()
	mp_game.call("net_plant_removed", 101)
	_send_state(mp_game, 101, 1, 1.0)
	_expect(
		_is_pending_state_empty(mp_game)
		and (mp_game.get("_removed_remote_plant_ids") as Dictionary).has(101),
		"remove→生产状态的乱序必须由 tombstone 拒绝，不能重新积累载荷。"
	)
	mp_game.free()


func _test_state_before_spawn_is_consumed() -> void:
	var mp_game := _new_mp_game()
	var building_net_id := 102
	var state := _make_state(7)
	_send_state_dictionary(mp_game, building_net_id, state, 2.5)
	state["enabled"] = false
	state["revision"] = 99
	var stored := (
		mp_game.get("_pending_remote_production_states") as Dictionary
	).get(building_net_id, {}) as Dictionary
	var stored_state := stored.get("state", {}) as Dictionary
	_expect(
		int(stored_state.get("revision", -1)) == 7
		and bool(stored_state.get("enabled", false)),
		"生产 pending 必须深拷贝 RPC 状态，不能持有调用方可变 Dictionary。"
	)

	var config := PlantDefenseRegistry.get_config(&"wood_processing_station")
	var building := (
		config.plant_scene.instantiate() as ProductionBuilding
		if config != null
		else null
	)
	_expect(building != null, "生产快照消费测试必须能实例化木头加工站。")
	if building == null or config == null:
		mp_game.free()
		return
	root.add_child(building)
	await process_frame
	building.setup(config, null, [Vector2i.ZERO], true)
	building.set_meta("net_id", building_net_id)
	runtime.plants[building_net_id] = building
	mp_game.call("_configure_production_network", building, false)
	_expect(
		building.production_revision == 7
		and building.production_enabled
		and _is_pending_state_empty(mp_game),
		"生产建筑 spawn/configure 必须应用 pending 最新 revision，并同步 O(1) 摘链。"
	)
	runtime.plants.erase(building_net_id)
	building.free()
	mp_game.free()


func _test_revision_replacement_preserves_fifo_age() -> void:
	var mp_game := _new_mp_game()
	_send_state(mp_game, 103, 1, 1.0)
	_send_state(mp_game, 104, 4, 2.0)
	_send_state(mp_game, 103, 3, 3.0)
	_send_state(mp_game, 103, 2, 9.0)
	var pending := mp_game.get("_pending_remote_production_states") as Dictionary
	var first_payload := pending.get(103, {}) as Dictionary
	var first_state := first_payload.get("state", {}) as Dictionary
	_expect(
		pending.size() == 2
		and int(first_state.get("revision", -1)) == 3
		and is_equal_approx(float(first_payload.get("host_sample_time", 0.0)), 3.0)
		and int(mp_game.get("_pending_remote_production_state_oldest_id")) == 103
		and int(mp_game.get("_pending_remote_production_state_newest_id")) == 104,
		"同 net id 的高 revision 必须原位替换且不变年轻；低 revision 必须被拒绝。"
	)
	_send_state(mp_game, 103, 3, 4.0)
	first_payload = pending.get(103, {}) as Dictionary
	var older_same_revision := _make_state(3)
	older_same_revision["enabled"] = false
	_send_state_dictionary(mp_game, 103, older_same_revision, 3.5)
	first_payload = pending.get(103, {}) as Dictionary
	first_state = first_payload.get("state", {}) as Dictionary
	_expect(
		is_equal_approx(float(first_payload.get("host_sample_time", 0.0)), 4.0)
		and bool(first_state.get("enabled", false))
		and int(mp_game.get("_pending_remote_production_state_oldest_id")) == 103,
		"同 revision 只允许 Host 时间前进；逆时间样本必须拒绝且不能改变 FIFO 顺序。"
	)
	mp_game.free()


func _test_bounded_fifo_removal_and_turnover() -> void:
	var mp_game := _new_mp_game()
	var limit := MP_GAME_SCRIPT.CLIENT_PENDING_PRODUCTION_STATE_MAX_ENTRIES
	for offset in range(limit):
		mp_game.call(
			"_cache_pending_remote_production_state",
			1000 + offset,
			_make_state(offset),
			float(offset)
		)
	mp_game.call("net_plant_removed", 1100)
	mp_game.call(
		"_cache_pending_remote_production_state",
		1000 + limit,
		_make_state(limit),
		float(limit)
	)
	var pending := mp_game.get("_pending_remote_production_states") as Dictionary
	_expect(
		pending.size() == limit
		and not pending.has(1100)
		and pending.has(1000)
		and pending.has(1000 + limit),
		"任意 remove 必须 O(1) 回收槽位，下一次插入不能误淘汰仍有效的最老状态。"
	)
	mp_game.call(
		"_cache_pending_remote_production_state",
		1001 + limit,
		_make_state(limit + 1),
		float(limit + 1)
	)
	_expect(
		not pending.has(1000)
		and int(mp_game.get("_pending_remote_production_state_oldest_id")) == 1001,
		"生产 pending 满容量后必须严格淘汰最老的未知建筑状态。"
	)

	var turnover_start := 2000
	var turnover_count := limit * 3 + 17
	for offset in range(turnover_count):
		mp_game.call(
			"_cache_pending_remote_production_state",
			turnover_start + offset,
			_make_state(offset),
			float(offset)
		)
	var order := _collect_pending_order(mp_game)
	var expected_oldest := turnover_start + turnover_count - limit
	_expect(
		pending.size() == limit
		and order.size() == limit
		and order[0] == expected_oldest
		and order[-1] == turnover_start + turnover_count - 1
		and (
			mp_game.get("_pending_remote_production_state_previous_ids")
			as Dictionary
		).size() == limit
		and (
			mp_game.get("_pending_remote_production_state_next_ids")
			as Dictionary
		).size() == limit,
		"多轮淘汰后载荷、双向链接与顺序必须仍固定为 256 项且无历史数组。"
	)
	mp_game.free()


func _test_cross_channel_manifest_and_spawn_ordering() -> void:
	var mp_game := _new_mp_game()
	var net_id := 5001
	var pending_state := _make_state(7)
	pending_state["enabled"] = false
	_send_state_dictionary(mp_game, net_id, pending_state, 20.0)
	mp_game.call(
		"net_runtime_world_manifest",
		PackedInt32Array(),
		PackedInt32Array(),
		PackedInt32Array()
	)
	_expect(
		(mp_game.get("_pending_remote_production_states") as Dictionary).has(net_id)
		and not (mp_game.get("_removed_remote_plant_ids") as Dictionary).has(net_id),
		"CH5 manifest 缺席不能删除 CH6 先到的未来状态，也不能伪造 tombstone。"
	)

	var config := PlantDefenseRegistry.get_config(&"wood_processing_station")
	var building := (
		config.plant_scene.instantiate() as ProductionBuilding
		if config != null
		else null
	)
	_expect(
		building != null,
		"跨通道 spawn 顺序测试必须能实例化木头加工站。"
	)
	if building == null or config == null:
		mp_game.free()
		return
	root.add_child(building)
	await process_frame
	building.setup(config, null, [Vector2i.ONE], true)
	building.set_meta("net_id", net_id)
	runtime.plants[net_id] = building
	var older_spawn_state := _make_state(7)
	older_spawn_state["enabled"] = true
	mp_game.call(
		"net_plant_spawned",
		0,
		1,
		net_id,
		"wood_processing_station",
		Vector2i.ONE,
		config.max_health,
		config.max_health,
		1,
		older_spawn_state,
		10.0
	)
	_expect(
		building.production_revision == 7
		and not building.production_enabled
		and is_equal_approx(
			float(building.get("_last_multiplayer_runtime_host_sample_time")),
			20.0
		)
		and _is_pending_state_empty(mp_game),
		"state→旧 manifest→spawn 的合法跨通道时序必须保留较新 pending，旧同 revision spawn 不得覆盖。"
	)

	var older_live_state := _make_state(7)
	older_live_state["enabled"] = true
	_send_state_dictionary(mp_game, net_id, older_live_state, 15.0)
	_expect(
		not building.production_enabled,
		"建筑已实例化后，同 revision 的逆时间 CH6 状态也不得覆盖较新样本。"
	)
	var newer_live_state := _make_state(7)
	newer_live_state["enabled"] = true
	_send_state_dictionary(mp_game, net_id, newer_live_state, 25.0)
	_expect(
		building.production_enabled
		and is_equal_approx(
			float(building.get("_last_multiplayer_runtime_host_sample_time")),
			25.0
		),
		"同 revision 的更晚 Host 样本必须继续应用，时间门不能冻结合法进度。"
	)
	var higher_revision_state := _make_state(8)
	higher_revision_state["enabled"] = false
	_send_state_dictionary(mp_game, net_id, higher_revision_state, 5.0)
	_expect(
		building.production_revision == 8
		and not building.production_enabled
		and is_equal_approx(
			float(building.get("_last_multiplayer_runtime_host_sample_time")),
			5.0
		),
		"更高 revision 必须优先于 Host 时间；跨 revision 时不得被旧时间门误拒绝。"
	)

	mp_game.call(
		"net_runtime_world_manifest",
		PackedInt32Array(),
		PackedInt32Array(),
		PackedInt32Array()
	)
	_expect(
		(mp_game.get("_removed_remote_plant_ids") as Dictionary).has(net_id)
		and runtime.silently_removed_ids.has(net_id),
		"manifest 仍必须 tombstone 并删除已经实例化、明确缺席的植物。"
	)
	runtime.plants.erase(net_id)
	building.free()
	mp_game.free()


func _test_session_cleanup_paths() -> void:
	var disconnect_mp_game := _new_mp_game()
	for net_id in range(600, 608):
		disconnect_mp_game.call(
			"_cache_pending_remote_production_state",
			net_id,
			_make_state(net_id),
			float(net_id)
		)
	disconnect_mp_game.call("_clear_pending_remote_production_states")
	_expect(
		_is_pending_state_empty(disconnect_mp_game),
		"会话清理辅助函数必须清空生产载荷、链接与首尾游标。"
	)
	disconnect_mp_game.free()

	var exit_mp_game := _new_mp_game()
	for net_id in range(700, 708):
		exit_mp_game.call(
			"_cache_pending_remote_production_state",
			net_id,
			_make_state(net_id),
			float(net_id)
		)
	exit_mp_game.set("game", null)
	exit_mp_game.set("net_manager", null)
	exit_mp_game.call("_exit_tree")
	_expect(
		_is_pending_state_empty(exit_mp_game),
		"异常场景退出必须清空生产 pending，而不能只依赖正常返回大厅。"
	)
	exit_mp_game.free()


func _test_ten_thousand_insert_ab_and_source_guard() -> void:
	var limit := MP_GAME_SCRIPT.CLIENT_PENDING_PRODUCTION_STATE_MAX_ENTRIES
	var state := _make_state(1)
	var unbounded_legacy: Dictionary = {}
	var unbounded_started_usec := Time.get_ticks_usec()
	for offset in range(PRESSURE_INSERT_COUNT):
		unbounded_legacy[10_000 + offset] = {
			"state": state.duplicate(true),
			"host_sample_time": float(offset),
		}
	var unbounded_usec := Time.get_ticks_usec() - unbounded_started_usec

	var keys_fifo: Dictionary = {}
	var keys_array_elements_allocated := 0
	var keys_fifo_started_usec := Time.get_ticks_usec()
	for offset in range(PRESSURE_INSERT_COUNT):
		var net_id := 20_000 + offset
		var previous := keys_fifo.get(net_id, {}) as Dictionary
		var previous_state := previous.get("state", {}) as Dictionary
		if int(state["revision"]) >= int(previous_state.get("revision", -1)):
			if not keys_fifo.has(net_id) and keys_fifo.size() >= limit:
				var keys := keys_fifo.keys()
				keys_array_elements_allocated += keys.size()
				keys_fifo.erase(keys[0])
			keys_fifo[net_id] = {
				"state": state.duplicate(true),
				"host_sample_time": float(offset),
			}
	var keys_fifo_usec := Time.get_ticks_usec() - keys_fifo_started_usec

	var linked_fifo_mp_game := _new_mp_game()
	var linked_fifo_started_usec := Time.get_ticks_usec()
	linked_fifo_mp_game.cache_pending_state_pressure(
		30_000,
		PRESSURE_INSERT_COUNT,
		state
	)
	var linked_fifo_usec := Time.get_ticks_usec() - linked_fifo_started_usec
	var linked_pending := (
		linked_fifo_mp_game.get("_pending_remote_production_states") as Dictionary
	)
	print((
		"PRODUCTION_PENDING_STATE_AB inserts=%d unbounded_usec=%d "
		+ "keys_fifo_usec=%d linked_fifo_usec=%d retained=%d_to_%d "
		+ "keys_array_elements=%d"
	) % [
		PRESSURE_INSERT_COUNT,
		unbounded_usec,
		keys_fifo_usec,
		linked_fifo_usec,
		unbounded_legacy.size(),
		linked_pending.size(),
		keys_array_elements_allocated,
	])
	_expect(
		unbounded_legacy.size() == PRESSURE_INSERT_COUNT
		and linked_pending.size() == limit
		and keys_fifo.size() == limit
		and keys_array_elements_allocated
		== (PRESSURE_INSERT_COUNT - limit) * limit,
		"10k A/B 必须证明新 FIFO 只保留 256 项，且消除 keys()[0] 的临时数组工作量。"
	)

	var source := FileAccess.get_file_as_string("res://scene/multiplayer/mp_game.gd")
	var cache_body := _get_function_body(
		source,
		"func _cache_pending_remote_production_state("
	)
	var configure_body := _get_function_body(
		source,
		"func _configure_production_network("
	)
	var return_body := _get_function_body(source, "func _return_to_lobby()")
	var exit_body := _get_function_body(source, "func _exit_tree()")
	var connection_body := _get_function_body(
		source,
		"func _on_connection_state_changed("
	)
	_expect(
		not cache_body.contains(".keys()")
		and not cache_body.contains("pop_front()")
		and not cache_body.contains("Array.erase")
		and source.count("_pending_remote_production_states.erase(") == 1
		and configure_body.contains("_take_pending_remote_production_state")
		and connection_body.contains("_return_to_lobby()")
		and return_body.contains("_clear_pending_remote_production_states()")
		and exit_body.contains("_clear_pending_remote_production_states()"),
		"source guard：插入不得退化为数组 FIFO，且所有消费/清理必须经过同步元数据的辅助函数。"
	)
	linked_fifo_mp_game.free()


func _send_state(
	mp_game: Node,
	net_id: int,
	revision: int,
	host_sample_time: float
) -> void:
	_send_state_dictionary(
		mp_game,
		net_id,
		_make_state(revision),
		host_sample_time
	)


func _send_state_dictionary(
	mp_game: Node,
	net_id: int,
	state: Dictionary,
	host_sample_time: float
) -> void:
	mp_game.call(
		"net_production_state_batch",
		PackedInt32Array([net_id]),
		[state],
		PackedFloat64Array([host_sample_time])
	)


func _make_state(revision: int) -> Dictionary:
	return {
		"schema": ProductionBuilding.RUNTIME_STATE_SCHEMA,
		"enabled": true,
		"active_recipe_id": "",
		"progress_elapsed_seconds": 0.0,
		"wait_reason": "",
		"personal_output_peer_id": 0,
		"revision": revision,
		"projection_duration_seconds": 0.1,
	}


func _collect_pending_order(mp_game: Node) -> Array[int]:
	var order: Array[int] = []
	var seen: Dictionary = {}
	var previous_id := 0
	var net_id := int(mp_game.get("_pending_remote_production_state_oldest_id"))
	var previous_ids := (
		mp_game.get("_pending_remote_production_state_previous_ids") as Dictionary
	)
	var next_ids := (
		mp_game.get("_pending_remote_production_state_next_ids") as Dictionary
	)
	while net_id > 0 and not seen.has(net_id):
		seen[net_id] = true
		if int(previous_ids.get(net_id, -1)) != previous_id:
			failures.append("生产 pending FIFO 的反向链接与正向遍历不一致。")
			break
		order.append(net_id)
		previous_id = net_id
		net_id = int(next_ids.get(net_id, 0))
	if net_id > 0:
		failures.append("生产 pending FIFO 出现循环链接。")
	return order


func _is_pending_state_empty(mp_game: Node) -> bool:
	return (
		(mp_game.get("_pending_remote_production_states") as Dictionary).is_empty()
		and (
			mp_game.get("_pending_remote_production_state_previous_ids")
			as Dictionary
		).is_empty()
		and (
			mp_game.get("_pending_remote_production_state_next_ids")
			as Dictionary
		).is_empty()
		and int(mp_game.get("_pending_remote_production_state_oldest_id")) == 0
		and int(mp_game.get("_pending_remote_production_state_newest_id")) == 0
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
