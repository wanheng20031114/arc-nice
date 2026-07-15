extends SceneTree

const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const SNAPSHOT_MANAGER := preload("res://scene/multiplayer/snapshot_manager.gd")
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const PICKUP_SCENE := preload("res://scene/pickup.tscn")
const PICKUP_CONFIG := preload("res://resources/config/pickups/pickup_health.tres")
const HOE_CAT_SCENE := preload("res://scene/player/hoe_cat/player_hoe_cat.tscn")
const TIYI_SCENE := preload("res://scene/player/tiyi/player_tiyi.tscn")


class ClientNetManagerStub:
	extends Node

	func is_host() -> bool:
		return false

	func is_client() -> bool:
		return true

	func get_local_peer_id() -> int:
		return 2


class HostNetManagerStub:
	extends Node

	func is_host() -> bool:
		return true

	func is_client() -> bool:
		return false

	func get_local_peer_id() -> int:
		return 1


class TestRuntime:
	extends GameRuntimeBase

	var proxy_plants: Dictionary[int, PlantDefense] = {}
	var lookup_targets: Dictionary[int, Enemy] = {}
	var target_lookup_count: int = 0

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return peer_players.get(peer_id) as Player

	func get_enemy_for_net_id(net_id: int) -> Enemy:
		return lookup_targets.get(net_id) as Enemy

	func get_pickup_for_net_id(net_id: int) -> Pickup:
		return multiplayer_pickups.get(net_id) as Pickup

	func remove_multiplayer_player(peer_id: int) -> void:
		peer_players.erase(peer_id)

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func apply_remote_flow_state(_step_id: StringName, _state: int, _seconds: int) -> void:
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

	func show_debug_collectible_grant_result(_config_path: String, _success: bool) -> void:
		pass

	func apply_remote_plant_health(
		net_id: int,
		current_health: int,
		maximum_health: int,
		health_revision: int
	) -> void:
		var plant := proxy_plants.get(net_id) as PlantDefense
		if plant != null:
			plant.apply_remote_health(current_health, maximum_health, health_revision)

	func supports_tower_defense() -> bool:
		return true

	func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
		var snapshots: Array[Dictionary] = []
		for net_id_variant in proxy_plants.keys():
			var net_id := int(net_id_variant)
			var plant := proxy_plants.get(net_id) as PlantDefense
			if plant != null and is_instance_valid(plant):
				snapshots.append({"net_id": net_id})
		return snapshots

	func apply_remote_plant_removed(net_id: int) -> void:
		var plant := proxy_plants.get(net_id) as PlantDefense
		proxy_plants.erase(net_id)
		if plant != null and is_instance_valid(plant):
			plant.free()

	func get_combat_target_by_net_id(net_id: int) -> Enemy:
		target_lookup_count += 1
		return lookup_targets.get(net_id) as Enemy


var failures: Array[String] = []
var fixture: TestRuntime = null
var client_net_manager := ClientNetManagerStub.new()
var host_net_manager := HostNetManagerStub.new()
var mp_games: Array[Node] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = TestRuntime.new()
	fixture.name = "MultiplayerHighPressureFixture"
	fixture.runtime_mode = GameRuntimeBase.RuntimeMode.CLIENT_VIEW
	var enemy_container := Node2D.new()
	enemy_container.name = "EnemyContainer"
	fixture.add_child(enemy_container)
	var boss_container := Node2D.new()
	boss_container.name = "BossContainer"
	fixture.add_child(boss_container)
	var pathfinder_stub := Node.new()
	pathfinder_stub.name = "GridPathfinder"
	fixture.add_child(pathfinder_stub)
	root.add_child(fixture)
	current_scene = fixture
	await process_frame

	_test_adaptive_enemy_snapshot_cadence()
	_test_unordered_enemy_chunk_convergence()
	_test_missing_delta_then_keyframe_recovery()
	_test_runtime_world_manifest_prunes_stale_replicas()
	_test_enemy_interpolator_iteration_prunes_after_traversal()
	_test_plant_health_batch_revision_ordering()
	_test_warehouse_transaction_cache_scope()
	_test_corn_burst_packed_queue_pressure()
	await _test_hoe_prediction_confirmation_reconciliation()
	await _test_tiyi_direct_lookup_retry()
	await _test_combat_target_query_reuse()
	await _test_offscreen_proxy_visual_budget()
	await _finish()


