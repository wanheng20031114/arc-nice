extends SceneTree

const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const SnapshotManager := preload("res://scene/multiplayer/snapshot_manager.gd")
const MpGameScript := preload("res://scene/multiplayer/mp_game.gd")
const MpProjectileCoordinator := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const MpTowerWorldCoordinatorScript := preload(
	"res://scene/game_modes/tower_defense/multiplayer/world/mp_tower_world_coordinator.gd"
)
const MP_TOWER_WORLD_COORDINATOR_PATH := (
	"res://scene/game_modes/tower_defense/multiplayer/world/mp_tower_world_coordinator.gd"
)
const MP_SESSION_COORDINATOR_PATH := (
	"res://scene/multiplayer/session/mp_session_coordinator.gd"
)
const BULLET_SCENE := preload("res://scene/combat/projectiles/bullet.tscn")
const TOWER_DEFENSE_PLANT_RUNTIME_PATH := (
	"res://scene/game_modes/tower_defense/plant/tower_defense_plant_runtime_coordinator.gd"
)
const PROJECTILE_SEQUENCE_MAX: int = 0xFFFFFFFF
const PROJECTILE_HOST_ORIGIN_BIT: int = 0x80000000
const PROJECTILE_SEQUENCE_COUNTER_MAX: int = 0x7FFFFFFF
const PLAYER_SNAPSHOT_ONLY_ARG := "--player-snapshot-only"


class TerrainClientNetManagerStub:
	extends NetManagerStore

	func is_host() -> bool:
		return false

	func is_client() -> bool:
		return true


class TerrainRuntimeStub:
	extends CombatRuntimeBase

	var snapshot_revisions: Array[int] = []
	var delta_revisions: Array[int] = []
	var accept_snapshot := true
	var accept_delta := true

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

	func supports_multiplayer_terrain_state() -> bool:
		return true

	func apply_remote_terrain_snapshot(
		revision: int,
		_cell_xy: PackedInt32Array,
		_terrain_types: PackedInt32Array
	) -> bool:
		if not accept_snapshot:
			return false
		snapshot_revisions.append(revision)
		return true

	func apply_remote_terrain_delta(
		revision: int,
		_cell_xy: PackedInt32Array,
		_terrain_types: PackedInt32Array
	) -> bool:
		if not accept_delta:
			return false
		delta_revisions.append(revision)
		return true


class TerrainTowerModeAdapter:
	extends TowerDefenseMultiplayerModeAdapter

	var terrain_runtime: TerrainRuntimeStub = null

	func bind_runtime(runtime_instance: CombatRuntimeBase) -> void:
		super.bind_runtime(runtime_instance)
		terrain_runtime = runtime_instance as TerrainRuntimeStub

	func supports_terrain_state() -> bool:
		return (
			terrain_runtime != null
			and terrain_runtime.supports_multiplayer_terrain_state()
		)

	func apply_remote_terrain_snapshot(
		revision: int,
		cell_xy: PackedInt32Array,
		terrain_types: PackedInt32Array
	) -> bool:
		return (
			terrain_runtime != null
			and terrain_runtime.apply_remote_terrain_snapshot(
				revision,
				cell_xy,
				terrain_types
			)
		)

	func apply_remote_terrain_delta(
		revision: int,
		cell_xy: PackedInt32Array,
		terrain_types: PackedInt32Array
	) -> bool:
		return (
			terrain_runtime != null
			and terrain_runtime.apply_remote_terrain_delta(
				revision,
				cell_xy,
				terrain_types
			)
		)


class CapturingTowerWorldCoordinator:
	extends "res://scene/game_modes/tower_defense/multiplayer/world/mp_tower_world_coordinator.gd"

	var repair_request_count := 0
	var bamboo_batches: Array[Array] = []

	func start_capture() -> void:
		if not terrain_snapshot_request_to_host.is_connected(
			_capture_terrain_snapshot_request
		):
			terrain_snapshot_request_to_host.connect(
				_capture_terrain_snapshot_request
			)
		if not bamboo_mortar_visual_batch_broadcast_requested.is_connected(
			_capture_bamboo_batch
		):
			bamboo_mortar_visual_batch_broadcast_requested.connect(
				_capture_bamboo_batch
			)

	func _capture_terrain_snapshot_request(_known_revision: int) -> void:
		repair_request_count += 1

	func _capture_bamboo_batch(
		plant_net_ids: PackedInt32Array,
		action_ids: PackedInt32Array,
		stages: PackedByteArray,
		spawn_positions: PackedVector2Array,
		landing_positions: PackedVector2Array,
		windup_durations: PackedFloat32Array,
		host_times: PackedFloat64Array
	) -> void:
		bamboo_batches.append([
			plant_net_ids,
			action_ids,
			stages,
			spawn_positions,
			landing_positions,
			windup_durations,
			host_times,
		])


