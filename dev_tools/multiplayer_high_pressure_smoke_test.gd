extends SceneTree

const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const SNAPSHOT_MANAGER := preload("res://scene/multiplayer/snapshot_manager.gd")
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const PICKUP_SCENE := preload("res://scene/pickup.tscn")
const PICKUP_CONFIG := preload("res://resources/config/pickups/pickup_health.tres")
const HOE_CAT_SCENE := preload("res://scene/player/hoe_cat/player_hoe_cat.tscn")
const TIYI_SCENE := preload("res://scene/player/tiyi/player_tiyi.tscn")
const CAPOO_PROJECTILE_MOTION_SYSTEM_SCENE := preload(
	"res://scene/enemy/capoo/capoo_projectile_motion_system.tscn"
)
const DAY_NIGHT_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)


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


class CapturingMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var outbound_calls: Array[Dictionary] = []
	var production_command_result_send_count := 0
	var warehouse_command_result_send_count := 0
	var simple_crafting_result_send_count := 0
	var runtime_state_send_count := 0
	var plant_placement_rejection_send_count := 0
	var test_net_time := -1.0

	func _ready() -> void:
		pass

	func _exit_tree() -> void:
		pass

	func _rpc_to_connected_clients(method_name: StringName, args: Array = []) -> void:
		outbound_calls.append({
			"method_name": method_name,
			"args": args.duplicate(true),
		})

	func _send_production_command_result(
		_peer_id: int,
		_result: Dictionary
	) -> void:
		production_command_result_send_count += 1

	func _send_warehouse_command_result(
		_peer_id: int,
		_result: Dictionary
	) -> void:
		warehouse_command_result_send_count += 1

	func _send_simple_crafting_result(_result: Dictionary) -> void:
		simple_crafting_result_send_count += 1

	func _send_runtime_state_to_peer(
		_peer_id: int,
		_include_flow_state: bool
	) -> void:
		runtime_state_send_count += 1

	func _send_plant_placement_rejected(
		_requester_peer_id: int,
		_request_id: int,
		_reason: StringName
	) -> void:
		plant_placement_rejection_send_count += 1

	func _get_net_time() -> float:
		if test_net_time >= 0.0:
			return test_net_time
		return super._get_net_time()


class TestRuntime:
	extends CombatRuntimeBase

	var proxy_plants: Dictionary[int, PlantDefense] = {}
	var lookup_targets: Dictionary[int, Enemy] = {}
	var target_lookup_count: int = 0
	var animated_plant_removal_ids: Array[int] = []
	var destroyed_plant_removal_ids: Array[int] = []
	var silent_plant_removal_ids: Array[int] = []
	var damage_number_requests: Array[Dictionary] = []
	var transaction_player_lookup_count := 0
	var transaction_plant_lookup_count := 0
	var transaction_snapshot_query_count := 0

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		transaction_player_lookup_count += 1
		return peer_players.get(peer_id) as Player

	func get_enemy_for_net_id(net_id: int) -> Enemy:
		target_lookup_count += 1
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
		var plant := proxy_plants.get(net_id) as PlantDefense
		if plant == null or not is_instance_valid(plant):
			plant = PlantDefense.new()
			plant.configure_multiplayer_proxy(
				current_health,
				maximum_health,
				health_revision
			)
			proxy_plants[net_id] = plant
			return
		plant.apply_remote_health(current_health, maximum_health, health_revision)

	func get_multiplayer_plant_node(net_id: int) -> PlantDefense:
		transaction_plant_lookup_count += 1
		return proxy_plants.get(net_id) as PlantDefense

	func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
		transaction_snapshot_query_count += 1
		var snapshots: Array[Dictionary] = []
		for net_id_variant in proxy_plants.keys():
			var net_id := int(net_id_variant)
			var plant := proxy_plants.get(net_id) as PlantDefense
			if plant != null and is_instance_valid(plant):
				snapshots.append({"net_id": net_id})
		return snapshots

	func reset_transaction_lookup_counts() -> void:
		transaction_player_lookup_count = 0
		transaction_plant_lookup_count = 0
		transaction_snapshot_query_count = 0

	func apply_remote_plant_removed(net_id: int) -> void:
		animated_plant_removal_ids.append(net_id)
		_remove_proxy_plant(net_id)

	func apply_remote_plant_removed_with_reason(
		net_id: int,
		was_destroyed: bool
	) -> void:
		animated_plant_removal_ids.append(net_id)
		if was_destroyed:
			destroyed_plant_removal_ids.append(net_id)
		_remove_proxy_plant(net_id)

	func apply_remote_plant_removed_silently(net_id: int) -> void:
		silent_plant_removal_ids.append(net_id)
		_remove_proxy_plant(net_id)

	func _remove_proxy_plant(net_id: int) -> void:
		var plant := proxy_plants.get(net_id) as PlantDefense
		proxy_plants.erase(net_id)
		if plant != null and is_instance_valid(plant):
			plant.free()

	func get_combat_target_by_net_id(net_id: int) -> Enemy:
		return lookup_targets.get(net_id) as Enemy

	func show_combat_number(
		amount: int,
		spawn_position: Vector2,
		number_kind: DamageNumberPool.CombatNumberKind,
		motion_direction: Vector2 = Vector2.ZERO,
		damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
		display_priority: DamageNumberPool.DisplayPriority = DamageNumberPool.DisplayPriority.NORMAL
	) -> bool:
		damage_number_requests.append({
			"amount": amount,
			"spawn_position": spawn_position,
			"number_kind": number_kind,
			"impact_direction": motion_direction,
			"damage_type": damage_type,
			"display_priority": display_priority,
		})
		return true


