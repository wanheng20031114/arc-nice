extends Node2D

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const GAME_SCENE := preload("res://scene/game.tscn")
const PICKUP_SCENE := preload("res://scene/pickup.tscn")

const INPUT_BUTTON_SKILL1 := 1
const GAME_RUNTIME_HOST_AUTHORITY := 1
const GAME_RUNTIME_CLIENT_VIEW := 2
const STATE_DISCONNECTED := 0
const LOCAL_CORRECTION_SNAP_DISTANCE := 96.0
const LOCAL_CORRECTION_LERP_DISTANCE := 32.0
const LOCAL_CORRECTION_LERP_WEIGHT := 0.08
const HOST_TIME_OFFSET_SMOOTH_WEIGHT := 0.08
const INPUT_CHANGE_EPSILON := 0.001

@onready var net_manager: Node = get_node("/root/NetManager")
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore

var snapshot_mgr := SnapshotManager.new()
var player_interpolators: Dictionary = {}
var enemy_interpolators: Dictionary = {}
var game: Game = null
var input_sequence: int = 0
var _net_time_origin: float = 0.0
var _net_enemies: Dictionary = {}
var _has_host_time_offset: bool = false
var _host_to_client_time_offset: float = 0.0
var _has_sent_input: bool = false
var _last_sent_move_input: Vector2 = Vector2.ZERO
var _last_sent_shoot_input: Vector2 = Vector2.ZERO
var _input_frames_since_last_send: int = _NetConstants.INPUT_KEEPALIVE_INTERVAL_FRAMES


func _ready() -> void:
	_net_time_origin = Time.get_ticks_msec() / 1000.0
	set_multiplayer_authority(_get_host_peer_id())
	net_manager.connection_state_changed.connect(_on_connection_state_changed)
	if net_manager.is_host():
		_setup_game(GAME_RUNTIME_HOST_AUTHORITY)
	elif net_manager.is_client():
		_setup_game(GAME_RUNTIME_CLIENT_VIEW)
	else:
		push_warning("MpGame 启动时没有有效的多人连接，返回大厅。")
		call_deferred("_return_to_lobby")
		return
	net_manager.mark_in_game()


func _physics_process(_delta: float) -> void:
	var frame: int = net_manager.get_physics_frame_count()
	if net_manager.is_host():
		_host_physics_tick(frame)
	elif net_manager.is_client():
		_client_physics_tick(frame)


func _process(_delta: float) -> void:
	if net_manager.is_client():
		_client_interpolate_entities()


func request_multiplayer_upgrade(stat_type: int) -> void:
	if net_manager.is_host():
		_apply_upgrade_for_peer(_get_local_peer_id(), stat_type)
	else:
		net_upgrade_selected.rpc_id(_get_host_peer_id(), stat_type)


func request_multiplayer_skill1_purchase() -> void:
	if net_manager.is_host():
		_apply_skill1_purchase_for_peer(_get_local_peer_id())
	else:
		net_skill1_purchase_requested.rpc_id(_get_host_peer_id())


func _setup_game(mode: int) -> void:
	game = GAME_SCENE.instantiate() as Game
	if game == null:
		push_error("MpGame: 无法实例化 game.tscn")
		return

	var local_peer_id: int = _get_local_peer_id()
	if local_peer_id <= 0 and net_manager.is_host():
		local_peer_id = _get_host_peer_id()
	game.configure_multiplayer(mode, local_peer_id, net_manager.connected_players)
	add_child(game)
	run_state.set_active_multiplayer_peer(local_peer_id)

	if net_manager.is_host():
		game.multiplayer_enemy_spawned.connect(_on_host_enemy_spawned)
		game.multiplayer_pickup_spawned.connect(_on_host_pickup_spawned)
		game.multiplayer_pickup_collected.connect(_on_host_pickup_collected)
		game.multiplayer_pickup_removed.connect(_on_host_pickup_removed)
		game.multiplayer_merchant_active_changed.connect(_on_host_merchant_active_changed)


