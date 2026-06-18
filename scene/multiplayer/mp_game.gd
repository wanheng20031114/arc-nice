extends Node2D

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const GAME_SCENE := preload("res://scene/game.tscn")

const INPUT_BUTTON_SKILL1 := 1
const GAME_RUNTIME_HOST_AUTHORITY := 1
const GAME_RUNTIME_CLIENT_VIEW := 2
const STATE_DISCONNECTED := 0

@onready var net_manager: Node = get_node("/root/NetManager")
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore

var snapshot_mgr := SnapshotManager.new()
var player_interpolators: Dictionary = {}
var enemy_interpolators: Dictionary = {}
var game: Node = null
var input_sequence: int = 0
var _net_time_origin: float = 0.0
var _net_enemies: Dictionary = {}


func _ready() -> void:
	_net_time_origin = Time.get_ticks_msec() / 1000.0
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
		_apply_upgrade_for_peer(1, stat_type)
	else:
		net_upgrade_selected.rpc_id(1, stat_type)


func _setup_game(mode: int) -> void:
	game = GAME_SCENE.instantiate()
	if game == null:
		push_error("MpGame: 无法实例化 game.tscn")
		return

	var local_peer_id: int = net_manager.get_local_peer_id()
	if local_peer_id <= 0 and net_manager.is_host():
		local_peer_id = 1
	game.configure_multiplayer(mode, local_peer_id, net_manager.connected_players)
	add_child(game)
	run_state.set_active_multiplayer_peer(local_peer_id)

	if net_manager.is_host():
		game.multiplayer_enemy_spawned.connect(_on_host_enemy_spawned)


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
	if frame % _NetConstants.INPUT_SEND_INTERVAL_FRAMES == 0:
		_client_send_input()


func _client_send_input() -> void:
	input_sequence += 1
	var move_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var shoot_input := Input.get_vector("shoot_left", "shoot_right", "shoot_up", "shoot_down")
	var buttons := 0
	if Input.is_action_just_pressed("skill1"):
		buttons |= INPUT_BUTTON_SKILL1
	_rpc_client_input.rpc_id(1, input_sequence, move_input, shoot_input, buttons)


func _client_interpolate_entities() -> void:
	if game == null:
		return
	var current_time := _get_net_time()
	for peer_id_variant in player_interpolators:
		var peer_id := int(peer_id_variant)
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
func _rpc_receive_player_snapshot(timestamp: float, data: PackedByteArray) -> void:
	if game == null:
		return
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
			timestamp,
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


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_receive_enemy_snapshot(timestamp: float, data: PackedByteArray) -> void:
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
			timestamp,
			enemy_state.position,
			enemy_state.velocity,
			0,
			0,
			enemy_state.health,
			enemy_state.is_dead
		)
		var enemy_node: Enemy = _net_enemies.get(enemy_state.net_id) as Enemy
		if enemy_node != null and is_instance_valid(enemy_node):
			enemy_node.global_position = enemy_state.position
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


func _on_host_enemy_spawned(
	net_id: int,
	enemy_config: EnemyConfig,
	spawn_position: Vector2
) -> void:
	if enemy_config == null:
		return
	net_enemy_spawned.rpc(net_id, enemy_config.resource_path, spawn_position.x, spawn_position.y)


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


@rpc("any_peer", "call_remote", "reliable", 3)
func net_upgrade_selected(stat_type: int) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	_apply_upgrade_for_peer(sender_id, stat_type)


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


func _apply_upgrade_for_peer(peer_id: int, stat_type: int) -> void:
	if game == null:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	var success := run_state.try_upgrade_for_peer(peer_id, stat_type, player_node)
	var level := run_state.get_upgrade_level_for_peer(peer_id, stat_type)
	var current_xirang := player_node.current_xirang if player_node != null else 0
	net_upgrade_confirmed.rpc(peer_id, stat_type, level, current_xirang, success)
	if peer_id == net_manager.get_local_peer_id():
		net_upgrade_confirmed(peer_id, stat_type, level, current_xirang, success)


func _get_net_time() -> float:
	return Time.get_ticks_msec() / 1000.0 - _net_time_origin


func _on_connection_state_changed(new_state: int) -> void:
	if new_state == STATE_DISCONNECTED:
		_return_to_lobby()


func _return_to_lobby() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	tree.change_scene_to_file("res://scene/multiplayer/multiplayer_lobby.tscn")
