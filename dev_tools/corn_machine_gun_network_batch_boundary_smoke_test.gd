extends SceneTree

const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const CORN_SCENE := preload("res://scene/plant_defense/corn_machine_gun.tscn")
const CORN_CONFIG := preload(
	"res://resources/config/plant_defense/corn_machine_gun.tres"
)

const SEND_RECORD_COUNT := 513
const SEND_PACKET_CAPACITY := 32
const CLIENT_TIME_BASE := 20.0
const HOST_TO_CLIENT_OFFSET := 10.0
const PROXY_PLANT_NET_ID := 77


class RecordingMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var sent_methods: Array[StringName] = []
	var sent_arguments: Array[Array] = []

	func _rpc_to_connected_clients(
		method_name: StringName,
		args: Array = []
	) -> void:
		sent_methods.append(method_name)
		sent_arguments.append(args.duplicate())


class ClientNetManagerStub:
	extends Node

	func is_host() -> bool:
		return false

	func is_client() -> bool:
		return true


class TestRuntime:
	extends GameRuntimeBase

	var proxy_plants: Dictionary[int, PlantDefense] = {}

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

	func get_multiplayer_plant_node(net_id: int) -> PlantDefense:
		return proxy_plants.get(net_id) as PlantDefense


var failures: Array[String] = []
var played_action_ids: Array[int] = []
var played_directions: Array[Vector2] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_production_send_flush_boundary()
	await _test_production_receive_boundary()
	_finish()


func _test_production_send_flush_boundary() -> void:
	var host_mp := RecordingMpGame.new()
	for record_index in range(SEND_RECORD_COUNT):
		host_mp.call(
			"_append_corn_machine_gun_burst_visual",
			10000 + record_index,
			20000 + record_index,
			_make_send_direction(record_index),
			1000.0 + float(record_index) * 0.125
		)

	host_mp.call("_flush_corn_machine_gun_burst_visuals")
	var expected_packet_count := ceili(
		float(SEND_RECORD_COUNT) / float(SEND_PACKET_CAPACITY)
	)
	_expect(
		host_mp.sent_methods.size() == expected_packet_count
		and host_mp.sent_arguments.size() == expected_packet_count,
		"The production Corn flush must split 513 records into exactly seventeen RPC packets."
	)

	var flattened_record_index := 0
	for packet_index in range(host_mp.sent_arguments.size()):
		_expect(
			host_mp.sent_methods[packet_index]
			== &"net_corn_machine_gun_burst_batch",
			"Every Corn flush packet must use the production burst-batch RPC."
		)
		var payload := host_mp.sent_arguments[packet_index]
		if payload.size() != 4:
			_expect(false, "Every Corn burst packet must contain four packed columns.")
			continue
		var plant_net_ids := payload[0] as PackedInt32Array
		var action_ids := payload[1] as PackedInt32Array
		var directions := payload[2] as PackedVector2Array
		var host_action_times := payload[3] as PackedFloat64Array
		var expected_chunk_size := mini(
			SEND_PACKET_CAPACITY,
			SEND_RECORD_COUNT - packet_index * SEND_PACKET_CAPACITY
		)
		_expect(
			plant_net_ids.size() == expected_chunk_size
			and action_ids.size() == expected_chunk_size
			and directions.size() == expected_chunk_size
			and host_action_times.size() == expected_chunk_size,
			"Corn packet %d must retain aligned packed columns and its exact chunk size."
			% packet_index
		)
		var safe_record_count := mini(
			plant_net_ids.size(),
			mini(
				action_ids.size(),
				mini(directions.size(), host_action_times.size())
			)
		)
		for chunk_record_index in range(safe_record_count):
			var source_index := packet_index * SEND_PACKET_CAPACITY + chunk_record_index
			_expect(
				plant_net_ids[chunk_record_index] == 10000 + source_index
				and action_ids[chunk_record_index] == 20000 + source_index
				and directions[chunk_record_index].is_equal_approx(
					_make_send_direction(source_index)
				)
				and is_equal_approx(
					host_action_times[chunk_record_index],
					1000.0 + float(source_index) * 0.125
				),
				"Corn packet %d record %d must preserve cross-column ordering."
				% [packet_index, chunk_record_index]
			)
		flattened_record_index += safe_record_count

	_expect(
		flattened_record_index == SEND_RECORD_COUNT,
		"The production Corn flush must emit all 513 queued records exactly once."
	)
	if not host_mp.sent_arguments.is_empty():
		var tail_payload := host_mp.sent_arguments[-1]
		_expect(
			(tail_payload[0] as PackedInt32Array).size() == 1
			and (tail_payload[0] as PackedInt32Array)[0] == 10512
			and (tail_payload[1] as PackedInt32Array)[0] == 20512
			and (tail_payload[2] as PackedVector2Array)[0].is_equal_approx(
				_make_send_direction(512)
			)
			and is_equal_approx(
				(tail_payload[3] as PackedFloat64Array)[0],
				1064.0
			),
			"The seventeenth Corn packet must contain the exact one-record tail."
		)
	_expect(
		(host_mp.get(
			"_pending_corn_machine_gun_burst_visuals"
		) as PackedInt32Array).is_empty()
		and (host_mp.get(
			"_pending_corn_machine_gun_burst_action_ids"
		) as PackedInt32Array).is_empty()
		and (host_mp.get(
			"_pending_corn_machine_gun_burst_directions"
		) as PackedVector2Array).is_empty()
		and (host_mp.get(
			"_pending_corn_machine_gun_burst_host_times"
		) as PackedFloat64Array).is_empty(),
		"A completed production Corn flush must clear all four pending columns together."
	)
	var packet_count_before_empty_flush := host_mp.sent_methods.size()
	host_mp.call("_flush_corn_machine_gun_burst_visuals")
	_expect(
		host_mp.sent_methods.size() == packet_count_before_empty_flush,
		"Flushing an empty Corn queue must not emit a second copy of any packet."
	)
	host_mp.free()