class ProjectileRuntimeStub:
	extends CombatRuntimeBase

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


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if OS.get_cmdline_user_args().has(PLAYER_SNAPSHOT_ONLY_ARG):
		_test_channel_contract()
		_test_v25_high_value_player_snapshot_contract()
		_test_player_codec_and_reuse()
		if failures.is_empty():
			print("PROTOCOL_V78_PLAYER_SNAPSHOT_SMOKE_TEST_OK")
			quit()
			return
		for failure in failures:
			push_error(failure)
		quit(1)
		return
	_test_channel_contract()
	_test_v25_high_value_player_snapshot_contract()
	_test_terrain_payload_contract()
	_test_terrain_delta_revision_repair_contract()
	_test_terrain_snapshot_repair_watchdog_contract()
	_test_bamboo_mortar_payload_contract()
	_test_corn_burst_payload_contract()
	_test_xiaocong_vote_payload_contract()
	_test_projectile_id_codec_contract()
	_test_projectile_origin_lane_runtime_contract()
	_test_linglan_skill1_ring_payload_contract()
	_test_runtime_state_send_order()
	_test_plant_removal_restore_order()
	_test_player_codec_and_reuse()
	_test_shared_snapshot_cohort_lifecycle()
	_test_enemy_codec_reuse_and_packet_budget()
	if failures.is_empty():
		print("PROTOCOL_V78_SNAPSHOT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_channel_contract() -> void:
	_expect(NetConstants.PROTOCOL_VERSION == 78, "Protocol must be v78.")
	_expect(
		Enemy.NETWORK_VISUAL_STATUS_MASK == 0x7f,
		"Protocol v78 must retain scene-specific bits 5..6 for shield stages, ninja boost, and main-battle airborne visuals."
	)
	_expect(
		NetConstants.NETWORK_COMBAT_VALUE_MIN == 0
		and NetConstants.NETWORK_COMBAT_VALUE_MAX == 0x7FFFFFFF,
		"Fixed-width network combat values must use the signed-int32 nonnegative range."
	)
	_expect(NetConstants.CHANNEL_COUNT == 8, "ENet must provision eight channels.")
	_expect(NetConstants.MAX_PLAYERS == 8, "Protocol capacity must accept an eight-player roster.")
	_expect(
		NetConstants.CH_AUTH == 0
		and NetConstants.CH_INPUT == 1
		and NetConstants.CH_PLAYER_STATE == 2
		and NetConstants.CH_ENEMY_STATE == 3
		and NetConstants.CH_PROJECTILE == 4
		and NetConstants.CH_WORLD_EVENT == 5
		and NetConstants.CH_TRANSACTION == 6
		and NetConstants.CH_FEEDBACK == 7,
		"Protocol v78 channel assignments must remain stable."
	)


func _test_xiaocong_vote_payload_contract() -> void:
	var mp_game := MpGameScript.new()
	var registered_buff_id := TowerDefenseFateRegistry.BUFF_PLAYER_REGENERATION
	_expect(
		mp_game._is_valid_xiaocong_vote_payload(
			TowerDefenseFateRegistry.OPTION_PERMANENT_CONTRACT,
			registered_buff_id
		),
		"Permanent-contract payloads must accept a registered global buff."
	)
	_expect(
		not mp_game._is_valid_xiaocong_vote_payload(
			TowerDefenseFateRegistry.OPTION_PERMANENT_CONTRACT,
			StringName()
		),
		"Permanent-contract payloads must reject an empty global buff."
	)
	_expect(
		mp_game._is_valid_xiaocong_vote_payload(
			TowerDefenseFateRegistry.OPTION_CRITICAL_CORE,
			StringName()
		),
		"The first critical-core vote must keep using an empty buff payload."
	)
	_expect(
		mp_game._is_valid_xiaocong_vote_payload(
			TowerDefenseFateRegistry.OPTION_CRITICAL_CORE,
			registered_buff_id
		),
		"The second critical-core vote must accept a registered global buff."
	)
	_expect(
		not mp_game._is_valid_xiaocong_vote_payload(
			TowerDefenseFateRegistry.OPTION_CRITICAL_CORE,
			&"unregistered_buff"
		),
		"Critical-core payloads must reject an unregistered global buff."
	)
	_expect(
		not mp_game._is_valid_xiaocong_vote_payload(
			TowerDefenseFateRegistry.OPTION_BASE_REBUILD,
			registered_buff_id
		),
		"Options without a buff stage must reject non-empty buff payloads."
	)
	mp_game.free()


func _test_v25_high_value_player_snapshot_contract() -> void:
	var health_boundaries: Array[int] = [
		32767,
		32768,
		65535,
		100000,
		NetConstants.NETWORK_COMBAT_VALUE_MAX,
	]
	for health_value in health_boundaries:
		var state := SnapshotManager.PlayerState.new()
		state.peer_id = 2
		state.sequence = health_boundaries.find(health_value) + 1
		state.position = Vector2(8192.0, 8192.0)
		state.current_health = health_value
		state.max_health = health_value
		var packet := SnapshotManager.new().encode_all_player_snapshots([state])
		var decoded := SnapshotManager.decode_all_player_snapshots(packet)
		_expect(
			decoded.size() == 1
			and decoded[0].current_health == health_value
			and decoded[0].max_health == health_value,
			"Player health %d must round-trip as signed int32." % health_value
		)
		_expect(
			decoded.size() == 1
			and decoded[0].position == Vector2(8192.0, 8192.0),
			"Xiaocong-room player positions must round-trip without int16 saturation."
		)

	var full_roster: Array[SnapshotManager.PlayerState] = []
	for peer_id in range(1, NetConstants.MAX_PLAYERS + 1):
		var roster_state := SnapshotManager.PlayerState.new()
		roster_state.peer_id = peer_id
		roster_state.sequence = 1
		roster_state.position = Vector2(8192.0 + peer_id, 8192.0 - peer_id)
		roster_state.current_health = 100000
		roster_state.max_health = 100000
		full_roster.append(roster_state)
	var full_packet := SnapshotManager.new().encode_all_player_snapshots(full_roster)
	_expect(
		full_packet.size() == 561,
		"Eight full v56 player snapshots must use exactly 561 bytes. actual=%d"
		% full_packet.size()
	)

	var invalid_negative := SnapshotManager.PlayerState.new()
	invalid_negative.current_health = -1
	invalid_negative.max_health = 100
	var invalid_overflow := SnapshotManager.PlayerState.new()
	invalid_overflow.current_health = 100
	invalid_overflow.max_health = NetConstants.NETWORK_COMBAT_VALUE_MAX + 1
	_expect(
		not SnapshotManager.is_player_snapshot_state_serializable(invalid_negative)
		and not SnapshotManager.is_player_snapshot_state_serializable(invalid_overflow),
		"Player snapshot serialization must reject negative and signed-int32-overflow health."
	)
	var invalid_enemy := SnapshotManager.EnemyState.new()
	invalid_enemy.health = NetConstants.NETWORK_COMBAT_VALUE_MAX + 1
	_expect(
		not SnapshotManager.is_enemy_snapshot_state_serializable(invalid_enemy),
		"Enemy snapshot serialization must reject signed-int32-overflow health."
	)


func _test_terrain_delta_revision_repair_contract() -> void:
	var mp_game := MpGameScript.new()
	var runtime := TerrainRuntimeStub.new()
	var net_stub := TerrainClientNetManagerStub.new()
	mp_game.game = runtime
	mp_game.net_manager = net_stub
	var world := _bind_tower_world_fixture(mp_game, runtime, net_stub)
	var cell_xy := PackedInt32Array([4, 7])
	var grass := PackedInt32Array([2])
	var dirt := PackedInt32Array([1])

	world.receive_terrain_delta(1, cell_xy, grass)
	_expect(
		world.repair_request_count == 1
		and runtime.delta_revisions.is_empty()
		and int(world.get("_client_terrain_revision")) == -1,
		"A delta before the first snapshot must request repair without mutating terrain."
	)

	world.receive_terrain_snapshot_chunk(1, 5, 0, 1, cell_xy, grass)
	_expect(
		runtime.snapshot_revisions == [5]
		and bool(world.get("_client_has_terrain_snapshot"))
		and not bool(world.get("_client_waiting_for_terrain_snapshot"))
		and int(world.get("_client_terrain_revision")) == 5,
		"A complete snapshot must apply atomically and establish the client revision."
	)

	world.receive_terrain_delta(5, cell_xy, dirt)
	_expect(
		runtime.delta_revisions.is_empty()
		and world.repair_request_count == 1,
		"A stale or duplicate terrain delta must be ignored without requesting repair."
	)
	world.receive_terrain_delta(7, cell_xy, dirt)
	world.receive_terrain_delta(6, cell_xy, dirt)
	_expect(
		runtime.delta_revisions.is_empty()
		and world.repair_request_count == 2
		and bool(world.get("_client_waiting_for_terrain_snapshot"))
		and int(world.get("_client_terrain_revision")) == 5,
		"A revision gap must request one repair and reject later deltas while waiting."
	)

	world.receive_terrain_snapshot_chunk(2, 7, 0, 1, cell_xy, dirt)
	world.receive_terrain_delta(8, cell_xy, grass)
	_expect(
		runtime.snapshot_revisions == [5, 7]
		and runtime.delta_revisions == [8]
		and int(world.get("_client_terrain_revision")) == 8,
		"After repair, exactly the next revision must apply once and advance the client."
	)

	runtime.accept_delta = false
	world.receive_terrain_delta(9, cell_xy, dirt)
	_expect(
		runtime.delta_revisions == [8]
		and world.repair_request_count == 3
		and int(world.get("_client_terrain_revision")) == 8,
		"A runtime-rejected delta must preserve the prior revision and request repair."
	)
	mp_game.free()
	runtime.free()
	net_stub.free()


func _test_terrain_snapshot_repair_watchdog_contract() -> void:
	var mp_game := MpGameScript.new()
	var runtime := TerrainRuntimeStub.new()
	var net_stub := TerrainClientNetManagerStub.new()
	mp_game.game = runtime
	mp_game.net_manager = net_stub
	var world := _bind_tower_world_fixture(mp_game, runtime, net_stub)

	world.call("_request_terrain_snapshot_repair")
	world.call("_request_terrain_snapshot_repair")
	_expect(
		world.repair_request_count == 1
		and bool(world.get("_client_waiting_for_terrain_snapshot")),
		"Terrain repair must send one request while a snapshot is already pending."
	)
	world.update_client(1.99)
	_expect(
		world.repair_request_count == 1,
		"Terrain repair watchdog must not retry before its conservative timeout."
	)
	world.update_client(0.02)
	_expect(
		world.repair_request_count == 2,
		"Terrain repair watchdog must retry a silent or Host-rate-limited request."
	)
	for _frame_index in range(60):
		world.update_client(1.0 / 60.0)
	_expect(
		world.repair_request_count == 2,
		"Terrain repair watchdog must not create a per-frame request storm."
	)

	var first_chunk_xy := PackedInt32Array()
	var first_chunk_types := PackedInt32Array()
	for cell_x in range(96):
		first_chunk_xy.append(cell_x)
		first_chunk_xy.append(0)
		first_chunk_types.append(1)
	world.receive_terrain_snapshot_chunk(
		41,
		0,
		0,
		2,
		first_chunk_xy,
		first_chunk_types
	)
	world.update_client(1.99)
	_expect(
		world.repair_request_count == 2,
		"Every valid terrain chunk must rearm the watchdog while assembly progresses."
	)
	world.update_client(0.02)
	_expect(
		world.repair_request_count == 3
		and (world.get("_pending_terrain_snapshot_batches") as Dictionary).is_empty(),
		"A stalled partial terrain snapshot must be discarded before retrying."
	)

	world.receive_terrain_snapshot_chunk(
		42,
		0,
		0,
		2,
		first_chunk_xy,
		first_chunk_types
	)
	world.update_client(1.5)
	var last_chunk_xy := PackedInt32Array([96, 0])
	var last_chunk_types := PackedInt32Array([1])
	world.receive_terrain_snapshot_chunk(
		42,
		0,
		1,
		2,
		last_chunk_xy,
		last_chunk_types
	)
	_expect(
		runtime.snapshot_revisions == [0]
		and not bool(world.get("_client_waiting_for_terrain_snapshot"))
		and is_zero_approx(float(world.get(
			"_terrain_snapshot_repair_watchdog_time_left"
		))),
		"A complete terrain snapshot must cancel the repair watchdog."
	)
	world.update_client(10.0)
	_expect(
		world.repair_request_count == 3,
		"A completed terrain snapshot must not trigger a later watchdog retry."
	)
	mp_game.free()
	runtime.free()
	net_stub.free()


func _bind_tower_world_fixture(
	mp_game: MultiplayerGameplaySession,
	runtime: TerrainRuntimeStub,
	net_manager: NetManagerStore
) -> CapturingTowerWorldCoordinator:
	var tower_adapter := TerrainTowerModeAdapter.new()
	tower_adapter.name = "MultiplayerModeAdapter"
	mp_game.add_child(tower_adapter)
	tower_adapter.bind_runtime(runtime)
	tower_adapter.attach_multiplayer_session(mp_game)
	runtime.multiplayer_mode_adapter = tower_adapter
	mp_game.set("_mode_adapter", tower_adapter)
	mp_game.set("tower_mode_adapter", tower_adapter)
	# 世界协调器的绑定边界要求依赖身份完整；这些节点只提供本用例不会触及的端口。
	var session_coordinator := MpSessionCoordinator.new()
	var transactions := MpTransactionsCoordinator.new()
	var enemy_coordinator := MpEnemyCoordinator.new()
	var tower_economy := MpTowerEconomyCoordinator.new()
	var world := CapturingTowerWorldCoordinator.new()
	for child in [
		session_coordinator,
		transactions,
		enemy_coordinator,
		tower_economy,
		world,
	]:
		mp_game.add_child(child)
	world.start_capture()
	world.bind_session(
		mp_game,
		session_coordinator,
		runtime,
		tower_adapter,
		net_manager,
		transactions,
		enemy_coordinator,
		tower_economy
	)
	mp_game.set("tower_world_coordinator", world)
	return world


func _test_player_codec_and_reuse() -> void:
	var sender := SnapshotManager.new()
	var receiver := SnapshotManager.new()
	var state := SnapshotManager.PlayerState.new()
	state.peer_id = 2
	state.sequence = 1
	state.character_id = &"tiyi"
	state.position = Vector2(12.3, -45.6)
	state.velocity = Vector2(2.0, -3.0)
	state.current_health = 48
	state.max_health = 50
	state.ammo_capacity = 7
	state.current_ammo = 4
	state.effective_move_speed_multiplier = 1.375
	var keyframe := sender.encode_player_snapshots_for_peer(8, [state], true)
	var decoded_keyframe := receiver.decode_player_snapshots_with_baseline(keyframe)
	_expect(decoded_keyframe.size() == 1, "Player keyframe must decode.")
	if decoded_keyframe.is_empty():
		return
	_expect(
		absf(decoded_keyframe[0].effective_move_speed_multiplier - 1.375) <= 0.001,
		"Authoritative movement multiplier must round-trip at 0.001 precision."
	)
	state.sequence = 2
	state.character_id = &"tango"
	state.position.x += 1.0
	var delta := sender.encode_player_snapshots_for_peer(8, [state], false)
	var decoded_delta := receiver.decode_player_snapshots_with_baseline(delta)
	_expect(
		decoded_delta.size() == 1
		and is_same(decoded_keyframe[0], decoded_delta[0])
		and decoded_delta[0].character_id == &"tango"
		and decoded_delta[0].position.distance_to(state.position) <= 0.11,
		"Tango's character code must round-trip while the player delta reuses its baseline object."
	)
	receiver.reset_delta_cache()
	_expect(
		receiver.player_receive_baselines.is_empty()
		and receiver.player_receive_output_states.is_empty(),
		"Player reset must release baseline and output-object caches."
	)


func _test_shared_snapshot_cohort_lifecycle() -> void:
	const cohort_id := -1
	var sender := SnapshotManager.new()
	var player_state := SnapshotManager.PlayerState.new()
	player_state.peer_id = 2
	player_state.sequence = 1
	player_state.position = Vector2(8.0, 12.0)
	player_state.velocity = Vector2.RIGHT * 4.0
	player_state.current_health = 90
	player_state.max_health = 100
	var keyframe := sender.encode_player_snapshots_for_cohort(
		cohort_id,
		[player_state],
		true
	)
	var receivers: Array[SnapshotManager] = []
	for _peer_index in range(3):
		var receiver := SnapshotManager.new()
		receivers.append(receiver)
		var decoded := receiver.decode_player_snapshots_with_baseline(keyframe)
		_expect(
			decoded.size() == 1
			and decoded[0].peer_id == player_state.peer_id
			and decoded[0].position.distance_to(player_state.position) <= 0.11,
			"Every member must decode the same shared player keyframe."
		)
	player_state.sequence = 2
	player_state.position += Vector2(3.0, -2.0)
	var delta := sender.encode_player_snapshots_for_cohort(
		cohort_id,
		[player_state],
		false
	)
	for receiver in receivers:
		var decoded := receiver.decode_player_snapshots_with_baseline(delta)
		_expect(
			decoded.size() == 1
			and decoded[0].position.distance_to(player_state.position) <= 0.11,
			"Every member must restore an identical delta from the shared baseline."
		)
	_expect(
		sender.player_send_baselines_by_peer.size() == 1
		and sender.player_send_baselines_by_peer.has(cohort_id),
		"One shared cohort must retain one player baseline instead of one per member."
	)

	var player_coordinator := MpPlayerCoordinator.new()
	var enemy_coordinator := MpEnemyCoordinator.new()
	var cohort_peers := player_coordinator.get("_snapshot_cohort_peers") as Dictionary
	var keyframe_times := (
		player_coordinator.get("_last_keyframe_time_by_peer") as Dictionary
	)
	var ready_peers: Array[int] = [2, 3, 4]
	player_coordinator.call(
		"_commit_snapshot_cohort_send",
		ready_peers,
		0.0,
		true
	)
	var player_snapshot_mgr := (
		player_coordinator.get("_snapshot_manager") as SnapshotManager
	)
	var enemy_snapshot_mgr := (
		enemy_coordinator.get("_snapshot_manager") as SnapshotManager
	)
	player_snapshot_mgr.encode_player_snapshots_for_cohort(
		cohort_id,
		[player_state],
		true
	)
	var enemy_state := SnapshotManager.EnemyState.new()
	enemy_state.net_id = 11
	enemy_state.position = Vector2(20.0, 30.0)
	enemy_snapshot_mgr.encode_enemy_snapshot_range_for_cohort(
		cohort_id,
		[enemy_state],
		0,
		1,
		true
	)
	var enemy_cohort_peers := (
		enemy_coordinator.get("_snapshot_cohort_peers") as Dictionary
	)
	var enemy_keyframe_times := (
		enemy_coordinator.get("_last_keyframe_time_by_peer") as Dictionary
	)
	enemy_coordinator.call(
		"_commit_snapshot_cohort_send",
		ready_peers,
		0.0,
		true
	)

	var temporarily_ready: Array[int] = [2, 4]
	player_coordinator.sync_snapshot_cohort_readiness(temporarily_ready)
	enemy_coordinator.sync_snapshot_cohort_readiness(temporarily_ready)
	_expect(
		cohort_peers.size() == 2
		and cohort_peers.has(2)
		and cohort_peers.has(4)
		and not cohort_peers.has(3)
		and not keyframe_times.has(3),
		"A send-unready peer must detach immediately without disturbing ready members."
	)
	_expect(
		not bool(player_coordinator.call(
			"_snapshot_cohort_requires_keyframe",
			temporarily_ready,
			0.25
		)),
		"The remaining continuously-ready members must keep using their shared delta."
	)
	var same_size_replacement: Array[int] = [2, 5]
	_expect(
		bool(player_coordinator.call(
			"_snapshot_cohort_requires_keyframe",
			same_size_replacement,
			0.25
		)),
		"Replacing one member must force a keyframe even when cohort size is unchanged."
	)
	_expect(
		bool(player_coordinator.call(
			"_snapshot_cohort_requires_keyframe",
			ready_peers,
			0.25
		)),
		"A recovered peer must force a full frame before rejoining the cohort."
	)
	player_coordinator.call(
		"_commit_snapshot_cohort_send",
		ready_peers,
		0.25,
		true
	)
	_expect(
		cohort_peers.size() == 3
		and is_equal_approx(float(keyframe_times.get(3, -1.0)), 0.25),
		"A shared recovery keyframe must atomically readmit every ready member."
	)
	_expect(
		bool(player_coordinator.call(
			"_snapshot_cohort_requires_keyframe",
			ready_peers,
			0.75
		)),
		"A stable cohort must still emit its periodic 0.5-second keyframe."
	)

	player_coordinator.clear_peer(3)
	enemy_coordinator.clear_peer(3)
	_expect(
		not cohort_peers.has(3)
		and not enemy_cohort_peers.has(3)
		and not keyframe_times.has(3)
		and not enemy_keyframe_times.has(3)
		and player_snapshot_mgr.player_send_baselines_by_peer.has(cohort_id)
		and enemy_snapshot_mgr.enemy_send_baselines_by_peer.has(cohort_id),
		"Disconnect cleanup must detach one member while preserving a live shared baseline."
	)
	var no_ready_peers: Array[int] = []
	player_coordinator.sync_snapshot_cohort_readiness(no_ready_peers)
	enemy_coordinator.sync_snapshot_cohort_readiness(no_ready_peers)
	_expect(
		cohort_peers.is_empty()
		and enemy_cohort_peers.is_empty()
		and not player_snapshot_mgr.player_send_baselines_by_peer.has(cohort_id)
		and not enemy_snapshot_mgr.enemy_send_baselines_by_peer.has(cohort_id),
		"An empty cohort must release both shared send baselines."
	)
	var empty_enemy_packet := enemy_snapshot_mgr.encode_enemy_snapshot_range_for_cohort(
		cohort_id,
		[],
		0,
		0,
		true
	)
	_expect(
		empty_enemy_packet.size() == 2
		and SnapshotManager.decode_all_enemy_snapshots(empty_enemy_packet).is_empty(),
		"An empty enemy cohort frame must remain a valid zero-roster packet."
	)
	player_coordinator.free()
	enemy_coordinator.free()


func _test_terrain_payload_contract() -> void:
	var world := MpTowerWorldCoordinatorScript.new()
	var cell_xy := PackedInt32Array([0, 0, 1, -2, 5, 7])
	var terrain_types := PackedInt32Array([-1, 1, 2])
	_expect(
		bool(world.call("_is_valid_terrain_payload", cell_xy, terrain_types, 96)),
		"Terrain payloads must preserve EMPTY=-1 alongside grass and dirt."
	)
	_expect(
		not bool(world.call(
			"_is_valid_terrain_payload",
			PackedInt32Array([0, 0, 0, 0]),
			PackedInt32Array([1, 2]),
			96
		)),
		"Terrain payloads must reject duplicate coordinates."
	)
	var maximum_cell_xy := PackedInt32Array()
	var maximum_types := PackedInt32Array()
	for cell_index in range(97):
		maximum_cell_xy.append(cell_index)
		maximum_cell_xy.append(0)
		maximum_types.append(1)
	_expect(
		not bool(world.call(
			"_is_valid_terrain_payload",
			maximum_cell_xy,
			maximum_types,
			96
		)),
		"Terrain chunks must reject a 97th cell."
	)
	world.free()


func _test_bamboo_mortar_payload_contract() -> void:
	var mp_game := MpGameScript.new()
	var world := MpTowerWorldCoordinatorScript.new()
	_expect(
		int(mp_game.call(
			"_get_rpc_traffic_channel",
			&"net_bamboo_mortar_visual_batch"
		)) == NetConstants.CH_WORLD_EVENT,
		"Bamboo mortar visual traffic must share ordered CH_WORLD_EVENT with plant lifecycle."
	)
	var mp_game_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_game.gd"
	)
	var world_source := FileAccess.get_file_as_string(
		MP_TOWER_WORLD_COORDINATOR_PATH
	)
	_expect(
		world_source.contains(
			"const BAMBOO_MORTAR_VISUAL_FLUSH_INTERVAL_SECONDS := 0.05"
		)
		and world_source.contains(
			"const BAMBOO_MORTAR_VISUAL_MAX_RECORDS_PER_PACKET := 24"
		)
		and mp_game_source.contains(
			'@rpc("authority", "call_remote", "reliable", 5)\nfunc net_bamboo_mortar_visual_batch'
		),
		"Bamboo mortar visuals must flush every 0.05 seconds in reliable CH_WORLD_EVENT packets of at most 24."
	)
	var removal_function_index := world_source.find(
		"func _on_host_plant_removed"
	)
	var removal_flush_index := world_source.find(
		"_flush_bamboo_mortar_visuals()",
		removal_function_index
	)
	var removal_rpc_index := world_source.find(
		'&"net_plant_removed"',
		removal_function_index
	)
	_expect(
		removal_function_index >= 0
		and removal_flush_index > removal_function_index
		and removal_rpc_index > removal_flush_index,
		"Host must flush Bamboo visual records before sending plant removal on the same ordered channel."
	)
	_expect(
		bool(world.call(
			"_is_valid_bamboo_mortar_visual_payload",
			PackedInt32Array([11, 12]),
			PackedInt32Array([21, 22]),
			PackedByteArray([0, 1]),
			PackedVector2Array([
				Vector2(1.0, 2.0),
				Vector2(3.0, 4.0),
			]),
			PackedVector2Array([
				Vector2(80.0, 0.0),
				Vector2(96.0, 8.0),
			]),
			PackedFloat32Array([4.0, 3.2]),
			PackedFloat64Array([0.0, 1.25])
		)),
		"Bamboo mortar payloads must accept equal-length finite windup/fire records."
	)
	_expect(
		not bool(world.call(
			"_is_valid_bamboo_mortar_visual_payload",
			PackedInt32Array([11, 12]),
			PackedInt32Array([21]),
			PackedByteArray([0, 1]),
			PackedVector2Array([Vector2.ZERO, Vector2.ZERO]),
			PackedVector2Array([Vector2.ZERO, Vector2.ZERO]),
			PackedFloat32Array([4.0, 4.0]),
			PackedFloat64Array([0.0, 1.25])
		))
		and not bool(world.call(
			"_is_valid_bamboo_mortar_visual_payload",
			PackedInt32Array([11]),
			PackedInt32Array([21]),
			PackedByteArray([2]),
			PackedVector2Array([Vector2.ZERO]),
			PackedVector2Array([Vector2.ZERO]),
			PackedFloat32Array([4.0]),
			PackedFloat64Array([0.0])
		))
		and not bool(world.call(
			"_is_valid_bamboo_mortar_visual_payload",
			PackedInt32Array([11]),
			PackedInt32Array([21]),
			PackedByteArray([1]),
			PackedVector2Array([Vector2(NAN, 0.0)]),
			PackedVector2Array([Vector2.ZERO]),
			PackedFloat32Array([4.0]),
			PackedFloat64Array([0.0])
		))
		and not bool(world.call(
			"_is_valid_bamboo_mortar_visual_payload",
			PackedInt32Array([11]),
			PackedInt32Array([21]),
			PackedByteArray([0]),
			PackedVector2Array([Vector2.ZERO]),
			PackedVector2Array([Vector2.ZERO]),
			PackedFloat32Array([0.0]),
			PackedFloat64Array([0.0])
		)),
		"Bamboo mortar payloads must reject mismatched, unknown, non-finite, or invalid-duration records."
	)
	var oversized_ids := PackedInt32Array()
	var oversized_actions := PackedInt32Array()
	var oversized_stages := PackedByteArray()
	var oversized_spawns := PackedVector2Array()
	var oversized_landings := PackedVector2Array()
	var oversized_windup_durations := PackedFloat32Array()
	var oversized_times := PackedFloat64Array()
	for record_index in range(25):
		oversized_ids.append(record_index + 1)
		oversized_actions.append(record_index + 1)
		oversized_stages.append(record_index % 2)
		oversized_spawns.append(Vector2.ZERO)
		oversized_landings.append(Vector2(96.0, 0.0))
		oversized_windup_durations.append(4.0)
		oversized_times.append(float(record_index))
	_expect(
		not bool(world.call(
			"_is_valid_bamboo_mortar_visual_payload",
			oversized_ids,
			oversized_actions,
			oversized_stages,
			oversized_spawns,
			oversized_landings,
			oversized_windup_durations,
			oversized_times
		)),
		"Bamboo mortar visual packets must reject a 25th record."
	)
	_expect(
		world_source.contains('"windup_elapsed_seconds"')
		and world_source.contains('"projectile_elapsed_seconds"')
		and world_source.contains("+ sample_age"),
		"Plant runtime repair must add network sample age to bamboo windup and projectile visual progress."
	)
	var recorder := CapturingTowerWorldCoordinator.new()
	recorder.start_capture()
	var record_count := 300
	var plant_ids := PackedInt32Array()
	var action_ids := PackedInt32Array()
	var stages := PackedByteArray()
	var spawn_positions := PackedVector2Array()
	var landing_positions := PackedVector2Array()
	var windup_durations := PackedFloat32Array()
	var host_times := PackedFloat64Array()
	for record_index in range(record_count):
		plant_ids.append(record_index + 1)
		action_ids.append(record_index + 101)
		stages.append(record_index % 2)
		spawn_positions.append(Vector2(record_index, 0.0))
		landing_positions.append(Vector2(96.0, record_index))
		windup_durations.append(3.2 if record_index % 2 == 0 else 4.0)
		host_times.append(float(record_index))
	recorder.set("_pending_bamboo_mortar_visuals", plant_ids)
	recorder.set("_pending_bamboo_mortar_action_ids", action_ids)
	recorder.set("_pending_bamboo_mortar_stages", stages)
	recorder.set("_pending_bamboo_mortar_spawn_positions", spawn_positions)
	recorder.set("_pending_bamboo_mortar_landing_positions", landing_positions)
	recorder.set("_pending_bamboo_mortar_windup_durations", windup_durations)
	recorder.set("_pending_bamboo_mortar_host_times", host_times)
	recorder.call("_flush_bamboo_mortar_visuals")
	var first_args: Array = (
		recorder.bamboo_batches[0]
		if recorder.bamboo_batches.size() >= 1
		else []
	)
	var last_args: Array = (
		recorder.bamboo_batches.back()
		if not recorder.bamboo_batches.is_empty()
		else []
	)
	_expect(
		recorder.bamboo_batches.size() == 13
		and first_args.size() == 7
		and last_args.size() == 7
		and (first_args[0] as PackedInt32Array).size() == 24
		and (last_args[0] as PackedInt32Array).size() == 12
		and (
			recorder.get("_pending_bamboo_mortar_visuals")
			as PackedInt32Array
		).is_empty(),
		"Bamboo visual flush must split 300 records into thirteen ordered packets and clear the queue."
	)
	recorder.free()
	world.free()
	mp_game.free()


