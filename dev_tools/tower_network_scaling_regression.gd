extends SceneTree

const Codec := preload(
	"res://scene/game_modes/tower_defense/multiplayer/economy/production_state_batch_codec.gd"
)
const Economy := preload(
	"res://scene/game_modes/tower_defense/multiplayer/economy/mp_tower_economy_coordinator.gd"
)

class CountingBuilding extends ProductionBuilding:
	var export_count := 0
	var fixture_state: Dictionary = {}

	func export_multiplayer_runtime_state() -> Dictionary:
		export_count += 1
		return fixture_state.duplicate()

class HostEconomy extends Economy:
	func _is_host_bound() -> bool:
		return true

	func _get_gameplay_net_time() -> float:
		return 100.25

var _failures: Array[String] = []
var _broadcast_packets: Array[PackedByteArray] = []


func _initialize() -> void:
	call_deferred(&"_run")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
		printerr("FAIL: ", message)


static func make_state(index: int) -> Dictionary:
	return {
		"schema": 5,
		"enabled": index % 3 != 0,
		"loop_enabled": index % 2 == 0,
		"active_recipe_id": "water" if index % 2 == 0 else "stone_brick",
		"progress_elapsed_seconds": float(index) * 0.125,
		"wait_reason": "missing_input" if index % 7 == 0 else "",
		"buffered_output_config_path": "",
		"buffered_output_count": 0,
		"personal_output_peer_id": 0,
		"revision": 1234567890123 + index,
		"projection_duration_seconds": 0.75,
	}


