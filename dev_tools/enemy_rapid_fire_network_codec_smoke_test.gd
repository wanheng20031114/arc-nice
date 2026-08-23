extends SceneTree

const Codec := preload(
	"res://scene/multiplayer/projectile/enemy_rapid_fire_network_codec.gd"
)

var _failures: Array[String] = []


func _initialize() -> void:
	_test_golden_wire_layouts()
	_test_burst_roundtrip()
	_test_burst_rejections()
	_test_snapshot_roundtrip()
	_test_snapshot_rejections()
	_test_finish_roundtrip()
	if _failures.is_empty():
		print("enemy_rapid_fire_network_codec_smoke_test: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_golden_wire_layouts() -> void:
	# These bytes freeze schema v1 endianness, field order and angle
	# quantization. Any intentional layout change must bump both the codec schema
	# and NetConstants.PROTOCOL_VERSION before replacing these fixtures.
	var burst := Codec.encode_burst(
		Codec.PROFILE_AK,
		0x102030405060708,
		0x1112131480000021,
		0x10203,
		Vector2(1.5, -2.25),
		Vector2(-3.75, 4.5),
		Vector2.from_angle(0.25),
		0.125,
		96.0,
		1.75,
		PackedVector2Array([
			Vector2.from_angle(0.25),
			Vector2.from_angle(-0.5),
		])
	)
	var snapshot_records: Array[Dictionary] = [{
		"projectile_id": 0x2122232480000042,
		"profile": Codec.PROFILE_GUNNER_ELITE,
		"source_enemy_id": 0x20304,
		"position": Vector2(-7.5, 8.25),
		"direction": Vector2.from_angle(-1.0),
		"speed": 144.5,
		"remaining_lifetime": 0.875,
	}]
	var finish_records: Array[Dictionary] = [{
		"projectile_id": 0x3132333480000063,
		"reason": 4,
		"position": Vector2(9.5, -10.75),
		"direction": Vector2.from_angle(2.0),
	}]
	_expect(
		burst.hex_encode() == (
			"0101020008070605040302012100008014131211030201000000c03f"
			+ "000010c0000070c000009040300a0000003e0000c0420000e03f000071e1"
		),
		"burst schema v1 golden bytes changed without a protocol bump"
	)
	_expect(
		Codec.encode_snapshot_chunk(snapshot_records).hex_encode() == (
			"0101000042000080242322210300040302000000f0c00000044142d70080"
			+ "10430000603f"
		),
		"snapshot schema v1 golden bytes changed without a protocol bump"
	)
	_expect(
		Codec.encode_finish_batch(finish_records).hex_encode() == (
			"010100006300008034333231040000184100002cc17c51"
		),
		"finish schema v1 golden bytes changed without a protocol bump"
	)


func _test_burst_roundtrip() -> void:
	var locked_direction := Vector2.from_angle(0.73)
	var directions := PackedVector2Array()
	for shot_index in range(12):
		directions.append(
			locked_direction.rotated(deg_to_rad(float(shot_index - 6) * 0.7))
		)
	var payload := Codec.encode_burst(
		Codec.PROFILE_GUNNER,
		9001,
		0x1234567880000123,
		77,
		Vector2(120.0, -48.0),
		Vector2(128.25, -42.5),
		locked_direction,
		0.08,
		80.0,
		1.5,
		directions
	)
	_expect(
		payload.size() == Codec.BURST_HEADER_BYTES + 24,
		"burst payload size must remain fixed and compact"
	)
	_expect(
		payload.size() < Codec.MAX_BURST_PAYLOAD_BYTES,
		"burst payload must stay below MTU budget"
	)
	var decoded := Codec.decode_burst(payload)
	_expect(bool(decoded.get("valid", false)), "burst roundtrip must decode")
	if not bool(decoded.get("valid", false)):
		return
	_expect(int(decoded["profile"]) == Codec.PROFILE_GUNNER, "profile mismatch")
	_expect(int(decoded["count"]) == 12, "burst count mismatch")
	_expect(int(decoded["action_id"]) == 9001, "action id mismatch")
	_expect(
		int(decoded["base_projectile_id"]) == 0x1234567880000123,
		"base projectile id mismatch"
	)
	_expect(int(decoded["source_enemy_id"]) == 77, "source enemy mismatch")
	_expect(
		(decoded["source_position"] as Vector2).distance_to(
			Vector2(120.0, -48.0)
		) < 0.001,
		"source position mismatch"
	)
	_expect(
		(decoded["origin"] as Vector2).distance_to(Vector2(128.25, -42.5)) < 0.001,
		"burst origin mismatch"
	)
	_expect(absf(float(decoded["interval"]) - 0.08) < 0.00001, "interval mismatch")
	var decoded_directions := decoded["directions"] as PackedVector2Array
	_expect(decoded_directions.size() == directions.size(), "direction count mismatch")
	for shot_index in range(mini(decoded_directions.size(), directions.size())):
		_expect(
			absf(decoded_directions[shot_index].angle_to(directions[shot_index])) < 0.0002,
			"direction quantization exceeded contract at shot %d" % shot_index
		)


func _test_burst_rejections() -> void:
	var directions := PackedVector2Array([Vector2.RIGHT])
	var valid_payload := Codec.encode_burst(
		Codec.PROFILE_AK,
		1,
		2,
		3,
		Vector2.ZERO,
		Vector2.ZERO,
		Vector2.RIGHT,
		0.08,
		100.0,
		2.0,
		directions
	)
	var wrong_version := valid_payload.duplicate()
	wrong_version[0] = Codec.SCHEMA_VERSION + 1
	_expect(
		not bool(Codec.decode_burst(wrong_version).get("valid", false)),
		"unknown burst schema must be rejected"
	)
	var wrong_count := valid_payload.duplicate()
	wrong_count[2] = 2
	_expect(
		not bool(Codec.decode_burst(wrong_count).get("valid", false)),
		"burst size/count mismatch must be rejected"
	)
	_expect(
		not bool(Codec.decode_burst(valid_payload.slice(0, valid_payload.size() - 1)).get("valid", false)),
		"truncated burst must be rejected"
	)
	var oversized_directions := PackedVector2Array()
	oversized_directions.resize(Codec.MAX_BURST_PROJECTILES + 1)
	oversized_directions.fill(Vector2.RIGHT)
	_expect(
		Codec.encode_burst(
			Codec.PROFILE_AK,
			1,
			2,
			3,
			Vector2.ZERO,
			Vector2.ZERO,
			Vector2.RIGHT,
			0.08,
			100.0,
			2.0,
			oversized_directions
		).is_empty(),
		"oversized burst must not encode"
	)
	_expect(
		Codec.encode_burst(
			Codec.PROFILE_AK,
			1,
			2,
			3,
			Vector2.ZERO,
			Vector2(INF, 0.0),
			Vector2.RIGHT,
			0.08,
			100.0,
			2.0,
			directions
		).is_empty(),
		"non-finite burst values must not encode"
	)


func _test_snapshot_roundtrip() -> void:
	var records: Array[Dictionary] = []
	for record_index in range(Codec.MAX_SNAPSHOT_RECORDS):
		records.append({
			"projectile_id": 1000 + record_index,
			"profile": 1 + record_index % 3,
			"source_enemy_id": 40 + record_index,
			"position": Vector2(record_index * 3.25, -record_index * 0.5),
			"direction": Vector2.from_angle(record_index * 0.1),
			"speed": 80.0 + record_index,
			"remaining_lifetime": 0.5 + record_index * 0.01,
		})
	var payload := Codec.encode_snapshot_chunk(records)
	_expect(
		payload.size() == (
			Codec.SNAPSHOT_HEADER_BYTES
			+ Codec.MAX_SNAPSHOT_RECORDS * Codec.SNAPSHOT_RECORD_BYTES
		),
		"snapshot chunk size mismatch"
	)
	_expect(
		payload.size() <= Codec.MAX_SNAPSHOT_PAYLOAD_BYTES,
		"snapshot chunk exceeded packet budget"
	)
	var decoded := Codec.decode_snapshot_chunk(payload)
	_expect(bool(decoded.get("valid", false)), "snapshot roundtrip must decode")
	if not bool(decoded.get("valid", false)):
		return
	var decoded_records := decoded["records"] as Array[Dictionary]
	_expect(decoded_records.size() == records.size(), "snapshot record count mismatch")
	for record_index in range(mini(decoded_records.size(), records.size())):
		var expected := records[record_index]
		var actual := decoded_records[record_index]
		_expect(
			int(actual["projectile_id"]) == int(expected["projectile_id"]),
			"snapshot projectile id mismatch at %d" % record_index
		)
		_expect(
			(actual["position"] as Vector2).distance_to(expected["position"] as Vector2) < 0.001,
			"snapshot position mismatch at %d" % record_index
		)
		_expect(
			absf((actual["direction"] as Vector2).angle_to(expected["direction"] as Vector2)) < 0.0002,
			"snapshot direction mismatch at %d" % record_index
		)


func _test_snapshot_rejections() -> void:
	var valid_record := {
		"projectile_id": 1,
		"profile": Codec.PROFILE_AK,
		"source_enemy_id": 2,
		"position": Vector2.ZERO,
		"direction": Vector2.RIGHT,
		"speed": 100.0,
		"remaining_lifetime": 1.0,
	}
	var valid_records: Array[Dictionary] = [valid_record]
	var valid_payload := Codec.encode_snapshot_chunk(valid_records)
	var wrong_version := valid_payload.duplicate()
	wrong_version[0] = Codec.SCHEMA_VERSION + 1
	_expect(
		not bool(Codec.decode_snapshot_chunk(wrong_version).get("valid", false)),
		"unknown snapshot schema must be rejected"
	)
	var wrong_count := valid_payload.duplicate()
	wrong_count[1] = 2
	_expect(
		not bool(Codec.decode_snapshot_chunk(wrong_count).get("valid", false)),
		"snapshot size/count mismatch must be rejected"
	)
	var too_many: Array[Dictionary] = []
	for _record_index in range(Codec.MAX_SNAPSHOT_RECORDS + 1):
		too_many.append(valid_record.duplicate())
	_expect(
		Codec.encode_snapshot_chunk(too_many).is_empty(),
		"oversized snapshot chunk must not encode"
	)
	var invalid_record := valid_record.duplicate()
	invalid_record["remaining_lifetime"] = 0.0
	var invalid_records: Array[Dictionary] = [invalid_record]
	_expect(
		Codec.encode_snapshot_chunk(invalid_records).is_empty(),
		"expired snapshot record must not encode"
	)


func _test_finish_roundtrip() -> void:
	var records: Array[Dictionary] = []
	for record_index in range(Codec.MAX_FINISH_RECORDS):
		records.append({
			"projectile_id": 1000 + record_index,
			"reason": 2 if record_index % 2 == 0 else 3,
			"position": Vector2(record_index * 1.25, -record_index),
			"direction": Vector2.from_angle(record_index * 0.03),
		})
	var payload := Codec.encode_finish_batch(records)
	_expect(
		payload.size() == Codec.FINISH_HEADER_BYTES \
			+ Codec.MAX_FINISH_RECORDS * Codec.FINISH_RECORD_BYTES
		and payload.size() < Codec.MAX_FINISH_PAYLOAD_BYTES,
		"finish batch must remain fixed, compact and below its packet budget"
	)
	var decoded := Codec.decode_finish_batch(payload)
	_expect(bool(decoded.get("valid", false)), "finish batch must roundtrip")
	var decoded_records := decoded.get("records", []) as Array
	_expect(decoded_records.size() == records.size(), "finish count mismatch")
	if decoded_records.size() == records.size():
		_expect(
			int((decoded_records[17] as Dictionary)["projectile_id"]) == 1017
			and int((decoded_records[17] as Dictionary)["reason"]) == 3
			and ((decoded_records[17] as Dictionary)["position"] as Vector2).distance_to(
				Vector2(21.25, -17.0)
			) < 0.001,
			"finish record identity, reason and position mismatch"
		)
	var invalid := records[0].duplicate()
	invalid["reason"] = 0
	var invalid_records: Array[Dictionary] = [invalid]
	_expect(
		Codec.encode_finish_batch(invalid_records).is_empty(),
		"finish reason NONE must not encode"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
