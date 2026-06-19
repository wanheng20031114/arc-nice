extends Node2D

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const GAME_SCENE := preload("res://scene/game.tscn")
const PICKUP_SCENE := preload("res://scene/pickup.tscn")
const BULLET_SCENE := preload("res://scene/bullet.tscn")
const SKILL1_BOMB_SCENE := preload("res://scene/weishidaier_skill1_bomb.tscn")
const CAPOO_AK47_BULLET_SCENE := preload("res://scene/capoo_ak47_bullet.tscn")
const YUANSHI_FIRE_PROJECTILE_SCENE := preload("res://scene/yuanshi_insect_fire_projectile.tscn")
const XIRANG_DROP_SCENE := preload("res://scene/xirang_drop.tscn")

const INPUT_BUTTON_SKILL1 := 1
const GAME_RUNTIME_HOST_AUTHORITY := 1
const GAME_RUNTIME_CLIENT_VIEW := 2
const STATE_DISCONNECTED := 0
const HOST_TIME_OFFSET_SMOOTH_WEIGHT := 0.08
const INPUT_CHANGE_EPSILON := 0.001
const PLAYER_STATE_SNAP_DISTANCE := 128.0
const PLAYER_STATE_SPEED_SLACK := 96.0
const PLAYER_REVIVE_DELAY_SECONDS := 10.0
const PLAYER_REVIVE_INVINCIBILITY_SECONDS := 3.0

@onready var net_manager: Node = get_node("/root/NetManager")
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore

var snapshot_mgr := SnapshotManager.new()
var player_interpolators: Dictionary = {}
var enemy_interpolators: Dictionary = {}
var game: Game = null
var input_sequence: int = 0
var _net_time_origin: float = 0.0
var _net_enemies: Dictionary = {}
var _enemy_spawn_snapshot_times: Dictionary = {}
var _host_had_enemies_last_snapshot: bool = false
var _has_host_time_offset: bool = false
var _host_to_client_time_offset: float = 0.0
var _has_sent_input: bool = false
var _last_sent_move_input: Vector2 = Vector2.ZERO
var _last_sent_shoot_input: Vector2 = Vector2.ZERO
var _input_frames_since_last_send: int = _NetConstants.INPUT_KEEPALIVE_INTERVAL_FRAMES
var _last_player_state_sequences: Dictionary = {}
var _accepted_player_state_positions: Dictionary = {}
var _accepted_player_state_times: Dictionary = {}
var _next_projectile_id: int = 1
var _known_projectiles: Dictionary = {}
var _processed_enemy_hit_ids: Dictionary = {}
var _processed_player_hit_ids: Dictionary = {}
var _next_xirang_orb_id: int = 1
var _xirang_orbs: Dictionary = {}
var _collected_xirang_orbs: Dictionary = {}
var _host_player_snapshot_sequence: int = 0
var _player_health_revisions: Dictionary = {}
var _local_player_hit_revision: int = 0
var _dead_player_revive_times: Dictionary = {}
var _dead_player_revive_last_seconds: Dictionary = {}
var _xirang_revision: int = 0


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


func _physics_process(delta: float) -> void:
	var frame: int = net_manager.get_physics_frame_count()
	if net_manager.is_host():
		_host_physics_tick(frame, delta)
	elif net_manager.is_client():
		_client_physics_tick(frame)


func _process(_delta: float) -> void:
	if net_manager.is_client() or net_manager.is_host():
		_client_interpolate_entities()
	if net_manager.is_client() and game != null:
		game.apply_remote_enemy_count(_net_enemies.size())


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
		game.multiplayer_enemy_removed.connect(_on_host_enemy_removed)
		game.multiplayer_pickup_spawned.connect(_on_host_pickup_spawned)
		game.multiplayer_pickup_collected.connect(_on_host_pickup_collected)
		game.multiplayer_pickup_removed.connect(_on_host_pickup_removed)
		game.multiplayer_merchant_active_changed.connect(_on_host_merchant_active_changed)
		game.multiplayer_wave_started.connect(_on_host_wave_started)
		game.multiplayer_revive_all_requested.connect(_on_host_revive_all_requested)


func _host_physics_tick(frame: int, _delta: float) -> void:
	if game == null:
		return
	_host_update_player_revives()
	if frame % _NetConstants.PLAYER_SNAPSHOT_INTERVAL_FRAMES == 0:
		_host_broadcast_player_snapshots()
	if frame % _NetConstants.ENEMY_SNAPSHOT_INTERVAL_FRAMES == 0:
		_host_broadcast_enemy_snapshots()


func _host_broadcast_player_snapshots() -> void:
	var states: Array[SnapshotManager.PlayerState] = game.collect_player_snapshot_states()
	if states.is_empty():
		return
	_host_player_snapshot_sequence += 1
	for state in states:
		state.sequence = _host_player_snapshot_sequence
	var data := snapshot_mgr.encode_all_player_snapshots(states)
	_rpc_receive_player_snapshot.rpc(_get_net_time(), data)


