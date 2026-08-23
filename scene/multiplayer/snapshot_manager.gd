extends RefCounted
class_name SnapshotManager

const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const CombatRelationServiceScript := preload(
	"res://scene/combat/faction/combat_relation_service.gd"
)

## 快照管理器：负责在 Host 端构建快照数据；
## 以及在 Client 端解析收到的快照。

## 位置精度系数 (× 10)。玩家使用 int32，敌人继续使用 int16。
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
const MASK_AUXILIARY := 64
const MASK_XIRANG := MASK_AUXILIARY
const MASK_ENEMY_VISUAL_STATUS := MASK_AUXILIARY
const MASK_PLAYER_META := 128
const MASK_ENEMY_LOCOMOTION := MASK_ANIM_STATE

const ENEMY_LOCOMOTION_IDLE := 0
const ENEMY_LOCOMOTION_MOVING := 1

const PLAYER_SNAPSHOT_HEADER_BYTES := 9
## 不经 delta 基线的玩家瞬态：充能电池 1B + 表现状态 1B + 最终开火间隔 2B。
## 这类值会被不同可靠频道上的物品/技能事务修改，必须逐帧绝对发送，
## 否则一次丢包就可能让客户端沿用旧射速直到下一次 keyframe。
const PLAYER_REALTIME_STATUS_BYTES := 4
const ENEMY_SNAPSHOT_HEADER_BYTES := 5
## 协议 94 的敌人快照由 MpEnemyCoordinator 固定分块。解码端同样执行该
## wire 上限，避免伪造的 uint16 count 扩张长期复用的 staging pool。
const ENEMY_SNAPSHOT_MAX_RECORDS_PER_PACKET := 41
const PACKED_VECTOR2_I16_BYTES := 4
const PACKED_VECTOR2_I32_BYTES := 8
const PACKED_U8_BYTES := 1
const PACKED_U16_BYTES := 2
const PACKED_U32_BYTES := 4
## 阵营随敌人 full keyframe 绝对发送：faction_id:u8 + faction_revision:u32。
## 普通 delta 不占用既有掩码位；可靠阵营事件负责实时变化，keyframe 负责重连修复。
const ENEMY_FACTION_KEYFRAME_BYTES := PACKED_U8_BYTES + PACKED_U32_BYTES
const PLAYER_META_BYTES := 46
const MOVE_MULTIPLIER_SCALE := 1000.0
const FIRE_INTERVAL_SCALE := 1000.0
const DEFAULT_CHARACTER_ID := &"weishidaier"
const HOE_CAT_CHARACTER_ID := &"hoe_cat"
const TIYI_CHARACTER_ID := &"tiyi"
const TANGO_CHARACTER_ID := &"tango"
const CHARACTER_CODE_WEISHIDAIER := 0
const CHARACTER_CODE_HOE_CAT := 1
const CHARACTER_CODE_TIYI := 2
const CHARACTER_CODE_TANGO := 3
const PACKED_I16_MIN := -32768
const PACKED_I16_MAX := 32767
const PACKED_I32_MIN := -0x80000000
const PACKED_I32_MAX := 0x7FFFFFFF
const FULL_PLAYER_MASK := (
	MASK_POSITION
	| MASK_VELOCITY
	| MASK_FACING
	| MASK_ANIM_STATE
	| MASK_PLAYER_META
)
## 玩家状态走 unreliable_ordered。位置、速度、朝向和动画若只在变化帧发送，
## 丢失一次停止/转向帧后，发送端基线已经前进，而接收端会保留旧运动直到关键帧。
## 因此轻量的运动表现字段每帧绝对发送；体积较大的 meta 仍保留 delta。
const PLAYER_REALTIME_MOTION_MASK := (
	MASK_POSITION
	| MASK_VELOCITY
	| MASK_FACING
	| MASK_ANIM_STATE
)
const FULL_ENEMY_MASK := (
	MASK_POSITION
	| MASK_VELOCITY
	| MASK_ENEMY_LOCOMOTION
	| MASK_HEALTH
	| MASK_IS_DEAD
	| MASK_ENEMY_VISUAL_STATUS
)


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
	## 与可靠生命事件共用的 Host 单调修订号，用于跨 RPC 通道拒绝陈旧生命快照。
	var health_revision: int = 0
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
	## 每帧绝对发送，收敛物品事务与技能确认跨 ENet 频道的乱序。
	var void_battery_charged: bool = false
	## Host 当前玩家表现位；不在客户端重放伤害，只修复晚加入/丢包后的视觉。
	var visual_status_mask: int = 0
	## Host 权威的最终有效移速相对角色稳定初始移速的倍率；包含平铺属性、
	## 支援塔、角色形态与收藏品等运行时修正。保持既有 u16 定点字段，不扩包。
	var effective_move_speed_multiplier: float = 1.0
	## Host 权威的最终有效开火间隔（秒）。它包含普通/药水/角色形态射速、
	## 收藏品加速与塔加成；使用毫秒 u16，并与 void battery 一样逐帧绝对发送。
	var effective_fire_interval_seconds: float = 1.0