func _run() -> void:
	var ids := PackedInt32Array()
	var states: Array = []
	var sample_times := PackedFloat64Array()
	for index in Codec.MAX_BUILDINGS:
		ids.append(index + 1)
		states.append(make_state(index))
		sample_times.append(123.456789 + index * 0.0001)
	var packets := Codec.encode_batches(ids, states, sample_times)
	_check(not packets.is_empty(), "valid full batch encodes")
	var byte_count := 0
	var restored_ids := PackedInt32Array()
	var restored_states: Array = []
	var restored_times := PackedFloat64Array()
	for packet in packets:
		_check(packet.size() <= Codec.MAX_PACKET_BYTES, "packet stays under payload budget")
		byte_count += packet.size()
		var decoded := Codec.decode_batch(packet)
		_check(not decoded.is_empty(), "packet is independently decodable")
		if decoded.is_empty():
			continue
		restored_ids.append_array(decoded["net_ids"])
		restored_states.append_array(decoded["states"])
		restored_times.append_array(decoded["host_sample_times"])
	_check(restored_ids == ids, "IDs round trip")
	_check(restored_states == states, "all production fields and int64 revisions round trip")
	_check(restored_times == sample_times, "sample times round trip without precision loss")
	var old_bytes := var_to_bytes([ids, states, sample_times]).size()
	_check(byte_count * 4 < old_bytes, "representative batch reduces payload by at least 75 percent")
	print("PRODUCTION_CODEC_BYTES old=", old_bytes, " new=", byte_count,
		" packets=", packets.size(), " recipients=5 old_total=", old_bytes * 5,
		" new_total=", byte_count * 5)
	_test_rejections(ids, states, sample_times, packets[0])
	_test_incompressible_splitting(ids, sample_times)
	_test_revision_convergence()
	_test_coalesced_export()
	_benchmark(ids, states, sample_times)
	await process_frame
	print("TOWER_NETWORK_SCALING_REGRESSION ", "PASS" if _failures.is_empty() else "FAIL",
		" failures=", _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _test_rejections(
	ids: PackedInt32Array, states: Array, sample_times: PackedFloat64Array,
	valid_packet: PackedByteArray
) -> void:
	_check(Codec.decode_batch(PackedByteArray()).is_empty(), "empty wire rejected")
	var wrong_schema := valid_packet.duplicate()
	wrong_schema[0] += 1
	_check(Codec.decode_batch(wrong_schema).is_empty(), "unknown schema rejected")
	var over_limit := valid_packet.duplicate()
	over_limit.encode_u32(1, Codec.MAX_DECODED_BYTES + 1)
	_check(Codec.decode_batch(over_limit).is_empty(), "allocation limit rejected before decompress")
	var too_large := valid_packet.duplicate()
	too_large.resize(Codec.MAX_PACKET_BYTES + 1)
	_check(Codec.decode_batch(too_large).is_empty(), "oversized packet rejected")
	var duplicate_ids := ids.duplicate()
	duplicate_ids[1] = duplicate_ids[0]
	_check(Codec.encode_batches(duplicate_ids, states, sample_times).is_empty(), "duplicate ID rejected")
	var nan_times := sample_times.duplicate()
	nan_times[0] = NAN
	_check(Codec.encode_batches(ids, states, nan_times).is_empty(), "non-finite sample rejected")
	_check(Codec.encode_batches(ids, states.slice(1), sample_times).is_empty(), "mismatched columns rejected")
	# Valid compression cannot make an invalid nested frame acceptable.
	var bad_raw := var_to_bytes([ids, states.slice(1), sample_times])
	_check(Codec.decode_batch(_wrap_raw(bad_raw)).is_empty(), "invalid decoded columns rejected")
	bad_raw = var_to_bytes([ids, states, sample_times])
	bad_raw.append(0)
	_check(Codec.decode_batch(_wrap_raw(bad_raw)).is_empty(), "trailing decoded bytes rejected")


func _test_incompressible_splitting(ids: PackedInt32Array, sample_times: PackedFloat64Array) -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 407198
	var states: Array = []
	for index in ids.size():
		var state := make_state(index)
		var suffix := ""
		for character_index in 400:
			suffix += char(33 + random.randi_range(0, 90))
		state["buffered_output_config_path"] = "res://resources/config/" + suffix + ".tres"
		states.append(state)
	var packets := Codec.encode_batches(ids, states, sample_times)
	_check(packets.size() > 1, "diverse large paths split by actual compressed bytes")
	var decoded_states: Array = []
	for packet in packets:
		_check(packet.size() <= Codec.MAX_PACKET_BYTES, "split packet obeys payload budget")
		var decoded := Codec.decode_batch(packet)
		_check(not decoded.is_empty(), "split packet decodes without a preceding packet")
		if not decoded.is_empty():
			decoded_states.append_array(decoded["states"])
	_check(decoded_states == states, "split packets preserve every record in order")


func _test_coalesced_export() -> void:
	var economy := HostEconomy.new()
	root.add_child(economy)
	economy.rpc_broadcast_requested.connect(_on_broadcast)
	var building := CountingBuilding.new()
	building.building_net_id = 42
	building.fixture_state = make_state(1)
	for index in 5:
		building.fixture_state["revision"] = index
		economy._on_authoritative_production_state_changed(true, building)
	_check(building.export_count == 0, "signals mark dirty without exporting transient states")
	economy._flush_shared_production_network_state()
	_check(building.export_count == 1, "five signals export one final state")
	_check(_broadcast_packets.size() == 1, "five signals broadcast one batch")
	if not _broadcast_packets.is_empty():
		var decoded := Codec.decode_batch(_broadcast_packets[0])
		_check(int(decoded["states"][0]["revision"]) == 4, "flush sends final revision")
	economy._on_authoritative_production_state_changed(true, building)
	building.free()
	economy._flush_shared_production_network_state()
	_check(_broadcast_packets.size() == 1, "removed building does not publish stale state")
	economy.queue_free()


func _test_revision_convergence() -> void:
	var building := ProductionBuilding.new()
	building.is_multiplayer_proxy = true
	var state := make_state(1)
	state["active_recipe_id"] = ""
	state["revision"] = 10
	state["enabled"] = true
	var packet := Codec.encode_batches(
		PackedInt32Array([1]), [state], PackedFloat64Array([100.0])
	)[0]
	var decoded := Codec.decode_batch(packet)
	building.apply_multiplayer_runtime_state_with_host_sample(decoded["states"][0], 100.0, 100.0)
	_check(building.production_revision == 10 and building.production_enabled,
		"late join accepts a complete state without a baseline")
	state["revision"] = 9
	state["enabled"] = false
	building.apply_multiplayer_runtime_state_with_host_sample(state, 101.0, 101.0)
	_check(building.production_revision == 10 and building.production_enabled,
		"a delayed lower revision cannot roll back a repaired building")
	state["revision"] = 10
	building.apply_multiplayer_runtime_state_with_host_sample(state, 99.0, 99.0)
	_check(building.production_enabled, "same-revision old sample cannot overwrite newer state")
	building.apply_multiplayer_runtime_state_with_host_sample(state, 102.0, 102.0)
	_check(not building.production_enabled, "same-revision newer complete repair sample converges")
	building.free()


func _on_broadcast(method: StringName, args: Array) -> void:
	_check(method == &"net_production_state_batch", "correct production RPC")
	_broadcast_packets.append(args[0])


func _benchmark(ids: PackedInt32Array, states: Array, sample_times: PackedFloat64Array) -> void:
	var iterations := 300
	var checksum := 0
	var start := Time.get_ticks_usec()
	for iteration in iterations:
		for recipient in 5:
			checksum += var_to_bytes([ids, states, sample_times]).size()
	var old_usec := Time.get_ticks_usec() - start
	start = Time.get_ticks_usec()
	for iteration in iterations:
		var packets := Codec.encode_batches(ids, states, sample_times)
		for recipient in 5:
			for packet in packets:
				checksum += var_to_bytes([packet]).size()
	var new_usec := Time.get_ticks_usec() - start
	print("PRODUCTION_CODEC_CPU iterations=", iterations, " old_us=", old_usec,
		" new_us=", new_usec, " checksum=", checksum)


func _wrap_raw(raw: PackedByteArray) -> PackedByteArray:
	var packet := PackedByteArray()
	packet.resize(Codec.HEADER_BYTES)
	packet[0] = Codec.WIRE_SCHEMA
	packet.encode_u32(1, raw.size())
	packet.append_array(raw.compress(FileAccess.COMPRESSION_ZSTD))
	return packet
