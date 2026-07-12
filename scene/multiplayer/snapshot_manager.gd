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
const PLAYER_META_BYTES := 36
const DEFAULT_CHARACTER_ID := &"weishidaier"
const HOE_CAT_CHARACTER_ID := &"hoe_cat"
const TIYI_CHARACTER_ID := &"tiyi"
const CHARACTER_CODE_WEISHIDAIER := 0
const CHARACTER_CODE_HOE_CAT := 1
const CHARACTER_CODE_TIYI := 2
const PACKED_I16_MIN := -32768
const PACKED_I16_MAX := 32767
const FULL_PLAYER_MASK := (
	MASK_POSITION
	| MASK_VELOCITY
	| MASK_FACING
	| MASK_ANIM_STATE
	| MASK_PLAYER_META
)
const FULL_ENEMY_MASK := MASK_POSITION | MASK_VELOCITY | MASK_HEALTH | MASK_IS_DEAD


# ─────────────────────────────────────────────
# 玩家快照
# ─────────────────────────────────────────────

## 单个玩家的当前帧状态
class PlayerState:
	var peer_id: int = 0
	var sequence: int = 0
	var character_id: StringName = DEFAULT_CHARACTER_ID
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
	var ammo_capacity: int = 1
	var current_ammo: int = 0
	var is_reloading: bool = false
	var reload_progress: float = 0.0
	var primary_cooldown_ratio: float = 0.0


## 每个接收端独立维护发送基线，避免丢包/晚加入导致不同客户端共用错误基准。
var player_send_baselines_by_peer: Dictionary = {}

## 每个接收端独立维护敌人发送基线。
var enemy_send_baselines_by_peer: Dictionary = {}

## Client 接收端玩家还原基线，用于把 delta 快照恢复为完整状态。
var player_receive_baselines: Dictionary = {}

## Client 接收端敌人还原基线。
var enemy_receive_baselines: Dictionary = {}


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
		mask = FULL_PLAYER_MASK
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
		buf.put_16(clampi(current.ammo_capacity, 1, 65535))
		buf.put_16(clampi(current.current_ammo, 0, 65535))
		buf.put_u8(1 if current.is_reloading else 0)
		buf.put_float(clampf(current.reload_progress, 0.0, 1.0))
		buf.put_u8(_encode_character_id(current.character_id))
		buf.put_u8(_pack_ratio_u8(current.primary_cooldown_ratio))

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
		or current.ammo_capacity != previous.ammo_capacity
		or current.current_ammo != previous.current_ammo
		or current.is_reloading != previous.is_reloading
		or not is_equal_approx(current.reload_progress, previous.reload_progress)
		or current.character_id != previous.character_id
		or _pack_ratio_u8(current.primary_cooldown_ratio)
		!= _pack_ratio_u8(previous.primary_cooldown_ratio)
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
		target.ammo_capacity = buf.get_u16()
		target.current_ammo = buf.get_u16()
		target.is_reloading = buf.get_u8() != 0
		target.reload_progress = buf.get_float()
		target.character_id = _decode_character_id(buf.get_u8())
		target.primary_cooldown_ratio = float(buf.get_u8()) / 255.0

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
	_write_enemy_snapshot(buf, current, previous)
	return buf.data_array


static func _get_enemy_change_mask(current: EnemyState, previous: EnemyState) -> int:
	if previous == null:
		return FULL_ENEMY_MASK
	var mask := 0
	if (
		_pack_scaled_i16(current.position.x, POSITION_SCALE)
		!= _pack_scaled_i16(previous.position.x, POSITION_SCALE)
		or _pack_scaled_i16(current.position.y, POSITION_SCALE)
		!= _pack_scaled_i16(previous.position.y, POSITION_SCALE)
	):
		mask |= MASK_POSITION
	if (
		_pack_scaled_i16(current.velocity.x, VELOCITY_SCALE)
		!= _pack_scaled_i16(previous.velocity.x, VELOCITY_SCALE)
		or _pack_scaled_i16(current.velocity.y, VELOCITY_SCALE)
		!= _pack_scaled_i16(previous.velocity.y, VELOCITY_SCALE)
	):
		mask |= MASK_VELOCITY
	if current.health != previous.health:
		mask |= MASK_HEALTH
	if current.is_dead != previous.is_dead:
		mask |= MASK_IS_DEAD
	return mask