func _host_physics_tick(frame: int) -> void:
	if game == null:
		return
	if frame % _NetConstants.PLAYER_SNAPSHOT_INTERVAL_FRAMES == 0:
		_host_broadcast_player_snapshots()
	if frame % _NetConstants.ENEMY_SNAPSHOT_INTERVAL_FRAMES == 0:
		_host_broadcast_enemy_snapshots()


func _host_broadcast_player_snapshots() -> void:
	var states: Array[SnapshotManager.PlayerState] = game.collect_player_snapshot_states()
	if states.is_empty():
		return
	var data := snapshot_mgr.encode_all_player_snapshots(states)
	_rpc_receive_player_snapshot.rpc(_get_net_time(), data)


func _host_broadcast_enemy_snapshots() -> void:
	var states: Array[SnapshotManager.EnemyState] = game.collect_enemy_snapshot_states()
	if states.is_empty():
		return
	var data := snapshot_mgr.encode_all_enemy_snapshots(states)
	_rpc_receive_enemy_snapshot.rpc(_get_net_time(), data)


func _client_physics_tick(frame: int) -> void:
	_input_frames_since_last_send += 1
	var buttons := 0
	if Input.is_action_just_pressed("skill1"):
		buttons |= INPUT_BUTTON_SKILL1
	if frame % _NetConstants.INPUT_SEND_INTERVAL_FRAMES == 0 or buttons != 0:
		_client_send_input_if_needed(buttons)


func _client_send_input_if_needed(buttons: int) -> void:
	var move_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var shoot_input := _get_client_shoot_input()
	var input_changed := (
		not _has_sent_input
		or move_input.distance_squared_to(_last_sent_move_input) > INPUT_CHANGE_EPSILON
		or shoot_input.distance_squared_to(_last_sent_shoot_input) > INPUT_CHANGE_EPSILON
	)
	var keepalive_due := (
		_input_frames_since_last_send >= _NetConstants.INPUT_KEEPALIVE_INTERVAL_FRAMES
	)
	if not input_changed and not keepalive_due and buttons == 0:
		return
	input_sequence += 1
	_has_sent_input = true
	_last_sent_move_input = move_input
	_last_sent_shoot_input = shoot_input
	_input_frames_since_last_send = 0
	_rpc_client_input.rpc_id(_get_host_peer_id(), input_sequence, move_input, shoot_input, buttons)


func _get_client_shoot_input() -> Vector2:
	var shoot_input := Input.get_vector("shoot_left", "shoot_right", "shoot_up", "shoot_down")
	if shoot_input != Vector2.ZERO:
		return shoot_input
	if game == null or game.player == null:
		return Vector2.ZERO
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return Vector2.ZERO
	return game.player.global_position.direction_to(game.player.get_global_mouse_position())