func _new_mp_game(use_host: bool = false) -> Node:
	var mp_game := MP_GAME_SCRIPT.new()
	mp_game.set("game", fixture)
	mp_game.set("net_manager", host_net_manager if use_host else client_net_manager)
	mp_games.append(mp_game)
	return mp_game


func _test_combat_target_query_reuse() -> void:
	var near_enemy := ENEMY_SCENE.instantiate() as Enemy
	var boss_enemy := ENEMY_SCENE.instantiate() as Enemy
	var far_enemy := ENEMY_SCENE.instantiate() as Enemy
	fixture.get_node("EnemyContainer").add_child(near_enemy)
	fixture.get_node("BossContainer").add_child(boss_enemy)
	fixture.get_node("EnemyContainer").add_child(far_enemy)
	near_enemy.global_position = Vector2(10.0, 0.0)
	boss_enemy.global_position = Vector2(20.0, 0.0)
	far_enemy.global_position = Vector2(100.0, 0.0)
	fixture.runtime_mode = GameRuntimeBase.RuntimeMode.SINGLEPLAYER
	var singleplayer_reused_targets: Array[Enemy] = [far_enemy]
	fixture.query_combat_targets_into(
		Vector2.ZERO,
		50.0,
		singleplayer_reused_targets,
		0
	)
	_expect(
		singleplayer_reused_targets == [near_enemy, boss_enemy],
		"Base single-player queries must refill one array from Enemy and Boss containers in distance order."
	)
	fixture.runtime_mode = GameRuntimeBase.RuntimeMode.CLIENT_VIEW
	fixture.register_combat_target(901, near_enemy)
	fixture.register_combat_target(902, boss_enemy)
	fixture.register_combat_target(903, far_enemy)

	var host_mp_game := _new_mp_game(true)
	var host_reused_targets: Array[Enemy] = [far_enemy]
	host_mp_game.call(
		"query_combat_targets_into",
		Vector2.ZERO,
		50.0,
		host_reused_targets,
		0
	)
	var host_returned_targets := host_mp_game.call(
		"query_combat_targets",
		Vector2.ZERO,
		50.0,
		0
	) as Array[Enemy]
	_expect(
		host_reused_targets == [near_enemy, boss_enemy]
		and host_returned_targets == host_reused_targets,
		"MP host target queries must forward into caller-owned arrays with wrapper parity."
	)

	var client_mp_game := _new_mp_game()
	client_mp_game.set("_net_enemies", {901: near_enemy, 902: boss_enemy, 903: far_enemy})
	var client_reused_targets: Array[Enemy] = [far_enemy]
	client_mp_game.call(
		"query_combat_targets_into",
		Vector2.ZERO,
		50.0,
		client_reused_targets,
		0
	)
	var client_returned_targets := client_mp_game.call(
		"query_combat_targets",
		Vector2.ZERO,
		50.0,
		0
	) as Array[Enemy]
	_expect(
		client_reused_targets == [near_enemy, boss_enemy]
		and client_returned_targets == client_reused_targets,
		"MP client target queries must preserve wrapper parity while refilling the caller-owned array."
	)
	client_mp_game.call(
		"query_combat_targets_into",
		Vector2.ZERO,
		0.0,
		client_reused_targets,
		1
	)
	_expect(
		client_reused_targets == [near_enemy],
		"MP client queries must preserve non-positive radius and max_count semantics."
	)
	boss_enemy.is_dead = true
	client_mp_game.call(
		"query_combat_targets_into",
		Vector2.ZERO,
		50.0,
		client_reused_targets,
		0
	)
	_expect(
		client_reused_targets == [near_enemy],
		"MP client queries must exclude dead proxy targets."
	)

	client_mp_game.set("_net_enemies", {})
	fixture.unregister_combat_target(901)
	fixture.unregister_combat_target(902)
	fixture.unregister_combat_target(903)
	near_enemy.queue_free()
	boss_enemy.queue_free()
	far_enemy.queue_free()
	await process_frame