class TestTowerModeAdapter:
	extends TowerDefenseMultiplayerModeAdapter

	func _test_runtime() -> TestRuntime:
		return runtime as TestRuntime

	func get_multiplayer_plant_node(net_id: int) -> PlantDefense:
		var test_runtime := _test_runtime()
		return (
			test_runtime.get_multiplayer_plant_node(net_id)
			if test_runtime != null
			else null
		)

	func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
		var test_runtime := _test_runtime()
		return (
			test_runtime.get_multiplayer_plant_snapshots()
			if test_runtime != null
			else []
		)

	func get_authoritative_team_plant_count() -> int:
		var test_runtime := _test_runtime()
		return test_runtime.proxy_plants.size() if test_runtime != null else -1

	func apply_remote_plant_health(
		net_id: int,
		current_health: int,
		maximum_health: int,
		health_revision: int
	) -> void:
		var test_runtime := _test_runtime()
		if test_runtime != null:
			test_runtime.apply_remote_plant_health(
				net_id,
				current_health,
				maximum_health,
				health_revision
			)

	func apply_remote_plant_spawn(
		request_id: int,
		owner_peer_id: int,
		net_id: int,
		plant_id: StringName,
		anchor: Vector2i,
		current_health: int,
		maximum_health: int,
		health_revision: int
	) -> void:
		var test_runtime := _test_runtime()
		if test_runtime != null:
			test_runtime.apply_remote_plant_spawn(
				request_id,
				owner_peer_id,
				net_id,
				plant_id,
				anchor,
				current_health,
				maximum_health,
				health_revision
			)

	func apply_remote_plant_removed(
		net_id: int,
		was_destroyed: bool = false,
		silent: bool = false
	) -> void:
		var test_runtime := _test_runtime()
		if test_runtime == null:
			return
		if silent:
			test_runtime.apply_remote_plant_removed_silently(net_id)
		else:
			test_runtime.apply_remote_plant_removed_with_reason(
				net_id,
				was_destroyed
			)


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
	fixture.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	var enemy_container := Node2D.new()
	enemy_container.name = "EnemyContainer"
	fixture.add_child(enemy_container)
	var boss_container := Node2D.new()
	boss_container.name = "BossContainer"
	fixture.add_child(boss_container)
	var pathfinder_stub := Node.new()
	pathfinder_stub.name = "GridPathfinder"
	fixture.add_child(pathfinder_stub)
	fixture.add_child(CAPOO_PROJECTILE_MOTION_SYSTEM_SCENE.instantiate())
	var drone_motion_system := CombatRobotDroneMotionSystem.new()
	drone_motion_system.name = "CombatRobotDroneMotionSystem"
	fixture.add_child(drone_motion_system)
	fixture.add_child(DAY_NIGHT_SCENE.instantiate())
	var gameplay_gateway := MultiplayerGameplayGateway.new()
	gameplay_gateway.name = "MultiplayerGameplayGateway"
	fixture.add_child(gameplay_gateway)
	var mode_adapter := TestTowerModeAdapter.new()
	mode_adapter.name = "MultiplayerModeAdapter"
	fixture.add_child(mode_adapter)
	mode_adapter.bind_runtime(fixture)
	fixture.multiplayer_mode_adapter = mode_adapter
	root.add_child(fixture)
	current_scene = fixture
	await process_frame

	_test_adaptive_enemy_snapshot_cadence()
	_test_unordered_enemy_chunk_convergence()
	_test_missing_delta_then_keyframe_recovery()
	_test_runtime_world_manifest_prunes_stale_replicas()
	_test_enemy_interpolator_iteration_prunes_after_traversal()
	_test_plant_health_batch_revision_ordering()
	_test_plant_health_before_spawn_debt()
	_test_plant_damage_feedback_revision_and_removal_ordering()
	_test_host_plant_damage_aggregation_and_fatal_flush()
	_test_warehouse_transaction_cache_scope()
	_test_transaction_rpc_admission_guards()
	_test_corn_burst_packed_queue_pressure()
	await _test_hoe_prediction_confirmation_reconciliation()
	await _test_tiyi_direct_lookup_retry()
	await _test_combat_target_query_reuse()
	await _test_offscreen_proxy_visual_budget()
	await _finish()


