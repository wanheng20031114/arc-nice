extends RefCounted
class_name EnemyRapidFireNetworkCodec

## Compact, versioned wire contract for enemy rapid-fire presentation.
## Authority damage and collision remain local to the Host; these payloads only
## reconstruct DATA projectile visuals on participants.

## The three v1 layouts are golden-byte frozen by the codec smoke test. Changing
## field order, width, endianness or quantization requires bumping this value and
## NetConstants.PROTOCOL_VERSION together.
const SCHEMA_VERSION := 1
const BURST_FLAG_NONE := 0
const SNAPSHOT_FLAG_NONE := 0
## GunnerConfig authoring allows up to 100 shots. Two-byte relative angles keep
## the entire authored maximum well below the 1200-byte packet ceiling.
const MAX_BURST_PROJECTILES := 100
const MAX_SNAPSHOT_RECORDS := 28
const MAX_BURST_PAYLOAD_BYTES := 1200
const MAX_SNAPSHOT_PAYLOAD_BYTES := 960
const MAX_SOURCE_ENEMY_ID := 0x7FFFFFFF
const BURST_HEADER_BYTES := 54
const BURST_DIRECTION_BYTES := 2
const SNAPSHOT_HEADER_BYTES := 4
const SNAPSHOT_RECORD_BYTES := 32
const FINISH_HEADER_BYTES := 4
const FINISH_RECORD_BYTES := 19
const MAX_FINISH_RECORDS := 48
const MAX_FINISH_PAYLOAD_BYTES := 960
const PROFILE_AK := 1
const PROFILE_GUNNER := 2
const PROFILE_GUNNER_ELITE := 3
const ANGLE_QUANTIZATION_MAX := 32767
const ANGLE_QUANTIZATION_SCALE := float(ANGLE_QUANTIZATION_MAX) / PI


static func encode_burst(
	profile: int,
	action_id: int,
	base_projectile_id: int,
	source_enemy_id: int,
	source_position: Vector2,
	origin: Vector2,
	locked_direction: Vector2,
	interval: float,
	speed: float,
	lifetime: float,
	directions: PackedVector2Array
) -> PackedByteArray:
	var projectile_count := directions.size()
	if (
		not _is_supported_profile(profile)
		or projectile_count <= 0
		or projectile_count > MAX_BURST_PROJECTILES
		or action_id <= 0
		or base_projectile_id <= 0
		or source_enemy_id <= 0
		or source_enemy_id > MAX_SOURCE_ENEMY_ID
		or not source_position.is_finite()
		or not origin.is_finite()
		or not _is_finite_direction(locked_direction)
		or not is_finite(interval)
		or interval < 0.0
		or not is_finite(speed)
		or speed <= 0.0
		or not is_finite(lifetime)
		or lifetime <= 0.0
	):
		return PackedByteArray()
	var normalized_locked_direction := locked_direction.normalized()
	for direction in directions:
		if not _is_finite_direction(direction):
			return PackedByteArray()
	var expected_size := (
		BURST_HEADER_BYTES
		+ projectile_count * BURST_DIRECTION_BYTES
	)
	if expected_size > MAX_BURST_PAYLOAD_BYTES:
		return PackedByteArray()

	var stream := StreamPeerBuffer.new()
	stream.big_endian = false
	stream.put_u8(SCHEMA_VERSION)
	stream.put_u8(profile)
	stream.put_u8(projectile_count)
	stream.put_u8(BURST_FLAG_NONE)
	stream.put_64(action_id)
	stream.put_64(base_projectile_id)
	stream.put_32(source_enemy_id)
	stream.put_float(source_position.x)
	stream.put_float(source_position.y)
	stream.put_float(origin.x)
	stream.put_float(origin.y)
	stream.put_16(_quantize_angle(normalized_locked_direction.angle()))
	stream.put_float(interval)
	stream.put_float(speed)
	stream.put_float(lifetime)
	var locked_angle := normalized_locked_direction.angle()
	for direction in directions:
		var relative_angle := wrapf(
			direction.normalized().angle() - locked_angle,
			-PI,
			PI
		)
		stream.put_16(_quantize_angle(relative_angle))
	var payload := stream.data_array
	return payload if payload.size() == expected_size else PackedByteArray()