func _host_broadcast_enemy_snapshots() -> void:
	var states: Array[SnapshotManager.EnemyState] = game.collect_enemy_snapshot_states()
	if states.is_empty() and not _host_had_enemies_last_snapshot:
		return
	_host_had_enemies_last_snapshot = not states.is_empty()
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
	var player_node := game.player if game != null else null
	if player_node == null:
		return
	var input_changed := (
		not _has_sent_input
		or move_input.distance_squared_to(_last_sent_move_input) > INPUT_CHANGE_EPSILON
		or shoot_input.distance_squared_to(_last_sent_shoot_input) > INPUT_CHANGE_EPSILON
	)
	var keepalive_due := (
		_input_frames_since_last_send >= _NetConstants.INPUT_KEEPALIVE_INTERVAL_FRAMES
	)
	var active_realtime_state := (
		move_input != Vector2.ZERO
		or shoot_input != Vector2.ZERO
		or player_node.velocity.length_squared() > INPUT_CHANGE_EPSILON
		or player_node.skill1_unlocked
		or player_node.invincibility_time_left > 0.0
		or player_node.current_form_mode != PickupConfig.PlayerFormMode.NORMAL
		or player_node.current_shot_pattern != PickupConfig.ShotPattern.NORMAL
	)
	if not input_changed and not keepalive_due and buttons == 0 and not active_realtime_state:
		return
	input_sequence += 1
	_has_sent_input = true
	_last_sent_move_input = move_input
	_last_sent_shoot_input = shoot_input
	_input_frames_since_last_send = 0
	_rpc_client_player_state.rpc_id(
		_get_host_peer_id(),
		input_sequence,
		player_node.global_position,
		player_node.velocity,
		shoot_input,
		buttons,
		player_node.current_health,
		player_node.max_health,
		player_node.current_xirang,
		player_node.is_dead,
		player_node.invincibility_time_left,
		player_node.skill1_unlocked,
		player_node.skill1_charge,
		player_node.skill1_charge_duration,
		player_node.current_form_mode,
		player_node.current_shot_pattern
	)


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
			var frame_state: NetInterpolator.FrameSnapshot = interp.get_current_state(current_time)
			player_node.apply_multiplayer_snapshot_motion(
				interp.get_interpolated_position(current_time),
				interp.get_interpolated_velocity(current_time),
				frame_state.facing,
				frame_state.anim_state
			)
	for net_id_variant in enemy_interpolators:
		var net_id := int(net_id_variant)
		var enemy_interp := enemy_interpolators[net_id] as NetInterpolator
		var enemy_node: Enemy = _get_valid_client_enemy_for_net_id(net_id)
		if enemy_interp != null and enemy_node != null and is_instance_valid(enemy_node):
			var enemy_position: Vector2 = enemy_interp.get_interpolated_position(current_time)
			var enemy_velocity: Vector2 = enemy_interp.get_interpolated_velocity(current_time)
			enemy_node.apply_multiplayer_proxy_motion(enemy_position, enemy_velocity)


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
		if net_manager.is_client() and player_state.peer_id == _get_local_peer_id():
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
			0,
			false
		)
		var player_node: Player = game.get_player_for_peer(player_state.peer_id)
		if player_node != null and is_instance_valid(player_node):
			player_node.apply_multiplayer_realtime_state(
				player_state.current_health,
				player_state.max_health,
				player_state.current_xirang,
				player_state.is_dead,
				player_state.invincibility_time_left,
				player_state.skill1_unlocked,
				player_state.skill1_charge,
				player_state.skill1_charge_duration,
				player_state.form_mode,
				player_state.shot_pattern
			)


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_receive_enemy_snapshot(host_timestamp: float, data: PackedByteArray) -> void:
	var snapshot_time := _map_host_timestamp_to_client_time(host_timestamp)
	var states := SnapshotManager.decode_all_enemy_snapshots(data)
	var seen_enemy_ids: Dictionary = {}
	for state in states:
		var enemy_state := state as SnapshotManager.EnemyState
		if enemy_state == null:
			continue
		seen_enemy_ids[enemy_state.net_id] = true
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
		var enemy_node: Enemy = _get_valid_client_enemy_for_net_id(enemy_state.net_id)
		if enemy_node != null and is_instance_valid(enemy_node):
			enemy_node.current_health = enemy_state.health
			enemy_node.is_dead = enemy_state.is_dead
	_reconcile_enemy_roster(seen_enemy_ids, snapshot_time)


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _rpc_client_player_state(
	sequence: int,
	reported_position: Vector2,
	reported_velocity: Vector2,
	shoot_input: Vector2,
	buttons: int,
	current_health: int,
	max_health: int,
	current_xirang: int,
	is_dead: bool,
	invincibility_time_left: float,
	skill1_unlocked: bool,
	skill1_charge: float,
	skill1_charge_duration: float,
	form_mode: int,
	shot_pattern: int
) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	var player_node := game.get_player_for_peer(sender_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var reported_alive: bool = not is_dead and current_health > 0
	if player_node.is_dead and reported_alive:
		_dead_player_revive_times.erase(sender_id)
		_dead_player_revive_last_seconds.erase(sender_id)
		player_node.revive_multiplayer(
			reported_position,
			clampi(current_health, 1, maxi(max_health, 1)),
			invincibility_time_left
		)
	if player_node.is_dead or player_node.controls_locked:
		net_player_state_corrected.rpc_id(sender_id, player_node.global_position, player_node.velocity)
		return
	if not _accept_client_player_state(sender_id, sequence, reported_position, reported_velocity):
		net_player_state_corrected.rpc_id(sender_id, player_node.global_position, player_node.velocity)
		return
	var use_skill1: bool = (buttons & INPUT_BUTTON_SKILL1) != 0
	player_node.apply_remote_multiplayer_view_state(reported_velocity, shoot_input, use_skill1)
	player_node.apply_multiplayer_realtime_state(
		current_health,
		max_health,
		current_xirang,
		is_dead,
		invincibility_time_left,
		skill1_unlocked,
		skill1_charge,
		skill1_charge_duration,
		form_mode,
		shot_pattern
	)
	_push_player_interpolator_state(
		sender_id,
		_get_net_time(),
		reported_position,
		reported_velocity,
		player_node.get_multiplayer_facing_id(),
		player_node.get_multiplayer_anim_state()
	)

@rpc("authority", "call_remote", "reliable", 4)
func net_player_state_corrected(corrected_position: Vector2, corrected_velocity: Vector2) -> void:
	if game == null or game.player == null:
		return
	game.player.global_position = corrected_position
	game.player.velocity = corrected_velocity


func _push_player_interpolator_snapshot(peer_id: int, timestamp: float, player_node: Player) -> void:
	if player_node == null or not is_instance_valid(player_node):
		return
	_push_player_interpolator_state(
		peer_id,
		timestamp,
		player_node.global_position,
		player_node.velocity,
		player_node.get_multiplayer_facing_id(),
		player_node.get_multiplayer_anim_state()
	)


func _push_player_interpolator_state(
	peer_id: int,
	timestamp: float,
	player_position: Vector2,
	player_velocity: Vector2,
	facing_id: int,
	anim_state: int
) -> void:
	if not player_interpolators.has(peer_id):
		player_interpolators[peer_id] = NetInterpolator.new(
			1.0 / float(_NetConstants.PLAYER_SNAPSHOT_HZ)
		)
	var interp: NetInterpolator = player_interpolators[peer_id] as NetInterpolator
	interp.push_snapshot(
		timestamp,
		player_position,
		player_velocity,
		facing_id,
		anim_state,
		0,
		false
	)

func _accept_client_player_state(
	peer_id: int,
	sequence: int,
	reported_position: Vector2,
	reported_velocity: Vector2
) -> bool:
	var last_sequence := int(_last_player_state_sequences.get(peer_id, 0))
	if sequence <= last_sequence:
		return false
	_last_player_state_sequences[peer_id] = sequence
	var now := _get_net_time()
	if not _accepted_player_state_positions.has(peer_id):
		_accepted_player_state_positions[peer_id] = reported_position
		_accepted_player_state_times[peer_id] = now
		return true
	var previous_position := _accepted_player_state_positions[peer_id] as Vector2
	var previous_time := float(_accepted_player_state_times.get(peer_id, now))
	var elapsed := maxf(now - previous_time, 1.0 / 60.0)
	var max_distance := reported_velocity.length() * elapsed + PLAYER_STATE_SPEED_SLACK
	if previous_position.distance_to(reported_position) > maxf(max_distance, PLAYER_STATE_SNAP_DISTANCE):
		return false
	_accepted_player_state_positions[peer_id] = reported_position
	_accepted_player_state_times[peer_id] = now
	return true

func register_local_projectile(
	projectile: Node,
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float
) -> void:
	if projectile == null:
		return
	var projectile_namespace := owner_peer_id if owner_peer_id > 0 else 999999
	var projectile_id := projectile_namespace * 1000000 + _next_projectile_id
	_next_projectile_id += 1
	_setup_projectile_network_identity(projectile, projectile_id, owner_peer_id, projectile_type)
	_known_projectiles[projectile_id] = projectile
	if net_manager.is_host():
		net_projectile_fired.rpc(
			projectile_id,
			String(projectile_type),
			owner_peer_id,
			spawn_position,
			direction,
			damage,
			speed,
			lifetime
		)
	else:
		_rpc_projectile_fired_from_client.rpc_id(
			_get_host_peer_id(),
			projectile_id,
			String(projectile_type),
			owner_peer_id,
			spawn_position,
			direction,
			damage,
			speed,
			lifetime
		)


@rpc("any_peer", "call_remote", "unreliable_ordered", 3)
func _rpc_projectile_fired_from_client(
	projectile_id: int,
	projectile_type: String,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float
) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0 or owner_peer_id != sender_id:
		return
	net_projectile_fired.rpc(
		projectile_id,
		projectile_type,
		owner_peer_id,
		spawn_position,
		direction,
		damage,
		speed,
		lifetime
	)
	net_projectile_fired(
		projectile_id,
		projectile_type,
		owner_peer_id,
		spawn_position,
		direction,
		damage,
		speed,
		lifetime
	)


@rpc("authority", "call_remote", "unreliable_ordered", 3)
func net_projectile_fired(
	projectile_id: int,
	projectile_type: String,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float
) -> void:
	if _known_projectiles.has(projectile_id):
		return
	_spawn_network_projectile(
		projectile_id,
		StringName(projectile_type),
		owner_peer_id,
		spawn_position,
		direction,
		damage,
		speed,
		lifetime
	)


func _spawn_network_projectile(
	projectile_id: int,
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float
) -> void:
	var projectile := _instantiate_projectile(projectile_type, owner_peer_id, direction, damage, speed, lifetime)
	if projectile == null:
		return
	_setup_projectile_network_identity(projectile, projectile_id, owner_peer_id, projectile_type)
	_known_projectiles[projectile_id] = projectile
	add_child(projectile)
	projectile.global_position = spawn_position


func _instantiate_projectile(
	projectile_type: StringName,
	owner_peer_id: int,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float
) -> Node:
	match projectile_type:
		&"player_bullet":
			var bullet := BULLET_SCENE.instantiate() as Bullet
			if bullet == null:
				return null
			bullet.top_level = true
			bullet.setup(direction, damage)
			bullet.speed = speed
			bullet.max_lifetime = lifetime
			bullet.remaining_lifetime = lifetime
			return bullet
		&"skill1_bomb":
			var bomb := SKILL1_BOMB_SCENE.instantiate() as WeishidaierSkill1Bomb
			if bomb == null:
				return null
			bomb.top_level = true
			bomb.setup(game.get_player_for_peer(owner_peer_id), direction, damage)
			bomb.speed = speed
			bomb.max_lifetime = lifetime
			bomb.remaining_lifetime = lifetime
			return bomb
		&"capoo_ak47_bullet":
			var capoo_bullet := CAPOO_AK47_BULLET_SCENE.instantiate() as CapooAK47Bullet
			if capoo_bullet == null:
				return null
			capoo_bullet.top_level = true
			capoo_bullet.setup(direction, damage, speed, lifetime)
			return capoo_bullet
		&"yuanshi_fire_projectile":
			var fire_projectile := YUANSHI_FIRE_PROJECTILE_SCENE.instantiate() as YuanshiInsectFireProjectile
			if fire_projectile == null:
				return null
			fire_projectile.top_level = true
			fire_projectile.setup(direction, damage, speed, lifetime)
			return fire_projectile
		_:
			return null


func _setup_projectile_network_identity(
	projectile: Node,
	projectile_id: int,
	owner_peer_id: int,
	projectile_type: StringName
) -> void:
	if projectile.has_method("setup_multiplayer"):
		projectile.call("setup_multiplayer", projectile_id, owner_peer_id, projectile_type)
	projectile.tree_exited.connect(_on_network_projectile_tree_exited.bind(projectile_id))


func _on_network_projectile_tree_exited(projectile_id: int) -> void:
	_known_projectiles.erase(projectile_id)


func request_enemy_hit_report(
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	damage: int,
	impact_direction: Vector2
) -> void:
	if net_manager.is_host():
		_apply_enemy_hit_report(projectile_id, owner_peer_id, enemy_net_id, damage, impact_direction)
	else:
		_rpc_enemy_hit_report.rpc_id(
			_get_host_peer_id(),
			projectile_id,
			owner_peer_id,
			enemy_net_id,
			damage,
			impact_direction
		)


@rpc("any_peer", "call_remote", "reliable", 4)
func _rpc_enemy_hit_report(
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	damage: int,
	impact_direction: Vector2
) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id > 0 and owner_peer_id != sender_id:
		return
	_apply_enemy_hit_report(projectile_id, owner_peer_id, enemy_net_id, damage, impact_direction)


func _apply_enemy_hit_report(
	projectile_id: int,
	_owner_peer_id: int,
	enemy_net_id: int,
	damage: int,
	impact_direction: Vector2
) -> void:
	if projectile_id <= 0 or enemy_net_id <= 0 or damage <= 0:
		return
	var hit_key := "%d:%d" % [projectile_id, enemy_net_id]
	if _processed_enemy_hit_ids.has(hit_key):
		return
	_processed_enemy_hit_ids[hit_key] = true
	var enemy := _get_host_enemy_for_net_id(enemy_net_id)
	if enemy == null or not is_instance_valid(enemy):
		return
	enemy.apply_damage(damage, impact_direction)
	net_enemy_damage_applied.rpc(enemy_net_id, enemy.current_health, enemy.is_dead, impact_direction)


@rpc("authority", "call_remote", "reliable", 4)
func net_enemy_damage_applied(
	enemy_net_id: int,
	current_health: int,
	is_dead: bool,
	impact_direction: Vector2
) -> void:
	var enemy := _get_client_enemy_for_net_id(enemy_net_id)
	if enemy == null or not is_instance_valid(enemy):
		return
	enemy.current_health = current_health
	if impact_direction != Vector2.ZERO:
		enemy.apply_damage(0, impact_direction)
	if is_dead:
		_remove_client_enemy(enemy_net_id, true)


func request_player_hit_report(
	source_id: int,
	player_peer_id: int,
	damage: int,
	source_type: StringName,
	reported_health_after: int,
	reported_is_dead: bool
) -> void:
	_local_player_hit_revision += 1
	if net_manager.is_host():
		_apply_player_hit_report(
			source_id,
			player_peer_id,
			damage,
			source_type,
			reported_health_after,
			reported_is_dead,
			_local_player_hit_revision
		)
	else:
		_rpc_player_hit_report.rpc_id(
			_get_host_peer_id(),
			source_id,
			player_peer_id,
			damage,
			String(source_type),
			reported_health_after,
			reported_is_dead,
			_local_player_hit_revision
		)


@rpc("any_peer", "call_remote", "reliable", 4)
func _rpc_player_hit_report(
	source_id: int,
	player_peer_id: int,
	damage: int,
	source_type: String,
	reported_health_after: int,
	reported_is_dead: bool,
	hit_revision: int
) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id > 0 and sender_id != player_peer_id:
		return
	_apply_player_hit_report(
		source_id,
		player_peer_id,
		damage,
		StringName(source_type),
		reported_health_after,
		reported_is_dead,
		hit_revision
	)


func _apply_player_hit_report(
	source_id: int,
	player_peer_id: int,
	damage: int,
	source_type: StringName,
	reported_health_after: int,
	reported_is_dead: bool,
	_hit_revision: int
) -> void:
	if source_id <= 0 or player_peer_id <= 0 or damage <= 0:
		return
	var hit_key := "%d:%d:%s" % [source_id, player_peer_id, String(source_type)]
	if _processed_player_hit_ids.has(hit_key):
		return
	_processed_player_hit_ids[hit_key] = true
	var player_node := game.get_player_for_peer(player_peer_id) if game != null else null
	if player_node == null or not is_instance_valid(player_node):
		return
	if player_node.is_dead and not reported_is_dead:
		return
	var confirmed_health := clampi(reported_health_after, 0, player_node.max_health)
	if player_node.current_health > 0:
		confirmed_health = mini(confirmed_health, player_node.current_health)
	var confirmed_dead := reported_is_dead or confirmed_health <= 0
	player_node.set_multiplayer_health_state(confirmed_health, confirmed_dead)
	var health_revision := _next_player_health_revision(player_peer_id)
	if confirmed_dead:
		_schedule_player_revive(player_peer_id)
	net_player_damage_applied.rpc(
		player_peer_id,
		player_node.current_health,
		player_node.is_dead,
		health_revision
	)
	net_player_damage_applied(
		player_peer_id,
		player_node.current_health,
		player_node.is_dead,
		health_revision
	)


@rpc("authority", "call_remote", "reliable", 4)
func net_player_damage_applied(
	player_peer_id: int,
	current_health: int,
	is_dead: bool,
	health_revision: int
) -> void:
	if health_revision <= int(_player_health_revisions.get(player_peer_id, 0)):
		return
	_player_health_revisions[player_peer_id] = health_revision
	var player_node := game.get_player_for_peer(player_peer_id) if game != null else null
	if player_node == null or not is_instance_valid(player_node):
		return
	player_node.set_multiplayer_health_state(current_health, is_dead)

func register_xirang_orb(drop: XirangDrop, amount: int) -> void:
	if drop == null or not net_manager.is_host():
		return
	var orb_id := _next_xirang_orb_id
	_next_xirang_orb_id += 1
	drop.setup_multiplayer_orb(orb_id, amount, false)
	_xirang_orbs[orb_id] = {"amount": amount, "drop": drop}
	net_xirang_orb_spawned.rpc(orb_id, amount, drop.global_position)


@rpc("authority", "call_remote", "reliable", 4)
func net_xirang_orb_spawned(orb_id: int, amount: int, spawn_position: Vector2) -> void:
	if game == null or net_manager.is_host():
		return
	if _xirang_orbs.has(orb_id):
		return
	var drop := XIRANG_DROP_SCENE.instantiate() as XirangDrop
	if drop == null:
		return
	game.enemy_container.add_child(drop)
	drop.global_position = spawn_position
	drop.setup_multiplayer_orb(orb_id, amount, true)
	_xirang_orbs[orb_id] = {"amount": amount, "drop": drop}


func request_xirang_orb_collected(orb_id: int) -> void:
	if net_manager.is_host():
		_apply_xirang_orb_collected(orb_id, _get_local_peer_id())
	else:
		_rpc_xirang_orb_collected.rpc_id(_get_host_peer_id(), orb_id)


@rpc("any_peer", "call_remote", "reliable", 4)
func _rpc_xirang_orb_collected(orb_id: int) -> void:
	if not net_manager.is_host():
		return
	_apply_xirang_orb_collected(orb_id, multiplayer.get_remote_sender_id())


func _apply_xirang_orb_collected(orb_id: int, collector_peer_id: int) -> void:
	if orb_id <= 0 or _collected_xirang_orbs.has(orb_id) or not _xirang_orbs.has(orb_id):
		if collector_peer_id > 0:
			net_xirang_orb_removed.rpc_id(collector_peer_id, orb_id)
		return
	_collected_xirang_orbs[orb_id] = true
	var orb_data := _xirang_orbs[orb_id] as Dictionary
	var amount := int(orb_data.get("amount", 1))
	var revision := _xirang_revision + 1
	net_xirang_granted_all.rpc(orb_id, amount, revision)
	net_xirang_granted_all(orb_id, amount, revision)


@rpc("authority", "call_remote", "reliable", 4)
func net_xirang_granted_all(orb_id: int, amount: int, revision: int) -> void:
	if revision <= _xirang_revision:
		return
	_xirang_revision = revision
	_grant_xirang_to_all_players(amount)
	_remove_xirang_orb_local(orb_id, true)


@rpc("authority", "call_remote", "reliable", 4)
func net_xirang_orb_removed(orb_id: int) -> void:
	_remove_xirang_orb_local(orb_id, false)


func _remove_xirang_orb_local(orb_id: int, play_collect_feedback: bool) -> void:
	if not _xirang_orbs.has(orb_id):
		return
	var orb_data := _xirang_orbs[orb_id] as Dictionary
	var drop := orb_data.get("drop") as XirangDrop
	if drop != null and is_instance_valid(drop):
		if play_collect_feedback:
			drop.confirm_multiplayer_collect()
		else:
			drop.queue_free()
	_xirang_orbs.erase(orb_id)


func _grant_xirang_to_all_players(amount: int) -> void:
	if game == null:
		return
	for peer_id_variant in game.peer_players:
		var player_node := game.peer_players[peer_id_variant] as Player
		if player_node != null and is_instance_valid(player_node):
			player_node.grant_multiplayer_xirang(amount)

func get_local_multiplayer_player() -> Player:
	return game.player if game != null else null


func is_host_multiplayer_authority() -> bool:
	return net_manager != null and net_manager.is_host()


func _get_host_enemy_for_net_id(enemy_net_id: int) -> Enemy:
	if game == null:
		return null
	for child in game.enemy_container.get_children():
		var enemy := child as Enemy
		if enemy != null and int(enemy.get_meta("net_id", 0)) == enemy_net_id:
			return enemy
	return null


func _get_client_enemy_for_net_id(enemy_net_id: int) -> Enemy:
	return _get_valid_client_enemy_for_net_id(enemy_net_id)


func _get_valid_client_enemy_for_net_id(enemy_net_id: int) -> Enemy:
	var enemy_variant: Variant = _net_enemies.get(enemy_net_id)
	if enemy_variant == null:
		return null
	if not is_instance_valid(enemy_variant):
		_net_enemies.erase(enemy_net_id)
		_enemy_spawn_snapshot_times.erase(enemy_net_id)
		enemy_interpolators.erase(enemy_net_id)
		return null
	return enemy_variant as Enemy

func _next_player_health_revision(peer_id: int) -> int:
	var next_revision := int(_player_health_revisions.get(peer_id, 0)) + 1
	_player_health_revisions[peer_id] = next_revision
	return next_revision


func _schedule_player_revive(peer_id: int) -> void:
	if peer_id <= 0 or _dead_player_revive_times.has(peer_id):
		return
	_dead_player_revive_times[peer_id] = _get_net_time() + PLAYER_REVIVE_DELAY_SECONDS
	_dead_player_revive_last_seconds[peer_id] = -1
	net_player_revive_countdown.rpc(peer_id, int(ceil(PLAYER_REVIVE_DELAY_SECONDS)))
	net_player_revive_countdown(peer_id, int(ceil(PLAYER_REVIVE_DELAY_SECONDS)))


func _host_update_player_revives() -> void:
	if not net_manager.is_host() or game == null:
		return
	if game.wave_state == Game.WaveState.DEFEAT:
		return
	var now := _get_net_time()
	var due_peers: Array[int] = []
	for peer_id_variant in _dead_player_revive_times:
		var peer_id := int(peer_id_variant)
		var revive_at := float(_dead_player_revive_times[peer_id])
		var seconds_left := maxi(ceili(revive_at - now), 0)
		if seconds_left != int(_dead_player_revive_last_seconds.get(peer_id, -1)):
			_dead_player_revive_last_seconds[peer_id] = seconds_left
			net_player_revive_countdown.rpc(peer_id, seconds_left)
			net_player_revive_countdown(peer_id, seconds_left)
		if now >= revive_at:
			due_peers.append(peer_id)
	for peer_id in due_peers:
		var revive_position_variant: Variant = _pick_revive_position(peer_id)
		if revive_position_variant == null:
			continue
		var revive_position: Vector2 = revive_position_variant
		_revive_player_peer(peer_id, revive_position)


func _pick_revive_position(dead_peer_id: int) -> Variant:
	if game == null:
		return null
	var alive_positions: Array[Vector2] = []
	for peer_id_variant in game.peer_players:
		var peer_id := int(peer_id_variant)
		if peer_id == dead_peer_id:
			continue
		var player_node := game.peer_players[peer_id_variant] as Player
		if player_node != null and is_instance_valid(player_node) and not player_node.is_dead:
			alive_positions.append(player_node.global_position)
	if alive_positions.is_empty():
		return null
	return alive_positions[randi() % alive_positions.size()]


func _revive_player_peer(peer_id: int, revive_position: Vector2) -> void:
	var player_node := game.get_player_for_peer(peer_id) if game != null else null
	if player_node == null or not is_instance_valid(player_node):
		return
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	var now: float = _get_net_time()
	_accepted_player_state_positions[peer_id] = revive_position
	_accepted_player_state_times[peer_id] = now
	var player_interp: NetInterpolator = player_interpolators.get(peer_id) as NetInterpolator
	if player_interp != null:
		player_interp.clear()
	var health_revision := _next_player_health_revision(peer_id)
	player_node.revive_multiplayer(
		revive_position,
		player_node.max_health,
		PLAYER_REVIVE_INVINCIBILITY_SECONDS
	)
	net_player_state_corrected.rpc_id(peer_id, revive_position, Vector2.ZERO)
	net_player_revived.rpc(
		peer_id,
		revive_position,
		player_node.current_health,
		PLAYER_REVIVE_INVINCIBILITY_SECONDS,
		health_revision
	)
	net_player_revived(
		peer_id,
		revive_position,
		player_node.current_health,
		PLAYER_REVIVE_INVINCIBILITY_SECONDS,
		health_revision
	)


func _on_host_revive_all_requested() -> void:
	if not net_manager.is_host() or game == null:
		return
	var fallback_position: Variant = _get_first_alive_position()
	for peer_id_variant in game.peer_players:
		var peer_id := int(peer_id_variant)
		var player_node := game.peer_players[peer_id_variant] as Player
		if player_node == null or not is_instance_valid(player_node) or not player_node.is_dead:
			continue
		var revive_position: Vector2 = player_node.global_position
		if fallback_position != null:
			revive_position = fallback_position
		_revive_player_peer(peer_id, revive_position)


func _get_first_alive_position() -> Variant:
	if game == null:
		return null
	for peer_id_variant in game.peer_players:
		var player_node := game.peer_players[peer_id_variant] as Player
		if player_node != null and is_instance_valid(player_node) and not player_node.is_dead:
			return player_node.global_position
	return null


@rpc("authority", "call_remote", "reliable", 4)
func net_player_revive_countdown(peer_id: int, seconds_left: int) -> void:
	if game == null:
		return
	var player_node := game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	player_node.set_multiplayer_revive_countdown(seconds_left)


@rpc("authority", "call_remote", "reliable", 4)
func net_player_revived(
	peer_id: int,
	revive_position: Vector2,
	current_health: int,
	invincible_seconds: float,
	health_revision: int
) -> void:
	if health_revision <= int(_player_health_revisions.get(peer_id, 0)):
		return
	_player_health_revisions[peer_id] = health_revision
	var player_node := game.get_player_for_peer(peer_id) if game != null else null
	if player_node == null or not is_instance_valid(player_node):
		return
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	player_node.revive_multiplayer(revive_position, current_health, invincible_seconds)

func _on_host_enemy_spawned(
	net_id: int,
	enemy_config: EnemyConfig,
	spawn_position: Vector2
) -> void:
	if enemy_config == null:
		return
	net_enemy_spawned.rpc(net_id, enemy_config.resource_path, spawn_position.x, spawn_position.y, _get_net_time())


func _on_host_enemy_removed(net_id: int) -> void:
	net_enemy_removed.rpc(net_id)


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


func _on_host_wave_started(wave_index: int) -> void:
	net_wave_started.rpc(wave_index)

@rpc("authority", "call_remote", "reliable", 4)
func net_enemy_spawned(
	net_id: int,
	config_path: String,
	pos_x: float,
	pos_y: float,
	host_spawn_timestamp: float
) -> void:
	if game == null or net_manager.is_host():
		return
	_remove_client_enemy(net_id, false)
	var enemy_config: EnemyConfig = load(config_path) as EnemyConfig
	if enemy_config == null:
		return
	var spawn_scene: PackedScene = (
		enemy_config.enemy_scene_override
		if enemy_config.enemy_scene_override != null
		else game.enemy_scene
	)
	var enemy: Enemy = spawn_scene.instantiate() as Enemy
	if enemy == null:
		return
	game.enemy_container.add_child(enemy)
	var spawn_position: Vector2 = Vector2(pos_x, pos_y)
	var mapped_spawn_time: float = _map_host_timestamp_to_client_time(host_spawn_timestamp)
	_enemy_spawn_snapshot_times[net_id] = mapped_spawn_time
	enemy.global_position = _get_buffered_enemy_position(net_id, spawn_position)
	enemy.setup(enemy_config, game.player, game.grid_pathfinder)
	enemy.configure_multiplayer_proxy()
	enemy.set_meta("net_id", net_id)
	enemy.tree_exited.connect(_on_client_enemy_tree_exited.bind(net_id, enemy))
	_net_enemies[net_id] = enemy


@rpc("authority", "call_remote", "reliable", 4)
func net_enemy_removed(net_id: int) -> void:
	_remove_client_enemy(net_id, true)



func _on_client_enemy_tree_exited(net_id: int, exiting_enemy: Enemy) -> void:
	var enemy_variant: Variant = _net_enemies.get(net_id)
	if enemy_variant == null:
		return
	if is_instance_valid(enemy_variant) and enemy_variant != exiting_enemy:
		return
	_net_enemies.erase(net_id)
	_enemy_spawn_snapshot_times.erase(net_id)
	enemy_interpolators.erase(net_id)

func _get_buffered_enemy_position(net_id: int, fallback_position: Vector2) -> Vector2:
	var interp: NetInterpolator = enemy_interpolators.get(net_id) as NetInterpolator
	if interp == null or interp.get_buffer_size() <= 0:
		return fallback_position
	return interp.get_interpolated_position(_get_net_time())


func _reconcile_enemy_roster(seen_enemy_ids: Dictionary, snapshot_time: float) -> void:
	var stale_ids: Array[int] = []
	for net_id_variant in _net_enemies:
		var net_id := int(net_id_variant)
		if seen_enemy_ids.has(net_id):
			continue
		var spawn_time := float(_enemy_spawn_snapshot_times.get(net_id, -INF))
		if spawn_time > snapshot_time:
			continue
		stale_ids.append(net_id)
	for net_id in stale_ids:
		_remove_client_enemy(net_id, true)


func _remove_client_enemy(net_id: int, clear_interpolator: bool) -> void:
	var enemy_variant: Variant = _net_enemies.get(net_id)
	if enemy_variant != null and is_instance_valid(enemy_variant):
		var enemy: Enemy = enemy_variant as Enemy
		if enemy != null:
			enemy.queue_free()
	_net_enemies.erase(net_id)
	_enemy_spawn_snapshot_times.erase(net_id)
	if clear_interpolator:
		enemy_interpolators.erase(net_id)

@rpc("authority", "call_remote", "reliable", 4)
func net_pickup_removed(net_id: int) -> void:
	if game == null or net_manager.is_host():
		return
	var pickup: Pickup = game.get_pickup_for_net_id(net_id)
	if pickup == null or not is_instance_valid(pickup):
		game.multiplayer_pickups.erase(net_id)
		return
	game.multiplayer_pickups.erase(net_id)
	pickup.queue_free()


@rpc("authority", "call_remote", "reliable", 4)
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


@rpc("authority", "call_remote", "reliable", 4)
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


@rpc("authority", "call_remote", "reliable", 4)
func net_merchant_active_changed(active: bool) -> void:
	if game == null or net_manager.is_host():
		return
	game.apply_remote_merchant_active(active)



@rpc("authority", "call_remote", "reliable", 4)
func net_wave_started(wave_index: int) -> void:
	if game == null or net_manager.is_host():
		return
	game.apply_remote_wave_started(wave_index)


@rpc("any_peer", "call_remote", "reliable", 4)
func net_upgrade_selected(stat_type: int) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	_apply_upgrade_for_peer(sender_id, stat_type)


@rpc("any_peer", "call_remote", "reliable", 4)
func net_skill1_purchase_requested() -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	_apply_skill1_purchase_for_peer(sender_id)


@rpc("authority", "call_remote", "reliable", 4)
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
		var already_applied_on_host: bool = net_manager.is_host() and peer_id == _get_local_peer_id()
		if not already_applied_on_host:
			_apply_confirmed_upgrade_to_player(player_node, stat_type)
		player_node.current_xirang = current_xirang
		player_node.xirang_changed.emit(current_xirang, 0)


func _apply_confirmed_upgrade_to_player(player_node: Player, stat_type: int) -> void:
	match stat_type:
		RunStateStore.StatType.ATTACK:
			player_node.upgrade_attack()
		RunStateStore.StatType.HEALTH:
			player_node.upgrade_max_health()
		RunStateStore.StatType.ATTACK_SPEED:
			player_node.upgrade_attack_speed()
		RunStateStore.StatType.DODGE:
			player_node.upgrade_dodge()


@rpc("authority", "call_remote", "reliable", 4)
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