func _new_mp_game(use_host: bool = false) -> Node:
	var mp_game := MP_GAME_SCRIPT.new()
	var tower_adapter := fixture.get_multiplayer_mode_adapter() as TestTowerModeAdapter
	mp_game.set("game", fixture)
	mp_game.set("net_manager", host_net_manager if use_host else client_net_manager)
	mp_game.set("_mode_adapter", tower_adapter)
	mp_game.set("tower_mode_adapter", tower_adapter)
	tower_adapter.attach_multiplayer_session(mp_game)
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
	fixture.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
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
	fixture.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
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
	_expect(
		host_mp_game.call(
			"pick_random_combat_target",
			Vector2.ZERO,
			15.0
		) == near_enemy,
		"MP host random target selection must forward the triggering player's local center and radius."
	)
	_expect(
		host_mp_game.call(
			"pick_random_combat_target",
			Vector2(300.0, 0.0),
			15.0
		) == null,
		"MP host bounded random selection must report an empty local radius before global fallback."
	)
	var host_global_pick := host_mp_game.call(
		"pick_random_combat_target",
		Vector2.ZERO,
		0.0
	) as Enemy
	_expect(
		host_global_pick in [near_enemy, boss_enemy, far_enemy],
		"MP host global random fallback must return one live indexed combat target."
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


func _test_transaction_rpc_admission_guards() -> void:
	const REMOTE_PEER_ID := 2
	var mp_game := _new_capturing_host_mp_game()
	var research_command := {
		"schema": ResearchCenter.MULTIPLAYER_RESEARCH_COMMAND_SCHEMA,
		"request_id": 1,
		"building_net_id": 7001,
		"peer_id": REMOTE_PEER_ID,
		"operation": "global",
		"research_id": "building_defense",
		"nested_junk": {"payload": [{"unexpected": "value"}]},
	}
	var canonical_research := mp_game.call(
		"_canonicalize_research_command",
		research_command,
		REMOTE_PEER_ID
	) as Dictionary
	var oversized_research := research_command.duplicate()
	oversized_research["research_id"] = "x".repeat(129)
	var spoofed_research := research_command.duplicate()
	spoofed_research["peer_id"] = REMOTE_PEER_ID + 1
	_expect(
		canonical_research.size() == 6
		and not canonical_research.has("nested_junk")
		and (mp_game.call(
			"_canonicalize_research_command",
			oversized_research,
			REMOTE_PEER_ID
		) as Dictionary).is_empty()
		and (mp_game.call(
			"_canonicalize_research_command",
			spoofed_research,
			REMOTE_PEER_ID
		) as Dictionary).is_empty(),
		"Research RPC decoding must copy only fixed fields and reject spoofed or oversized wire values."
	)
	mp_game.test_net_time = 500.0
	fixture.reset_transaction_lookup_counts()
	mp_game.call(
		"_apply_authoritative_production_command",
		REMOTE_PEER_ID,
		{"nested_junk": {"payload": [{"unexpected": "value"}]}}
	)
	var malformed_ingress_bucket := (
		mp_game.get("_player_transaction_ingress_rate_buckets") as Dictionary
	).get(REMOTE_PEER_ID, {}) as Dictionary
	_expect(
		is_equal_approx(float(malformed_ingress_bucket.get("tokens", -1.0)), 47.0)
		and (mp_game.get("_production_command_rate_buckets") as Dictionary).is_empty()
		and fixture.transaction_player_lookup_count == 0
		and fixture.transaction_plant_lookup_count == 0,
		"Malformed transaction payloads must consume shared ingress before decoding while avoiding feature work."
	)
	mp_game.set("_player_transaction_ingress_rate_buckets", {})
	mp_game.set("_plant_placement_rate_buckets", {})
	fixture.reset_transaction_lookup_counts()
	mp_game.call(
		"_handle_authoritative_plant_placement_request",
		REMOTE_PEER_ID,
		1,
		"x".repeat(129),
		Vector2i.ZERO
	)
	mp_game.call(
		"_handle_authoritative_inventory_plant_placement_request",
		REMOTE_PEER_ID,
		2,
		"oak_defender",
		Vector2i.ZERO,
		0,
		0,
		"x".repeat(257)
	)
	var placement_ingress_bucket := (
		mp_game.get("_player_transaction_ingress_rate_buckets") as Dictionary
	).get(REMOTE_PEER_ID, {}) as Dictionary
	_expect(
		is_equal_approx(float(placement_ingress_bucket.get("tokens", -1.0)), 46.0)
		and (mp_game.get("_plant_placement_rate_buckets") as Dictionary).is_empty()
		and fixture.transaction_snapshot_query_count == 0,
		"Oversized placement strings must consume shared ingress but be rejected before StringName creation or plant scans."
	)

	mp_game.set("_player_transaction_ingress_rate_buckets", {})
	mp_game.set("_plant_placement_rate_buckets", {})
	mp_game.set("_last_plant_placement_request_ids", {REMOTE_PEER_ID: 9})
	_exhaust_rate_bucket(
		mp_game,
		mp_game.get("_plant_placement_rate_buckets") as Dictionary,
		REMOTE_PEER_ID,
		4.0,
		8
	)
	fixture.reset_transaction_lookup_counts()
	mp_game.call(
		"_handle_authoritative_plant_placement_request",
		REMOTE_PEER_ID,
		1,
		"oak_defender",
		Vector2i.ZERO
	)
	_expect(
		mp_game.plant_placement_rejection_send_count == 0
		and fixture.transaction_snapshot_query_count == 0,
		"Placement feature admission must reject stale replay before reply amplification or team scans."
	)
	mp_game.set("_last_plant_placement_request_ids", {})
	mp_game.set("_plant_placement_rate_buckets", {})
	mp_game.set("_player_transaction_ingress_rate_buckets", {})

	var production_command := ProductionBuildingProtocol.make_set_enabled_command(
		1,
		7002,
		REMOTE_PEER_ID,
		0,
		false
	)
	var warehouse_command := OakWarehouseProtocol.make_transfer_command(
		1,
		7003,
		REMOTE_PEER_ID,
		OakWarehouseProtocol.TransferDirection.PLAYER_TO_STORAGE,
		0,
		1,
		0,
		0
	)
	mp_game.call(
		"_cache_production_command_result",
		REMOTE_PEER_ID,
		7002,
		1,
		{"cached": true}
	)
	mp_game.call(
		"_cache_warehouse_transaction_result",
		REMOTE_PEER_ID,
		7003,
		1,
		{"cached": true}
	)
	mp_game.call(
		"_cache_simple_crafting_result",
		REMOTE_PEER_ID,
		1,
		{"cached": true}
	)
	_exhaust_rate_bucket(
		mp_game,
		mp_game.get("_production_command_rate_buckets") as Dictionary,
		REMOTE_PEER_ID,
		8.0,
		12
	)
	_exhaust_rate_bucket(
		mp_game,
		mp_game.get("_warehouse_transaction_rate_buckets") as Dictionary,
		REMOTE_PEER_ID,
		12.0,
		20
	)
	_exhaust_rate_bucket(
		mp_game,
		mp_game.get("_simple_crafting_rate_buckets") as Dictionary,
		REMOTE_PEER_ID,
		8.0,
		12
	)
	_exhaust_rate_bucket(
		mp_game,
		mp_game.get("_research_command_rate_buckets") as Dictionary,
		REMOTE_PEER_ID,
		4.0,
		6
	)
	fixture.reset_transaction_lookup_counts()
	mp_game.call(
		"_apply_authoritative_production_command",
		REMOTE_PEER_ID,
		production_command
	)
	mp_game.call(
		"_apply_authoritative_warehouse_command",
		REMOTE_PEER_ID,
		warehouse_command
	)
	mp_game.call(
		"_apply_authoritative_simple_crafting_request",
		REMOTE_PEER_ID,
		1,
		"campfire_plank",
		0
	)
	mp_game.call(
		"_apply_authoritative_research_command",
		REMOTE_PEER_ID,
		research_command
	)
	_expect(
		mp_game.production_command_result_send_count == 0
		and mp_game.warehouse_command_result_send_count == 0
		and mp_game.simple_crafting_result_send_count == 0
		and fixture.transaction_player_lookup_count == 0
		and fixture.transaction_plant_lookup_count == 0
		and fixture.transaction_snapshot_query_count == 0,
		"Feature admission must reject cache replay and new transaction work before lookups, snapshots, or full responses."
	)

	mp_game.set("_production_command_rate_buckets", {})
	mp_game.set("_warehouse_transaction_rate_buckets", {})
	mp_game.set("_simple_crafting_rate_buckets", {})
	mp_game.set("_research_command_rate_buckets", {})
	mp_game.test_net_time = 1000.0
	_exhaust_shared_transaction_ingress(mp_game, REMOTE_PEER_ID)
	fixture.reset_transaction_lookup_counts()
	mp_game.call(
		"_apply_authoritative_production_command",
		REMOTE_PEER_ID,
		production_command
	)
	mp_game.call(
		"_apply_authoritative_warehouse_command",
		REMOTE_PEER_ID,
		warehouse_command
	)
	mp_game.call(
		"_apply_authoritative_simple_crafting_request",
		REMOTE_PEER_ID,
		2,
		"campfire_plank",
		0
	)
	research_command["request_id"] = 2
	mp_game.call(
		"_apply_authoritative_research_command",
		REMOTE_PEER_ID,
		research_command
	)
	_expect(
		(mp_game.get("_production_command_rate_buckets") as Dictionary).is_empty()
		and (mp_game.get("_warehouse_transaction_rate_buckets") as Dictionary).is_empty()
		and (mp_game.get("_simple_crafting_rate_buckets") as Dictionary).is_empty()
		and (mp_game.get("_research_command_rate_buckets") as Dictionary).is_empty()
		and fixture.transaction_player_lookup_count == 0
		and fixture.transaction_plant_lookup_count == 0
		and fixture.transaction_snapshot_query_count == 0,
		"Shared transaction ingress must bound mixed-RPC spam before feature buckets or gameplay lookups."
	)
	var pressure_started_usec := Time.get_ticks_usec()
	for _request_index in 10_000:
		mp_game.call(
			"_apply_authoritative_production_command",
			REMOTE_PEER_ID,
			production_command
		)
	var pressure_usec := maxi(
		Time.get_ticks_usec() - pressure_started_usec,
		0
	)
	print(
		"TRANSACTION_ADMISSION_PRESSURE denied_requests=10000 usec=%d lookups=%d snapshots=%d sends=%d"
		% [
			pressure_usec,
			fixture.transaction_player_lookup_count
				+ fixture.transaction_plant_lookup_count,
			fixture.transaction_snapshot_query_count,
			mp_game.production_command_result_send_count,
		]
	)
	_expect(
		pressure_usec <= 1_000_000
		and fixture.transaction_player_lookup_count == 0
		and fixture.transaction_plant_lookup_count == 0
		and fixture.transaction_snapshot_query_count == 0
		and mp_game.production_command_result_send_count == 0,
		"Ten thousand denied transaction requests must remain bounded before scene scans, snapshot allocation, or replies."
	)

	var runtime_player := Player.new()
	fixture.peer_players[REMOTE_PEER_ID] = runtime_player
	fixture.reset_transaction_lookup_counts()
	mp_game.test_net_time = 2000.0
	var runtime_pressure_started_usec := Time.get_ticks_usec()
	for _request_index in 10_000:
		mp_game.call(
			"_handle_authoritative_runtime_state_request",
			REMOTE_PEER_ID,
			true
		)
	var runtime_pressure_usec := maxi(
		Time.get_ticks_usec() - runtime_pressure_started_usec,
		0
	)
	print(
		"RUNTIME_STATE_ADMISSION_PRESSURE requests=10000 usec=%d lookups=%d sends=%d"
		% [
			runtime_pressure_usec,
			fixture.transaction_player_lookup_count,
			mp_game.runtime_state_send_count,
		]
	)
	_expect(
		runtime_pressure_usec <= 1_000_000
		and fixture.transaction_player_lookup_count == 2
		and mp_game.runtime_state_send_count == 2,
		"Runtime-state repair admission must cap ten thousand small requests at the two-request burst before world serialization."
	)
	fixture.peer_players.erase(REMOTE_PEER_ID)
	runtime_player.free()
	mp_game.queue_free()


func _exhaust_rate_bucket(
	mp_game: Node,
	bucket: Dictionary,
	peer_id: int,
	rate_per_second: float,
	burst_count: int
) -> void:
	for _request_index in burst_count:
		_expect(
			bool(mp_game.call(
				"_consume_peer_rate_token",
				bucket,
				peer_id,
				rate_per_second,
				float(burst_count)
			)),
			"The configured feature burst must be admitted before exhaustion."
		)


func _exhaust_shared_transaction_ingress(mp_game: Node, peer_id: int) -> void:
	mp_game.set("_player_transaction_ingress_rate_buckets", {})
	for _request_index in 48:
		_expect(
			bool(mp_game.call(
				"_consume_remote_transaction_admission",
				peer_id
			)),
			"The shared transaction ingress burst must admit its first 48 requests."
		)
	_expect(
		not bool(mp_game.call(
			"_consume_remote_transaction_admission",
			peer_id
		)),
		"The shared transaction ingress must reject the request after its burst is exhausted."
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
	var unordered_frame := (
		(mp_game.enemy_interpolators[1] as NetInterpolator).get_latest_state()
	)
	_expect(
		unordered_frame.anim_state == Enemy.LocomotionState.MOVING,
		"Unordered chunks must preserve each enemy's discrete locomotion state."
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
	var repaired_frame := (
		(mp_game.enemy_interpolators[900] as NetInterpolator).get_latest_state()
	)
	_expect(
		repaired_frame.anim_state == Enemy.LocomotionState.MOVING,
		"The repair keyframe must restore locomotion together with continuous motion."
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
	mp_game.call(
		"_cache_pending_warehouse_snapshot",
		20,
		{"revision": 1}
	)
	mp_game.call(
		"_cache_pending_warehouse_snapshot",
		21,
		{"revision": 1}
	)
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
		and not (mp_game.get("_pending_warehouse_snapshots") as Dictionary).has(21)
		and int(mp_game.get("_pending_warehouse_snapshot_oldest_id")) == 20
		and int(mp_game.get("_pending_warehouse_snapshot_newest_id")) == 20
		and fixture.silent_plant_removal_ids.has(21)
		and not fixture.animated_plant_removal_ids.has(21),
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
		PackedInt32Array([5, 4, 6]),
		PackedInt32Array([0, 0, 0]),
		PackedInt32Array([0, 0, 0]),
		PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]),
		PackedByteArray([0, 0, 0]),
		PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	)
	_expect(
		plant.health_revision == 6 and plant.current_health == 60,
		"Plant health batching must ignore a reordered stale revision and apply the newest record."
	)
	fixture.proxy_plants.clear()
	plant.free()


func _test_plant_health_before_spawn_debt() -> void:
	var mp_game := _new_mp_game()
	mp_game.call(
		"net_plant_health_batch",
		PackedInt32Array([71, 71, 71]),
		PackedInt32Array([80, 15, 60]),
		PackedInt32Array([100, 100, 100]),
		PackedInt32Array([5, 4, 7]),
		PackedInt32Array([0, 0, 0]),
		PackedInt32Array([0, 0, 0]),
		PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]),
		PackedByteArray([0, 0, 0]),
		PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	)
	var pending := mp_game.get("_pending_remote_plant_health_updates") as Dictionary
	_expect(
		not fixture.proxy_plants.has(71)
		and pending.size() == 1
		and int((pending.get(71, {}) as Dictionary).get("health_revision", -1)) == 7,
		"A CH7 health update received before its CH5 spawn must retain only the highest revision."
	)
	mp_game.call(
		"net_plant_spawned",
		0,
		2,
		71,
		"test_plant",
		Vector2i.ZERO,
		100,
		100,
		3,
		{},
		0.0
	)
	var spawned_plant := fixture.proxy_plants.get(71) as PlantDefense
	_expect(
		spawned_plant != null
		and spawned_plant.health_revision == 7
		and spawned_plant.current_health == 60
		and not pending.has(71),
		"Plant registration must immediately settle a newer deferred health revision."
	)
	mp_game.call(
		"net_plant_health_batch",
		PackedInt32Array([71, 71]),
		PackedInt32Array([10, 55]),
		PackedInt32Array([100, 100]),
		PackedInt32Array([6, 8]),
		PackedInt32Array([0, 0]),
		PackedInt32Array([0, 0]),
		PackedVector2Array([Vector2.ZERO, Vector2.ZERO]),
		PackedByteArray([0, 0]),
		PackedVector2Array([Vector2.ZERO, Vector2.ZERO])
	)
	_expect(
		spawned_plant.health_revision == 8 and spawned_plant.current_health == 55,
		"Settling spawn debt must not let a later stale health record overwrite the replica."
	)

	mp_game.call(
		"net_plant_health_batch",
		PackedInt32Array([72]),
		PackedInt32Array([40]),
		PackedInt32Array([100]),
		PackedInt32Array([9]),
		PackedInt32Array([0]),
		PackedInt32Array([0]),
		PackedVector2Array([Vector2.ZERO]),
		PackedByteArray([0]),
		PackedVector2Array([Vector2.ZERO])
	)
	mp_game.call("net_plant_removed", 72, true)
	_expect(
		fixture.animated_plant_removal_ids.has(72)
		and fixture.destroyed_plant_removal_ids.has(72)
		and not fixture.silent_plant_removal_ids.has(72),
		"A reliable destroyed-building removal must preserve its reason on the animated client path."
	)
	mp_game.call(
		"net_plant_health_batch",
		PackedInt32Array([72]),
		PackedInt32Array([20]),
		PackedInt32Array([100]),
		PackedInt32Array([10]),
		PackedInt32Array([0]),
		PackedInt32Array([0]),
		PackedVector2Array([Vector2.ZERO]),
		PackedByteArray([0]),
		PackedVector2Array([Vector2.ZERO])
	)
	var removed_ids := mp_game.get("_removed_remote_plant_ids") as Dictionary
	_expect(
		not pending.has(72) and removed_ids.has(72),
		"A reliable removal must erase health debt and reject CH7 records that arrive afterward."
	)
	mp_game.call(
		"net_plant_spawned",
		0,
		2,
		72,
		"test_plant",
		Vector2i.ZERO,
		90,
		100,
		11,
		{},
		0.0
	)
	_expect(
		fixture.proxy_plants.has(72) and not removed_ids.has(72),
		"A newer authoritative spawn must clear an older local removal marker."
	)

	mp_game.call("_clear_remote_plant_health_state")
	var limit := MP_GAME_SCRIPT.CLIENT_PENDING_PLANT_HEALTH_MAX_ENTRIES
	for index in range(limit + 5):
		mp_game.call(
			"_apply_or_defer_remote_plant_health",
			1000 + index,
			90 - index % 10,
			100,
			index + 1
		)
	pending = mp_game.get("_pending_remote_plant_health_updates") as Dictionary
	var pending_order := mp_game.get("_pending_remote_plant_health_order") as Array
	_expect(
		pending.size() == limit
		and pending_order.size() == limit
		and not pending.has(1000)
		and pending.has(1000 + limit + 4),
		"Unknown-plant health debt must remain bounded at the multiplayer plant limit."
	)
	var newest_debt_id := 1000 + limit + 4
	mp_game.call(
		"net_runtime_world_manifest",
		PackedInt32Array(),
		PackedInt32Array(),
		PackedInt32Array([72, newest_debt_id])
	)
	_expect(
		pending.size() == limit
		and pending.has(1005)
		and pending.has(newest_debt_id)
		and not removed_ids.has(1005),
		"A CH5 manifest must not discard or tombstone unknown CH7 health debt from a future spawn."
	)
	mp_game.call(
		"net_plant_spawned",
		0,
		2,
		newest_debt_id,
		"test_plant",
		Vector2i.ZERO,
		100,
		100,
		1,
		{},
		0.0
	)
	var newest_plant := fixture.proxy_plants.get(newest_debt_id) as PlantDefense
	_expect(
		newest_plant != null
		and newest_plant.health_revision == limit + 5
		and newest_plant.current_health == 90
		and pending.size() == limit - 1
		and not pending.has(newest_debt_id),
		"Debt retained by a live manifest entry must settle when its snapshot spawn registers."
	)
	var tombstone_limit := MP_GAME_SCRIPT.CLIENT_REMOVED_PLANT_TOMBSTONE_MAX_ENTRIES
	for index in range(tombstone_limit + 5):
		mp_game.call("_mark_remote_plant_removed", 2000 + index)
	removed_ids = mp_game.get("_removed_remote_plant_ids") as Dictionary
	_expect(
		removed_ids.size() == tombstone_limit
		and not removed_ids.has(2000)
		and removed_ids.has(2000 + tombstone_limit + 4),
		"Late-health removal markers must remain bounded during long high-churn sessions."
	)

	mp_game.call("net_plant_removed", 71)
	mp_game.call("net_plant_removed", 72)
	mp_game.call("net_plant_removed", newest_debt_id)
	mp_game.call("_clear_remote_plant_health_state")
	_expect(
		(mp_game.get("_pending_remote_plant_health_updates") as Dictionary).is_empty()
		and (mp_game.get("_removed_remote_plant_ids") as Dictionary).is_empty(),
		"Leaving a session must be able to clear all deferred plant-health ordering state."
	)