func _test_corn_burst_payload_contract() -> void:
	var mp_game := MpGameScript.new()
	var world := MpTowerWorldCoordinatorScript.new()
	_expect(
		int(mp_game.call(
			"_get_rpc_traffic_channel",
			&"net_corn_machine_gun_burst_batch"
		)) == NetConstants.CH_PROJECTILE,
		"Corn burst traffic metrics must be attributed to CH_PROJECTILE."
	)
	var world_source := FileAccess.get_file_as_string(
		MP_TOWER_WORLD_COORDINATOR_PATH
	)
	_expect(
		world_source.contains(
			"const CORN_MACHINE_GUN_BURST_FLUSH_INTERVAL_SECONDS := 0.05"
		)
		and world_source.contains(
			"const CORN_MACHINE_GUN_BURST_MAX_RECORDS_PER_PACKET := 32"
		),
		"Corn burst visuals must flush every 0.05 seconds in packets of at most 32."
	)
	_expect(
		world_source.contains(
			"_pending_corn_machine_gun_burst_host_times.append(host_action_time)"
		)
		and world_source.contains("_get_remote_action_elapsed("),
		"Corn burst records must carry Host time and map it before client playback."
	)
	_expect(
		bool(world.call(
			"_is_valid_corn_machine_gun_burst_payload",
			PackedInt32Array([11, 12]),
			PackedInt32Array([21, 22]),
			PackedVector2Array([Vector2.RIGHT, Vector2.UP]),
			PackedFloat64Array([0.0, 1.25])
		)),
		"Corn burst payloads must accept equal-length finite records."
	)
	_expect(
		not bool(world.call(
			"_is_valid_corn_machine_gun_burst_payload",
			PackedInt32Array([11, 12]),
			PackedInt32Array([21]),
			PackedVector2Array([Vector2.RIGHT, Vector2.UP]),
			PackedFloat64Array([0.0, 1.25])
		)),
		"Corn burst payloads must reject mismatched packed-array lengths."
	)
	_expect(
		not bool(world.call(
			"_is_valid_corn_machine_gun_burst_payload",
			PackedInt32Array([11]),
			PackedInt32Array([21]),
			PackedVector2Array([Vector2(NAN, 0.0)]),
			PackedFloat64Array([0.0])
		))
		and not bool(world.call(
			"_is_valid_corn_machine_gun_burst_payload",
			PackedInt32Array([11]),
			PackedInt32Array([21]),
			PackedVector2Array([Vector2.RIGHT]),
			PackedFloat64Array([NAN])
		)),
		"Corn burst payloads must reject non-finite directions and Host times."
	)
	var oversized_ids := PackedInt32Array()
	var oversized_actions := PackedInt32Array()
	var oversized_directions := PackedVector2Array()
	var oversized_times := PackedFloat64Array()
	for record_index in range(33):
		oversized_ids.append(record_index + 1)
		oversized_actions.append(record_index + 1)
		oversized_directions.append(Vector2.RIGHT)
		oversized_times.append(float(record_index))
	_expect(
		not bool(world.call(
			"_is_valid_corn_machine_gun_burst_payload",
			oversized_ids,
			oversized_actions,
			oversized_directions,
			oversized_times
		)),
		"Corn burst packets must reject a 33rd record."
	)
	world.set(
		"_pending_corn_machine_gun_burst_visuals",
		PackedInt32Array([11])
	)
	world.set(
		"_pending_corn_machine_gun_burst_action_ids",
		PackedInt32Array([21])
	)
	world.set(
		"_pending_corn_machine_gun_burst_directions",
		PackedVector2Array([Vector2.RIGHT])
	)
	world.set(
		"_pending_corn_machine_gun_burst_host_times",
		PackedFloat64Array([0.0])
	)
	world.reset_session_state()
	_expect(
		(world.get("_pending_corn_machine_gun_burst_visuals") as PackedInt32Array).is_empty()
		and (
			world.get("_pending_corn_machine_gun_burst_action_ids")
			as PackedInt32Array
		).is_empty()
		and (
			world.get("_pending_corn_machine_gun_burst_directions")
			as PackedVector2Array
		).is_empty()
		and (
			world.get("_pending_corn_machine_gun_burst_host_times")
			as PackedFloat64Array
		).is_empty(),
		"World session teardown must discard every packed column of queued corn burst visuals."
	)
	world.free()
	mp_game.free()