func _client_interpolate_entities() -> void:
	if game == null:
		return
	var current_time := _get_net_time()
	var local_peer_id: int = _get_local_peer_id()
	for peer_id_variant in player_interpolators:
		var peer_id := int(peer_id_variant)
		if peer_id == local_peer_id:
			continue
		var interp := player_interpolators[peer_id] as NetInterpolator
		var player_node: Player = game.get_player_for_peer(peer_id)
		if interp != null and player_node != null and is_instance_valid(player_node):
			player_node.global_position = interp.get_interpolated_position(current_time)
	for net_id_variant in enemy_interpolators:
		var net_id := int(net_id_variant)
		var enemy_interp := enemy_interpolators[net_id] as NetInterpolator
		var enemy_node: Enemy = _net_enemies.get(net_id) as Enemy
		if enemy_interp != null and enemy_node != null and is_instance_valid(enemy_node):
			enemy_node.global_position = enemy_interp.get_interpolated_position(current_time)


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_receive_player_snapshot(host_timestamp: float, data: PackedByteArray) -> void:
	if game == null:
		return
	var snapshot_time := _map_host_timestamp_to_client_time(host_timestamp)
	var states := SnapshotManager.decode_all_player_snapshots(data)
	for state in states:
		var player_state := state as SnapshotManager.PlayerState
		if player_state == null:
			continue
		if not player_interpolators.has(player_state.peer_id):
			player_interpolators[player_state.peer_id] = NetInterpolator.new(
				1.0 / float(_NetConstants.PLAYER_SNAPSHOT_HZ)
			)
		var interp := player_interpolators[player_state.peer_id] as NetInterpolator
		interp.push_snapshot(
			snapshot_time,
			player_state.position,
			player_state.velocity,
			player_state.facing,
			player_state.anim_state,
			player_state.health,
			player_state.is_dead
		)
		var player_node: Player = game.get_player_for_peer(player_state.peer_id)
		if player_node != null and is_instance_valid(player_node):
			player_node.current_health = player_state.health
			player_node.is_dead = player_state.is_dead
			if player_node.current_xirang != player_state.xirang:
				player_node.current_xirang = player_state.xirang
				player_node.xirang_changed.emit(player_state.xirang, 0)
			if net_manager.is_client() and player_state.peer_id == _get_local_peer_id():
				_apply_local_player_authority_correction(
					player_node,
					player_state.position,
					player_state.velocity,
					snapshot_time
				)


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_receive_enemy_snapshot(host_timestamp: float, data: PackedByteArray) -> void:
	var snapshot_time := _map_host_timestamp_to_client_time(host_timestamp)
	var states := SnapshotManager.decode_all_enemy_snapshots(data)
	for state in states:
		var enemy_state := state as SnapshotManager.EnemyState
		if enemy_state == null:
			continue
		if not enemy_interpolators.has(enemy_state.net_id):
			enemy_interpolators[enemy_state.net_id] = NetInterpolator.new(
				1.0 / float(_NetConstants.ENEMY_SNAPSHOT_HZ)
			)
		var interp := enemy_interpolators[enemy_state.net_id] as NetInterpolator
		interp.push_snapshot(
			snapshot_time,
			enemy_state.position,
			enemy_state.velocity,
			0,
			0,
			enemy_state.health,
			enemy_state.is_dead
		)
		var enemy_node: Enemy = _net_enemies.get(enemy_state.net_id) as Enemy
		if enemy_node != null and is_instance_valid(enemy_node):
			enemy_node.current_health = enemy_state.health
			enemy_node.is_dead = enemy_state.is_dead


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _rpc_client_input(
	_sequence: int,
	move_input: Vector2,
	shoot_input: Vector2,
	buttons: int
) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var use_skill1 := (buttons & INPUT_BUTTON_SKILL1) != 0
	game.apply_network_input_for_peer(sender_id, move_input, shoot_input, use_skill1)


func _apply_local_player_authority_correction(
	player_node: Player,
	authority_position: Vector2,
	authority_velocity: Vector2,
	snapshot_time: float
) -> void:
	var snapshot_age := clampf(
		_get_net_time() - snapshot_time,
		0.0,
		_NetConstants.MAX_EXTRAPOLATION_SECONDS
	)
	var predicted_authority_position := authority_position + authority_velocity * snapshot_age
	var error_distance := player_node.global_position.distance_to(predicted_authority_position)
	if error_distance >= LOCAL_CORRECTION_SNAP_DISTANCE:
		player_node.global_position = predicted_authority_position
		return
	if error_distance >= LOCAL_CORRECTION_LERP_DISTANCE:
		player_node.global_position = player_node.global_position.lerp(
			predicted_authority_position,
			LOCAL_CORRECTION_LERP_WEIGHT
		)


func _on_host_enemy_spawned(
	net_id: int,
	enemy_config: EnemyConfig,
	spawn_position: Vector2
) -> void:
	if enemy_config == null:
		return
	net_enemy_spawned.rpc(net_id, enemy_config.resource_path, spawn_position.x, spawn_position.y)


