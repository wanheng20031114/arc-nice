extends RefCounted
class_name NetInterpolator

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")

## 客户端实体插值器。
## 缓存最近若干帧的快照，在渲染时使用线性插值平滑过渡。
## 渲染延迟 = delay_factor × snapshot_interval。

## 单帧缓存
class FrameSnapshot:
	var timestamp: float = 0.0
	var position: Vector2 = Vector2.ZERO
	var velocity: Vector2 = Vector2.ZERO
	var facing: int = 0
	var anim_state: int = 0
	var health: int = 0
	var is_dead: bool = false


## 缓存最近的快照（逻辑上按 timestamp 升序）。
## 物理数组是双镜像环形缓冲区；后半区镜像前半区的相同帧引用，
## _buffer_head 指向逻辑最老帧。18 帧逻辑窗口因此始终物理连续，
## 有序状态流满载后只需复用头对象并推进游标，不需要 remove_at(0)、
## 取模或 GDScript 辅助函数调用；乱序包仍走低频有序插入路径。
var _buffer: Array[FrameSnapshot] = []
var _buffer_max_size: int = _NetConstants.INTERPOLATION_BUFFER_SIZE * 3
var _buffer_head: int = 0
var _buffer_size: int = 0

## 当前的插值渲染延迟（秒）
var _render_delay: float = 0.1
var _delay_factor: float = _NetConstants.INTERPOLATION_DELAY_FACTOR
var _max_extrapolation_seconds: float = _NetConstants.MAX_EXTRAPOLATION_SECONDS
var _last_position: Vector2 = Vector2.ZERO
var _has_position: bool = false
var _cached_motion_time: float = 0.0
var _cached_motion_position: Vector2 = Vector2.ZERO
var _cached_motion_velocity: Vector2 = Vector2.ZERO
var _empty_frame_state := FrameSnapshot.new()
var _cached_frame_state: FrameSnapshot = _empty_frame_state
var _has_cached_motion: bool = false


func _init(
	snapshot_interval: float = 0.05,
	delay_factor: float = -1.0,
	max_extrapolation_seconds: float = -1.0
) -> void:
	# 渲染延迟 = delay_factor × snapshot_interval
	var resolved_delay_factor := (
		_NetConstants.INTERPOLATION_DELAY_FACTOR
		if delay_factor < 0.0
		else delay_factor
	)
	_delay_factor = resolved_delay_factor
	_render_delay = _delay_factor * snapshot_interval
	_max_extrapolation_seconds = (
		_NetConstants.MAX_EXTRAPOLATION_SECONDS
		if max_extrapolation_seconds < 0.0
		else maxf(max_extrapolation_seconds, 0.0)
	)


func set_snapshot_interval(snapshot_interval: float) -> void:
	_render_delay = _delay_factor * maxf(snapshot_interval, 0.001)
	_has_cached_motion = false


## 添加一帧快照到缓存
func push_snapshot(
	timestamp: float,
	position: Vector2,
	velocity: Vector2,
	facing: int = 0,
	anim_state: int = 0,
	health: int = 0,
	is_dead: bool = false,
) -> void:
	_has_cached_motion = false
	var latest_frame: FrameSnapshot = null
	if _buffer_size > 0:
		latest_frame = _buffer[_buffer_head + _buffer_size - 1]
	var appends_in_order := _buffer_size == 0 or timestamp > latest_frame.timestamp
	var buffer_is_full := _buffer_size >= _buffer_max_size
	var frame: FrameSnapshot = null
	if appends_in_order and buffer_is_full:
		# The state channel is ordered in the common path. Reuse the expired frame
		# object and advance the logical head in O(1).
		frame = _buffer[_buffer_head]
	else:
		frame = FrameSnapshot.new()
	frame.timestamp = timestamp
	frame.position = position
	frame.velocity = velocity
	frame.facing = facing
	frame.anim_state = anim_state
	frame.health = health
	frame.is_dead = is_dead

	if _buffer_size > 0 and timestamp <= latest_frame.timestamp:
		_insert_ordered_snapshot(frame)
	elif buffer_is_full:
		# frame is already present in both mirrored slots. Mutating the shared
		# object above turns its mirror into the new logical tail automatically.
		_buffer_head += 1
		if _buffer_head >= _buffer_max_size:
			_buffer_head = 0
	else:
		_append_snapshot(frame)
	_last_position = position
	_has_position = true


## 获取指定时刻的插值位置
## current_time 通常为 Time.get_ticks_msec() / 1000.0
func get_interpolated_position(current_time: float) -> Vector2:
	_update_cached_motion(current_time)
	return _cached_motion_position


## 获取指定时刻的插值速度
func get_interpolated_velocity(current_time: float) -> Vector2:
	_update_cached_motion(current_time)
	return _cached_motion_velocity


