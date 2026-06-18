extends Node2D

## 多人游戏场景主控脚本。
## Host: 运行完整物理模拟，广播快照，处理客户端输入。
## Client: 发送输入，接收快照，插值渲染。

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const GAME_SCENE_PATH := "res://scene/game.tscn"

@onready var net_manager: Node = get_node("/root/NetManager")

## 快照管理器（Host 端编码，Client 端解码用静态方法）
var snapshot_mgr: SnapshotManager = SnapshotManager.new()

## 远程实体的插值器  { peer_id/net_id: int → NetInterpolator }
var player_interpolators: Dictionary = {}
var enemy_interpolators: Dictionary = {}

## Host 分配的下一个网络 ID（敌人/道具）
var _next_net_id: int = 1

## 本局所有远程玩家节点  { peer_id → Player }
var _remote_players: Dictionary = {}

## Host: 所有活跃敌人  { net_id → Enemy }
var _net_enemies: Dictionary = {}

## 网络时间戳（使用本地 ticks 作为相对时间基准）
var _net_time_origin: float = 0.0


func _ready() -> void:
	_net_time_origin = Time.get_ticks_msec() / 1000.0
	net_manager.connection_state_changed.connect(_on_connection_state_changed)

	if net_manager.is_host():
		_setup_as_host()
	elif net_manager.is_client():
		_setup_as_client()


func _physics_process(_delta: float) -> void:
	var frame := net_manager.get_physics_frame_count()

	if net_manager.is_host():
		_host_physics_tick(frame)
	elif net_manager.is_client():
		_client_physics_tick(frame)


func _process(_delta: float) -> void:
	if net_manager.is_client():
		_client_interpolate_entities()


# ─────────────────────────────────────────────
# Host 初始化
# ─────────────────────────────────────────────

func _setup_as_host() -> void:
	print("MpGame: 以 Host 身份启动")
	# 游戏场景由 Host 加载并运行
	# TODO: 在真正实现时，这里会实例化 game.tscn 作为子节点
	#       目前先搭建网络框架骨架


func _setup_as_client() -> void:
	print("MpGame: 以 Client 身份启动")
	# Client 等待 Host 的完整状态快照


# ─────────────────────────────────────────────
# Host 物理帧逻辑
# ─────────────────────────────────────────────

func _host_physics_tick(frame: int) -> void:
	# 每 PLAYER_SNAPSHOT_INTERVAL_FRAMES 帧发送玩家快照
	if frame % _NetConstants.PLAYER_SNAPSHOT_INTERVAL_FRAMES == 0:
		_host_broadcast_player_snapshots()

	# 每 ENEMY_SNAPSHOT_INTERVAL_FRAMES 帧发送敌人快照
	if frame % _NetConstants.ENEMY_SNAPSHOT_INTERVAL_FRAMES == 0:
		_host_broadcast_enemy_snapshots()


func _host_broadcast_player_snapshots() -> void:
	var states: Array[SnapshotManager.PlayerState] = []

	# 收集所有玩家状态（包括 Host 自己）
	# TODO: 遍历实际的 Player 节点，读取 position/velocity/facing 等
	# 示例骨架：
	# for peer_id in net_manager.connected_players:
	#     var player_node = _get_player_node(peer_id)
	#     if player_node == null: continue
	#     var state = SnapshotManager.PlayerState.new()
	#     state.peer_id = peer_id
	#     state.position = player_node.global_position
	#     state.velocity = player_node.velocity
	#     state.health = player_node.current_health
	#     state.is_dead = player_node.is_dead
	#     states.append(state)

	if states.is_empty():
		return

	var data := snapshot_mgr.encode_all_player_snapshots(states)
	var timestamp := _get_net_time()
	_rpc_receive_player_snapshot.rpc(timestamp, data)