func _test_adaptive_enemy_snapshot_cadence() -> void:
	var mp_game := _new_mp_game()
	fixture.multiplayer_enemies_by_net_id.clear()
	for enemy_index in range(199):
		fixture.multiplayer_enemies_by_net_id[enemy_index + 1] = null
	_expect(
		int(mp_game.call("_get_enemy_snapshot_interval_frames")) == 2,
		"Below 200 enemies, the Host must retain the 30 Hz enemy cadence."
	)
	fixture.multiplayer_enemies_by_net_id[200] = null
	_expect(
		int(mp_game.call("_get_enemy_snapshot_interval_frames")) == 3,
		"At the 200-enemy threshold, the Host must reduce enemy snapshots to 20 Hz."
	)
	for enemy_index in range(200, 300):
		fixture.multiplayer_enemies_by_net_id[enemy_index + 1] = null
	_expect(
		int(mp_game.call("_get_enemy_snapshot_interval_frames")) == 3,
		"The 300-enemy pressure target must remain on the 20 Hz cadence."
	)
	fixture.multiplayer_enemies_by_net_id.clear()


func _test_enemy_interpolator_iteration_prunes_after_traversal() -> void:
	var mp_game := _new_mp_game()
	var stale_ids: Array = mp_game.get("_stale_enemy_interpolator_ids") as Array
	mp_game.enemy_interpolators[7001] = NetInterpolator.new()
	mp_game.call("_client_interpolate_entities")
	_expect(
		not mp_game.enemy_interpolators.has(7001),
		"Client interpolation must prune missing enemies after direct dictionary traversal."
	)
	_expect(
		is_same(stale_ids, mp_game.get("_stale_enemy_interpolator_ids")),
		"Client interpolation must reuse its stale-id buffer instead of allocating one each frame."
	)
	var source := FileAccess.get_file_as_string("res://scene/multiplayer/mp_game.gd")
	var function_start := source.find("func _client_interpolate_entities()")
	var function_end := source.find("\n\n@rpc", function_start)
	var function_source := source.substr(function_start, function_end - function_start)
	_expect(
		function_start >= 0
		and function_end > function_start
		and not function_source.contains("enemy_interpolators.keys()"),
		"Client enemy interpolation must not allocate a Dictionary keys array every render frame."
	)


func _test_warehouse_transaction_cache_scope() -> void:
	var mp_game := _new_mp_game()
	var warehouse_a_result := {"warehouse_net_id": 10, "request_id": 1, "success": true}
	var warehouse_b_result := {"warehouse_net_id": 11, "request_id": 1, "success": false}
	mp_game.call(
		"_cache_warehouse_transaction_result",
		2,
		10,
		1,
		warehouse_a_result
	)
	mp_game.call(
		"_cache_warehouse_transaction_result",
		2,
		11,
		1,
		warehouse_b_result
	)
	_expect(
		bool((mp_game.call(
			"_get_cached_warehouse_transaction_result",
			2,
			10,
			1
		) as Dictionary).get("success", false))
		and not bool((mp_game.call(
			"_get_cached_warehouse_transaction_result",
			2,
			11,
			1
		) as Dictionary).get("success", true)),
		"Warehouse idempotency cache keys must include warehouse_net_id as well as request_id."
	)