func _test_production_receive_boundary() -> void:
	var runtime := TestRuntime.new()
	runtime.name = "CornNetworkBatchBoundaryRuntime"
	runtime.runtime_mode = GameRuntimeBase.RuntimeMode.CLIENT_VIEW
	var enemy_container := Node2D.new()
	enemy_container.name = "EnemyContainer"
	runtime.add_child(enemy_container)
	var grid_pathfinder := Node.new()
	grid_pathfinder.name = "GridPathfinder"
	runtime.add_child(grid_pathfinder)
	root.add_child(runtime)
	current_scene = runtime

	var corn := CORN_SCENE.instantiate() as CornMachineGun
	runtime.add_child(corn)
	await process_frame
	var footprint: Array[Vector2i] = [
		Vector2i.ZERO,
		Vector2i.RIGHT,
		Vector2i.DOWN,
		Vector2i.ONE,
	]
	corn.setup(CORN_CONFIG, null, footprint, true)
	corn.burst_shot_emitted.connect(_on_proxy_shot_emitted.bind(corn))
	runtime.proxy_plants[PROXY_PLANT_NET_ID] = corn

	var client_mp := MP_GAME_SCRIPT.new()
	var client_net_manager := ClientNetManagerStub.new()
	client_mp.set("game", runtime)
	client_mp.set("net_manager", client_net_manager)
	client_mp.set(
		"_net_time_origin",
		Time.get_ticks_msec() / 1000.0 - CLIENT_TIME_BASE
	)
	client_mp.set("_has_host_time_offset", true)
	client_mp.set("_host_to_client_time_offset", HOST_TO_CLIENT_OFFSET)

	var client_now := float(client_mp.call("_get_net_time"))
	var future_host_time := client_now - HOST_TO_CLIENT_OFFSET + 1.0
	var initial_directions := PackedVector2Array([
		Vector2.RIGHT,
		Vector2.DOWN,
		Vector2.LEFT,
		Vector2.UP,
	])
	client_mp.call(
		"net_corn_machine_gun_burst_batch",
		PackedInt32Array([
			PROXY_PLANT_NET_ID,
			PROXY_PLANT_NET_ID,
			PROXY_PLANT_NET_ID,
			PROXY_PLANT_NET_ID,
		]),
		PackedInt32Array([1, 2, 3, 4]),
		initial_directions,
		PackedFloat64Array([
			future_host_time,
			future_host_time,
			future_host_time,
			future_host_time,
		])
	)
	_expect(
		played_action_ids == [1, 2, 3, 4]
		and played_directions == [
			Vector2.RIGHT,
			Vector2.DOWN,
			Vector2.LEFT,
			Vector2.UP,
		]
		and corn.latest_proxy_action_id == 4,
		"The production receive path must play every valid ordered action exactly once."
	)

	var played_count_before_duplicates := played_action_ids.size()
	client_mp.call(
		"net_corn_machine_gun_burst_batch",
		PackedInt32Array([
			PROXY_PLANT_NET_ID,
			PROXY_PLANT_NET_ID,
			PROXY_PLANT_NET_ID,
		]),
		PackedInt32Array([4, 2, 3]),
		PackedVector2Array([Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]),
		PackedFloat64Array([future_host_time, future_host_time, future_host_time])
	)
	_expect(
		played_action_ids.size() == played_count_before_duplicates
		and corn.latest_proxy_action_id == 4,
		"Duplicate and stale Corn actions must not replay through the production receiver."
	)

	client_mp.call(
		"net_corn_machine_gun_burst_batch",
		PackedInt32Array([
			PROXY_PLANT_NET_ID,
			PROXY_PLANT_NET_ID,
			PROXY_PLANT_NET_ID,
		]),
		PackedInt32Array([5, 7, 6]),
		PackedVector2Array([Vector2.RIGHT, Vector2.UP, Vector2.LEFT]),
		PackedFloat64Array([future_host_time, future_host_time, future_host_time])
	)
	_expect(
		played_action_ids == [1, 2, 3, 4, 5, 7]
		and corn.latest_proxy_action_id == 7,
		"The receiver must accept newer Corn actions once and reject a stale record later in the same valid batch."
	)

	var played_count_before_malformed := played_action_ids.size()
	client_mp.call(
		"net_corn_machine_gun_burst_batch",
		PackedInt32Array([PROXY_PLANT_NET_ID, PROXY_PLANT_NET_ID]),
		PackedInt32Array([8, 0]),
		PackedVector2Array([Vector2.RIGHT, Vector2.DOWN]),
		PackedFloat64Array([future_host_time, future_host_time])
	)
	_expect(
		played_action_ids.size() == played_count_before_malformed
		and corn.latest_proxy_action_id == 7,
		"An invalid tail record must reject the complete Corn packet before its valid first record is applied."
	)
	client_mp.call(
		"net_corn_machine_gun_burst_batch",
		PackedInt32Array([PROXY_PLANT_NET_ID, PROXY_PLANT_NET_ID]),
		PackedInt32Array([8, 9]),
		PackedVector2Array([Vector2.RIGHT]),
		PackedFloat64Array([future_host_time, future_host_time])
	)
	_expect(
		played_action_ids.size() == played_count_before_malformed
		and corn.latest_proxy_action_id == 7,
		"Misaligned Corn packed columns must be rejected atomically without partial playback."
	)

	var mapping_sample_time := float(client_mp.call("_get_net_time"))
	var mapped_elapsed_target := 0.13
	var past_host_time := (
		mapping_sample_time
		- HOST_TO_CLIENT_OFFSET
		- mapped_elapsed_target
	)
	client_mp.call(
		"net_corn_machine_gun_burst_batch",
		PackedInt32Array([PROXY_PLANT_NET_ID]),
		PackedInt32Array([8]),
		PackedVector2Array([Vector2(3.0, 4.0)]),
		PackedFloat64Array([past_host_time])
	)
	_expect(
		corn.latest_proxy_action_id == 8
		and corn.burst_active
		and corn.burst_action_id == 8
		and corn.burst_direction.is_equal_approx(Vector2(0.6, 0.8))
		and corn.burst_elapsed_seconds >= 0.12
		and corn.burst_elapsed_seconds <= 0.16
		and corn.burst_next_shot_index == 3,
		"The receive path must map Host time and resume a late Corn burst at its correct visual phase."
	)
	client_mp.call(
		"net_corn_machine_gun_burst_batch",
		PackedInt32Array([PROXY_PLANT_NET_ID]),
		PackedInt32Array([8]),
		PackedVector2Array([Vector2.LEFT]),
		PackedFloat64Array([future_host_time])
	)
	_expect(
		corn.burst_action_id == 8
		and corn.burst_direction.is_equal_approx(Vector2(0.6, 0.8))
		and played_action_ids.size() == played_count_before_malformed,
		"A duplicate late Corn action must not restart or redirect the active proxy burst."
	)

	client_mp.free()
	client_net_manager.free()
	runtime.proxy_plants.clear()
	current_scene = null
	runtime.queue_free()
	for _frame in range(3):
		await process_frame
		await physics_frame


func _on_proxy_shot_emitted(
	_shot_index: int,
	authoritative: bool,
	corn: CornMachineGun
) -> void:
	_expect(not authoritative, "A received Corn burst must remain visual-only on clients.")
	played_action_ids.append(corn.burst_action_id)
	played_directions.append(corn.burst_direction)


func _make_send_direction(record_index: int) -> Vector2:
	return Vector2(
		float(record_index % 17 + 1),
		-float(record_index % 11 + 1)
	).normalized()


func _finish() -> void:
	if failures.is_empty():
		print(
			"CORN_MACHINE_GUN_NETWORK_BATCH_BOUNDARY_SMOKE_TEST_OK ",
			"records=513 packets=17 packet_capacity=32 tail=1 ",
			"accepted_actions=7 malformed_atomic_rejections=2"
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