func _test_linglan_skill1_ring_payload_contract() -> void:
	var mp_game := MpGameScript.new()
	var first_projectile_id := MpProjectileCoordinator.encode_projectile_id(
		1,
		PROJECTILE_HOST_ORIGIN_BIT | 1000000
	)
	var second_projectile_id := MpProjectileCoordinator.encode_projectile_id(
		1,
		PROJECTILE_HOST_ORIGIN_BIT | 1000001
	)
	var projectile_ids := PackedInt64Array([first_projectile_id, second_projectile_id])
	var spawn_positions := PackedVector2Array([Vector2(10.0, 20.0), Vector2(30.0, 40.0)])
	var directions := PackedVector2Array([Vector2.RIGHT, Vector2.UP])
	_expect(
		int(mp_game.call(
			"_get_rpc_traffic_channel",
			&"net_linglan_skill1_ring_batch"
		)) == NetConstants.CH_PROJECTILE,
		"Linglan ring batches must be attributed to CH_PROJECTILE."
	)
	_expect(
		MpProjectileCoordinator.is_valid_linglan_skill1_ring_payload(
			projectile_ids,
			spawn_positions,
			directions,
			1,
			50,
			300.0,
			2.0,
			1.25
		),
		"Linglan ring batches must accept aligned, finite packed columns."
	)
	_expect(
		not MpProjectileCoordinator.is_valid_linglan_skill1_ring_payload(
			PackedInt64Array([first_projectile_id, first_projectile_id]),
			spawn_positions,
			directions,
			1,
			50,
			300.0,
			2.0,
			1.25
		),
		"Linglan ring batches must reject duplicate projectile IDs."
	)
	_expect(
		not MpProjectileCoordinator.is_valid_linglan_skill1_ring_payload(
			PackedInt64Array([
				first_projectile_id,
				MpProjectileCoordinator.encode_projectile_id(
					2,
					PROJECTILE_HOST_ORIGIN_BIT | 1000001
				),
			]),
			spawn_positions,
			directions,
			1,
			50,
			300.0,
			2.0,
			1.25
		),
		"Linglan ring batches must reject an ID encoded for another owner."
	)
	_expect(
		not MpProjectileCoordinator.is_valid_linglan_skill1_ring_payload(
			PackedInt64Array([
				MpProjectileCoordinator.encode_projectile_id(1, 1000000),
				MpProjectileCoordinator.encode_projectile_id(1, 1000001),
			]),
			spawn_positions,
			directions,
			1,
			50,
			300.0,
			2.0,
			1.25
		),
		"Host-authored Linglan batches must reject client-origin projectile IDs."
	)
	var wrapped_host_ids := PackedInt64Array([
		MpProjectileCoordinator.encode_projectile_id(
			1,
			PROJECTILE_HOST_ORIGIN_BIT | PROJECTILE_SEQUENCE_COUNTER_MAX
		),
		MpProjectileCoordinator.encode_projectile_id(
			1,
			PROJECTILE_HOST_ORIGIN_BIT | 1
		),
	])
	_expect(
		wrapped_host_ids[1] < wrapped_host_ids[0]
		and MpProjectileCoordinator.is_valid_linglan_skill1_ring_payload(
			wrapped_host_ids,
			spawn_positions,
			directions,
			1,
			50,
			300.0,
			2.0,
			1.25
		),
		"A valid Host ring must survive the 31-bit counter wrap without relying on monotonic IDs."
	)
	mp_game.free()