func _test_corn_burst_packed_queue_pressure() -> void:
	var mp_game := _new_mp_game(true)
	const RECORD_COUNT := 513
	for record_index in range(RECORD_COUNT):
		mp_game.call(
			"_append_corn_machine_gun_burst_visual",
			1000 + record_index,
			2000 + record_index,
			Vector2.RIGHT.rotated(float(record_index % 16) * 0.1),
			3.0 + float(record_index) * 0.01
		)
	var plant_ids: PackedInt32Array = mp_game.get(
		"_pending_corn_machine_gun_burst_visuals"
	)
	var action_ids: PackedInt32Array = mp_game.get(
		"_pending_corn_machine_gun_burst_action_ids"
	)
	var directions: PackedVector2Array = mp_game.get(
		"_pending_corn_machine_gun_burst_directions"
	)
	var host_times: PackedFloat64Array = mp_game.get(
		"_pending_corn_machine_gun_burst_host_times"
	)
	_expect(
		plant_ids.size() == RECORD_COUNT
		and action_ids.size() == RECORD_COUNT
		and directions.size() == RECORD_COUNT
		and host_times.size() == RECORD_COUNT,
		"Corn burst pressure queue must keep all four packed columns exactly parallel."
	)
	_expect(
		plant_ids[512] == 1512
		and action_ids[512] == 2512
		and directions[512].is_equal_approx(Vector2.RIGHT)
		and is_equal_approx(host_times[512], 8.12),
		"Corn burst pressure queue must preserve the final record without truncation or reordering."
	)
	# PackedArray.slice uses an exclusive end index and preserves the concrete
	# packed type. The production flush depends on both details for 32-record
	# packets and the one-record tail of this pressure fixture.
	var first_chunk: PackedInt32Array = plant_ids.slice(0, 32)
	var middle_chunk: PackedInt32Array = plant_ids.slice(32, 64)
	var tail_chunk: PackedInt32Array = plant_ids.slice(512, 513)
	var direction_tail: PackedVector2Array = directions.slice(512, 513)
	var time_tail: PackedFloat64Array = host_times.slice(512, 513)
	_expect(
		first_chunk.size() == 32
		and first_chunk[0] == 1000
		and first_chunk[31] == 1031
		and middle_chunk.size() == 32
		and middle_chunk[0] == 1032
		and middle_chunk[31] == 1063
		and tail_chunk.size() == 1
		and tail_chunk[0] == 1512
		and direction_tail.size() == 1
		and direction_tail[0].is_equal_approx(Vector2.RIGHT)
		and time_tail.size() == 1
		and is_equal_approx(time_tail[0], 8.12),
		"Corn burst packed slices must be end-exclusive, typed and retain the final tail record."
	)
	mp_game.call("_clear_corn_machine_gun_burst_visuals")
	_expect(
		(mp_game.get("_pending_corn_machine_gun_burst_visuals") as PackedInt32Array).is_empty()
		and (mp_game.get("_pending_corn_machine_gun_burst_action_ids") as PackedInt32Array).is_empty()
		and (mp_game.get("_pending_corn_machine_gun_burst_directions") as PackedVector2Array).is_empty()
		and (mp_game.get("_pending_corn_machine_gun_burst_host_times") as PackedFloat64Array).is_empty(),
		"Corn burst queue cleanup must release every packed column together."
	)
	var source := FileAccess.get_file_as_string("res://scene/multiplayer/mp_game.gd")
	_expect(
		not source.contains(
			"var _pending_corn_machine_gun_burst_visuals: Array[Dictionary]"
		),
		"Corn burst batching must not regress to one Dictionary allocation per tower action."
	)


func _test_unordered_enemy_chunk_convergence() -> void:
	var mp_game := _new_mp_game()
	var sender := SNAPSHOT_MANAGER.new()
	var states := _make_enemy_states(70, 1)
	var chunk_zero := sender.encode_enemy_snapshot_range_for_peer(2, states, 0, 56, true)
	var chunk_one := sender.encode_enemy_snapshot_range_for_peer(2, states, 56, 14, true)

	# Channel 3 is unordered: the tail may arrive before the head.
	mp_game.call("_rpc_receive_enemy_snapshot", 1.0, chunk_one, 10, 1, 2, 20)
	_expect(
		(mp_game.get("_pending_enemy_snapshot_batches") as Dictionary).has(10),
		"An out-of-order first chunk must remain pending instead of reconciling a partial roster."
	)
	mp_game.call("_rpc_receive_enemy_snapshot", 1.0, chunk_zero, 10, 0, 2, 20)
	_expect(
		int(mp_game.get("_last_completed_enemy_snapshot_batch_id")) == 10,
		"Both unordered chunks must converge into one completed batch."
	)
	_expect(
		(mp_game.get("enemy_interpolators") as Dictionary).size() == 70,
		"A completed unordered batch must apply all seventy enemy states exactly once."
	)
	_expect(
		int(mp_game.get("_current_enemy_snapshot_hz")) == 20,
		"The client interpolator cadence must follow the Host's adaptive 20 Hz hint."
	)

	# A permanently incomplete batch must be bounded and evicted once the stream advances.
	mp_game.call("_rpc_receive_enemy_snapshot", 2.0, chunk_zero, 11, 0, 2, 20)
	var one_state := _make_enemy_states(1, 500)
	var repair_keyframe := sender.encode_enemy_snapshots_for_peer(2, one_state, true)
	mp_game.call("_rpc_receive_enemy_snapshot", 2.1, repair_keyframe, 14, 0, 1, 20)
	_expect(
		not (mp_game.get("_pending_enemy_snapshot_batches") as Dictionary).has(11)
		and int(mp_game.get("_enemy_snapshot_incomplete_batch_evict_count")) >= 1,
		"A missing-chunk batch must be evicted after the bounded reorder window."
	)
	var stale_before := int(mp_game.get("_enemy_snapshot_stale_chunk_count"))
	mp_game.call("_rpc_receive_enemy_snapshot", 2.2, repair_keyframe, 13, 0, 1, 20)
	_expect(
		int(mp_game.get("_enemy_snapshot_stale_chunk_count")) == stale_before + 1,
		"A chunk older than the completed batch must be ignored and counted as stale."
	)


