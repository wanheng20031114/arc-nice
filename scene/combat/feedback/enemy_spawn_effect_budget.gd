extends RefCounted
class_name EnemySpawnEffectBudget

const WORLD_EFFECT_VISIBILITY := preload("res://scene/combat/feedback/world_effect_visibility.gd")

const DEFAULT_REFILL_RATE_PER_SECOND := 40.0
const DEFAULT_CAPACITY := 8.0

var refill_rate_per_second: float
var capacity: float

var _available_tokens: float
var _last_sample_time_seconds := 0.0
var _has_time_sample := false


func _init(
	configured_refill_rate_per_second: float = DEFAULT_REFILL_RATE_PER_SECOND,
	configured_capacity: float = DEFAULT_CAPACITY
) -> void:
	refill_rate_per_second = maxf(configured_refill_rate_per_second, 0.0)
	capacity = maxf(configured_capacity, 1.0)
	_available_tokens = capacity


## Visibility is intentionally checked before the token bucket. Far-offscreen
## requests are pure visual work and therefore must not displace an upcoming
## visible spawn effect from the shared budget.
func try_reserve(
	context: Node,
	world_position: Vector2,
	sample_time_seconds: float = -1.0
) -> bool:
	if not WORLD_EFFECT_VISIBILITY.is_position_near_viewport(context, world_position):
		return false
	var resolved_sample_time := sample_time_seconds
	if resolved_sample_time < 0.0:
		resolved_sample_time = float(Time.get_ticks_usec()) / 1000000.0
	return try_consume_at(resolved_sample_time)


## An explicit monotonic sample makes the rate limiter deterministic in smoke
## tests and lets callers share one clock sample across a whole spawn batch.
func try_consume_at(sample_time_seconds: float) -> bool:
	_refill_at(maxf(sample_time_seconds, 0.0))
	if _available_tokens + 0.000001 < 1.0:
		return false
	_available_tokens = maxf(_available_tokens - 1.0, 0.0)
	return true


func _refill_at(sample_time_seconds: float) -> void:
	if not _has_time_sample:
		_has_time_sample = true
		_last_sample_time_seconds = sample_time_seconds
		return
	if sample_time_seconds <= _last_sample_time_seconds:
		return
	var elapsed_seconds := sample_time_seconds - _last_sample_time_seconds
	_available_tokens = minf(
		_available_tokens + elapsed_seconds * refill_rate_per_second,
		capacity
	)
	_last_sample_time_seconds = sample_time_seconds
