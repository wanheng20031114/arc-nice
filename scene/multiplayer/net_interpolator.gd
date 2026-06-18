extends RefCounted
class_name NetInterpolator

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")

## 客户端实体插值器。
## 缓存最近若干帧的快照，在渲染时使用线性插值平滑过渡。
## 渲染延迟 = INTERPOLATION_DELAY_FACTOR × snapshot_interval。

## 单帧缓存
class FrameSnapshot:
	var timestamp: float = 0.0
	var position: Vector2 = Vector2.ZERO
	var velocity: Vector2 = Vector2.ZERO
	var facing: int = 0
	var anim_state: int = 0
	var health: int = 0
	var is_dead: bool = false


## 缓存最近的快照（按 timestamp 升序）
var _buffer: Array[FrameSnapshot] = []
var _buffer_max_size: int = _NetConstants.INTERPOLATION_BUFFER_SIZE * 3

## 当前的插值渲染延迟（秒）
var _render_delay: float = 0.1


func _init(snapshot_interval: float = 0.05) -> void:
	# 渲染延迟 = delay_factor × snapshot_interval
	_render_delay = _NetConstants.INTERPOLATION_DELAY_FACTOR * snapshot_interval


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
	var frame := FrameSnapshot.new()
	frame.timestamp = timestamp
	frame.position = position
	frame.velocity = velocity
	frame.facing = facing
	frame.anim_state = anim_state
	frame.health = health
	frame.is_dead = is_dead

	_buffer.append(frame)

	# 保持缓存大小
	while _buffer.size() > _buffer_max_size:
		_buffer.remove_at(0)


## 获取指定时刻的插值位置
## current_time 通常为 Time.get_ticks_msec() / 1000.0
func get_interpolated_position(current_time: float) -> Vector2:
	var render_time := current_time - _render_delay

	if _buffer.is_empty():
		return Vector2.ZERO

	# 找到 render_time 前后的两帧
	var before: FrameSnapshot = null
	var after: FrameSnapshot = null

	for i in range(_buffer.size() - 1):
		if _buffer[i].timestamp <= render_time and _buffer[i + 1].timestamp >= render_time:
			before = _buffer[i]
			after = _buffer[i + 1]
			break

	if before == null or after == null:
		# 若没找到合适的区间，返回最后已知位置
		return _buffer[_buffer.size() - 1].position

	# 计算插值因子
	var total := after.timestamp - before.timestamp
	if total <= 0.0:
		return after.position

	var t := clampf((render_time - before.timestamp) / total, 0.0, 1.0)
	return before.position.lerp(after.position, t)


## 获取指定时刻的插值速度
func get_interpolated_velocity(current_time: float) -> Vector2:
	var render_time := current_time - _render_delay

	if _buffer.is_empty():
		return Vector2.ZERO

	var before: FrameSnapshot = null
	var after: FrameSnapshot = null

	for i in range(_buffer.size() - 1):
		if _buffer[i].timestamp <= render_time and _buffer[i + 1].timestamp >= render_time:
			before = _buffer[i]
			after = _buffer[i + 1]
			break

	if before == null or after == null:
		return _buffer[_buffer.size() - 1].velocity

	var total := after.timestamp - before.timestamp
	if total <= 0.0:
		return after.velocity

	var t := clampf((render_time - before.timestamp) / total, 0.0, 1.0)
	return before.velocity.lerp(after.velocity, t)


## 获取当前渲染时间对应的离散状态（朝向、动画、血量等不做插值）
func get_current_state(current_time: float) -> FrameSnapshot:
	var render_time := current_time - _render_delay

	if _buffer.is_empty():
		return FrameSnapshot.new()

	# 返回 render_time 之前最近的一帧
	var best: FrameSnapshot = _buffer[0]
	for frame: FrameSnapshot in _buffer:
		if frame.timestamp <= render_time:
			best = frame
		else:
			break

	return best


## 清空缓存
func clear() -> void:
	_buffer.clear()


## 获取缓存中最新快照的时间戳
func get_latest_timestamp() -> float:
	if _buffer.is_empty():
		return 0.0
	return _buffer[_buffer.size() - 1].timestamp


## 获取缓存大小
func get_buffer_size() -> int:
	return _buffer.size()