func _test_missing_delta_then_keyframe_recovery() -> void:
	var mp_game := _new_mp_game()
	var sender := SNAPSHOT_MANAGER.new()
	var states := _make_enemy_states(1, 900)
	# Seed only the sender baseline. The client intentionally never sees this frame.
	sender.encode_enemy_snapshots_for_peer(7, states, true)
	states[0].position += Vector2(4.0, -2.0)
	var undecodable_delta := sender.encode_enemy_snapshots_for_peer(7, states, false)
	mp_game.call("_rpc_receive_enemy_snapshot", 3.0, undecodable_delta, 20, 0, 1, 20)
	_expect(
		int(mp_game.get("_last_completed_enemy_snapshot_batch_id")) == 0
		and (mp_game.get("enemy_interpolators") as Dictionary).is_empty(),
		"A delta with no receive baseline must not complete or create a corrupted proxy."
	)

	var keyframe := sender.encode_enemy_snapshots_for_peer(7, states, true)
	mp_game.call("_rpc_receive_enemy_snapshot", 3.1, keyframe, 21, 0, 1, 20)
	_expect(
		int(mp_game.get("_last_completed_enemy_snapshot_batch_id")) == 21
		and (mp_game.get("enemy_interpolators") as Dictionary).has(900),
		"The next keyframe must self-heal a lost baseline and converge the enemy proxy."
	)
	_expect(
		(mp_game.get("_pending_enemy_snapshot_batches") as Dictionary).is_empty(),
		"Keyframe repair must discard the older incomplete delta batch."
	)


func _test_runtime_world_manifest_prunes_stale_replicas() -> void:
	var mp_game := _new_mp_game()
	var live_enemy := ENEMY_SCENE.instantiate() as Enemy
	var stale_enemy := ENEMY_SCENE.instantiate() as Enemy
	fixture.add_child(live_enemy)
	fixture.add_child(stale_enemy)
	live_enemy.process_mode = Node.PROCESS_MODE_DISABLED
	stale_enemy.process_mode = Node.PROCESS_MODE_DISABLED
	mp_game.set("_net_enemies", {1: live_enemy, 2: stale_enemy})
	fixture.multiplayer_enemies_by_net_id = {1: live_enemy, 2: stale_enemy}

	var live_pickup := PICKUP_SCENE.instantiate() as Pickup
	var stale_pickup := PICKUP_SCENE.instantiate() as Pickup
	live_pickup.config = PICKUP_CONFIG
	stale_pickup.config = PICKUP_CONFIG
	fixture.add_child(live_pickup)
	fixture.add_child(stale_pickup)
	fixture.multiplayer_pickups = {10: live_pickup, 11: stale_pickup}
	var live_plant := PlantDefense.new()
	var stale_plant := PlantDefense.new()
	fixture.proxy_plants = {20: live_plant, 21: stale_plant}
	mp_game.set("_pending_warehouse_snapshots", {20: {"revision": 1}, 21: {"revision": 1}})
	mp_game.call(
		"net_runtime_world_manifest",
		PackedInt32Array([1]),
		PackedInt32Array([10]),
		PackedInt32Array([20])
	)
	_expect(
		(mp_game.get("_net_enemies") as Dictionary).has(1)
		and not (mp_game.get("_net_enemies") as Dictionary).has(2),
		"A complete-state manifest must silently prune a leaked enemy replica."
	)
	_expect(
		fixture.multiplayer_pickups.has(10) and not fixture.multiplayer_pickups.has(11),
		"A complete-state manifest must prune a pickup whose reliable removal was missed."
	)
	_expect(
		fixture.proxy_plants.has(20)
		and not fixture.proxy_plants.has(21)
		and (mp_game.get("_pending_warehouse_snapshots") as Dictionary).has(20)
		and not (mp_game.get("_pending_warehouse_snapshots") as Dictionary).has(21),
		"A complete-state manifest must prune stale plants and their queued warehouse snapshots."
	)
	mp_game.set("_net_enemies", {})
	fixture.multiplayer_enemies_by_net_id.clear()
	fixture.multiplayer_pickups.clear()
	fixture.proxy_plants.clear()
	live_enemy.queue_free()
	live_pickup.queue_free()
	live_plant.free()