func _update_cached_motion(current_time: float) -> void:
	if _has_cached_motion and current_time == _cached_motion_time:
		return
	_cached_motion_time = current_time
	_has_cached_motion = true
	var render_time := current_time - _render_delay

	if _buffer_size == 0:
		_cached_motion_position = _last_position if _has_position else Vector2.ZERO
		_cached_motion_velocity = Vector2.ZERO
		_cached_frame_state = _empty_frame_state
		return

	if _buffer_size == 1:
		var only_frame := _buffer[_buffer_head]
		_cached_motion_position = only_frame.position
		_cached_motion_velocity = only_frame.velocity
		_cached_frame_state = only_frame
		return

	var oldest_frame := _buffer[_buffer_head]
	if render_time <= oldest_frame.timestamp:
		_cached_motion_position = oldest_frame.position
		_cached_motion_velocity = oldest_frame.velocity
		_cached_frame_state = oldest_frame
		return

	var before: FrameSnapshot = null
	var after: FrameSnapshot = null

	# 渲染延迟通常只有 2-3 个快照，从最新端反查能避免遍历整个缓冲区。
	for i in range(_buffer_size - 2, -1, -1):
		var candidate_before := _buffer[_buffer_head + i]
		var candidate_after := _buffer[_buffer_head + i + 1]
		if candidate_before.timestamp <= render_time and candidate_after.timestamp >= render_time:
			before = candidate_before
			after = candidate_after
			break

	if before == null or after == null:
		var latest_frame := _buffer[_buffer_head + _buffer_size - 1]
		_cached_motion_position = _extrapolate_latest_position(render_time)
		_cached_motion_velocity = latest_frame.velocity
		_cached_frame_state = latest_frame
		return

	var total := after.timestamp - before.timestamp
	if total <= 0.0:
		_cached_motion_position = after.position
		_cached_motion_velocity = after.velocity
		_cached_frame_state = after
		return

	var t := clampf((render_time - before.timestamp) / total, 0.0, 1.0)
	_cached_motion_position = before.position.lerp(after.position, t)
	_cached_motion_velocity = before.velocity.lerp(after.velocity, t)
	_cached_frame_state = after if render_time >= after.timestamp else before


## 获取当前渲染时间对应的离散状态（朝向、动画、血量等不做插值）
func get_current_state(current_time: float) -> FrameSnapshot:
	# Continuous motion and discrete presentation state share one render-time
	# lookup. Position, velocity and locomotion can therefore be sampled in any
	# order without traversing the short history more than once per render frame.
	_update_cached_motion(current_time)
	return _cached_frame_state


## 清空缓存
func clear() -> void:
	_buffer.clear()
	_buffer_head = 0
	_buffer_size = 0
	_has_position = false
	_cached_frame_state = _empty_frame_state
	_has_cached_motion = false


## 获取缓存中最新快照的时间戳
func get_latest_timestamp() -> float:
	if _buffer_size == 0:
		return 0.0
	return _buffer[_buffer_head + _buffer_size - 1].timestamp


## 获取最新收到的完整帧。位置校正等辅助样本可继承其离散表现状态，
## 避免把“本样本不携带速度”误解释成角色静止。
func get_latest_state() -> FrameSnapshot:
	if _buffer_size == 0:
		return FrameSnapshot.new()
	return _buffer[_buffer_head + _buffer_size - 1]


## 获取缓存大小
func get_buffer_size() -> int:
	return _buffer_size


func _insert_ordered_snapshot(frame: FrameSnapshot) -> void:
	for index in range(_buffer_size):
		var buffered_frame := _get_buffer_frame(index)
		if is_equal_approx(buffered_frame.timestamp, frame.timestamp):
			_set_buffer_frame(index, frame)
			return
		if frame.timestamp < buffered_frame.timestamp:
			# A sample older than every retained frame would be evicted immediately
			# by the previous bounded-array implementation as well.
			if _buffer_size >= _buffer_max_size:
				if index == 0:
					return
				_advance_buffer_head()
				index -= 1
			_insert_buffer_frame(index, frame)
			return
	_append_snapshot(frame)


func _append_snapshot(frame: FrameSnapshot) -> void:
	_ensure_buffer_storage()
	if _buffer_size >= _buffer_max_size:
		_set_buffer_frame(0, frame)
		_advance_buffer_head()
		_buffer_size += 1
		return
	_set_buffer_frame(_buffer_size, frame)
	_buffer_size += 1


func _insert_buffer_frame(logical_index: int, frame: FrameSnapshot) -> void:
	_ensure_buffer_storage()
	for shift_index in range(_buffer_size, logical_index, -1):
		_set_buffer_frame(shift_index, _get_buffer_frame(shift_index - 1))
	_set_buffer_frame(logical_index, frame)
	_buffer_size += 1


func _advance_buffer_head() -> void:
	_buffer_head += 1
	if _buffer_head >= _buffer_max_size:
		_buffer_head = 0
	_buffer_size -= 1


func _ensure_buffer_storage() -> void:
	var physical_size := _buffer_max_size * 2
	if _buffer.size() != physical_size:
		_buffer.resize(physical_size)


func _get_buffer_frame(logical_index: int) -> FrameSnapshot:
	return _buffer[_buffer_head + logical_index]


func _set_buffer_frame(logical_index: int, frame: FrameSnapshot) -> void:
	var physical_index := _buffer_head + logical_index
	if physical_index >= _buffer_max_size:
		physical_index -= _buffer_max_size
	_buffer[physical_index] = frame
	_buffer[physical_index + _buffer_max_size] = frame


func _extrapolate_latest_position(render_time: float) -> Vector2:
	var latest := _buffer[_buffer_head + _buffer_size - 1]
	var extrapolation_time := clampf(
		render_time - latest.timestamp,
		0.0,
		_max_extrapolation_seconds
	)
	return latest.position + latest.velocity * extrapolation_time