static func decode_burst(payload: PackedByteArray) -> Dictionary:
	if (
		payload.size() < BURST_HEADER_BYTES + BURST_DIRECTION_BYTES
		or payload.size() > MAX_BURST_PAYLOAD_BYTES
	):
		return _invalid_result()
	var projectile_count := int(payload[2])
	var expected_size := (
		BURST_HEADER_BYTES
		+ projectile_count * BURST_DIRECTION_BYTES
	)
	if (
		projectile_count <= 0
		or projectile_count > MAX_BURST_PROJECTILES
		or payload.size() != expected_size
	):
		return _invalid_result()

	var stream := StreamPeerBuffer.new()
	stream.big_endian = false
	stream.data_array = payload
	var version := stream.get_u8()
	var profile := stream.get_u8()
	var decoded_count := stream.get_u8()
	var flags := stream.get_u8()
	var action_id := stream.get_64()
	var base_projectile_id := stream.get_64()
	var source_enemy_id := stream.get_32()
	var source_position := Vector2(stream.get_float(), stream.get_float())
	var origin := Vector2(stream.get_float(), stream.get_float())
	var locked_angle := _dequantize_angle(stream.get_16())
	var interval := stream.get_float()
	var speed := stream.get_float()
	var lifetime := stream.get_float()
	if (
		version != SCHEMA_VERSION
		or not _is_supported_profile(profile)
		or decoded_count != projectile_count
		or flags != BURST_FLAG_NONE
		or action_id <= 0
		or base_projectile_id <= 0
		or source_enemy_id <= 0
		or source_enemy_id > MAX_SOURCE_ENEMY_ID
		or not source_position.is_finite()
		or not origin.is_finite()
		or not is_finite(locked_angle)
		or not is_finite(interval)
		or interval < 0.0
		or not is_finite(speed)
		or speed <= 0.0
		or not is_finite(lifetime)
		or lifetime <= 0.0
	):
		return _invalid_result()

	var locked_direction := Vector2.from_angle(locked_angle)
	var directions := PackedVector2Array()
	directions.resize(projectile_count)
	for projectile_index in range(projectile_count):
		var relative_angle := _dequantize_angle(stream.get_16())
		directions[projectile_index] = Vector2.from_angle(
			locked_angle + relative_angle
		)
	return {
		"valid": true,
		"version": version,
		"profile": profile,
		"count": projectile_count,
		"action_id": action_id,
		"base_projectile_id": base_projectile_id,
		"source_enemy_id": source_enemy_id,
		"source_position": source_position,
		"origin": origin,
		"locked_direction": locked_direction,
		"interval": interval,
		"speed": speed,
		"lifetime": lifetime,
		"directions": directions,
	}


static func encode_snapshot_chunk(
	records: Array[Dictionary]
) -> PackedByteArray:
	var record_count := records.size()
	if record_count <= 0 or record_count > MAX_SNAPSHOT_RECORDS:
		return PackedByteArray()
	var expected_size := (
		SNAPSHOT_HEADER_BYTES
		+ record_count * SNAPSHOT_RECORD_BYTES
	)
	if expected_size > MAX_SNAPSHOT_PAYLOAD_BYTES:
		return PackedByteArray()
	for record in records:
		if not _is_valid_snapshot_record(record):
			return PackedByteArray()

	var stream := StreamPeerBuffer.new()
	stream.big_endian = false
	stream.put_u8(SCHEMA_VERSION)
	stream.put_u8(record_count)
	stream.put_u16(SNAPSHOT_FLAG_NONE)
	for record in records:
		var direction := (record["direction"] as Vector2).normalized()
		stream.put_64(int(record["projectile_id"]))
		stream.put_u8(int(record["profile"]))
		stream.put_u8(SNAPSHOT_FLAG_NONE)
		stream.put_32(int(record["source_enemy_id"]))
		var position := record["position"] as Vector2
		stream.put_float(position.x)
		stream.put_float(position.y)
		stream.put_16(_quantize_angle(direction.angle()))
		stream.put_float(float(record["speed"]))
		stream.put_float(float(record["remaining_lifetime"]))
	var payload := stream.data_array
	return payload if payload.size() == expected_size else PackedByteArray()