func _test_plant_health_batch_revision_ordering() -> void:
	var mp_game := _new_mp_game()
	var plant := PlantDefense.new()
	plant.configure_multiplayer_proxy(100, 100, 3)
	fixture.proxy_plants[42] = plant
	mp_game.call(
		"net_plant_health_batch",
		PackedInt32Array([42, 42, 42]),
		PackedInt32Array([80, 15, 60]),
		PackedInt32Array([100, 100, 100]),
		PackedInt32Array([5, 4, 6])
	)
	_expect(
		plant.health_revision == 6 and plant.current_health == 60,
		"Plant health batching must ignore a reordered stale revision and apply the newest record."
	)
	fixture.proxy_plants.clear()
	plant.free()


func _test_hoe_prediction_confirmation_reconciliation() -> void:
	var player := HOE_CAT_SCENE.instantiate() as PlayerHoeCat
	fixture.add_child(player)
	await process_frame
	player.skill1_charge_duration = 4.0
	player.skill1_charge = 4.0

	player.play_predicted_hoe_action(&"primary", Vector2.RIGHT, 10)
	_expect(
		float(player.get("_primary_visual_time_left")) > 0.0
		and player.basic_slash_effect.visible,
		"Hoe Cat must immediately predict the primary visual without predicting damage."
	)
	player.reconcile_predicted_hoe_action(9, false, &"primary", 0.0, 1.0)
	_expect(
		float(player.get("_primary_visual_time_left")) > 0.0
		and is_equal_approx(player.skill1_charge, 4.0),
		"An older Hoe confirmation must not roll back a newer predicted action."
	)
	player.reconcile_predicted_hoe_action(10, false, &"primary", 0.25, 1.5)
	_expect(
		is_zero_approx(float(player.get("_primary_visual_time_left")))
		and not player.basic_slash_effect.visible
		and is_equal_approx(player.skill1_charge, 1.5),
		"A rejected primary prediction must cancel its visual and restore authoritative charge."
	)

	player.play_predicted_hoe_action(&"whirlwind", Vector2.ZERO, 11)
	player.reconcile_predicted_hoe_action(11, true, &"whirlwind", 1.0, 0.75)
	_expect(
		float(player.get("_whirlwind_visual_time_left")) > 0.0
		and is_equal_approx(player.skill1_charge, 0.75),
		"An accepted whirlwind must retain prediction while reconciling authoritative resources."
	)
	player.play_predicted_hoe_action(&"whirlwind", Vector2.ZERO, 12)
	player.reconcile_predicted_hoe_action(12, false, &"whirlwind", 1.0, 2.0)
	_expect(
		is_zero_approx(float(player.get("_whirlwind_visual_time_left")))
		and is_equal_approx(player.skill1_charge, 2.0),
		"A rejected whirlwind must terminate the predicted visual and refund authority state."
	)
	player.queue_free()
	await process_frame