static func _write_enemy_snapshot(
	buf: StreamPeerBuffer,
	current: EnemyState,
	previous: EnemyState
) -> void:
	buf.put_32(current.net_id)
	var mask := _get_enemy_change_mask(current, previous)

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
	_read_enemy_snapshot(buf, target)
	return buf.get_position()


static func _read_enemy_snapshot(buf: StreamPeerBuffer, target: EnemyState) -> void:
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


static func _encode_character_id(character_id: StringName) -> int:
	match character_id:
		HOE_CAT_CHARACTER_ID:
			return CHARACTER_CODE_HOE_CAT
		TIYI_CHARACTER_ID:
			return CHARACTER_CODE_TIYI
		_:
			return CHARACTER_CODE_WEISHIDAIER


static func _decode_character_id(character_code: int) -> StringName:
	match character_code:
		CHARACTER_CODE_HOE_CAT:
			return HOE_CAT_CHARACTER_ID
		CHARACTER_CODE_TIYI:
			return TIYI_CHARACTER_ID
		_:
			return DEFAULT_CHARACTER_ID


static func _pack_ratio_u8(value: float) -> int:
	return clampi(roundi(clampf(value, 0.0, 1.0) * 255.0), 0, 255)


static func _pack_scaled_i16(value: float, scale: float) -> int:
	return clampi(roundi(value * scale), PACKED_I16_MIN, PACKED_I16_MAX)


static func _copy_player_state(source: PlayerState) -> PlayerState:
	var copy := PlayerState.new()
	if source == null:
		return copy
	copy.peer_id = source.peer_id
	copy.sequence = source.sequence
	copy.character_id = source.character_id
	copy.position = source.position
	copy.velocity = source.velocity
	copy.facing = source.facing
	copy.anim_state = source.anim_state
	copy.current_health = source.current_health
	copy.max_health = source.max_health
	copy.current_xirang = source.current_xirang
	copy.is_dead = source.is_dead
	copy.invincibility_time_left = source.invincibility_time_left
	copy.skill1_unlocked = source.skill1_unlocked
	copy.skill1_charge = source.skill1_charge
	copy.skill1_charge_duration = source.skill1_charge_duration
	copy.skill1_upgrade_level = source.skill1_upgrade_level
	copy.form_mode = source.form_mode
	copy.shot_pattern = source.shot_pattern
	copy.ammo_capacity = source.ammo_capacity
	copy.current_ammo = source.current_ammo
	copy.is_reloading = source.is_reloading
	copy.reload_progress = source.reload_progress
	copy.primary_cooldown_ratio = source.primary_cooldown_ratio
	return copy


static func _copy_enemy_state(source: EnemyState) -> EnemyState:
	var copy := EnemyState.new()
	_copy_enemy_state_into(source, copy)
	return copy


static func _copy_enemy_state_into(source: EnemyState, target: EnemyState) -> void:
	if source == null or target == null:
		return
	target.net_id = source.net_id
	target.position = source.position
	target.velocity = source.velocity
	target.health = source.health
	target.is_dead = source.is_dead


