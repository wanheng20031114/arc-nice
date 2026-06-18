extends RefCounted
class_name SnapshotManager

## 快照管理器：负责在 Host 端构建快照数据、增量压缩；
## 以及在 Client 端解析收到的快照。

## 位置精度系数 (× 10)，int16 覆盖 ±3276.7 像素
const POSITION_SCALE := 10.0
## 速度精度系数
const VELOCITY_SCALE := 10.0

## 变化掩码位
const MASK_POSITION := 1
const MASK_VELOCITY := 2
const MASK_FACING := 4
const MASK_ANIM_STATE := 8
const MASK_HEALTH := 16
const MASK_IS_DEAD := 32


# ─────────────────────────────────────────────
# 玩家快照
# ─────────────────────────────────────────────

## 单个玩家的当前帧状态
class PlayerState:
	var peer_id: int = 0
	var position: Vector2 = Vector2.ZERO
	var velocity: Vector2 = Vector2.ZERO
	var facing: int = 0       # 0=right, 1=left, 2=up, 3=down
	var anim_state: int = 0   # 动画枚举
	var health: int = 0
	var is_dead: bool = false


## 上一帧发送的玩家状态缓存（用于增量比较）
var _prev_player_states: Dictionary = {}   # peer_id → PlayerState

## 上一帧发送的敌人状态缓存
var _prev_enemy_states: Dictionary = {}    # net_id → EnemyState


## 构建玩家快照的二进制数据包
## 返回 PackedByteArray，可直接通过 RPC 发送
static func encode_player_snapshot(
	current: PlayerState,
	previous: PlayerState,
) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()

	# 1) peer_id (int32)
	buf.put_32(current.peer_id)

	# 2) 计算变化掩码
	var mask := 0
	if previous == null:
		mask = MASK_POSITION | MASK_VELOCITY | MASK_FACING | MASK_ANIM_STATE | MASK_HEALTH | MASK_IS_DEAD
	else:
		if not current.position.is_equal_approx(previous.position):
			mask |= MASK_POSITION
		if not current.velocity.is_equal_approx(previous.velocity):
			mask |= MASK_VELOCITY
		if current.facing != previous.facing:
			mask |= MASK_FACING
		if current.anim_state != previous.anim_state:
			mask |= MASK_ANIM_STATE
		if current.health != previous.health:
			mask |= MASK_HEALTH
		if current.is_dead != previous.is_dead:
			mask |= MASK_IS_DEAD

	# 3) 掩码 (uint8)
	buf.put_u8(mask)

	# 4) 按掩码写入变化字段
	if mask & MASK_POSITION:
		buf.put_16(int(current.position.x * POSITION_SCALE))
		buf.put_16(int(current.position.y * POSITION_SCALE))
	if mask & MASK_VELOCITY:
		buf.put_16(int(current.velocity.x * VELOCITY_SCALE))
		buf.put_16(int(current.velocity.y * VELOCITY_SCALE))
	if mask & MASK_FACING:
		buf.put_u8(current.facing)
	if mask & MASK_ANIM_STATE:
		buf.put_u8(current.anim_state)
	if mask & MASK_HEALTH:
		buf.put_16(current.health)
	if mask & MASK_IS_DEAD:
		buf.put_u8(1 if current.is_dead else 0)

	return buf.data_array


## 解码玩家快照数据，将变化应用到 target 上
static func decode_player_snapshot(
	data: PackedByteArray,
	offset: int,
	target: PlayerState,
) -> int:
	var buf := StreamPeerBuffer.new()
	buf.data_array = data
	buf.seek(offset)

	target.peer_id = buf.get_32()
	var mask: int = buf.get_u8()

	if mask & MASK_POSITION:
		target.position.x = buf.get_16() / POSITION_SCALE
		target.position.y = buf.get_16() / POSITION_SCALE
	if mask & MASK_VELOCITY:
		target.velocity.x = buf.get_16() / VELOCITY_SCALE
		target.velocity.y = buf.get_16() / VELOCITY_SCALE
	if mask & MASK_FACING:
		target.facing = buf.get_u8()
	if mask & MASK_ANIM_STATE:
		target.anim_state = buf.get_u8()
	if mask & MASK_HEALTH:
		target.health = buf.get_16()
	if mask & MASK_IS_DEAD:
		target.is_dead = buf.get_u8() != 0

	return buf.get_position()


# ─────────────────────────────────────────────
# 敌人快照
# ─────────────────────────────────────────────

class EnemyState:
	var net_id: int = 0
	var position: Vector2 = Vector2.ZERO
	var velocity: Vector2 = Vector2.ZERO
	var health: int = 0
	var is_dead: bool = false