func _on_host_pickup_removed(net_id: int) -> void:
	net_pickup_removed.rpc(net_id)


func _on_host_pickup_spawned(
	net_id: int,
	pickup_config: PickupConfig,
	spawn_position: Vector2
) -> void:
	if pickup_config == null:
		return
	net_pickup_spawned.rpc(net_id, pickup_config.resource_path, spawn_position.x, spawn_position.y)


func _on_host_pickup_collected(
	net_id: int,
	collector_peer_id: int,
	pickup_config: PickupConfig,
	applied_immediately: bool
) -> void:
	var config_path := pickup_config.resource_path if pickup_config != null else ""
	net_pickup_collected.rpc(net_id, collector_peer_id, config_path, applied_immediately)


func _on_host_merchant_active_changed(active: bool) -> void:
	net_merchant_active_changed.rpc(active)


@rpc("authority", "call_remote", "reliable", 3)
func net_enemy_spawned(net_id: int, config_path: String, pos_x: float, pos_y: float) -> void:
	if game == null or net_manager.is_host():
		return
	var enemy_config: EnemyConfig = load(config_path) as EnemyConfig
	if enemy_config == null:
		return
	var spawn_scene: PackedScene = (
		enemy_config.enemy_scene_override
		if enemy_config.enemy_scene_override != null
		else game.enemy_scene
	)
	var enemy := spawn_scene.instantiate() as Enemy
	if enemy == null:
		return
	game.enemy_container.add_child(enemy)
	enemy.global_position = Vector2(pos_x, pos_y)
	enemy.setup(enemy_config, game.player, game.grid_pathfinder)
	enemy.set_physics_process(false)
	enemy.set_process(false)
	enemy.collision_layer = 0
	enemy.collision_mask = 0
	enemy.set_meta("net_id", net_id)
	_net_enemies[net_id] = enemy


@rpc("authority", "call_remote", "reliable", 3)
func net_pickup_removed(net_id: int) -> void:
	if game == null or net_manager.is_host():
		return
	var pickup: Pickup = game.get_pickup_for_net_id(net_id)
	if pickup == null or not is_instance_valid(pickup):
		game.multiplayer_pickups.erase(net_id)
		return
	game.multiplayer_pickups.erase(net_id)
	pickup.queue_free()


@rpc("authority", "call_remote", "reliable", 3)
func net_pickup_spawned(net_id: int, config_path: String, pos_x: float, pos_y: float) -> void:
	if game == null or net_manager.is_host():
		return
	if game.get_pickup_for_net_id(net_id) != null:
		return
	var pickup_config := load(config_path) as PickupConfig
	if pickup_config == null:
		return
	var pickup := PICKUP_SCENE.instantiate() as Pickup
	if pickup == null:
		return
	pickup.config = pickup_config
	game.enemy_container.add_child(pickup)
	pickup.global_position = Vector2(pos_x, pos_y)
	pickup.set_meta("net_id", net_id)
	pickup.collision_layer = 0
	pickup.collision_mask = 0
	game.multiplayer_pickups[net_id] = pickup