static func _apply_player_delta(target: PlayerState, delta: PlayerState, mask: int) -> void:
	target.peer_id = delta.peer_id
	target.sequence = delta.sequence
	if mask & MASK_POSITION:
		target.position = delta.position
	if mask & MASK_VELOCITY:
		target.velocity = delta.velocity
	if mask & MASK_FACING:
		target.facing = delta.facing
	if mask & MASK_ANIM_STATE:
		target.anim_state = delta.anim_state
	if mask & MASK_PLAYER_META:
		target.current_health = delta.current_health
		target.max_health = delta.max_health
		target.current_xirang = delta.current_xirang
		target.is_dead = delta.is_dead
		target.invincibility_time_left = delta.invincibility_time_left
		target.skill1_unlocked = delta.skill1_unlocked
		target.skill1_charge = delta.skill1_charge
		target.skill1_charge_duration = delta.skill1_charge_duration
		target.skill1_upgrade_level = delta.skill1_upgrade_level
		target.form_mode = delta.form_mode
		target.shot_pattern = delta.shot_pattern
		target.ammo_capacity = delta.ammo_capacity
		target.current_ammo = delta.current_ammo
		target.is_reloading = delta.is_reloading
		target.reload_progress = delta.reload_progress
		target.character_id = delta.character_id
		target.primary_cooldown_ratio = delta.primary_cooldown_ratio


static func _apply_enemy_delta(target: EnemyState, delta: EnemyState, mask: int) -> void:
	target.net_id = delta.net_id
	if mask & MASK_POSITION:
		target.position = delta.position
	if mask & MASK_VELOCITY:
		target.velocity = delta.velocity
	if mask & MASK_HEALTH:
		target.health = delta.health
	if mask & MASK_IS_DEAD:
		target.is_dead = delta.is_dead


static func _is_full_player_mask(mask: int) -> bool:
	return (mask & FULL_PLAYER_MASK) == FULL_PLAYER_MASK


static func _is_full_enemy_mask(mask: int) -> bool:
	return (mask & FULL_ENEMY_MASK) == FULL_ENEMY_MASK


static func _get_player_snapshot_mask(data: PackedByteArray, offset: int) -> int:
	if offset < 0 or offset + PLAYER_SNAPSHOT_HEADER_BYTES > data.size():
		return -1
	return int(data[offset + PLAYER_SNAPSHOT_HEADER_BYTES - 1])


static func _get_enemy_snapshot_mask(data: PackedByteArray, offset: int) -> int:
	if offset < 0 or offset + ENEMY_SNAPSHOT_HEADER_BYTES > data.size():
		return -1
	return int(data[offset + ENEMY_SNAPSHOT_HEADER_BYTES - 1])


static func _prune_dictionary_to_ids(target: Dictionary, live_ids: Dictionary) -> void:
	var stale_ids: Array = []
	for id_variant in target.keys():
		if not live_ids.has(id_variant):
			stale_ids.append(id_variant)
	for id_variant in stale_ids:
		target.erase(id_variant)


func _get_player_send_baseline(receiver_peer_id: int) -> Dictionary:
	if not player_send_baselines_by_peer.has(receiver_peer_id):
		player_send_baselines_by_peer[receiver_peer_id] = {}
	return player_send_baselines_by_peer[receiver_peer_id] as Dictionary


func _get_enemy_send_baseline(receiver_peer_id: int) -> Dictionary:
	if not enemy_send_baselines_by_peer.has(receiver_peer_id):
		enemy_send_baselines_by_peer[receiver_peer_id] = {}
	return enemy_send_baselines_by_peer[receiver_peer_id] as Dictionary


# ─────────────────────────────────────────────
# 批量编码/解码 — 将多个快照打包为一条消息
# ─────────────────────────────────────────────

## 编码一批玩家快照。格式: [count:u8] [snapshot_0] [snapshot_1] ...
func encode_all_player_snapshots(players: Array[PlayerState]) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append(players.size())
	for player_state: PlayerState in players:
		buf.append_array(encode_player_snapshot(player_state, null))
	return buf