static func decode_snapshot_chunk(payload: PackedByteArray) -> Dictionary:
	if (
		payload.size() < SNAPSHOT_HEADER_BYTES + SNAPSHOT_RECORD_BYTES
		or payload.size() > MAX_SNAPSHOT_PAYLOAD_BYTES
	):
		return _invalid_result()
	var record_count := int(payload[1])
	var expected_size := (
		SNAPSHOT_HEADER_BYTES
		+ record_count * SNAPSHOT_RECORD_BYTES
	)
	if (
		record_count <= 0
		or record_count > MAX_SNAPSHOT_RECORDS
		or payload.size() != expected_size
	):
		return _invalid_result()

	var stream := StreamPeerBuffer.new()
	stream.big_endian = false
	stream.data_array = payload
	var version := stream.get_u8()
	var decoded_count := stream.get_u8()
	var flags := stream.get_u16()
	if (
		version != SCHEMA_VERSION
		or decoded_count != record_count
		or flags != SNAPSHOT_FLAG_NONE
	):
		return _invalid_result()
	var records: Array[Dictionary] = []
	records.resize(record_count)
	for record_index in range(record_count):
		var projectile_id := stream.get_64()
		var profile := stream.get_u8()
		var record_flags := stream.get_u8()
		var source_enemy_id := stream.get_32()
		var position := Vector2(stream.get_float(), stream.get_float())
		var direction := Vector2.from_angle(
			_dequantize_angle(stream.get_16())
		)
		var speed := stream.get_float()
		var remaining_lifetime := stream.get_float()
		var record := {
			"projectile_id": projectile_id,
			"profile": profile,
			"source_enemy_id": source_enemy_id,
			"position": position,
			"direction": direction,
			"speed": speed,
			"remaining_lifetime": remaining_lifetime,
		}
		if record_flags != SNAPSHOT_FLAG_NONE or not _is_valid_snapshot_record(record):
			return _invalid_result()
		records[record_index] = record
	return {
		"valid": true,
		"version": version,
		"records": records,
	}


static func encode_finish_batch(records: Array[Dictionary]) -> PackedByteArray:
	var record_count := records.size()
	if record_count <= 0 or record_count > MAX_FINISH_RECORDS:
		return PackedByteArray()
	var expected_size := FINISH_HEADER_BYTES + record_count * FINISH_RECORD_BYTES
	if expected_size > MAX_FINISH_PAYLOAD_BYTES:
		return PackedByteArray()
	for record in records:
		if not _is_valid_finish_record(record):
			return PackedByteArray()
	var stream := StreamPeerBuffer.new()
	stream.big_endian = false
	stream.put_u8(SCHEMA_VERSION)
	stream.put_u8(record_count)
	stream.put_u16(0)
	for record in records:
		stream.put_64(int(record["projectile_id"]))
		stream.put_u8(int(record["reason"]))
		var position := record["position"] as Vector2
		stream.put_float(position.x)
		stream.put_float(position.y)
		stream.put_16(_quantize_angle(
			(record["direction"] as Vector2).normalized().angle()
		))
	var payload := stream.data_array
	return payload if payload.size() == expected_size else PackedByteArray()