## 按接收端或经过调用方认证的共享 cohort 维护玩家发送基线。
## cohort 成员必须拥有相同发送历史；缺席/晚加入成员须先收到 full keyframe。
var player_send_baselines_by_peer: Dictionary = {}

## 按接收端或共享 cohort 维护敌人发送基线，成员约束同上。
var enemy_send_baselines_by_peer: Dictionary = {}

## Client 接收端玩家还原基线，用于把 delta 快照恢复为完整状态。
var player_receive_baselines: Dictionary = {}

## Client 接收端敌人还原基线。
var enemy_receive_baselines: Dictionary = {}

## 接收解码结果按实体复用。调用方应在下一次同类解码前消费返回值，勿长期持有引用。
var player_receive_output_states: Dictionary = {}
var enemy_receive_output_states: Dictionary = {}
## 敌人整包原子解码的临时对象按“包内记录序号”复用。不能按网络 net-id
## 建池，否则攻击者可以用不断变化的 ID 扩张字典；序号池只会增长到单包实际
## 通过长度校验的记录数，生产分块上限为 41。
var enemy_receive_staging_states: Array[EnemyState] = []


## 构建玩家快照的二进制数据包
## 返回 PackedByteArray，可直接通过 RPC 发送
static func encode_player_snapshot(
	current: PlayerState,
	previous: PlayerState,
) -> PackedByteArray:
	if not is_player_snapshot_state_serializable(current):
		push_error(
			"SnapshotManager: 拒绝序列化非法玩家快照 peer=%d health=%d/%d。"
			% [
				current.peer_id if current != null else 0,
				current.current_health if current != null else -1,
				current.max_health if current != null else -1,
			]
		)
		return PackedByteArray()
	var buf := StreamPeerBuffer.new()

	# 1) peer_id + sequence (int32)
	buf.put_32(current.peer_id)
	buf.put_32(current.sequence)

	# 2) 计算变化掩码
	var mask := 0
	if previous == null:
		mask = FULL_PLAYER_MASK
	else:
		mask = PLAYER_REALTIME_MOTION_MASK
		if _player_meta_changed(current, previous):
			mask |= MASK_PLAYER_META

	# 3) 掩码 (uint8)
	buf.put_u8(mask)

	# 4) 按掩码写入变化字段
	if mask & MASK_POSITION:
		buf.put_32(_pack_scaled_i32(current.position.x, POSITION_SCALE))
		buf.put_32(_pack_scaled_i32(current.position.y, POSITION_SCALE))
	if mask & MASK_VELOCITY:
		buf.put_16(_pack_scaled_i16(current.velocity.x, VELOCITY_SCALE))
		buf.put_16(_pack_scaled_i16(current.velocity.y, VELOCITY_SCALE))
	if mask & MASK_FACING:
		buf.put_u8(current.facing)
	if mask & MASK_ANIM_STATE:
		buf.put_u8(current.anim_state)
	if mask & MASK_PLAYER_META:
		buf.put_32(current.current_health)
		buf.put_32(current.max_health)
		buf.put_u32(current.health_revision)
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
		buf.put_u16(_pack_scaled_u16(
			current.effective_move_speed_multiplier,
			MOVE_MULTIPLIER_SCALE
		))
	# Transient item state is absolute each frame instead of delta/meta. It may
	# arm and discharge between adjacent snapshots, while the reliable inventory
	# transaction is delivered on another ENet channel.
	buf.put_u8(1 if current.void_battery_charged else 0)
	buf.put_u8(clampi(current.visual_status_mask, 0, 255))
	buf.put_u16(_pack_scaled_u16(
		current.effective_fire_interval_seconds,
		FIRE_INTERVAL_SCALE
	))

	return buf.data_array


static func is_player_snapshot_state_serializable(state: PlayerState) -> bool:
	return (
		state != null
		and state.position.is_finite()
		and state.velocity.is_finite()
		and NetConstants.is_valid_network_combat_value(state.current_health)
		and NetConstants.is_valid_network_combat_value(state.max_health)
		and NetConstants.is_valid_network_combat_value(state.health_revision)
		and is_finite(state.effective_move_speed_multiplier)
		and state.effective_move_speed_multiplier >= 0.0
		and is_finite(state.effective_fire_interval_seconds)
		and state.effective_fire_interval_seconds > 0.0
	)


static func are_player_snapshot_states_serializable(
	players: Array[PlayerState]
) -> bool:
	if players.size() > 255:
		return false
	for state in players:
		if not is_player_snapshot_state_serializable(state):
			return false
	return true