func _test_plant_damage_feedback_revision_and_removal_ordering() -> void:
	var mp_game := _new_mp_game()
	fixture.damage_number_requests.clear()
	var feedback_position := Vector2(88.0, 96.0)
	var feedback_arguments := [
		PackedInt32Array([73]),
		PackedInt32Array([95]),
		PackedInt32Array([100]),
		PackedInt32Array([3]),
		PackedInt32Array([10]),
		PackedInt32Array([5]),
		PackedVector2Array([Vector2.LEFT]),
		PackedByteArray([EnemyConfig.DamageType.MAGIC]),
		PackedVector2Array([feedback_position]),
	]
	mp_game.callv("net_plant_health_batch", feedback_arguments)
	mp_game.callv("net_plant_health_batch", feedback_arguments)
	_expect(
		fixture.damage_number_requests.size() == 2,
		"One plant feedback revision must display damage and healing once each, without replaying either on duplicate delivery."
	)
	if fixture.damage_number_requests.size() >= 2:
		var damage_request := fixture.damage_number_requests[0]
		var healing_request := fixture.damage_number_requests[1]
		_expect(
			int(damage_request.get("amount", 0)) == 10
			and damage_request.get("spawn_position", Vector2.ZERO) == feedback_position
			and int(damage_request.get("number_kind", -1))
			== DamageNumberPool.CombatNumberKind.DAMAGE
			and damage_request.get("impact_direction", Vector2.ZERO) == Vector2.LEFT
			and int(damage_request.get("damage_type", -1))
			== EnemyConfig.DamageType.MAGIC
			and int(damage_request.get("display_priority", -1))
			== DamageNumberPool.DisplayPriority.IMPORTANT,
			"Plant feedback must preserve its aggregate, position, direction, type, and priority."
		)
		_expect(
			int(healing_request.get("amount", 0)) == 5
			and healing_request.get("spawn_position", Vector2.ZERO) == feedback_position
			and int(healing_request.get("number_kind", -1))
			== DamageNumberPool.CombatNumberKind.HEALING
			and healing_request.get("impact_direction", Vector2.INF) == Vector2.ZERO
			and int(healing_request.get("display_priority", -1))
			== DamageNumberPool.DisplayPriority.IMPORTANT,
			"Plant healing feedback must preserve its actual amount, position, semantic kind, and important priority."
		)
	mp_game.call("net_plant_removed", 73)
	mp_game.call(
		"net_plant_health_batch",
		PackedInt32Array([73]),
		PackedInt32Array([0]),
		PackedInt32Array([100]),
		PackedInt32Array([4]),
		PackedInt32Array([90]),
		PackedInt32Array([0]),
		PackedVector2Array([Vector2.RIGHT]),
		PackedByteArray([EnemyConfig.DamageType.PHYSICAL]),
		PackedVector2Array([feedback_position])
	)
	_expect(
		fixture.damage_number_requests.size() == 3,
		"A fatal plant feedback record must still display when reliable removal arrives first."
	)
	var newer_live_plant := PlantDefense.new()
	newer_live_plant.configure_multiplayer_proxy(80, 100, 5)
	fixture.proxy_plants[74] = newer_live_plant
	mp_game.call(
		"net_plant_health_batch",
		PackedInt32Array([74]),
		PackedInt32Array([90]),
		PackedInt32Array([100]),
		PackedInt32Array([4]),
		PackedInt32Array([10]),
		PackedInt32Array([0]),
		PackedVector2Array([Vector2.LEFT]),
		PackedByteArray([EnemyConfig.DamageType.PHYSICAL]),
		PackedVector2Array([feedback_position])
	)
	_expect(
		fixture.damage_number_requests.size() == 3,
		"A CH7 record older than a reliable live-plant state must not replay historical damage."
	)
	fixture.proxy_plants.erase(74)
	newer_live_plant.free()


