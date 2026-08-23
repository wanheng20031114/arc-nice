extends RefCounted
class_name EnemySimulationEvidenceRecorder

const POLICY := preload("res://scene/combat/simulation/enemy_simulation_policy.gd")

## Allocation-bounded evidence collector shared by semantic and timing probes.
## Detailed event recording is disabled for timing runs so instrumentation does
## not become part of the measured production cost.

const DEFAULT_MAX_FRAME_SAMPLES := 3600
const SIGNATURE_MODULUS := 2_147_483_647
const SIGNATURE_MULTIPLIER := 48_271
const SIGNATURE_SEED := 17

var mode := POLICY.Mode.LEGACY
var detailed_events_enabled := true
var max_frame_samples := DEFAULT_MAX_FRAME_SAMPLES
var authoritative_tick_count := 0
var event_count := 0
var event_signature := SIGNATURE_SEED
var event_counts: Dictionary[StringName, int] = {}
var _frame_time_samples_ms: Array[float] = []
var _frame_sample_write_index := 0


func reset(
	new_mode: int = POLICY.Mode.LEGACY,
	enable_detailed_events: bool = true
) -> void:
	mode = POLICY.normalize_mode(new_mode)
	detailed_events_enabled = enable_detailed_events
	authoritative_tick_count = 0
	event_count = 0
	event_signature = SIGNATURE_SEED
	event_counts.clear()
	_frame_time_samples_ms.clear()
	_frame_sample_write_index = 0


func record_authoritative_tick(tick: int) -> void:
	authoritative_tick_count += 1
	if detailed_events_enabled:
		_mix_signature(tick)


func record_event(
	event_type: StringName,
	simulation_tick: int,
	simulation_id: int,
	payload: PackedInt64Array = PackedInt64Array()
) -> void:
	event_count += 1
	event_counts[event_type] = int(event_counts.get(event_type, 0)) + 1
	if not detailed_events_enabled:
		return
	_mix_signature(_stable_string_name_hash(event_type))
	_mix_signature(simulation_tick)
	_mix_signature(simulation_id)
	_mix_signature(payload.size())
	for value in payload:
		_mix_signature(value)


func record_frame_time_ms(frame_time_ms: float) -> void:
	if frame_time_ms < 0.0 or not is_finite(frame_time_ms):
		return
	var safe_capacity := maxi(max_frame_samples, 1)
	if _frame_time_samples_ms.size() < safe_capacity:
		_frame_time_samples_ms.append(frame_time_ms)
		return
	_frame_time_samples_ms[_frame_sample_write_index] = frame_time_ms
	_frame_sample_write_index = (_frame_sample_write_index + 1) % safe_capacity


func get_summary() -> Dictionary:
	return {
		"mode": POLICY.mode_to_name(mode),
		"authoritative_tick_count": authoritative_tick_count,
		"event_count": event_count,
		"event_signature": event_signature,
		"event_counts": event_counts.duplicate(),
		"frame_time": _summarize_samples(_frame_time_samples_ms),
	}


func has_equivalent_semantics(other: RefCounted) -> bool:
	if other == null:
		return false
	return (
		authoritative_tick_count == other.authoritative_tick_count
		and event_count == other.event_count
		and event_signature == other.event_signature
		and event_counts == other.event_counts
	)


func _mix_signature(value: int) -> void:
	var normalized := posmod(value, SIGNATURE_MODULUS)
	event_signature = int(
		(
			(event_signature * SIGNATURE_MULTIPLIER) % SIGNATURE_MODULUS
			+ normalized
		) % SIGNATURE_MODULUS
	)


static func _stable_string_name_hash(value: StringName) -> int:
	var hash_value := SIGNATURE_SEED
	var text := String(value)
	for index in range(text.length()):
		hash_value = int(
			(
				(hash_value * SIGNATURE_MULTIPLIER) % SIGNATURE_MODULUS
				+ text.unicode_at(index)
			) % SIGNATURE_MODULUS
		)
	return hash_value


static func _summarize_samples(samples: Array[float]) -> Dictionary:
	if samples.is_empty():
		return {
			"sample_count": 0,
			"p50_ms": 0.0,
			"p95_ms": 0.0,
			"p99_ms": 0.0,
			"max_ms": 0.0,
		}
	var sorted_samples := samples.duplicate()
	sorted_samples.sort()
	return {
		"sample_count": sorted_samples.size(),
		"p50_ms": _nearest_rank_percentile(sorted_samples, 0.50),
		"p95_ms": _nearest_rank_percentile(sorted_samples, 0.95),
		"p99_ms": _nearest_rank_percentile(sorted_samples, 0.99),
		"max_ms": sorted_samples.back(),
	}


static func _nearest_rank_percentile(
	sorted_samples: Array[float],
	percentile: float
) -> float:
	if sorted_samples.is_empty():
		return 0.0
	var rank := ceili(clampf(percentile, 0.0, 1.0) * sorted_samples.size())
	return sorted_samples[clampi(rank - 1, 0, sorted_samples.size() - 1)]