static func decode_finish_batch(payload: PackedByteArray) -> Dictionary:
	if (
		payload.size() < FINISH_HEADER_BYTES + FINISH_RECORD_BYTES
		or payload.size() > MAX_FINISH_PAYLOAD_BYTES
	):
		return _invalid_result()
	var record_count := int(payload[1])
	var expected_size := FINISH_HEADER_BYTES + record_count * FINISH_RECORD_BYTES
	if (
		record_count <= 0
		or record_count > MAX_FINISH_RECORDS
		or payload.size() != expected_size
	):
		return _invalid_result()
	var stream := StreamPeerBuffer.new()
	stream.big_endian = false
	stream.data_array = payload
	if (
		stream.get_u8() != SCHEMA_VERSION
		or stream.get_u8() != record_count
		or stream.get_u16() != 0
	):
		return _invalid_result()
	var records: Array[Dictionary] = []
	records.resize(record_count)
	for record_index in range(record_count):
		var record := {
			"projectile_id": stream.get_64(),
			"reason": stream.get_u8(),
			"position": Vector2(stream.get_float(), stream.get_float()),
			"direction": Vector2.from_angle(
				_dequantize_angle(stream.get_16())
			),
		}
		if not _is_valid_finish_record(record):
			return _invalid_result()
		records[record_index] = record
	return {
		"valid": true,
		"version": SCHEMA_VERSION,
		"records": records,
	}


static func _is_valid_snapshot_record(record: Dictionary) -> bool:
	if (
		not record.has("projectile_id")
		or not record.has("profile")
		or not record.has("source_enemy_id")
		or not record.has("position")
		or not record.has("direction")
		or not record.has("speed")
		or not record.has("remaining_lifetime")
		or not record["position"] is Vector2
		or not record["direction"] is Vector2
	):
		return false
	var position := record["position"] as Vector2
	var direction := record["direction"] as Vector2
	var speed := float(record["speed"])
	var remaining_lifetime := float(record["remaining_lifetime"])
	return (
		int(record["projectile_id"]) > 0
		and _is_supported_profile(int(record["profile"]))
		and int(record["source_enemy_id"]) > 0
		and int(record["source_enemy_id"]) <= MAX_SOURCE_ENEMY_ID
		and position.is_finite()
		and _is_finite_direction(direction)
		and is_finite(speed)
		and speed > 0.0
		and is_finite(remaining_lifetime)
		and remaining_lifetime > 0.0
	)


static func _is_valid_finish_record(record: Dictionary) -> bool:
	if (
		not record.has("projectile_id")
		or not record.has("reason")
		or not record.has("position")
		or not record.has("direction")
		or not record["position"] is Vector2
		or not record["direction"] is Vector2
	):
		return false
	var reason := int(record["reason"])
	return (
		int(record["projectile_id"]) > 0
		and reason >= 1
		and reason <= 4
		and (record["position"] as Vector2).is_finite()
		and _is_finite_direction(record["direction"] as Vector2)
	)


static func _is_supported_profile(profile: int) -> bool:
	return (
		profile == PROFILE_AK
		or profile == PROFILE_GUNNER
		or profile == PROFILE_GUNNER_ELITE
	)


static func _is_finite_direction(direction: Vector2) -> bool:
	return direction.is_finite() and direction.length_squared() > 0.000001


static func _quantize_angle(angle: float) -> int:
	return clampi(
		roundi(wrapf(angle, -PI, PI) * ANGLE_QUANTIZATION_SCALE),
		-ANGLE_QUANTIZATION_MAX,
		ANGLE_QUANTIZATION_MAX
	)


static func _dequantize_angle(encoded_angle: int) -> float:
	return clampi(
		encoded_angle,
		-ANGLE_QUANTIZATION_MAX,
		ANGLE_QUANTIZATION_MAX
	) / ANGLE_QUANTIZATION_SCALE


static func _invalid_result() -> Dictionary:
	return {"valid": false}