## 按接收端编码玩家快照。force_keyframe=true 时全部实体写 full。
func encode_player_snapshots_for_peer(
	receiver_peer_id: int,
	players: Array[PlayerState],
	force_keyframe: bool = false
) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append(players.size())
	var baseline := _get_player_send_baseline(receiver_peer_id)
	var live_ids: Dictionary = {}
	for player_state: PlayerState in players:
		live_ids[player_state.peer_id] = true
		var previous: PlayerState = null
		if not force_keyframe:
			previous = baseline.get(player_state.peer_id) as PlayerState
		buf.append_array(encode_player_snapshot(player_state, previous))
		baseline[player_state.peer_id] = _copy_player_state(player_state)
	_prune_dictionary_to_ids(baseline, live_ids)
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


## 使用接收端基线解码 delta 玩家快照；缺失基线的 delta 实体会被跳过。
func decode_player_snapshots_with_baseline(data: PackedByteArray) -> Array[PlayerState]:
	var result: Array[PlayerState] = []
	if data.is_empty():
		return result

	var count: int = data[0]
	var offset := 1
	var live_ids: Dictionary = {}
	var can_prune := true
	for _i in range(count):
		var snapshot_size := _get_player_snapshot_size(data, offset)
		if snapshot_size < 0 or offset + snapshot_size > data.size():
			can_prune = false
			break
		var mask := _get_player_snapshot_mask(data, offset)
		var delta := PlayerState.new()
		var next_offset := decode_player_snapshot(data, offset, delta)
		if next_offset <= offset or next_offset > data.size():
			can_prune = false
			break
		offset = next_offset

		var previous := player_receive_baselines.get(delta.peer_id) as PlayerState
		if previous == null and not _is_full_player_mask(mask):
			can_prune = false
			continue

		var restored := _copy_player_state(previous)
		_apply_player_delta(restored, delta, mask)
		player_receive_baselines[restored.peer_id] = _copy_player_state(restored)
		live_ids[restored.peer_id] = true
		result.append(restored)

	if can_prune and offset == data.size():
		_prune_dictionary_to_ids(player_receive_baselines, live_ids)
	return result


## 编码一批敌人快照
func encode_all_enemy_snapshots(enemies: Array[EnemyState]) -> PackedByteArray:
	var stream := StreamPeerBuffer.new()
	# 敌人数量用 uint16 表示（最多 65535）
	stream.put_u16(enemies.size())
	for enemy_state: EnemyState in enemies:
		_write_enemy_snapshot(stream, enemy_state, null)
	return stream.data_array


## 按接收端编码敌人快照。force_keyframe=true 时全部实体写 full。
func encode_enemy_snapshots_for_peer(
	receiver_peer_id: int,
	enemies: Array[EnemyState],
	force_keyframe: bool = false,
	prune_baseline: bool = true
) -> PackedByteArray:
	return _encode_enemy_snapshot_range_for_peer(
		receiver_peer_id,
		enemies,
		0,
		enemies.size(),
		force_keyframe,
		prune_baseline
	)


## 编码连续敌人区间，供多人分块发送使用；分块调用方在整批完成后统一 prune。
func encode_enemy_snapshot_range_for_peer(
	receiver_peer_id: int,
	enemies: Array[EnemyState],
	start_index: int,
	entity_count: int,
	force_keyframe: bool = false
) -> PackedByteArray:
	return _encode_enemy_snapshot_range_for_peer(
		receiver_peer_id,
		enemies,
		start_index,
		entity_count,
		force_keyframe,
		false
	)


