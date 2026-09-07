extends RefCounted

## Full, independently decodable production states. Godot serializes and ZSTD
## compresses each cohort batch once, before the same bytes are sent to peers.
## No receiver baseline is required, so join/repair and CH5 lifecycle races keep
## the existing production revision and tombstone semantics.
const WIRE_SCHEMA := 1
const MAX_BUILDINGS := 24
const MAX_PACKET_BYTES := 1152
const MAX_DECODED_BYTES := 128 * 1024
const HEADER_BYTES := 5


static func encode_batches(
	net_ids: PackedInt32Array,
	states: Array,
	host_sample_times: PackedFloat64Array
) -> Array[PackedByteArray]:
	var packets: Array[PackedByteArray] = []
	if not _is_valid_batch_shape(net_ids, states, host_sample_times):
		return packets
	if not _append_encoded_range(
		net_ids, states, host_sample_times, 0, net_ids.size(), packets
	):
		packets.clear()
	return packets


static func decode_batch(packet: PackedByteArray) -> Dictionary:
	if (
		packet.size() <= HEADER_BYTES
		or packet.size() > MAX_PACKET_BYTES
		or packet[0] != WIRE_SCHEMA
	):
		return {}
	var decoded_size := int(packet.decode_u32(1))
	# Validate the allocation BEFORE native decompression. ZSTD requires the
	# original length; never use an unbounded decompression of network input.
	if decoded_size < 24 or decoded_size > MAX_DECODED_BYTES:
		return {}
	var raw := packet.slice(HEADER_BYTES).decompress(
		decoded_size, FileAccess.COMPRESSION_ZSTD
	)
	if raw.size() != decoded_size or not raw.has_encoded_var(0, false):
		return {}
	if raw.decode_var_size(0, false) != raw.size():
		return {}
	# Object construction is disabled; this envelope only carries value types.
	var value: Variant = raw.decode_var(0, false)
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 3:
		return {}
	var fields := value as Array
	if (
		typeof(fields[0]) != TYPE_PACKED_INT32_ARRAY
		or typeof(fields[1]) != TYPE_ARRAY
		or typeof(fields[2]) != TYPE_PACKED_FLOAT64_ARRAY
	):
		return {}
	var net_ids: PackedInt32Array = fields[0]
	var states: Array = fields[1]
	var sample_times: PackedFloat64Array = fields[2]
	if not _is_valid_batch_shape(net_ids, states, sample_times):
		return {}
	return {"net_ids": net_ids, "states": states, "host_sample_times": sample_times}


static func _append_encoded_range(
	net_ids: PackedInt32Array,
	states: Array,
	sample_times: PackedFloat64Array,
	start: int,
	end: int,
	packets: Array[PackedByteArray]
) -> bool:
	var raw := var_to_bytes([
		net_ids.slice(start, end), states.slice(start, end), sample_times.slice(start, end)
	])
	if raw.size() > MAX_DECODED_BYTES:
		return false
	var compressed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	if compressed.is_empty():
		return false
	if compressed.size() + HEADER_BYTES > MAX_PACKET_BYTES:
		# Different recipes/output paths can compress less than homogeneous rows.
		# Split by measured bytes, not an assumed dictionary or average row size.
		if end - start <= 1:
			return false
		var middle := start + (end - start) / 2
		return (
			_append_encoded_range(net_ids, states, sample_times, start, middle, packets)
			and _append_encoded_range(net_ids, states, sample_times, middle, end, packets)
		)
	var packet := PackedByteArray()
	packet.resize(HEADER_BYTES)
	packet[0] = WIRE_SCHEMA
	packet.encode_u32(1, raw.size())
	packet.append_array(compressed)
	packets.append(packet)
	return true


static func _is_valid_batch_shape(
	net_ids: PackedInt32Array,
	states: Array,
	sample_times: PackedFloat64Array
) -> bool:
	if (
		net_ids.is_empty()
		or net_ids.size() > MAX_BUILDINGS
		or states.size() != net_ids.size()
		or sample_times.size() != net_ids.size()
	):
		return false
	var previous_id := 0
	for index in net_ids.size():
		if (
			net_ids[index] <= previous_id
			or typeof(states[index]) != TYPE_DICTIONARY
			or not is_finite(sample_times[index])
		):
			return false
		previous_id = net_ids[index]
	return true