## 解码玩家快照数据，将变化应用到 target 上

static func _player_meta_changed(current: PlayerState, previous: PlayerState) -> bool:
	return (
		current.current_health != previous.current_health
		or current.max_health != previous.max_health
		or current.health_revision != previous.health_revision
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
		or _pack_scaled_u16(
			current.effective_move_speed_multiplier,
			MOVE_MULTIPLIER_SCALE
		) != _pack_scaled_u16(
			previous.effective_move_speed_multiplier,
			MOVE_MULTIPLIER_SCALE
		)
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
		target.position.x = buf.get_32() / POSITION_SCALE
		target.position.y = buf.get_32() / POSITION_SCALE
	if mask & MASK_VELOCITY:
		target.velocity.x = buf.get_16() / VELOCITY_SCALE
		target.velocity.y = buf.get_16() / VELOCITY_SCALE
	if mask & MASK_FACING:
		target.facing = buf.get_u8()
	if mask & MASK_ANIM_STATE:
		target.anim_state = buf.get_u8()
	if mask & MASK_PLAYER_META:
		target.current_health = buf.get_32()
		target.max_health = buf.get_32()
		target.health_revision = buf.get_u32()
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
		target.effective_move_speed_multiplier = (
			float(buf.get_u16()) / MOVE_MULTIPLIER_SCALE
		)
	target.void_battery_charged = buf.get_u8() != 0
	target.visual_status_mask = buf.get_u8()
	target.effective_fire_interval_seconds = (
		float(buf.get_u16()) / FIRE_INTERVAL_SCALE
	)

	return buf.get_position()


static func _get_player_snapshot_size(data: PackedByteArray, offset: int) -> int:
	if offset < 0 or offset + PLAYER_SNAPSHOT_HEADER_BYTES > data.size():
		return -1
	var mask := int(data[offset + PLAYER_SNAPSHOT_HEADER_BYTES - 1])
	var size := PLAYER_SNAPSHOT_HEADER_BYTES + PLAYER_REALTIME_STATUS_BYTES
	if mask & MASK_POSITION:
		size += PACKED_VECTOR2_I32_BYTES
	if mask & MASK_VELOCITY:
		size += PACKED_VECTOR2_I16_BYTES
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
	## 离散移动语义：0=静止、1=移动。不得由接收端的量化速度反推。
	var locomotion_state: int = ENEMY_LOCOMOTION_IDLE
	var health: int = 0
	## 与伤害反馈共用的 Host 单调修订号，允许敌人在同一 net-id 生命周期内治疗。
	var health_revision: int = 0
	var is_dead: bool = false
	## 纯表现状态位：0..4 为通用 burn/bleed/chill/mark/electric；5..6 为
	## 场景互斥的敌人专用状态。盾兵以两位编码盾态，v45 忍者以 bit5 编码
	## 短时加速态；伤害、耐久和实际速度仍只由 Host 结算。
	var visual_status_mask: int = 0
	## 只附加在 full keyframe 尾部，不改变既有 24-byte 字段顺序。
	var faction_id: int = CombatRelationServiceScript.HOSTILE_WAVE
	var faction_revision: int = 0


## 构建敌人快照二进制数据
static func encode_enemy_snapshot(
	current: EnemyState,
	previous: EnemyState,
) -> PackedByteArray:
	if not is_enemy_snapshot_state_serializable(current):
		push_error(
			"SnapshotManager: 拒绝序列化非法敌人快照 net_id=%d health=%d。"
			% [
				current.net_id if current != null else 0,
				current.health if current != null else -1,
			]
		)
		return PackedByteArray()
	var buf := StreamPeerBuffer.new()
	_write_enemy_snapshot(buf, current, previous)
	return buf.data_array


static func is_enemy_snapshot_state_serializable(state: EnemyState) -> bool:
	return (
		state != null
		and state.position.is_finite()
		and state.velocity.is_finite()
		and NetConstants.is_valid_network_combat_value(state.health)
		and NetConstants.is_valid_network_combat_value(state.health_revision)
		and CombatRelationServiceScript.is_valid_faction_id(state.faction_id)
		and NetConstants.is_valid_network_combat_value(state.faction_revision)
	)


static func are_enemy_snapshot_states_serializable(
	enemies: Array[EnemyState]
) -> bool:
	if enemies.size() > 65535:
		return false
	for state in enemies:
		if not is_enemy_snapshot_state_serializable(state):
			return false
	return true


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
	if (
		_normalize_enemy_locomotion_state(current.locomotion_state)
		!= _normalize_enemy_locomotion_state(previous.locomotion_state)
	):
		mask |= MASK_ENEMY_LOCOMOTION
	if (
		current.health != previous.health
		or current.health_revision != previous.health_revision
	):
		mask |= MASK_HEALTH
	if current.is_dead != previous.is_dead:
		mask |= MASK_IS_DEAD
	if current.visual_status_mask != previous.visual_status_mask:
		mask |= MASK_ENEMY_VISUAL_STATUS
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
	if mask & MASK_ENEMY_LOCOMOTION:
		buf.put_u8(_normalize_enemy_locomotion_state(current.locomotion_state))
	if mask & MASK_HEALTH:
		buf.put_32(current.health)
		buf.put_u32(current.health_revision)
	if mask & MASK_IS_DEAD:
		buf.put_u8(1 if current.is_dead else 0)
	if mask & MASK_ENEMY_VISUAL_STATUS:
		buf.put_u8(clampi(current.visual_status_mask, 0, 255))
	if _is_full_enemy_mask(mask):
		buf.put_u8(current.faction_id)
		buf.put_u32(current.faction_revision)


## 解码敌人快照
static func decode_enemy_snapshot(
	data: PackedByteArray,
	offset: int,
	target: EnemyState,
) -> int:
	if target == null:
		return offset
	var snapshot_size := _get_enemy_snapshot_size(data, offset)
	if snapshot_size < 0 or offset + snapshot_size > data.size():
		return offset
	# 单条解码同样采用临时对象：delta 需要先继承调用方基线，但只有完整
	# 重建状态通过网络边界校验后才允许写回，避免非法包部分污染 target。
	var restored := EnemyState.new()
	_copy_enemy_state_into(target, restored)
	var buf := StreamPeerBuffer.new()
	buf.data_array = data
	buf.seek(offset)
	_read_enemy_snapshot(buf, restored)
	var next_offset := buf.get_position()
	if (
		next_offset != offset + snapshot_size
		or not _is_received_enemy_state_valid(restored)
	):
		return offset
	_copy_enemy_state_into(restored, target)
	return next_offset


static func _read_enemy_snapshot(buf: StreamPeerBuffer, target: EnemyState) -> void:
	target.net_id = buf.get_32()
	var mask: int = buf.get_u8()

	if mask & MASK_POSITION:
		target.position.x = buf.get_16() / POSITION_SCALE
		target.position.y = buf.get_16() / POSITION_SCALE
	if mask & MASK_VELOCITY:
		target.velocity.x = buf.get_16() / VELOCITY_SCALE
		target.velocity.y = buf.get_16() / VELOCITY_SCALE
	if mask & MASK_ENEMY_LOCOMOTION:
		target.locomotion_state = _normalize_enemy_locomotion_state(buf.get_u8())
	if mask & MASK_HEALTH:
		target.health = buf.get_32()
		target.health_revision = buf.get_u32()
	if mask & MASK_IS_DEAD:
		target.is_dead = buf.get_u8() != 0
	if mask & MASK_ENEMY_VISUAL_STATUS:
		target.visual_status_mask = buf.get_u8()
	if _is_full_enemy_mask(mask):
		target.faction_id = buf.get_u8()
		target.faction_revision = buf.get_u32()


static func _get_enemy_snapshot_size(data: PackedByteArray, offset: int) -> int:
	if offset < 0 or offset + ENEMY_SNAPSHOT_HEADER_BYTES > data.size():
		return -1
	var mask := int(data[offset + ENEMY_SNAPSHOT_HEADER_BYTES - 1])
	if not _is_valid_enemy_snapshot_mask(mask):
		return -1
	var size := ENEMY_SNAPSHOT_HEADER_BYTES
	if mask & MASK_POSITION:
		size += PACKED_VECTOR2_I16_BYTES
	if mask & MASK_VELOCITY:
		size += PACKED_VECTOR2_I16_BYTES
	if mask & MASK_ENEMY_LOCOMOTION:
		size += PACKED_U8_BYTES
	if mask & MASK_HEALTH:
		size += PACKED_U32_BYTES * 2
	if mask & MASK_IS_DEAD:
		size += PACKED_U8_BYTES
	if mask & MASK_ENEMY_VISUAL_STATUS:
		size += PACKED_U8_BYTES
	if _is_full_enemy_mask(mask):
		size += ENEMY_FACTION_KEYFRAME_BYTES
	return size


static func _encode_character_id(character_id: StringName) -> int:
	match character_id:
		HOE_CAT_CHARACTER_ID:
			return CHARACTER_CODE_HOE_CAT
		TIYI_CHARACTER_ID:
			return CHARACTER_CODE_TIYI
		TANGO_CHARACTER_ID:
			return CHARACTER_CODE_TANGO
		_:
			return CHARACTER_CODE_WEISHIDAIER


static func _decode_character_id(character_code: int) -> StringName:
	match character_code:
		CHARACTER_CODE_HOE_CAT:
			return HOE_CAT_CHARACTER_ID
		CHARACTER_CODE_TIYI:
			return TIYI_CHARACTER_ID
		CHARACTER_CODE_TANGO:
			return TANGO_CHARACTER_ID
		_:
			return DEFAULT_CHARACTER_ID


static func _pack_ratio_u8(value: float) -> int:
	return clampi(roundi(clampf(value, 0.0, 1.0) * 255.0), 0, 255)


static func _pack_scaled_i16(value: float, scale: float) -> int:
	return clampi(roundi(value * scale), PACKED_I16_MIN, PACKED_I16_MAX)


static func _pack_scaled_i32(value: float, scale: float) -> int:
	return clampi(roundi(value * scale), PACKED_I32_MIN, PACKED_I32_MAX)


static func _pack_scaled_u16(value: float, scale: float) -> int:
	return clampi(roundi(maxf(value, 0.0) * scale), 0, 65535)


static func _normalize_enemy_locomotion_state(state: int) -> int:
	return (
		ENEMY_LOCOMOTION_MOVING
		if state == ENEMY_LOCOMOTION_MOVING
		else ENEMY_LOCOMOTION_IDLE
	)


## 返回一份由调用方独占的玩家状态。实时解码器和 roster 采样器都会复用
## PlayerState 对象；需要跨帧保存（例如断线重连）时必须先复制，不能长期
## 持有它们的工作缓冲区引用。
static func copy_player_state(source: PlayerState) -> PlayerState:
	if source == null:
		return null
	var copy := PlayerState.new()
	_copy_player_state_into(source, copy)
	return copy


static func _copy_player_state_into(source: PlayerState, target: PlayerState) -> void:
	if source == null or target == null:
		return
	target.peer_id = source.peer_id
	target.sequence = source.sequence
	target.character_id = source.character_id
	target.position = source.position
	target.velocity = source.velocity
	target.facing = source.facing
	target.anim_state = source.anim_state
	target.current_health = source.current_health
	target.max_health = source.max_health
	target.health_revision = source.health_revision
	target.current_xirang = source.current_xirang
	target.is_dead = source.is_dead
	target.invincibility_time_left = source.invincibility_time_left
	target.skill1_unlocked = source.skill1_unlocked
	target.skill1_charge = source.skill1_charge
	target.skill1_charge_duration = source.skill1_charge_duration
	target.skill1_upgrade_level = source.skill1_upgrade_level
	target.form_mode = source.form_mode
	target.shot_pattern = source.shot_pattern
	target.ammo_capacity = source.ammo_capacity
	target.current_ammo = source.current_ammo
	target.is_reloading = source.is_reloading
	target.reload_progress = source.reload_progress
	target.primary_cooldown_ratio = source.primary_cooldown_ratio
	target.effective_move_speed_multiplier = source.effective_move_speed_multiplier
	target.void_battery_charged = source.void_battery_charged
	target.visual_status_mask = source.visual_status_mask
	target.effective_fire_interval_seconds = source.effective_fire_interval_seconds


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
	target.locomotion_state = _normalize_enemy_locomotion_state(source.locomotion_state)
	target.health = source.health
	target.health_revision = source.health_revision
	target.is_dead = source.is_dead
	target.visual_status_mask = source.visual_status_mask
	target.faction_id = source.faction_id
	target.faction_revision = source.faction_revision


static func _reset_enemy_state(target: EnemyState) -> void:
	if target == null:
		return
	target.net_id = 0
	target.position = Vector2.ZERO
	target.velocity = Vector2.ZERO
	target.locomotion_state = ENEMY_LOCOMOTION_IDLE
	target.health = 0
	target.health_revision = 0
	target.is_dead = false
	target.visual_status_mask = 0
	target.faction_id = CombatRelationServiceScript.HOSTILE_WAVE
	target.faction_revision = 0


static func _apply_player_delta(target: PlayerState, delta: PlayerState, mask: int) -> void:
	target.peer_id = delta.peer_id
	target.sequence = delta.sequence
	target.void_battery_charged = delta.void_battery_charged
	target.visual_status_mask = delta.visual_status_mask
	target.effective_fire_interval_seconds = delta.effective_fire_interval_seconds
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
		target.health_revision = delta.health_revision
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
		target.effective_move_speed_multiplier = delta.effective_move_speed_multiplier


static func _apply_enemy_delta(target: EnemyState, delta: EnemyState, mask: int) -> void:
	target.net_id = delta.net_id
	if mask & MASK_POSITION:
		target.position = delta.position
	if mask & MASK_VELOCITY:
		target.velocity = delta.velocity
	if mask & MASK_ENEMY_LOCOMOTION:
		target.locomotion_state = delta.locomotion_state
	if mask & MASK_HEALTH:
		target.health = delta.health
		target.health_revision = delta.health_revision
	if mask & MASK_IS_DEAD:
		target.is_dead = delta.is_dead
	if mask & MASK_ENEMY_VISUAL_STATUS:
		target.visual_status_mask = delta.visual_status_mask
	if _is_full_enemy_mask(mask):
		target.faction_id = delta.faction_id
		target.faction_revision = delta.faction_revision


static func _is_full_player_mask(mask: int) -> bool:
	return (mask & FULL_PLAYER_MASK) == FULL_PLAYER_MASK


static func _is_full_enemy_mask(mask: int) -> bool:
	return (mask & FULL_ENEMY_MASK) == FULL_ENEMY_MASK


static func _is_valid_enemy_snapshot_mask(mask: int) -> bool:
	return mask >= 0 and mask <= 0xFF and (mask & FULL_ENEMY_MASK) == mask


static func _is_received_enemy_state_valid(state: EnemyState) -> bool:
	return (
		state != null
		and state.net_id > 0
		and NetConstants.is_valid_network_combat_value(state.net_id)
		and state.position.is_finite()
		and state.velocity.is_finite()
		and NetConstants.is_valid_network_combat_value(state.health)
		and NetConstants.is_valid_network_combat_value(state.health_revision)
		and CombatRelationServiceScript.is_valid_faction_id(state.faction_id)
		and NetConstants.is_valid_network_combat_value(state.faction_revision)
	)


static func _get_player_snapshot_mask(data: PackedByteArray, offset: int) -> int:
	if offset < 0 or offset + PLAYER_SNAPSHOT_HEADER_BYTES > data.size():
		return -1
	return int(data[offset + PLAYER_SNAPSHOT_HEADER_BYTES - 1])


static func _get_enemy_snapshot_mask(data: PackedByteArray, offset: int) -> int:
	if offset < 0 or offset + ENEMY_SNAPSHOT_HEADER_BYTES > data.size():
		return -1
	return int(data[offset + ENEMY_SNAPSHOT_HEADER_BYTES - 1])


static func _prune_dictionary_to_ids(target: Dictionary, live_ids: Dictionary) -> void:
	# Every complete encode/decode pass has already inserted all live IDs before
	# pruning. Equal sizes therefore prove that no stale key exists, which is the
	# overwhelmingly common horde-snapshot path.
	if target.size() == live_ids.size():
		return
	var stale_ids: Array = []
	for id_variant in target:
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
	if not are_player_snapshot_states_serializable(players):
		push_error("SnapshotManager: 拒绝序列化包含非法状态的玩家快照批次。")
		return PackedByteArray()
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
	if not are_player_snapshot_states_serializable(players):
		push_error("SnapshotManager: 拒绝序列化包含非法状态的玩家 delta 批次。")
		return PackedByteArray()
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
		var stored := baseline.get(player_state.peer_id) as PlayerState
		if stored == null:
			stored = PlayerState.new()
			baseline[player_state.peer_id] = stored
		_copy_player_state_into(player_state, stored)
	_prune_dictionary_to_ids(baseline, live_ids)
	return buf


## 按共享发送 cohort 编码玩家快照。cohort 中的所有接收端必须拥有完全相同的
## 发送历史；成员缺席或恢复时由调用方先强制 keyframe，再允许复用该基线。
func encode_player_snapshots_for_cohort(
	cohort_id: int,
	players: Array[PlayerState],
	force_keyframe: bool = false
) -> PackedByteArray:
	return encode_player_snapshots_for_peer(cohort_id, players, force_keyframe)


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
	var stream := StreamPeerBuffer.new()
	stream.data_array = data
	for _i in range(count):
		var snapshot_size := _get_player_snapshot_size(data, offset)
		if snapshot_size < 0 or offset + snapshot_size > data.size():
			can_prune = false
			break
		var mask := _get_player_snapshot_mask(data, offset)
		stream.seek(offset)
		var peer_id := stream.get_32()
		var previous := player_receive_baselines.get(peer_id) as PlayerState
		if previous == null and not _is_full_player_mask(mask):
			can_prune = false
			offset += snapshot_size
			continue

		var restored := player_receive_output_states.get(peer_id) as PlayerState
		if restored == null or previous == null:
			restored = PlayerState.new()
			player_receive_output_states[peer_id] = restored
		else:
			_copy_player_state_into(previous, restored)
		var next_offset := decode_player_snapshot(data, offset, restored)
		if next_offset <= offset or next_offset > data.size():
			can_prune = false
			break
		offset = next_offset

		var stored := previous
		if stored == null:
			stored = PlayerState.new()
			player_receive_baselines[restored.peer_id] = stored
		_copy_player_state_into(restored, stored)
		live_ids[restored.peer_id] = true
		result.append(restored)

	if can_prune and offset == data.size():
		_prune_dictionary_to_ids(player_receive_baselines, live_ids)
		_prune_dictionary_to_ids(player_receive_output_states, live_ids)
	return result


## 编码一批敌人快照
func encode_all_enemy_snapshots(enemies: Array[EnemyState]) -> PackedByteArray:
	if enemies.size() > ENEMY_SNAPSHOT_MAX_RECORDS_PER_PACKET:
		push_error("SnapshotManager: 单个敌人快照包超过协议 94 的 41 实体上限。")
		return PackedByteArray()
	if not are_enemy_snapshot_states_serializable(enemies):
		push_error("SnapshotManager: 拒绝序列化包含非法状态的敌人快照批次。")
		return PackedByteArray()
	var stream := StreamPeerBuffer.new()
	# wire 保留 uint16；协议 94 的实际分块上限由常量约束为 41。
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


## 按共享发送 cohort 编码连续敌人区间。与玩家 cohort 一样，调用方负责保证
## 所有成员拥有同一发送历史；整批结束后统一 prune。
func encode_enemy_snapshot_range_for_cohort(
	cohort_id: int,
	enemies: Array[EnemyState],
	start_index: int,
	entity_count: int,
	force_keyframe: bool = false
) -> PackedByteArray:
	return encode_enemy_snapshot_range_for_peer(
		cohort_id,
		enemies,
		start_index,
		entity_count,
		force_keyframe
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
	if resolved_count > ENEMY_SNAPSHOT_MAX_RECORDS_PER_PACKET:
		push_error("SnapshotManager: 单个敌人 delta 包超过协议 94 的 41 实体上限。")
		return PackedByteArray()
	for state_index in range(resolved_start, resolved_start + resolved_count):
		if not is_enemy_snapshot_state_serializable(enemies[state_index]):
			push_error(
				"SnapshotManager: 拒绝序列化包含非法状态的敌人 delta 批次。"
			)
			return PackedByteArray()
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
	if count > ENEMY_SNAPSHOT_MAX_RECORDS_PER_PACKET:
		return result
	var offset := 2
	var seen_net_ids: Dictionary[int, bool] = {}
	for _i in range(count):
		var mask := _get_enemy_snapshot_mask(data, offset)
		if not _is_valid_enemy_snapshot_mask(mask) or not _is_full_enemy_mask(mask):
			break
		var snapshot_size := _get_enemy_snapshot_size(data, offset)
		if snapshot_size < 0 or offset + snapshot_size > data.size():
			break
		var state := EnemyState.new()
		stream.seek(offset)
		_read_enemy_snapshot(stream, state)
		var next_offset := stream.get_position()
		if (
			next_offset != offset + snapshot_size
			or not _is_received_enemy_state_valid(state)
			or seen_net_ids.has(state.net_id)
		):
			break
		offset = next_offset
		seen_net_ids[state.net_id] = true
		result.append(state)
	return result


## 只读预扫整包 wire 结构并收集实体 ID，不推进任何接收基线。协调器在
## chunk 级重复/元数据检查前调用它，保证被判无效的后续 chunk 不会先把
## 同一实体的 delta/full 写进共享 baseline。缺少接收基线的 delta 也视为
## 整包不可解码，避免正式解码器“跳过一条、提交其余条”的部分提交语义。
func try_collect_decodable_enemy_snapshot_ids(
	data: PackedByteArray,
	result: Array[int]
) -> bool:
	result.clear()
	if data.size() < 2:
		return false
	var stream := StreamPeerBuffer.new()
	stream.data_array = data
	var count := stream.get_u16()
	if count > ENEMY_SNAPSHOT_MAX_RECORDS_PER_PACKET:
		return false
	var offset := 2
	var seen_net_ids: Dictionary[int, bool] = {}
	for _record_index in range(count):
		var mask := _get_enemy_snapshot_mask(data, offset)
		if not _is_valid_enemy_snapshot_mask(mask):
			result.clear()
			return false
		var snapshot_size := _get_enemy_snapshot_size(data, offset)
		if snapshot_size < 0 or offset + snapshot_size > data.size():
			result.clear()
			return false
		stream.seek(offset)
		var net_id := stream.get_32()
		if (
			net_id <= 0
			or not NetConstants.is_valid_network_combat_value(net_id)
			or seen_net_ids.has(net_id)
			or (
				not _is_full_enemy_mask(mask)
				and not enemy_receive_baselines.has(net_id)
			)
		):
			result.clear()
			return false
		seen_net_ids[net_id] = true
		result.append(net_id)
		offset += snapshot_size
	if offset != data.size():
		result.clear()
		return false
	return true


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
	if count > ENEMY_SNAPSHOT_MAX_RECORDS_PER_PACKET:
		return result
	var offset := 2
	var live_ids: Dictionary = {}
	var can_prune := true
	var seen_net_ids: Dictionary[int, bool] = {}
	var staged_states: Array[EnemyState] = []
	for record_index in range(count):
		var mask := _get_enemy_snapshot_mask(data, offset)
		if not _is_valid_enemy_snapshot_mask(mask):
			return result
		var snapshot_size := _get_enemy_snapshot_size(data, offset)
		if snapshot_size < 0 or offset + snapshot_size > data.size():
			return result
		stream.seek(offset)
		var net_id := stream.get_32()
		if (
			net_id <= 0
			or not NetConstants.is_valid_network_combat_value(net_id)
			or seen_net_ids.has(net_id)
		):
			return result
		seen_net_ids[net_id] = true
		var previous := enemy_receive_baselines.get(net_id) as EnemyState
		var restored: EnemyState = null
		if record_index < enemy_receive_staging_states.size():
			restored = enemy_receive_staging_states[record_index]
		else:
			restored = EnemyState.new()
			enemy_receive_staging_states.append(restored)
		if previous != null:
			_copy_enemy_state_into(previous, restored)
		else:
			_reset_enemy_state(restored)
		stream.seek(offset)
		_read_enemy_snapshot(stream, restored)
		var next_offset := stream.get_position()
		if (
			next_offset != offset + snapshot_size
			or not _is_received_enemy_state_valid(restored)
		):
			return result
		offset = next_offset
		if previous == null and not _is_full_enemy_mask(mask):
			can_prune = false
			continue
		live_ids[restored.net_id] = true
		staged_states.append(restored)

	# The receive dictionaries are shared across packets and their output objects
	# are reused by hot callers. Commit only after every declared record and all
	# trailing bytes have been validated, so a malformed later record cannot leave
	# an earlier entity partially advanced or poison its monotonic revisions.
	if offset != data.size():
		return result
	for staged_state in staged_states:
		var stored := enemy_receive_baselines.get(staged_state.net_id) as EnemyState
		if stored == null:
			stored = EnemyState.new()
			enemy_receive_baselines[staged_state.net_id] = stored
		_copy_enemy_state_into(staged_state, stored)
		var output := enemy_receive_output_states.get(
			staged_state.net_id
		) as EnemyState
		if output == null:
			output = EnemyState.new()
			enemy_receive_output_states[staged_state.net_id] = output
		_copy_enemy_state_into(staged_state, output)
		result.append(output)
	if prune_baseline and can_prune:
		_prune_dictionary_to_ids(enemy_receive_baselines, live_ids)
		_prune_dictionary_to_ids(enemy_receive_output_states, live_ids)
	return result


func prune_enemy_send_baseline_to_ids(receiver_peer_id: int, live_ids: Dictionary) -> void:
	var baseline := _get_enemy_send_baseline(receiver_peer_id)
	_prune_dictionary_to_ids(baseline, live_ids)


func prune_enemy_send_cohort_baseline_to_ids(cohort_id: int, live_ids: Dictionary) -> void:
	prune_enemy_send_baseline_to_ids(cohort_id, live_ids)


func clear_player_send_baseline(receiver_or_cohort_id: int) -> void:
	player_send_baselines_by_peer.erase(receiver_or_cohort_id)


func clear_enemy_send_baseline(receiver_or_cohort_id: int) -> void:
	enemy_send_baselines_by_peer.erase(receiver_or_cohort_id)


## 同一 net_id 发布新 incarnation 前，清掉所有发送 cohort 中的旧实体基线。
## 否则首个非强制关键帧会只发送旧实体到新实体的 partial delta，而接收端已按
## spawn 清空基线，只能等下一次周期关键帧自愈。
func erase_enemy_send_baseline(net_id: int) -> void:
	if net_id <= 0:
		return
	for receiver_or_cohort_id in enemy_send_baselines_by_peer.keys():
		var baseline := enemy_send_baselines_by_peer.get(
			receiver_or_cohort_id,
			{}
		) as Dictionary
		baseline.erase(net_id)


func prune_enemy_receive_baseline_to_ids(live_ids: Dictionary) -> void:
	_prune_dictionary_to_ids(enemy_receive_baselines, live_ids)
	_prune_dictionary_to_ids(enemy_receive_output_states, live_ids)


## 丢弃单个网络敌人的接收基线与复用输出。
## 同一 net_id 发布新 incarnation 或拒绝旧 incarnation 快照时调用，避免旧高 revision
## 留在增量解码基线中，继而污染新实体的后续 keyframe/delta。
func erase_enemy_receive_baseline(net_id: int) -> void:
	if net_id <= 0:
		return
	enemy_receive_baselines.erase(net_id)
	enemy_receive_output_states.erase(net_id)


func clear_peer_delta_cache(peer_id: int) -> void:
	player_send_baselines_by_peer.erase(peer_id)
	enemy_send_baselines_by_peer.erase(peer_id)
	player_receive_baselines.erase(peer_id)
	player_receive_output_states.erase(peer_id)
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
	player_receive_output_states.clear()
	enemy_receive_output_states.clear()
	enemy_receive_staging_states.clear()