## 构建敌人快照二进制数据
static func encode_enemy_snapshot(
	current: EnemyState,
	previous: EnemyState,
) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()

	buf.put_32(current.net_id)

	var mask := 0
	if previous == null:
		mask = MASK_POSITION | MASK_VELOCITY | MASK_HEALTH | MASK_IS_DEAD
	else:
		if not current.position.is_equal_approx(previous.position):
			mask |= MASK_POSITION
		if not current.velocity.is_equal_approx(previous.velocity):
			mask |= MASK_VELOCITY
		if current.health != previous.health:
			mask |= MASK_HEALTH
		if current.is_dead != previous.is_dead:
			mask |= MASK_IS_DEAD

	buf.put_u8(mask)

	if mask & MASK_POSITION:
		buf.put_16(int(current.position.x * POSITION_SCALE))
		buf.put_16(int(current.position.y * POSITION_SCALE))
	if mask & MASK_VELOCITY:
		buf.put_16(int(current.velocity.x * VELOCITY_SCALE))
		buf.put_16(int(current.velocity.y * VELOCITY_SCALE))
	if mask & MASK_HEALTH:
		buf.put_16(current.health)
	if mask & MASK_IS_DEAD:
		buf.put_u8(1 if current.is_dead else 0)

	return buf.data_array


## 解码敌人快照
static func decode_enemy_snapshot(
	data: PackedByteArray,
	offset: int,
	target: EnemyState,
) -> int:
	var buf := StreamPeerBuffer.new()
	buf.data_array = data
	buf.seek(offset)

	target.net_id = buf.get_32()
	var mask: int = buf.get_u8()

	if mask & MASK_POSITION:
		target.position.x = buf.get_16() / POSITION_SCALE
		target.position.y = buf.get_16() / POSITION_SCALE
	if mask & MASK_VELOCITY:
		target.velocity.x = buf.get_16() / VELOCITY_SCALE
		target.velocity.y = buf.get_16() / VELOCITY_SCALE
	if mask & MASK_HEALTH:
		target.health = buf.get_16()
	if mask & MASK_IS_DEAD:
		target.is_dead = buf.get_u8() != 0

	return buf.get_position()


# ─────────────────────────────────────────────
# 批量编码/解码 — 将多个快照打包为一条消息
# ─────────────────────────────────────────────

## 编码一批玩家快照。格式: [count:u8] [snapshot_0] [snapshot_1] ...
func encode_all_player_snapshots(players: Array[PlayerState]) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append(players.size())
	for player_state: PlayerState in players:
		var prev: PlayerState = _prev_player_states.get(player_state.peer_id)
		buf.append_array(encode_player_snapshot(player_state, prev))
		# 缓存本帧状态作为下一帧的比较基准
		_prev_player_states[player_state.peer_id] = player_state
	return buf


## 解码一批玩家快照
static func decode_all_player_snapshots(data: PackedByteArray) -> Array[PlayerState]:
	var result: Array[PlayerState] = []
	if data.is_empty():
		return result

	var count: int = data[0]
	var offset := 1
	for _i in range(count):
		var state := PlayerState.new()
		offset = decode_player_snapshot(data, offset, state)
		result.append(state)
	return result


## 编码一批敌人快照
func encode_all_enemy_snapshots(enemies: Array[EnemyState]) -> PackedByteArray:
	var buf := PackedByteArray()
	# 敌人数量用 uint16 表示（最多 65535）
	var stream := StreamPeerBuffer.new()
	stream.put_u16(enemies.size())
	buf.append_array(stream.data_array)

	for enemy_state: EnemyState in enemies:
		var prev: EnemyState = _prev_enemy_states.get(enemy_state.net_id)
		buf.append_array(encode_enemy_snapshot(enemy_state, prev))
		_prev_enemy_states[enemy_state.net_id] = enemy_state
	return buf


## 解码一批敌人快照
static func decode_all_enemy_snapshots(data: PackedByteArray) -> Array[EnemyState]:
	var result: Array[EnemyState] = []
	if data.size() < 2:
		return result

	var stream := StreamPeerBuffer.new()
	stream.data_array = data
	var count: int = stream.get_u16()
	var offset := 2
	for _i in range(count):
		var state := EnemyState.new()
		offset = decode_enemy_snapshot(data, offset, state)
		result.append(state)
	return result


## 清除增量缓存（新一轮游戏或重连时调用）
func reset_delta_cache() -> void:
	_prev_player_states.clear()
	_prev_enemy_states.clear()