func _encode_enemy_snapshot_range_for_peer(
	receiver_peer_id: int,
	enemies: Array[EnemyState],
	start_index: int,
	entity_count: int,
	force_keyframe: bool,
	prune_baseline: bool
) -> PackedByteArray:
	var resolved_start := clampi(start_index, 0, enemies.size())
	var resolved_count := clampi(entity_count, 0, enemies.size() - resolved_start)
	var stream := StreamPeerBuffer.new()
	stream.put_u16(resolved_count)

	var baseline := _get_enemy_send_baseline(receiver_peer_id)
	for state_index in range(resolved_start, resolved_start + resolved_count):
		var enemy_state: EnemyState = enemies[state_index]
		var previous: EnemyState = null
		if not force_keyframe:
			previous = baseline.get(enemy_state.net_id) as EnemyState
		_write_enemy_snapshot(stream, enemy_state, previous)
		var stored := baseline.get(enemy_state.net_id) as EnemyState
		if stored == null:
			stored = EnemyState.new()
			baseline[enemy_state.net_id] = stored
		_copy_enemy_state_into(enemy_state, stored)
	if prune_baseline:
		var live_ids: Dictionary = {}
		for state_index in range(resolved_start, resolved_start + resolved_count):
			var live_enemy_state: EnemyState = enemies[state_index]
			live_ids[live_enemy_state.net_id] = true
		_prune_dictionary_to_ids(baseline, live_ids)
	return stream.data_array


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
		stream.seek(offset)
		_read_enemy_snapshot(stream, state)
		var next_offset := stream.get_position()
		if next_offset <= offset or next_offset > data.size():
			break
		offset = next_offset
		result.append(state)
	return result


## 使用接收端基线解码 delta 敌人快照；缺失基线的 delta 实体会被跳过。
func decode_enemy_snapshots_with_baseline(
	data: PackedByteArray,
	prune_baseline: bool = true
) -> Array[EnemyState]:
	var result: Array[EnemyState] = []
	if data.size() < 2:
		return result

	var stream := StreamPeerBuffer.new()
	stream.data_array = data
	var count: int = stream.get_u16()
	var offset := 2
	var live_ids: Dictionary = {}
	var can_prune := true
	for _i in range(count):
		var snapshot_size := _get_enemy_snapshot_size(data, offset)
		if snapshot_size < 0 or offset + snapshot_size > data.size():
			can_prune = false
			break
		var mask := _get_enemy_snapshot_mask(data, offset)
		stream.seek(offset)
		var net_id := stream.get_32()
		var previous := enemy_receive_baselines.get(net_id) as EnemyState
		if previous == null and not _is_full_enemy_mask(mask):
			can_prune = false
			offset += snapshot_size
			continue

		var restored := EnemyState.new()
		_copy_enemy_state_into(previous, restored)
		stream.seek(offset)
		_read_enemy_snapshot(stream, restored)
		var next_offset := stream.get_position()
		if next_offset <= offset or next_offset > data.size():
			can_prune = false
			break
		offset = next_offset

		var stored := previous
		if stored == null:
			stored = EnemyState.new()
			enemy_receive_baselines[restored.net_id] = stored
		_copy_enemy_state_into(restored, stored)
		live_ids[restored.net_id] = true
		result.append(restored)

	if prune_baseline and can_prune and offset == data.size():
		_prune_dictionary_to_ids(enemy_receive_baselines, live_ids)
	return result


func prune_enemy_send_baseline_to_ids(receiver_peer_id: int, live_ids: Dictionary) -> void:
	var baseline := _get_enemy_send_baseline(receiver_peer_id)
	_prune_dictionary_to_ids(baseline, live_ids)


func prune_enemy_receive_baseline_to_ids(live_ids: Dictionary) -> void:
	_prune_dictionary_to_ids(enemy_receive_baselines, live_ids)


func clear_peer_delta_cache(peer_id: int) -> void:
	player_send_baselines_by_peer.erase(peer_id)
	enemy_send_baselines_by_peer.erase(peer_id)
	player_receive_baselines.erase(peer_id)
	for receiver_peer_id in player_send_baselines_by_peer.keys():
		var player_baseline := player_send_baselines_by_peer[receiver_peer_id] as Dictionary
		if player_baseline != null:
			player_baseline.erase(peer_id)


## 清除增量缓存（新一轮游戏或重连时调用）
func reset_delta_cache() -> void:
	player_send_baselines_by_peer.clear()
	enemy_send_baselines_by_peer.clear()
	player_receive_baselines.clear()
	enemy_receive_baselines.clear()