func _host_broadcast_enemy_snapshots() -> void:
	var states: Array[SnapshotManager.EnemyState] = []

	# TODO: 遍历所有活跃敌人，收集状态
	# for net_id in _net_enemies:
	#     var enemy = _net_enemies[net_id]
	#     if enemy == null or not is_instance_valid(enemy): continue
	#     var state = SnapshotManager.EnemyState.new()
	#     state.net_id = net_id
	#     state.position = enemy.global_position
	#     state.velocity = enemy.velocity
	#     state.health = enemy.current_health
	#     state.is_dead = enemy.is_dead
	#     states.append(state)

	if states.is_empty():
		return

	var data := snapshot_mgr.encode_all_enemy_snapshots(states)
	var timestamp := _get_net_time()
	_rpc_receive_enemy_snapshot.rpc(timestamp, data)


# ─────────────────────────────────────────────
# Client 物理帧逻辑
# ─────────────────────────────────────────────

func _client_physics_tick(frame: int) -> void:
	# 每 INPUT_SEND_INTERVAL_FRAMES 帧上报输入
	if frame % _NetConstants.INPUT_SEND_INTERVAL_FRAMES == 0:
		_client_send_input()


func _client_send_input() -> void:
	var move_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var shoot_input := Input.get_vector("shoot_left", "shoot_right", "shoot_up", "shoot_down")
	# TODO: 鼠标射击方向也需传入
	_rpc_client_input.rpc_id(1, move_input, shoot_input)


func _client_interpolate_entities() -> void:
	var current_time := _get_net_time()

	# 插值远程玩家
	for peer_id: int in player_interpolators:
		var interp: NetInterpolator = player_interpolators[peer_id]
		if peer_id == net_manager.get_local_peer_id():
			continue  # 本地玩家不需要插值

		var target_pos := interp.get_interpolated_position(current_time)
		var player_node: Node2D = _remote_players.get(peer_id)
		if player_node != null and is_instance_valid(player_node):
			player_node.global_position = target_pos

	# 插值远程敌人
	for net_id: int in enemy_interpolators:
		var interp: NetInterpolator = enemy_interpolators[net_id]
		var target_pos := interp.get_interpolated_position(current_time)
		var enemy_node: Node2D = _net_enemies.get(net_id)
		if enemy_node != null and is_instance_valid(enemy_node):
			enemy_node.global_position = target_pos


# ─────────────────────────────────────────────
# RPC：快照接收（Host → Client）
# ─────────────────────────────────────────────

@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_receive_player_snapshot(timestamp: float, data: PackedByteArray) -> void:
	var states := SnapshotManager.decode_all_player_snapshots(data)
	for state: SnapshotManager.PlayerState in states:
		if not player_interpolators.has(state.peer_id):
			player_interpolators[state.peer_id] = NetInterpolator.new(
				1.0 / _NetConstants.PLAYER_SNAPSHOT_HZ
			)
		var interp: NetInterpolator = player_interpolators[state.peer_id]
		interp.push_snapshot(
			timestamp,
			state.position,
			state.velocity,
			state.facing,
			state.anim_state,
			state.health,
			state.is_dead,
		)


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_receive_enemy_snapshot(timestamp: float, data: PackedByteArray) -> void:
	var states := SnapshotManager.decode_all_enemy_snapshots(data)
	for state: SnapshotManager.EnemyState in states:
		if not enemy_interpolators.has(state.net_id):
			enemy_interpolators[state.net_id] = NetInterpolator.new(
				1.0 / _NetConstants.ENEMY_SNAPSHOT_HZ
			)
		var interp: NetInterpolator = enemy_interpolators[state.net_id]
		interp.push_snapshot(
			timestamp,
			state.position,
			state.velocity,
			0, 0,
			state.health,
			state.is_dead,
		)


# ─────────────────────────────────────────────
# RPC：客户端输入上报（Client → Host）
# ─────────────────────────────────────────────

