extends SceneTree

const MetricsScript := preload("res://scene/multiplayer/multiplayer_runtime_metrics.gd")
const CAPACITY := 256
const WARMUP_SAMPLE_COUNT := 20_000
const MEASURED_SAMPLE_COUNT := 500_000
const MEASURED_ROUNDS := 7


class LegacyLatencyWindow extends RefCounted:
	var samples: Array[float] = []


	func record(latency_ms: float) -> void:
		if not is_finite(latency_ms) or latency_ms < 0.0:
			return
		samples.append(latency_ms)
		if samples.size() > CAPACITY:
			samples.pop_front()


func _init() -> void:
	_run_semantic_parity()
	_measure_ab()
	quit(0)


func _run_semantic_parity() -> void:
	var legacy := LegacyLatencyWindow.new()
	var optimized: MultiplayerRuntimeMetrics = MetricsScript.new(8)
	for sample_index in range(CAPACITY * 3 + 19):
		var value := float((sample_index * 37) % 997) * 0.25
		legacy.record(value)
		optimized.record_transaction_latency_ms(value)
	var optimized_samples := optimized.get_transaction_latency_samples_ms()
	assert(
		optimized_samples.size() == legacy.samples.size(),
		"Ring and legacy windows must retain the same number of samples."
	)
	for sample_index in range(legacy.samples.size()):
		assert(
			is_equal_approx(optimized_samples[sample_index], legacy.samples[sample_index]),
			"Ring must retain the exact chronological legacy window."
		)
	var legacy_p95 := _percentile(legacy.samples)
	var optimized_summary := optimized.get_summary()
	assert(
		is_equal_approx(
			float(optimized_summary.get("transaction_latency_p95_ms", -1.0)),
			legacy_p95
		),
		"Ring must preserve nearest-rank p95 semantics after repeated wraps."
	)


func _measure_ab() -> void:
	_measure_legacy(WARMUP_SAMPLE_COUNT)
	_measure_ring(WARMUP_SAMPLE_COUNT)
	var legacy_samples_usec: Array[float] = []
	var ring_samples_usec: Array[float] = []
	for round_index in range(MEASURED_ROUNDS):
		if round_index % 2 == 0:
			legacy_samples_usec.append(float(_measure_legacy(MEASURED_SAMPLE_COUNT)))
			ring_samples_usec.append(float(_measure_ring(MEASURED_SAMPLE_COUNT)))
		else:
			ring_samples_usec.append(float(_measure_ring(MEASURED_SAMPLE_COUNT)))
			legacy_samples_usec.append(float(_measure_legacy(MEASURED_SAMPLE_COUNT)))
	var legacy_median_usec := _median(legacy_samples_usec)
	var ring_median_usec := _median(ring_samples_usec)
	var speedup := legacy_median_usec / maxf(ring_median_usec, 1.0)
	print(
		(
			"MULTIPLAYER_RUNTIME_METRICS_RING_AB samples=%d capacity=%d "
			+ "legacy_median_ms=%.3f ring_median_ms=%.3f speedup=%.2fx"
		) % [
			MEASURED_SAMPLE_COUNT,
			CAPACITY,
			legacy_median_usec / 1000.0,
			ring_median_usec / 1000.0,
			speedup,
		]
	)
	assert(
		ring_median_usec < legacy_median_usec,
		"O(1) ring recording must outperform the shifting legacy window."
	)
	print("MULTIPLAYER_RUNTIME_METRICS_RING_AB_PROBE_OK")


func _measure_legacy(sample_count: int) -> int:
	var metrics := LegacyLatencyWindow.new()
	var started_usec := Time.get_ticks_usec()
	for sample_index in range(sample_count):
		metrics.record(float(sample_index % 1000) * 0.125)
	return Time.get_ticks_usec() - started_usec


func _measure_ring(sample_count: int) -> int:
	var metrics: MultiplayerRuntimeMetrics = MetricsScript.new(8)
	var started_usec := Time.get_ticks_usec()
	for sample_index in range(sample_count):
		metrics.record_transaction_latency_ms(float(sample_index % 1000) * 0.125)
	return Time.get_ticks_usec() - started_usec


func _percentile(samples: Array[float]) -> float:
	var sorted_samples := samples.duplicate()
	sorted_samples.sort()
	return sorted_samples[clampi(
		ceili(0.95 * float(sorted_samples.size())) - 1,
		0,
		sorted_samples.size() - 1
	)]


func _median(samples: Array[float]) -> float:
	var sorted_samples := samples.duplicate()
	sorted_samples.sort()
	return sorted_samples[sorted_samples.size() / 2]