func _test_host_plant_damage_aggregation_and_fatal_flush() -> void:
	var mp_game := _new_capturing_host_mp_game()
	mp_game.call("_on_host_plant_health_changed", 81, 90, 100, 2)
	mp_game.call(
		"_on_host_plant_damage_applied",
		81,
		6,
		Vector2.LEFT,
		EnemyConfig.DamageType.MAGIC,
		Vector2(40.0, 50.0)
	)
	mp_game.call(
		"_on_host_plant_damage_applied",
		81,
		4,
		Vector2.RIGHT,
		EnemyConfig.DamageType.PHYSICAL,
		Vector2(42.0, 52.0)
	)
	mp_game.call("_on_host_plant_health_changed", 81, 93, 100, 3)
	mp_game.call(
		"_on_host_plant_healing_applied",
		81,
		3,
		Vector2(43.0, 53.0)
	)
	mp_game.call("_on_host_plant_health_changed", 81, 95, 100, 4)
	mp_game.call(
		"_on_host_plant_healing_applied",
		81,
		2,
		Vector2(44.0, 54.0)
	)
	var pending := mp_game.get("_pending_plant_health_updates") as Dictionary
	var aggregate := pending.get(81, {}) as Dictionary
	_expect(
		mp_game.outbound_calls.is_empty()
		and pending.size() == 1
		and int(aggregate.get("damage", 0)) == 10
		and int(aggregate.get("healing", 0)) == 5
		and int(aggregate.get("health_revision", 0)) == 4,
		"Host plant damage and healing must aggregate independently by net ID without sending one packet per event."
	)
	mp_game.call("_on_host_plant_removed", 81, true)
	_expect(
		mp_game.outbound_calls.size() == 2
		and mp_game.outbound_calls[0].get("method_name", &"")
		== &"net_plant_health_batch"
		and mp_game.outbound_calls[1].get("method_name", &"") == &"net_plant_removed"
		and pending.is_empty(),
		"Plant removal must flush aggregate damage and healing before its reliable removal event."
	)
	if mp_game.outbound_calls.size() >= 2:
		var removal_args := mp_game.outbound_calls[1].get("args", []) as Array
		_expect(
			removal_args == [81, true],
			"Reliable plant removal must carry the destroyed-building reason."
		)
	if mp_game.outbound_calls.size() >= 1:
		var batch_args := mp_game.outbound_calls[0].get("args", []) as Array
		_expect(
			batch_args.size() == 9
			and (batch_args[0] as PackedInt32Array) == PackedInt32Array([81])
			and (batch_args[3] as PackedInt32Array) == PackedInt32Array([4])
			and (batch_args[4] as PackedInt32Array) == PackedInt32Array([10])
			and (batch_args[5] as PackedInt32Array) == PackedInt32Array([5])
			and (batch_args[6] as PackedVector2Array) == PackedVector2Array([Vector2.LEFT])
			and (batch_args[7] as PackedByteArray)
			== PackedByteArray([EnemyConfig.DamageType.MAGIC])
			and (batch_args[8] as PackedVector2Array)
			== PackedVector2Array([Vector2(44.0, 54.0)]),
			"The removal flush must preserve separate damage/healing sums and the latest visual metadata."
		)
	mp_game.queue_free()

	var chunk_mp_game := _new_capturing_host_mp_game()
	var plant_limit := MP_GAME_SCRIPT.MULTIPLAYER_TEAM_PLANT_LIMIT
	var chunk_limit := MP_GAME_SCRIPT.PLANT_HEALTH_MAX_RECORDS_PER_PACKET
	for record_index in range(plant_limit):
		chunk_mp_game.call(
			"_on_host_plant_health_changed",
			1000 + record_index,
			90,
			100,
			1
		)
		chunk_mp_game.call(
			"_on_host_plant_healing_applied",
			1000 + record_index,
			1,
			Vector2(float(record_index), 1.0)
		)
	chunk_mp_game.call("_flush_plant_health_updates")
	var chunked_record_count := 0
	var chunks_with_valid_size := true
	var maximum_estimated_packet_bytes := 0
	for outbound_call in chunk_mp_game.outbound_calls:
		var batch_args := outbound_call.get("args", []) as Array
		if (
			outbound_call.get("method_name", &"") != &"net_plant_health_batch"
			or batch_args.size() != 9
		):
			chunks_with_valid_size = false
			continue
		var chunk_ids := batch_args[0] as PackedInt32Array
		chunked_record_count += chunk_ids.size()
		maximum_estimated_packet_bytes = maxi(
			maximum_estimated_packet_bytes,
			var_to_bytes(batch_args).size() + 16
		)
		chunks_with_valid_size = (
			chunks_with_valid_size
			and chunk_ids.size() > 0
			and chunk_ids.size() <= chunk_limit
			and (batch_args[5] as PackedInt32Array).size() == chunk_ids.size()
		)
	_expect(
		chunk_mp_game.outbound_calls.size()
		== ceili(float(plant_limit) / float(chunk_limit))
		and chunked_record_count == plant_limit
		and chunks_with_valid_size
		and maximum_estimated_packet_bytes <= MP_GAME_SCRIPT.SNAPSHOT_PACKET_WARN_BYTES,
		"The full plant limit with healing metadata must chunk into actual MTU-safe batches without dropping records."
	)
	chunk_mp_game.queue_free()