func _test_projectile_id_codec_contract() -> void:
	var coordinator := MpProjectileCoordinator.new()
	var below_legacy_boundary := MpProjectileCoordinator.encode_projectile_id(
		2,
		999999
	)
	var at_legacy_boundary := MpProjectileCoordinator.encode_projectile_id(
		2,
		1000000
	)
	var above_legacy_boundary := MpProjectileCoordinator.encode_projectile_id(
		2,
		1000001
	)
	var other_owner_same_sequence := MpProjectileCoordinator.encode_projectile_id(
		3,
		1000000
	)
	var host_same_owner_and_counter := (
		MpProjectileCoordinator.encode_projectile_id(
			2,
			PROJECTILE_HOST_ORIGIN_BIT | 1000000
		)
	)
	_expect(
		below_legacy_boundary > 0
		and at_legacy_boundary > below_legacy_boundary
		and above_legacy_boundary > at_legacy_boundary
		and other_owner_same_sequence != at_legacy_boundary
		and host_same_owner_and_counter != at_legacy_boundary,
		"Projectile IDs must stay unique across the old one-million boundary, owners, and origin lanes."
	)
	for projectile_id in [
		below_legacy_boundary,
		at_legacy_boundary,
		above_legacy_boundary,
	]:
		_expect(
			MpProjectileCoordinator.decode_projectile_owner_peer_id(projectile_id) == 2
			and MpProjectileCoordinator.is_projectile_id_valid_for_owner(
				projectile_id,
				2
			),
			"Cross-boundary projectile IDs must retain owner 2 exactly."
		)
	_expect(
		MpProjectileCoordinator.decode_projectile_sequence(at_legacy_boundary) == 1000000
		and MpProjectileCoordinator.decode_projectile_owner_peer_id(
			other_owner_same_sequence
		) == 3
		and not MpProjectileCoordinator.is_projectile_id_valid_for_owner(
			other_owner_same_sequence,
			2
		),
		"Projectile ID decoding must keep owner and sequence in disjoint bit fields."
	)
	_expect(
		MpProjectileCoordinator.is_projectile_id_valid_for_client_owner(
			at_legacy_boundary,
			2
		)
		and not MpProjectileCoordinator.is_projectile_id_valid_for_client_owner(
			host_same_owner_and_counter,
			2
		)
		and MpProjectileCoordinator.is_projectile_id_valid_for_host_owner(
			host_same_owner_and_counter,
			2
		)
		and not MpProjectileCoordinator.is_projectile_id_valid_for_host_owner(
			at_legacy_boundary,
			2
		)
		and MpProjectileCoordinator.decode_projectile_sequence_counter(
			host_same_owner_and_counter
		) == 1000000,
		"Host and client origin lanes must be disjoint while retaining the same 31-bit counter."
	)
	var signed_int64_max := MpProjectileCoordinator.encode_projectile_id(
		0x7FFFFFFF,
		PROJECTILE_SEQUENCE_MAX
	)
	_expect(
		signed_int64_max == 0x7FFFFFFFFFFFFFFF
		and MpProjectileCoordinator.decode_projectile_owner_peer_id(
			signed_int64_max
		) == 0x7FFFFFFF
		and MpProjectileCoordinator.decode_projectile_sequence(
			signed_int64_max
		) == PROJECTILE_SEQUENCE_MAX,
		"The largest supported owner/sequence pair must remain a positive signed int64."
	)
	_expect(
		MpProjectileCoordinator.encode_projectile_id(0, 1) == 0
		and MpProjectileCoordinator.encode_projectile_id(0x80000000, 1) == 0
		and MpProjectileCoordinator.encode_projectile_id(2, 0) == 0
		and MpProjectileCoordinator.encode_projectile_id(
			2,
			PROJECTILE_SEQUENCE_MAX + 1
		) == 0,
		"Projectile ID encoding must reject zero and signed-overflow fields."
	)
	_expect(
		not MpProjectileCoordinator.is_projectile_id_valid_for_owner(1, 0)
		and not MpProjectileCoordinator.is_projectile_id_valid_for_owner(
			0x7FFFFFFF,
			0
		),
		"Owner zero must never become valid through a hand-crafted low sequence ID."
	)

	var occupied_wrapped_id := MpProjectileCoordinator.encode_projectile_id(2, 1)
	coordinator.remember_projectile_record(
		occupied_wrapped_id,
		2,
		&"player_bullet",
		1,
		INF,
		false,
		0.0
	)
	coordinator.set("_next_projectile_sequence", PROJECTILE_SEQUENCE_COUNTER_MAX)
	var final_sequence_id := coordinator.allocate_projectile_id(2, false)
	var wrapped_sequence_id := coordinator.allocate_projectile_id(2, false)
	_expect(
		MpProjectileCoordinator.decode_projectile_sequence_counter(
			final_sequence_id
		) == PROJECTILE_SEQUENCE_COUNTER_MAX
		and MpProjectileCoordinator.decode_projectile_sequence_counter(
			wrapped_sequence_id
		) == 2,
		"Sequence wrap must skip zero and any still-live/recent wrapped identity."
	)
	coordinator.set("_next_projectile_sequence", 42)
	var client_lane_id := coordinator.allocate_projectile_id(2, false)
	coordinator.set("_next_projectile_sequence", 42)
	var host_lane_id := coordinator.allocate_projectile_id(2, true)
	_expect(
		client_lane_id != host_lane_id
		and MpProjectileCoordinator.decode_projectile_sequence_counter(
			client_lane_id
		) == 42
		and MpProjectileCoordinator.decode_projectile_sequence_counter(
			host_lane_id
		) == 42
		and MpProjectileCoordinator.is_host_origin_projectile_id(host_lane_id)
		and not MpProjectileCoordinator.is_host_origin_projectile_id(client_lane_id),
		"Concurrent Host/client allocation for one owner must use collision-free origin lanes."
	)
	_expect(
		MpProjectileCoordinator.is_projectile_id_valid_for_client_owner(
			client_lane_id,
			2
		)
		and not MpProjectileCoordinator.is_projectile_id_valid_for_client_owner(
			host_lane_id,
			2
		)
		and MpProjectileCoordinator.is_projectile_id_valid_for_host_owner(
			host_lane_id,
			2
		),
		"Origin lanes must remain structurally distinct even though neither lane authorizes a remote enemy-hit claim."
	)
	coordinator.free()


