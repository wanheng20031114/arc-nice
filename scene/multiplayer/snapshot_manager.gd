extends RefCounted
class_name SnapshotManager

## 快照管理器：负责在 Host 端构建快照数据；
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
const MASK_XIRANG := 64
const MASK_PLAYER_META := 128

const PLAYER_SNAPSHOT_HEADER_BYTES := 9
const ENEMY_SNAPSHOT_HEADER_BYTES := 5
const PACKED_VECTOR2_BYTES := 4
const PACKED_U8_BYTES := 1
const PACKED_U16_BYTES := 2
const PACKED_U32_BYTES := 4
const PLAYER_META_BYTES := 25
const PACKED_I16_MIN := -32768
const PACKED_I16_MAX := 32767


# ─────────────────────────────────────────────
# 玩家快照
# ─────────────────────────────────────────────

## 单个玩家的当前帧状态
class PlayerState:
	var peer_id: int = 0
	var sequence: int = 0
	var position: Vector2 = Vector2.ZERO
	var velocity: Vector2 = Vector2.ZERO
	var facing: int = 0       # 0=right, 1=left, 2=up, 3=down
	var anim_state: int = 0   # 动画枚举
	var current_health: int = 0
	var max_health: int = 0
	var current_xirang: int = 0
	var is_dead: bool = false
	var invincibility_time_left: float = 0.0
	var skill1_unlocked: bool = false
	var skill1_charge: float = 0.0
	var skill1_charge_duration: float = 0.0
	var skill1_upgrade_level: int = 0
	var form_mode: int = 0
	var shot_pattern: int = 0


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

	# 1) peer_id + sequence (int32)
	buf.put_32(current.peer_id)
	buf.put_32(current.sequence)

	# 2) 计算变化掩码
	var mask := 0
	if previous == null:
		mask = (
			MASK_POSITION
			| MASK_VELOCITY
			| MASK_FACING
			| MASK_ANIM_STATE
			| MASK_PLAYER_META
		)
	else:
		if not current.position.is_equal_approx(previous.position):
			mask |= MASK_POSITION
		if not current.velocity.is_equal_approx(previous.velocity):
			mask |= MASK_VELOCITY
		if current.facing != previous.facing:
			mask |= MASK_FACING
		if current.anim_state != previous.anim_state:
			mask |= MASK_ANIM_STATE
		if _player_meta_changed(current, previous):
			mask |= MASK_PLAYER_META

	# 3) 掩码 (uint8)
	buf.put_u8(mask)

	# 4) 按掩码写入变化字段
	if mask & MASK_POSITION:
		buf.put_16(_pack_scaled_i16(current.position.x, POSITION_SCALE))
		buf.put_16(_pack_scaled_i16(current.position.y, POSITION_SCALE))
	if mask & MASK_VELOCITY:
		buf.put_16(_pack_scaled_i16(current.velocity.x, VELOCITY_SCALE))
		buf.put_16(_pack_scaled_i16(current.velocity.y, VELOCITY_SCALE))
	if mask & MASK_FACING:
		buf.put_u8(current.facing)
	if mask & MASK_ANIM_STATE:
		buf.put_u8(current.anim_state)
	if mask & MASK_PLAYER_META:
		buf.put_16(current.current_health)
		buf.put_16(current.max_health)
		buf.put_32(current.current_xirang)
		buf.put_u8(1 if current.is_dead else 0)
		buf.put_float(current.invincibility_time_left)
		buf.put_u8(1 if current.skill1_unlocked else 0)
		buf.put_float(current.skill1_charge)
		buf.put_float(current.skill1_charge_duration)
		buf.put_u8(clampi(current.skill1_upgrade_level, 0, 255))
		buf.put_u8(current.form_mode)
		buf.put_u8(current.shot_pattern)

	return buf.data_array


## 解码玩家快照数据，将变化应用到 target 上

static func _player_meta_changed(current: PlayerState, previous: PlayerState) -> bool:
	return (
		current.current_health != previous.current_health
		or current.max_health != previous.max_health
		or current.current_xirang != previous.current_xirang
		or current.is_dead != previous.is_dead
		or not is_equal_approx(current.invincibility_time_left, previous.invincibility_time_left)
		or current.skill1_unlocked != previous.skill1_unlocked
		or not is_equal_approx(current.skill1_charge, previous.skill1_charge)
		or not is_equal_approx(current.skill1_charge_duration, previous.skill1_charge_duration)
		or current.skill1_upgrade_level != previous.skill1_upgrade_level
		or current.form_mode != previous.form_mode
		or current.shot_pattern != previous.shot_pattern
	)