@rpc("authority", "call_remote", "reliable", 3)
func net_pickup_collected(
	net_id: int,
	collector_peer_id: int,
	config_path: String,
	applied_immediately: bool
) -> void:
	if game == null or net_manager.is_host():
		return
	var pickup: Pickup = game.get_pickup_for_net_id(net_id)
	if pickup != null and is_instance_valid(pickup):
		game.multiplayer_pickups.erase(net_id)
		pickup.queue_free()
	if not applied_immediately or config_path.is_empty():
		return
	var pickup_config := load(config_path) as PickupConfig
	if pickup_config == null:
		return
	var player_node: Player = game.get_player_for_peer(collector_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	player_node.apply_pickup(pickup_config)


@rpc("authority", "call_remote", "reliable", 3)
func net_merchant_active_changed(active: bool) -> void:
	if game == null or net_manager.is_host():
		return
	game.apply_remote_merchant_active(active)


@rpc("any_peer", "call_remote", "reliable", 3)
func net_upgrade_selected(stat_type: int) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	_apply_upgrade_for_peer(sender_id, stat_type)


@rpc("any_peer", "call_remote", "reliable", 3)
func net_skill1_purchase_requested() -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	_apply_skill1_purchase_for_peer(sender_id)


@rpc("authority", "call_remote", "reliable", 3)
func net_upgrade_confirmed(
	peer_id: int,
	stat_type: int,
	level: int,
	current_xirang: int,
	success: bool
) -> void:
	if not success:
		return
	run_state.ensure_multiplayer_peer_state(peer_id)
	run_state.set_upgrade_level_for_peer(peer_id, stat_type, level)
	var player_node: Player = game.get_player_for_peer(peer_id) if game != null else null
	if player_node != null:
		player_node.current_xirang = current_xirang
		player_node.xirang_changed.emit(current_xirang, 0)


@rpc("authority", "call_remote", "reliable", 3)
func net_skill1_purchase_confirmed(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	result_code: int
) -> void:
	if game == null:
		return
	game.apply_skill1_purchase_state(peer_id, current_xirang, skill1_unlocked)
	if peer_id == _get_local_peer_id():
		game.show_local_skill1_purchase_result(result_code)


func _apply_upgrade_for_peer(peer_id: int, stat_type: int) -> void:
	if game == null:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	var success := run_state.try_upgrade_for_peer(peer_id, stat_type, player_node)
	var level := run_state.get_upgrade_level_for_peer(peer_id, stat_type)
	var current_xirang := player_node.current_xirang if player_node != null else 0
	net_upgrade_confirmed.rpc(peer_id, stat_type, level, current_xirang, success)
	if peer_id == _get_local_peer_id():
		net_upgrade_confirmed(peer_id, stat_type, level, current_xirang, success)


func _apply_skill1_purchase_for_peer(peer_id: int) -> void:
	if game == null:
		return
	var result_code := game.try_purchase_skill1_for_peer(peer_id)
	var player_node := game.get_player_for_peer(peer_id)
	var current_xirang := player_node.current_xirang if player_node != null else 0
	var skill1_unlocked := player_node.has_skill1() if player_node != null else false
	net_skill1_purchase_confirmed.rpc(peer_id, current_xirang, skill1_unlocked, result_code)
	if peer_id == _get_local_peer_id():
		net_skill1_purchase_confirmed(peer_id, current_xirang, skill1_unlocked, result_code)


func _get_host_peer_id() -> int:
	if net_manager != null and net_manager.has_method("get_host_peer_id"):
		return int(net_manager.get_host_peer_id())
	return 1


func _get_local_peer_id() -> int:
	if net_manager == null:
		return 0
	return int(net_manager.get_local_peer_id())


func _get_net_time() -> float:
	return Time.get_ticks_msec() / 1000.0 - _net_time_origin


func _map_host_timestamp_to_client_time(host_timestamp: float) -> float:
	var receive_time := _get_net_time()
	var sampled_offset := receive_time - host_timestamp
	if not _has_host_time_offset:
		_host_to_client_time_offset = sampled_offset
		_has_host_time_offset = true
	else:
		_host_to_client_time_offset = lerpf(
			_host_to_client_time_offset,
			sampled_offset,
			HOST_TIME_OFFSET_SMOOTH_WEIGHT
		)
	return host_timestamp + _host_to_client_time_offset


func _on_connection_state_changed(new_state: int) -> void:
	if new_state == STATE_DISCONNECTED:
		_return_to_lobby()


func _return_to_lobby() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	tree.change_scene_to_file("res://scene/multiplayer/multiplayer_lobby.tscn")