func _test_projectile_origin_lane_runtime_contract() -> void:
	var mp_game := MpGameScript.new()
	var coordinator := MpProjectileCoordinator.new()
	coordinator.name = "ProjectileCoordinator"
	mp_game.add_child(coordinator)
	mp_game.projectile_coordinator = coordinator
	var runtime := _bind_neutral_runtime_fixture(mp_game)
	coordinator.bind_runtime(runtime)
	var client_lane_id := MpProjectileCoordinator.encode_projectile_id(2, 57)
	var host_lane_id := MpProjectileCoordinator.encode_projectile_id(
		2,
		PROJECTILE_HOST_ORIGIN_BIT | 57
	)
	var predicted_bullet := BULLET_SCENE.instantiate() as Bullet
	mp_game.add_child(predicted_bullet)
	coordinator.setup_projectile_network_identity(
		predicted_bullet,
		client_lane_id,
		2,
		&"player_bullet"
	)
	var known_projectiles := coordinator.get("_known_projectiles") as Dictionary
	known_projectiles[client_lane_id] = predicted_bullet
	coordinator.remember_projectile_record(
		client_lane_id,
		2,
		&"player_bullet",
		3,
		2.0,
		false,
		0.0
	)

	# The Host echo for a predicted client-lane shot must update the same node
	# instead of creating a duplicate proxy.
	coordinator.receive_projectile_fired(
		client_lane_id,
		&"player_bullet",
		2,
		Vector2(10.0, 20.0),
		Vector2.UP,
		11,
		222.0,
		1.5,
		false,
		0,
		0,
		0.0,
		0.0
	)
	var reconciled_record := coordinator.get_projectile_record(client_lane_id)
	_expect(
		known_projectiles.size() == 1
		and known_projectiles.get(client_lane_id) == predicted_bullet
		and predicted_bullet.direction.is_equal_approx(Vector2.UP)
		and predicted_bullet.damage == 11
		and is_equal_approx(predicted_bullet.speed, 222.0)
		and int(reconciled_record.get("damage", -1)) == 11,
		"A Host echo must reconcile the existing client prediction in place."
	)

	# A distinct Host-authoritative projectile for the same remote owner and
	# counter must coexist under the Host lane without replacing that prediction.
	coordinator.receive_projectile_fired(
		host_lane_id,
		&"player_bullet",
		2,
		Vector2(30.0, 40.0),
		Vector2.LEFT,
		13,
		180.0,
		1.25,
		false,
		0,
		0,
		0.0,
		0.0
	)
	var host_bullet := known_projectiles.get(host_lane_id) as Bullet
	_expect(
		known_projectiles.size() == 2
		and known_projectiles.get(client_lane_id) == predicted_bullet
		and host_bullet != null
		and host_bullet != predicted_bullet
		and host_bullet.projectile_id == host_lane_id
		and host_bullet.owner_peer_id == 2
		and host_bullet.damage == 13,
		"A Host-lane projectile must coexist with the same owner's client prediction "
		+ "without an ID collision or replacement."
	)
	coordinator.unbind_runtime(runtime)
	mp_game.free()
	runtime.free()