func _new_capturing_host_mp_game() -> CapturingMpGame:
	var mp_game := CapturingMpGame.new()
	mp_game.process_mode = Node.PROCESS_MODE_DISABLED
	var keepalive_request := HTTPRequest.new()
	keepalive_request.name = "PublicRoomKeepaliveRequest"
	mp_game.add_child(keepalive_request)
	fixture.add_child(mp_game)
	mp_game.set("game", fixture)
	mp_game.set("net_manager", host_net_manager)
	var tower_adapter := fixture.get_multiplayer_mode_adapter() as TestTowerModeAdapter
	mp_game._mode_adapter = tower_adapter
	mp_game.tower_mode_adapter = tower_adapter
	tower_adapter.attach_multiplayer_session(mp_game)
	return mp_game


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
	player.play_predicted_hoe_action(&"primary", Vector2.RIGHT, 11)
	_expect(
		not player.primary_impact_timer.is_stopped()
		and float(player.get("_primary_visual_time_left")) > 0.0,
		"A predicted primary must arm its presentation timer before skill-priority coverage."
	)
	player.play_predicted_hoe_action(&"whirlwind", Vector2.ZERO, 12)
	_expect(
		player.primary_impact_timer.is_stopped()
		and is_zero_approx(float(player.get("_primary_visual_time_left")))
		and not player.basic_slash_effect.visible
		and float(player.get("_whirlwind_visual_time_left")) > 0.0,
		"A predicted whirlwind must immediately replace an in-flight primary presentation."
	)
	player.reconcile_predicted_hoe_action(12, false, &"whirlwind", 1.0, 2.0)

	player.play_predicted_hoe_action(&"whirlwind", Vector2.ZERO, 13)
	player.reconcile_predicted_hoe_action(13, true, &"whirlwind", 1.0, 0.75)
	_expect(
		float(player.get("_whirlwind_visual_time_left")) > 0.0
		and is_equal_approx(player.skill1_charge, 0.75),
		"An accepted whirlwind must retain prediction while reconciling authoritative resources."
	)
	player.play_predicted_hoe_action(&"whirlwind", Vector2.ZERO, 14)
	player.reconcile_predicted_hoe_action(14, false, &"whirlwind", 1.0, 2.0)
	_expect(
		is_zero_approx(float(player.get("_whirlwind_visual_time_left")))
		and is_equal_approx(player.skill1_charge, 2.0),
		"A rejected whirlwind must terminate the predicted visual and refund authority state."
	)
	player.queue_free()
	await process_frame