@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _rpc_client_input(move_input: Vector2, shoot_input: Vector2) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	# TODO: 将输入应用到对应 peer_id 的玩家节点上
	# var player = _get_player_node(sender_id)
	# if player: player.apply_remote_input(move_input, shoot_input)


# ─────────────────────────────────────────────
# RPC：可靠游戏事件（Host → All Clients，信道 3）
# ─────────────────────────────────────────────

@rpc("authority", "call_remote", "reliable", 3)
func net_enemy_spawned(net_id: int, config_path: String, pos_x: float, pos_y: float) -> void:
	# Client: 实例化敌人的视觉表现
	var position := Vector2(pos_x, pos_y)
	print("MpGame Client: 敌人生成 net_id=%d at %s" % [net_id, position])
	# TODO: 实例化敌人场景并定位


@rpc("authority", "call_remote", "reliable", 3)
func net_enemy_died(net_id: int, drop_config_path: String, drop_x: float, drop_y: float) -> void:
	var drop_position := Vector2(drop_x, drop_y)
	print("MpGame Client: 敌人死亡 net_id=%d, drop at %s" % [net_id, drop_position])
	# TODO: 播放死亡动画，生成掉落


@rpc("authority", "call_remote", "reliable", 3)
func net_player_died(peer_id: int) -> void:
	print("MpGame Client: 玩家死亡 peer_id=%d" % peer_id)
	# TODO: 对应玩家播放死亡动画


@rpc("authority", "call_remote", "reliable", 3)
func net_pickup_spawned(pickup_net_id: int, config_path: String, pos_x: float, pos_y: float) -> void:
	var position := Vector2(pos_x, pos_y)
	print("MpGame Client: 掉落生成 id=%d at %s" % [pickup_net_id, position])


@rpc("authority", "call_remote", "reliable", 3)
func net_wave_started(wave_index: int, total_enemies: int) -> void:
	print("MpGame Client: 波次 %d 开始, 总敌人 %d" % [wave_index + 1, total_enemies])


@rpc("authority", "call_remote", "reliable", 3)
func net_wave_ended(wave_index: int) -> void:
	print("MpGame Client: 波次 %d 结束" % (wave_index + 1))


@rpc("authority", "call_remote", "reliable", 3)
func net_boss_spawned(net_id: int, config_path: String, pos_x: float, pos_y: float) -> void:
	var position := Vector2(pos_x, pos_y)
	print("MpGame Client: Boss 生成 net_id=%d at %s" % [net_id, position])


## 子弹同步：Host 广播「某玩家开火」事件，客户端本地模拟弹道
@rpc("authority", "call_remote", "reliable", 3)
func net_player_fired(
	peer_id: int,
	pos_x: float, pos_y: float,
	dir_x: float, dir_y: float,
	shot_pattern: int,
	spiral_phase: float,
) -> void:
	var position := Vector2(pos_x, pos_y)
	var direction := Vector2(dir_x, dir_y)
	# Client 端本地实例化子弹做视觉飞行（不做碰撞）
	# TODO: 实例化子弹场景，设置碰撞层为 0


## Client → Host：升级选择
@rpc("any_peer", "call_remote", "reliable", 3)
func net_upgrade_selected(stat_type: int) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	print("MpGame Host: 玩家 %d 请求升级 stat_type=%d" % [sender_id, stat_type])
	# TODO: 验证并应用升级


# ─────────────────────────────────────────────
# 工具方法
# ─────────────────────────────────────────────

func _get_net_time() -> float:
	return Time.get_ticks_msec() / 1000.0 - _net_time_origin


func allocate_net_id() -> int:
	var id := _next_net_id
	_next_net_id += 1
	return id


func _on_connection_state_changed(new_state: int) -> void:
	if new_state == 0:  # ConnectionState.DISCONNECTED
		# 返回大厅
		get_tree().change_scene_to_file("res://scene/multiplayer/multiplayer_lobby.tscn")