func _bind_neutral_runtime_fixture(
	mp_game: MultiplayerGameplaySession
) -> ProjectileRuntimeStub:
	var runtime := ProjectileRuntimeStub.new()
	var gateway := MultiplayerGameplayGateway.new()
	gateway.name = "MultiplayerGameplayGateway"
	runtime.add_child(gateway)
	gateway.bind_runtime(runtime)
	gateway.attach_multiplayer_session(mp_game)
	runtime.multiplayer_gateway = gateway
	var mode_adapter := MultiplayerModeAdapter.new()
	mode_adapter.name = "MultiplayerModeAdapter"
	runtime.add_child(mode_adapter)
	mode_adapter.bind_runtime(runtime)
	mode_adapter.attach_multiplayer_session(mp_game)
	runtime.multiplayer_mode_adapter = mode_adapter
	mp_game.game = runtime
	mp_game.set("_gameplay_gateway", gateway)
	mp_game.set("_mode_adapter", mode_adapter)
	return runtime


func _test_enemy_codec_reuse_and_packet_budget() -> void:
	var sender := SnapshotManager.new()
	var receiver := SnapshotManager.new()
	var states: Array[SnapshotManager.EnemyState] = []
	for enemy_index in range(46):
		var state := SnapshotManager.EnemyState.new()
		state.net_id = enemy_index + 1
		state.position = Vector2(enemy_index * 2.0, enemy_index * -1.5)
		state.velocity = Vector2(1.0, -1.0)
		state.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_MOVING
		state.health = 100 + enemy_index
		state.health_revision = enemy_index + 3
		# Enemy 1 combines the common low-five status bits with the scene-specific
		# high bits. Shield bearers use them as 10 = critical; v45 ninja robots
		# independently use bit 5 as their boost flag.
		state.visual_status_mask = 0b1011101 if enemy_index == 0 else 0
		states.append(state)
	var keyframe := sender.encode_enemy_snapshots_for_peer(8, states, true)
	_expect(
		keyframe.size() == 1106,
		"A v25 46-enemy keyframe must use 1106 bytes and stay within the 1200-byte budget."
	)
	var decoded_keyframe := receiver.decode_enemy_snapshots_with_baseline(keyframe)
	_expect(decoded_keyframe.size() == 46, "The complete 46-enemy keyframe must decode.")
	if decoded_keyframe.is_empty():
		return
	_expect(
		decoded_keyframe[0].visual_status_mask == 0b1011101
		and decoded_keyframe[0].locomotion_state
			== SnapshotManager.ENEMY_LOCOMOTION_MOVING
		and decoded_keyframe[0].health_revision == 3,
		"Enemy visual status, locomotion and health revision must round-trip in a keyframe."
	)
	states[0].position.x += 2.0
	# Preserve common bits while setting both scene-specific bits. This remains
	# 11 = broken for shield bearers and also proves the v45 ninja bit5 survives.
	states[0].visual_status_mask = 0b1110100
	states[0].locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_IDLE
	var delta := sender.encode_enemy_snapshots_for_peer(8, states, false)
	var decoded_delta := receiver.decode_enemy_snapshots_with_baseline(delta)
	_expect(
		decoded_delta.size() == 46
		and is_same(decoded_keyframe[0], decoded_delta[0])
		and decoded_delta[0].visual_status_mask == 0b1110100
		and decoded_delta[0].locomotion_state
			== SnapshotManager.ENEMY_LOCOMOTION_IDLE,
		"Enemy delta output must reuse objects and update visual and locomotion bits."
	)
	var unchanged_delta := sender.encode_enemy_snapshots_for_peer(8, states, false)
	var decoded_unchanged := receiver.decode_enemy_snapshots_with_baseline(
		unchanged_delta
	)
	_expect(
		decoded_unchanged.size() == 46
		and is_same(decoded_delta[0], decoded_unchanged[0])
		and decoded_unchanged[0].visual_status_mask == 0b1110100,
		"An unchanged delta must retain combined common and shield-stage status bits."
	)
	receiver.prune_enemy_receive_baseline_to_ids({1: true})
	_expect(
		receiver.enemy_receive_baselines.size() == 1
		and receiver.enemy_receive_output_states.size() == 1,
		"Enemy pruning must release stale baseline and output-object entries together."
	)

	var locomotion_sender := SnapshotManager.new()
	var locomotion_receiver := SnapshotManager.new()
	var locomotion_state := SnapshotManager.EnemyState.new()
	locomotion_state.net_id = 99
	locomotion_state.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_MOVING
	var locomotion_keyframe := locomotion_sender.encode_enemy_snapshots_for_peer(
		9,
		[locomotion_state],
		true
	)
	locomotion_receiver.decode_enemy_snapshots_with_baseline(locomotion_keyframe)
	locomotion_state.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_IDLE
	var locomotion_delta := locomotion_sender.encode_enemy_snapshots_for_peer(
		9,
		[locomotion_state],
		false
	)
	var decoded_locomotion_delta := (
		locomotion_receiver.decode_enemy_snapshots_with_baseline(locomotion_delta)
	)
	_expect(
		locomotion_delta.size() == 8
		and decoded_locomotion_delta.size() == 1
		and decoded_locomotion_delta[0].locomotion_state
			== SnapshotManager.ENEMY_LOCOMOTION_IDLE,
		"A locomotion-only enemy delta must use exactly one payload byte and round-trip."
	)