func _test_tiyi_direct_lookup_retry() -> void:
	var player := TIYI_SCENE.instantiate() as PlayerTiyi
	player.bind_combat_runtime(fixture)
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
	var first_offscreen_sample := bool(
		mp_game.call("_should_interpolate_enemy_proxy", 2, far_enemy, 10.0)
	)
	var duplicate_offscreen_sample := bool(
		mp_game.call("_should_interpolate_enemy_proxy", 2, far_enemy, 10.0)
	)
	var later_offscreen_sample := bool(
		mp_game.call("_should_interpolate_enemy_proxy", 2, far_enemy, 10.2)
	)
	_expect(
		first_offscreen_sample
		and not duplicate_offscreen_sample
		and later_offscreen_sample,
		"A safely offscreen proxy must sample at bounded 15 Hz slots instead of every render call."
	)
	far_enemy.global_position = Vector2.ZERO
	mp_game.set("_client_proxy_visual_budget_time_left", 0.0)
	mp_game.call("_update_client_proxy_visual_budget", 0.0)
	_expect(
		far_enemy.multiplayer_proxy_visual_active
		and int(mp_game.get("_offscreen_enemy_proxy_count")) == 0,
		"A proxy re-entering the expanded camera rectangle must immediately restore visuals."
	)
	_expect(
		bool(mp_game.call("_should_interpolate_enemy_proxy", 2, far_enemy, 10.2))
		and bool(mp_game.call("_should_interpolate_enemy_proxy", 2, far_enemy, 10.2)),
		"A visible proxy must keep full render-rate interpolation even with a retained offscreen slot."
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
		state.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_MOVING
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