func _test_tiyi_direct_lookup_retry() -> void:
	var player := TIYI_SCENE.instantiate() as PlayerTiyi
	fixture.add_child(player)
	await process_frame
	fixture.target_lookup_count = 0
	fixture.lookup_targets.erase(77)
	player.play_remote_high_noon_started(1)
	player.apply_remote_high_noon_targets(1, PackedInt32Array([77]))
	_expect(
		fixture.target_lookup_count == 1,
		"Tiyi must resolve remote targets through the O(1) net-id index, not a scene-tree scan."
	)
	_expect(
		float(player.get("_high_noon_remote_resolve_time_left")) > 0.0,
		"A target whose spawn RPC is late must schedule a bounded low-frequency retry."
	)

	var target := ENEMY_SCENE.instantiate() as Enemy
	fixture.add_child(target)
	target.process_mode = Node.PROCESS_MODE_DISABLED
	target.is_dead = false
	fixture.lookup_targets[77] = target
	player.call("_update_high_noon", 0.11)
	var locked_ids := player.get("_high_noon_locked_instance_ids") as Dictionary
	_expect(
		fixture.target_lookup_count == 2
		and locked_ids.has(target.get_instance_id()),
		"Tiyi's next bounded retry must resolve a proxy that spawned after the target batch."
	)
	player.cancel_remote_high_noon(1)
	fixture.lookup_targets.erase(77)
	player.queue_free()
	target.queue_free()
	await process_frame


func _test_offscreen_proxy_visual_budget() -> void:
	var mp_game := _new_mp_game()
	var camera := Camera2D.new()
	camera.name = "PressureCamera"
	camera.position = Vector2.ZERO
	camera.enabled = true
	fixture.add_child(camera)
	var near_enemy := ENEMY_SCENE.instantiate() as Enemy
	var far_enemy := ENEMY_SCENE.instantiate() as Enemy
	fixture.add_child(near_enemy)
	fixture.add_child(far_enemy)
	near_enemy.process_mode = Node.PROCESS_MODE_DISABLED
	far_enemy.process_mode = Node.PROCESS_MODE_DISABLED
	near_enemy.is_multiplayer_proxy = true
	far_enemy.is_multiplayer_proxy = true
	near_enemy.global_position = Vector2.ZERO
	far_enemy.global_position = Vector2(100000.0, 100000.0)
	mp_game.set("_net_enemies", {1: near_enemy, 2: far_enemy})
	await process_frame
	mp_game.call("_update_client_proxy_visual_budget", 1.0)
	_expect(
		near_enemy.multiplayer_proxy_visual_active
		and not far_enemy.multiplayer_proxy_visual_active
		and int(mp_game.get("_offscreen_enemy_proxy_count")) == 1,
		"The client visual budget must pause only the safely offscreen enemy proxy."
	)
	far_enemy.global_position = Vector2.ZERO
	mp_game.set("_client_proxy_visual_budget_time_left", 0.0)
	mp_game.call("_update_client_proxy_visual_budget", 0.0)
	_expect(
		far_enemy.multiplayer_proxy_visual_active
		and int(mp_game.get("_offscreen_enemy_proxy_count")) == 0,
		"A proxy re-entering the expanded camera rectangle must immediately restore visuals."
	)
	mp_game.set("_net_enemies", {})
	near_enemy.queue_free()
	far_enemy.queue_free()
	camera.queue_free()
	await process_frame


func _make_enemy_states(count: int, first_net_id: int) -> Array[SnapshotManager.EnemyState]:
	var states: Array[SnapshotManager.EnemyState] = []
	for enemy_index in range(count):
		var state := SnapshotManager.EnemyState.new()
		state.net_id = first_net_id + enemy_index
		state.position = Vector2(enemy_index * 3.0, enemy_index * -2.0)
		state.velocity = Vector2(1.0, -0.5)
		state.health = 100 + enemy_index
		state.visual_status_mask = enemy_index & 0x0f
		states.append(state)
	return states


func _finish() -> void:
	current_scene = null
	for mp_game in mp_games:
		if mp_game != null and is_instance_valid(mp_game):
			mp_game.free()
	mp_games.clear()
	client_net_manager.free()
	host_net_manager.free()
	if fixture != null:
		fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("MULTIPLAYER_HIGH_PRESSURE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