func _test_runtime_state_send_order() -> void:
	var mp_game_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_game.gd"
	)
	var session_source := FileAccess.get_file_as_string(
		MP_SESSION_COORDINATOR_PATH
	)
	var request_start := mp_game_source.find("func net_runtime_state_requested(")
	var request_end := mp_game_source.find("\n\nfunc ", request_start + 1)
	var request_body := (
		mp_game_source.substr(request_start, request_end - request_start)
		if request_start >= 0 and request_end > request_start
		else ""
	)
	var handler_start := mp_game_source.find(
		"func _handle_authoritative_runtime_state_request("
	)
	var handler_end := mp_game_source.find("\n\nfunc ", handler_start + 1)
	var handler_body := (
		mp_game_source.substr(handler_start, handler_end - handler_start)
		if handler_start >= 0 and handler_end > handler_start
		else ""
	)
	var admission_start := session_source.find(
		"func admit_authoritative_runtime_state_request("
	)
	var admission_end := session_source.find("\n\nfunc ", admission_start + 1)
	var admission_body := (
		session_source.substr(admission_start, admission_end - admission_start)
		if admission_start >= 0 and admission_end > admission_start
		else ""
	)
	_expect(
		request_body.contains("multiplayer.get_remote_sender_id()")
		and request_body.contains(
			"_handle_authoritative_runtime_state_request(sender_id"
		)
		and handler_body.contains(
			"session_coordinator.admit_authoritative_runtime_state_request("
		)
		and handler_body.contains("net_manager.is_host()")
		and handler_body.contains("_get_net_time()")
		and handler_body.contains(
			"session_coordinator.send_authoritative_runtime_state_to_peer("
		)
		and admission_body.contains("_consume_runtime_state_request_token(")
		and admission_body.contains("_runtime.get_player_for_peer(sender_id)"),
		"Complete-state repair requests must come from a registered in-game peer."
	)
	var function_start := session_source.find(
		"func send_authoritative_runtime_state_to_peer("
	)
	var function_end := session_source.find("\n\nfunc ", function_start + 1)
	var function_body := (
		session_source.substr(function_start, function_end - function_start)
		if function_start >= 0 and function_end > function_start
		else ""
	)
	var terrain_position := function_body.find(
		"_tower_world_coordinator.request_terrain_snapshot_for_peer"
	)
	var plant_position := function_body.find(
		"runtime_repair_plant_roster_requested.emit"
	)
	var other_position := function_body.find(
		"_enemy_coordinator.send_live_spawn_roster_to_peer"
	)
	var manifest_position := function_body.find("_send_runtime_world_manifest_to_peer")
	_expect(
		terrain_position >= 0
		and plant_position > terrain_position
		and other_position > plant_position
		and manifest_position > other_position,
		"Complete-state repair must send terrain, plants, other state, then the world manifest."
	)


func _test_plant_removal_restore_order() -> void:
	var source := FileAccess.get_file_as_string(TOWER_DEFENSE_PLANT_RUNTIME_PATH)
	var function_start := source.find("func handle_plant_removed(")
	var function_end := source.find("\n\nfunc ", function_start + 1)
	var function_body := (
		source.substr(function_start, function_end - function_start)
		if function_start >= 0 and function_end > function_start
		else ""
	)
	var removal_signal_position := function_body.find("network_plant_removed.emit")
	var cancel_position := function_body.find("vegetation_spread_system.cancel_source")
	_expect(
		removal_signal_position >= 0
		and cancel_position > removal_signal_position,
		"Plant removal must reach reliable CH5 before its terrain-restore delta so clients clear the growth overlay first."
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
