extends SceneTree

const TANGO_SCENE := preload("res://scene/player/tango/player_tango.tscn")
const TANGO_LASER_SCENE := preload(
	"res://scene/player/tango/tango_laser_bullet.tscn"
)


class HostNetManagerStub:
	extends Node

	func is_multiplayer_active() -> bool:
		return true

	func is_host() -> bool:
		return true


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


class PoolRuntime:
	extends Node2D

	var pool: SessionObjectPool = null
	var tracked_peer_id := 0
	var tracked_player: Player = null

	func install_pool() -> void:
		pool = SessionObjectPool.new()
		pool.name = "SessionObjectPool"
		add_child(pool)
		pool.register_scene(TANGO_LASER_SCENE, 9, 32)

	func has_session_object_pool_scene(scene: PackedScene) -> bool:
		return pool != null and pool.is_registered(scene)

	func acquire_session_object(
		scene: PackedScene,
		strict: bool = false
	) -> Node:
		if pool == null or not pool.is_registered(scene):
			return null
		return pool.try_acquire(scene) if strict else pool.acquire(scene)

	func get_player_for_peer(peer_id: int) -> Player:
		return tracked_player if peer_id == tracked_peer_id else null


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var runtime := PoolRuntime.new()
	runtime.name = "TangoLaserNetworkBatchRuntime"
	runtime.install_pool()
	root.add_child(runtime)
	current_scene = runtime

	var owner_peer_id := 7
	var player := TANGO_SCENE.instantiate() as PlayerTango
	runtime.add_child(player)
	await process_frame
	player.set_process(false)
	player.set_physics_process(false)
	runtime.tracked_peer_id = owner_peer_id
	runtime.tracked_player = player

	var spawn_positions := PackedVector2Array([
		Vector2(100, 0),
		Vector2(98, 5),
		Vector2(99, -5),
	])
	var projectiles: Array[Node] = []
	for spawn_position in spawn_positions:
		var bullet := runtime.pool.acquire(TANGO_LASER_SCENE) as TangoLaserBullet
		_expect(bullet != null, "Host fixture must acquire all three Tango bullets.")
		if bullet == null:
			continue
		bullet.setup(Vector2.RIGHT, 15, false)
		bullet.global_position = spawn_position
		projectiles.append(bullet)
	_expect(projectiles.size() == 3, "Host fixture must build one complete volley.")

	var host_mp := RecordingMpGame.new()
	var host_net := HostNetManagerStub.new()
	host_mp.add_child(host_net)
	host_mp.set("net_manager", host_net)
	(host_mp.get("_tango_charge_sequences_by_peer") as Dictionary)[owner_peer_id] = 3
	var ordinary_overflow_rejected := not bool(host_mp.call(
		"register_local_tango_laser_volley",
		projectiles,
		spawn_positions,
		Vector2.RIGHT,
		owner_peer_id,
		15,
		480.0,
		0.722,
		1.0,
		7.5
	))
	_expect(
		ordinary_overflow_rejected and host_mp.sent_methods.is_empty(),
		"非技能弹幕不得借由满充比例突破既有5秒网络上限。"
	)
	(host_mp.get("_active_tango_electric_surges_by_peer") as Dictionary)[owner_peer_id] = {
		"activation_id": 1,
		"charge_sequence": 3,
	}
	var registered := bool(host_mp.call(
		"register_local_tango_laser_volley",
		projectiles,
		spawn_positions,
		Vector2.RIGHT,
		owner_peer_id,
		15,
		480.0,
		0.722,
		1.0,
		7.5
	))
	_expect(
		registered
		and host_mp.sent_methods == [&"net_tango_laser_volley"]
		and host_mp.sent_arguments.size() == 1,
		"Host must register and broadcast one atomic three-laser batch."
	)
	if host_mp.sent_arguments.is_empty():
		await _cleanup(runtime, host_mp, null)
		_finish()
		return

	var payload := host_mp.sent_arguments[0]
	var projectile_ids := payload[0] as PackedInt64Array
	var payload_positions := payload[1] as PackedVector2Array
	var direction := payload[2] as Vector2
	var payload_owner := int(payload[3])
	var charge_sequence := int(payload[4])
	var charge_ratio := float(payload[5])
	var barrage_remaining := float(payload[6])
	var damage := int(payload[7])
	var speed := float(payload[8])
	var lifetime := float(payload[9])
	var host_fire_timestamp := float(payload[10])
	_expect(
		projectile_ids.size() == 3
		and projectile_ids[0] != projectile_ids[1]
		and projectile_ids[1] != projectile_ids[2]
		and projectile_ids[0] != projectile_ids[2]
		and payload_positions == spawn_positions
		and direction == Vector2.RIGHT
		and payload_owner == owner_peer_id
		and charge_sequence == 3
		and is_equal_approx(charge_ratio, 1.0)
		and is_equal_approx(barrage_remaining, 5.0)
		and damage == 15
		and is_equal_approx(speed, 480.0)
		and is_equal_approx(lifetime, 0.722)
		and host_fire_timestamp >= 0.0,
		"技能弹幕可接收8秒内部寿命，但批处理包必须维持5秒协议上限。"
	)
	for projectile_id in projectile_ids:
		_expect(
			bool(host_mp.call(
				"_is_projectile_id_valid_for_host_owner",
				int(projectile_id),
				owner_peer_id
			)),
			"Every Tango projectile ID must use the Host-origin owner lane."
		)
	_expect(
		(host_mp.get("_known_projectiles") as Dictionary).size() == 3
		and (host_mp.get("_projectile_records") as Dictionary).size() == 3,
		"Host registration must retain exactly three identities and damage records."
	)

	var client_mp := RecordingMpGame.new()
	var client_game := StandardGame.new()
	client_game.peer_players[owner_peer_id] = player
	client_mp.set("game", client_game)
	client_mp.set("_has_host_time_offset", true)
	client_mp.set("_host_to_client_time_offset", 0.0)
	# Keep the direct-call fixture at zero compensation age. In production MpGame
	# is in-tree before adding a fresh proxy; this isolated source-level fixture
	# intentionally stays out of tree to avoid running its full loading lifecycle.
	var client_payload := payload.duplicate()
	client_payload[10] = Time.get_ticks_usec() / 1000000.0 + 1.0
	var client_host_timestamp := float(client_payload[10])
	client_mp.callv("net_tango_laser_volley", client_payload)
	var client_known := client_mp.get("_known_projectiles") as Dictionary
	_expect(
		client_known.size() == 3
		and (client_mp.get("_projectile_records") as Dictionary).size() == 3,
		"Client playback must create exactly three de-duplicated proxy bullets."
	)
	for projectile_id in projectile_ids:
		var proxy := client_known.get(int(projectile_id)) as TangoLaserBullet
		_expect(
			proxy != null
			and proxy.owner_peer_id == owner_peer_id
			and proxy.source_type == &"tango_laser_bullet"
			and proxy.damage == 15
			and proxy.direction == Vector2.RIGHT,
			"Every client proxy must preserve its identity, source, damage, and direction."
		)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.FIRING
		and Vector2(player.get("_barrage_direction")) == Vector2.RIGHT,
		"A CH4 batch arriving first must recover the current barrage visual."
	)
	_expect(
		player.primary_attack_audio.playing,
		"A newly accepted remote three-cannon batch must play exactly one volley cue."
	)

	var created_before_duplicate := int(
		runtime.pool.get_metrics(TANGO_LASER_SCENE.resource_path).get("created", 0)
	)
	player.primary_attack_audio.stop()
	client_mp.callv("net_tango_laser_volley", client_payload)
	_expect(
		client_known.size() == 3
		and int(runtime.pool.get_metrics(
			TANGO_LASER_SCENE.resource_path
		).get("created", 0)) == created_before_duplicate
		and not player.primary_attack_audio.playing,
		"A duplicate batch must neither lease bullets nor replay its volley cue."
	)

	var old_sequence_payload := client_payload.duplicate()
	old_sequence_payload[2] = Vector2.LEFT
	old_sequence_payload[4] = 2
	old_sequence_payload[10] = client_host_timestamp + 0.01
	client_mp.callv("net_tango_laser_volley", old_sequence_payload)
	_expect(
		Vector2(player.get("_barrage_direction")) == Vector2.RIGHT
		and not player.primary_attack_audio.playing,
		"An older charge sequence may not overwrite aim or replay audio."
	)
	var old_timestamp_payload := client_payload.duplicate()
	old_timestamp_payload[2] = Vector2.DOWN
	old_timestamp_payload[10] = client_host_timestamp - 0.01
	client_mp.callv("net_tango_laser_volley", old_timestamp_payload)
	_expect(
		Vector2(player.get("_barrage_direction")) == Vector2.RIGHT
		and not player.primary_attack_audio.playing,
		"An older timestamp in the same sequence may not rewind aim or replay audio."
	)
	var newer_payload := client_payload.duplicate()
	newer_payload[2] = Vector2.UP
	newer_payload[6] = 3.0
	newer_payload[10] = client_host_timestamp + 0.02
	client_mp.callv("net_tango_laser_volley", newer_payload)
	_expect(
		Vector2(player.get("_barrage_direction")) == Vector2.UP
		and player.primary_attack_audio.playing,
		"A newer same-sequence batch must update live aim and play one new volley cue."
	)
	player.primary_attack_audio.stop()
	var next_sequence_payload := client_payload.duplicate()
	next_sequence_payload[2] = Vector2.LEFT
	next_sequence_payload[4] = 4
	next_sequence_payload[5] = 0.0
	next_sequence_payload[6] = 2.0
	next_sequence_payload[10] = client_host_timestamp + 0.03
	client_mp.callv("net_tango_laser_volley", next_sequence_payload)
	var elapsed_before_release := float(player.get("_barrage_elapsed"))
	player.reconcile_predicted_tango_barrage_started(Vector2.LEFT, 0.0, 4)
	_expect(
		Vector2(player.get("_barrage_direction")) == Vector2.LEFT
		and player.primary_attack_audio.playing
		and is_equal_approx(
			float(player.get("_barrage_elapsed")),
			elapsed_before_release
		),
		"A new sequence must play once, and its later reliable release must not restart recovery."
	)

	_expect(
		not bool(client_mp.call(
			"_is_valid_tango_laser_volley_payload",
			PackedInt64Array([projectile_ids[0], projectile_ids[0], projectile_ids[2]]),
			spawn_positions,
			Vector2.RIGHT,
			owner_peer_id,
			3,
			1.0,
			4.0,
			15,
			480.0,
			0.722,
			host_fire_timestamp
		))
		and not bool(client_mp.call(
			"_is_valid_tango_laser_volley_payload",
			projectile_ids,
			spawn_positions,
			Vector2.RIGHT,
			owner_peer_id,
			0,
			1.0,
			4.0,
			15,
			480.0,
			0.722,
			host_fire_timestamp
		))
		and not bool(client_mp.call(
			"_is_valid_tango_laser_volley_payload",
			projectile_ids,
			spawn_positions,
			Vector2.RIGHT,
			owner_peer_id,
			3,
			1.1,
			4.0,
			15,
			480.0,
			0.722,
			host_fire_timestamp
		))
		and not bool(client_mp.call(
			"_is_valid_tango_laser_volley_payload",
			projectile_ids,
			spawn_positions,
			Vector2.RIGHT,
			owner_peer_id,
			3,
			1.0,
			5.1,
			15,
			480.0,
			0.722,
			host_fire_timestamp
		)),
		"Validator must reject duplicate IDs and invalid sequence, ratio, or remaining time."
	)

	_retire_projectiles(client_known)
	_retire_projectiles(host_mp.get("_known_projectiles") as Dictionary)
	client_mp.call("_prune_projectile_records", INF)
	host_mp.call("_prune_projectile_records", INF)
	client_mp.set("game", null)
	client_game.free()
	await _cleanup(runtime, host_mp, client_mp)
	_finish()


func _retire_projectiles(projectiles: Dictionary) -> void:
	var active: Array[Node] = []
	for projectile_variant in projectiles.values():
		var projectile := projectile_variant as Node
		if projectile != null and is_instance_valid(projectile):
			active.append(projectile)
	for projectile in active:
		projectile.call("retire")


func _cleanup(
	runtime: PoolRuntime,
	host_mp: RecordingMpGame,
	client_mp: RecordingMpGame
) -> void:
	if client_mp != null:
		client_mp.free()
	if host_mp != null:
		host_mp.free()
	current_scene = null
	if runtime != null and is_instance_valid(runtime):
		runtime.queue_free()
	for _frame in range(3):
		await process_frame
		await physics_frame


func _finish() -> void:
	if failures.is_empty():
		print("TANGO_LASER_NETWORK_BATCH_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