static func decode_player_snapshot(
	data: PackedByteArray,
	offset: int,
	target: PlayerState,
) -> int:
	var snapshot_size := _get_player_snapshot_size(data, offset)
	if snapshot_size < 0 or offset + snapshot_size > data.size():
		return offset
	var buf := StreamPeerBuffer.new()
	buf.data_array = data
	buf.seek(offset)

	target.peer_id = buf.get_32()
	target.sequence = buf.get_32()
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
	if mask & MASK_PLAYER_META:
		target.current_health = buf.get_16()
		target.max_health = buf.get_16()
		target.current_xirang = buf.get_32()
		target.is_dead = buf.get_u8() != 0
		target.invincibility_time_left = buf.get_float()
		target.skill1_unlocked = buf.get_u8() != 0
		target.skill1_charge = buf.get_float()
		target.skill1_charge_duration = buf.get_float()
		target.skill1_upgrade_level = buf.get_u8()
		target.form_mode = buf.get_u8()
		target.shot_pattern = buf.get_u8()

	return buf.get_position()


static func _get_player_snapshot_size(data: PackedByteArray, offset: int) -> int:
	if offset < 0 or offset + PLAYER_SNAPSHOT_HEADER_BYTES > data.size():
		return -1
	var mask := int(data[offset + PLAYER_SNAPSHOT_HEADER_BYTES - 1])
	var size := PLAYER_SNAPSHOT_HEADER_BYTES
	if mask & MASK_POSITION:
		size += PACKED_VECTOR2_BYTES
	if mask & MASK_VELOCITY:
		size += PACKED_VECTOR2_BYTES
	if mask & MASK_FACING:
		size += PACKED_U8_BYTES
	if mask & MASK_ANIM_STATE:
		size += PACKED_U8_BYTES
	if mask & MASK_PLAYER_META:
		size += PLAYER_META_BYTES
	return size


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
		buf.put_16(_pack_scaled_i16(current.position.x, POSITION_SCALE))
		buf.put_16(_pack_scaled_i16(current.position.y, POSITION_SCALE))
	if mask & MASK_VELOCITY:
		buf.put_16(_pack_scaled_i16(current.velocity.x, VELOCITY_SCALE))
		buf.put_16(_pack_scaled_i16(current.velocity.y, VELOCITY_SCALE))
	if mask & MASK_HEALTH:
		buf.put_32(current.health)
	if mask & MASK_IS_DEAD:
		buf.put_u8(1 if current.is_dead else 0)

	return buf.data_array


## 解码敌人快照
static func decode_enemy_snapshot(
	data: PackedByteArray,
	offset: int,
	target: EnemyState,
) -> int:
	var snapshot_size := _get_enemy_snapshot_size(data, offset)
	if snapshot_size < 0 or offset + snapshot_size > data.size():
		return offset
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
		target.health = buf.get_32()
	if mask & MASK_IS_DEAD:
		target.is_dead = buf.get_u8() != 0

	return buf.get_position()


static func _get_enemy_snapshot_size(data: PackedByteArray, offset: int) -> int:
	if offset < 0 or offset + ENEMY_SNAPSHOT_HEADER_BYTES > data.size():
		return -1
	var mask := int(data[offset + ENEMY_SNAPSHOT_HEADER_BYTES - 1])
	var size := ENEMY_SNAPSHOT_HEADER_BYTES
	if mask & MASK_POSITION:
		size += PACKED_VECTOR2_BYTES
	if mask & MASK_VELOCITY:
		size += PACKED_VECTOR2_BYTES
	if mask & MASK_HEALTH:
		size += PACKED_U32_BYTES
	if mask & MASK_IS_DEAD:
		size += PACKED_U8_BYTES
	return size


static func _pack_scaled_i16(value: float, scale: float) -> int:
	return clampi(roundi(value * scale), PACKED_I16_MIN, PACKED_I16_MAX)


# ─────────────────────────────────────────────
# 批量编码/解码 — 将多个快照打包为一条消息
# ─────────────────────────────────────────────

## 编码一批玩家快照。格式: [count:u8] [snapshot_0] [snapshot_1] ...
func encode_all_player_snapshots(players: Array[PlayerState]) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append(players.size())
	for player_state: PlayerState in players:
		buf.append_array(encode_player_snapshot(player_state, null))
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
		var snapshot_size := _get_player_snapshot_size(data, offset)
		if snapshot_size < 0 or offset + snapshot_size > data.size():
			break
		var state := PlayerState.new()
		var next_offset := decode_player_snapshot(data, offset, state)
		if next_offset <= offset or next_offset > data.size():
			break
		offset = next_offset
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
		buf.append_array(encode_enemy_snapshot(enemy_state, null))
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
		var snapshot_size := _get_enemy_snapshot_size(data, offset)
		if snapshot_size < 0 or offset + snapshot_size > data.size():
			break
		var state := EnemyState.new()
		var next_offset := decode_enemy_snapshot(data, offset, state)
		if next_offset <= offset or next_offset > data.size():
			break
		offset = next_offset
		result.append(state)
	return result


## 清除增量缓存（新一轮游戏或重连时调用）
func reset_delta_cache() -> void:
	_prev_player_states.clear()
	_prev_enemy_states.clear()
