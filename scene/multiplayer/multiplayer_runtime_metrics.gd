extends RefCounted
class_name MultiplayerRuntimeMetrics

const MAX_TRANSACTION_LATENCY_SAMPLES := 256

var channel_count: int = 0
var channels: Array[Dictionary] = []
var started_usec: int = 0
var state_repair_count: int = 0
var incomplete_batch_count: int = 0
# The write index always points at the next free slot, or at the oldest sample
# once the preallocated ring is full.
var _transaction_latency_sample_ring_ms := PackedFloat64Array()
var _transaction_latency_sample_count := 0
var _transaction_latency_sample_write_index := 0


func _init(initial_channel_count: int = 8) -> void:
	reset(initial_channel_count)


func reset(new_channel_count: int = -1) -> void:
	if new_channel_count > 0:
		channel_count = new_channel_count
	channel_count = maxi(channel_count, 1)
	channels.clear()
	channels.resize(channel_count)
	for channel in range(channel_count):
		channels[channel] = {
			"payload_bytes_total": 0,
			"packet_count": 0,
			"max_packet_bytes": 0,
		}
	started_usec = Time.get_ticks_usec()
	state_repair_count = 0
	incomplete_batch_count = 0
	_transaction_latency_sample_ring_ms.resize(MAX_TRANSACTION_LATENCY_SAMPLES)
	_transaction_latency_sample_count = 0
	_transaction_latency_sample_write_index = 0


func record_packet(channel: int, payload_bytes: int, packet_count: int = 1) -> void:
	if channel < 0 or channel >= channel_count or packet_count <= 0:
		return
	var safe_payload_bytes := maxi(payload_bytes, 0)
	var metric := channels[channel]
	metric["payload_bytes_total"] = (
		int(metric.get("payload_bytes_total", 0)) + safe_payload_bytes * packet_count
	)
	metric["packet_count"] = int(metric.get("packet_count", 0)) + packet_count
	metric["max_packet_bytes"] = maxi(
		int(metric.get("max_packet_bytes", 0)),
		safe_payload_bytes
	)


func record_state_repair() -> void:
	state_repair_count += 1


func record_incomplete_batch() -> void:
	incomplete_batch_count += 1


func record_transaction_latency_ms(latency_ms: float) -> void:
	if not is_finite(latency_ms) or latency_ms < 0.0:
		return
	_transaction_latency_sample_ring_ms[
		_transaction_latency_sample_write_index
	] = latency_ms
	_transaction_latency_sample_write_index += 1
	if _transaction_latency_sample_write_index >= MAX_TRANSACTION_LATENCY_SAMPLES:
		_transaction_latency_sample_write_index = 0
	_transaction_latency_sample_count = mini(
		_transaction_latency_sample_count + 1,
		MAX_TRANSACTION_LATENCY_SAMPLES
	)


func get_transaction_latency_samples_ms() -> PackedFloat64Array:
	var samples := PackedFloat64Array()
	samples.resize(_transaction_latency_sample_count)
	if _transaction_latency_sample_count <= 0:
		return samples
	var oldest_index := 0
	if _transaction_latency_sample_count >= MAX_TRANSACTION_LATENCY_SAMPLES:
		oldest_index = _transaction_latency_sample_write_index
	for sample_offset in range(_transaction_latency_sample_count):
		samples[sample_offset] = _transaction_latency_sample_ring_ms[
			(oldest_index + sample_offset) % MAX_TRANSACTION_LATENCY_SAMPLES
		]
	return samples


func get_summary() -> Dictionary:
	var transaction_latency_samples_ms := get_transaction_latency_samples_ms()
	var elapsed_seconds := maxf(
		float(Time.get_ticks_usec() - started_usec) / 1_000_000.0,
		0.001
	)
	var channel_summaries: Array[Dictionary] = []
	channel_summaries.resize(channel_count)
	for channel in range(channel_count):
		var source := channels[channel]
		var payload_bytes_total := int(source.get("payload_bytes_total", 0))
		var packet_count := int(source.get("packet_count", 0))
		channel_summaries[channel] = {
			"payload_bytes_total": payload_bytes_total,
			"packet_count": packet_count,
			"max_packet_bytes": int(source.get("max_packet_bytes", 0)),
			"bytes_per_second": float(payload_bytes_total) / elapsed_seconds,
			"packets_per_second": float(packet_count) / elapsed_seconds,
		}
	return {
		"elapsed_seconds": elapsed_seconds,
		"channels": channel_summaries,
		"state_repair_count": state_repair_count,
		"incomplete_batch_count": incomplete_batch_count,
		"transaction_latency_sample_count": _transaction_latency_sample_count,
		"transaction_latency_p95_ms": _percentile(transaction_latency_samples_ms, 0.95),
	}


func _percentile(samples: PackedFloat64Array, ratio: float) -> float:
	if samples.is_empty():
		return 0.0
	var sorted_samples := samples.duplicate()
	sorted_samples.sort()
	var index := clampi(
		ceili(clampf(ratio, 0.0, 1.0) * float(sorted_samples.size())) - 1,
		0,
		sorted_samples.size() - 1
	)
	return sorted_samples[index]
