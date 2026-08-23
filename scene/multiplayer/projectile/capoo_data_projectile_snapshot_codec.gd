extends RefCounted
class_name CapooDataProjectileSnapshotCodec

## Reliable, chunked visual snapshot contract for active RPG and Mage DATA rows.
## The payload never grants damage authority; frozen attribution is retained so
## client records remain structurally identical to the Host launch record.

const SCHEMA_VERSION := 2
const FLAG_NONE := 0
const FAMILY_CAPOO_RPG := 1
const FAMILY_CAPOO_MAGE := 2
const SOURCE_TYPE_CAPOO_RPG := &"capoo_rpg_rocket"
const SOURCE_TYPE_CAPOO_MAGE := &"capoo_mage_fireball"
const HEADER_BYTES := 4
const RECORD_BYTES := 76
## Leave enough headroom for the RPC method id and five envelope arguments so
## the encoded ENet packet stays below the 1200-byte application budget.
const MAX_RECORDS_PER_CHUNK := 14
const MAX_PAYLOAD_BYTES := 1200
const ANGLE_QUANTIZATION_MAX := 32767
const ANGLE_QUANTIZATION_SCALE := float(ANGLE_QUANTIZATION_MAX) / PI


static func encode_chunk(records: Array[Dictionary]) -> PackedByteArray:
	var record_count := records.size()
	if record_count <= 0 or record_count > MAX_RECORDS_PER_CHUNK:
		return PackedByteArray()
	var expected_size := HEADER_BYTES + record_count * RECORD_BYTES
	if expected_size > MAX_PAYLOAD_BYTES:
		return PackedByteArray()
	for record in records:
		if not _is_valid_record(record):
			return PackedByteArray()
	var stream := StreamPeerBuffer.new()
	stream.big_endian = false
	stream.put_u8(SCHEMA_VERSION)
	stream.put_u8(record_count)
	stream.put_u16(FLAG_NONE)
	for record in records:
		var direction := (record["direction"] as Vector2).normalized()
		stream.put_64(int(record["projectile_id"]))
		stream.put_u8(int(record["family"]))
		stream.put_u8(FLAG_NONE)
		stream.put_32(int(record["owner_peer_id"]))
		var position := record["position"] as Vector2
		stream.put_float(position.x)
		stream.put_float(position.y)
		stream.put_16(_quantize_angle(direction.angle()))
		stream.put_float(float(record["speed"]))
		stream.put_32(int(record["damage"]))
		stream.put_float(float(record["remaining_lifetime"]))
		stream.put_float(float(record["visual_age"]))
		stream.put_32(int(record["target_peer_id"]))
		stream.put_64(int(record["target_enemy_net_id"]))
		stream.put_32(int(record["source_faction_id"]))
		stream.put_32(int(record["source_credit_peer_id"]))
		stream.put_64(int(record["source_instigator_entity_id"]))
		stream.put_64(int(record["source_event_id"]))
	var payload := stream.data_array
	return payload if payload.size() == expected_size else PackedByteArray()


static func decode_chunk(payload: PackedByteArray) -> Dictionary:
	if (
		payload.size() < HEADER_BYTES + RECORD_BYTES
		or payload.size() > MAX_PAYLOAD_BYTES
	):
		return _invalid_result()
	var record_count := int(payload[1])
	var expected_size := HEADER_BYTES + record_count * RECORD_BYTES
	if (
		record_count <= 0
		or record_count > MAX_RECORDS_PER_CHUNK
		or payload.size() != expected_size
	):
		return _invalid_result()
	var stream := StreamPeerBuffer.new()
	stream.big_endian = false
	stream.data_array = payload
	if (
		stream.get_u8() != SCHEMA_VERSION
		or stream.get_u8() != record_count
		or stream.get_u16() != FLAG_NONE
	):
		return _invalid_result()
	var records: Array[Dictionary] = []
	records.resize(record_count)
	for record_index in range(record_count):
		var projectile_id := stream.get_64()
		var family := stream.get_u8()
		var record_flags := stream.get_u8()
		var record := {
			"projectile_id": projectile_id,
			"family": family,
			"owner_peer_id": stream.get_32(),
			"position": Vector2(stream.get_float(), stream.get_float()),
			"direction": Vector2.from_angle(
				_dequantize_angle(stream.get_16())
			),
			"speed": stream.get_float(),
			"damage": stream.get_32(),
			"remaining_lifetime": stream.get_float(),
			"visual_age": stream.get_float(),
			"target_peer_id": stream.get_32(),
			"target_enemy_net_id": stream.get_64(),
			"source_faction_id": stream.get_32(),
			"source_credit_peer_id": stream.get_32(),
			"source_instigator_entity_id": stream.get_64(),
			"source_event_id": stream.get_64(),
			"source_type": source_type_for_family(family),
		}
		if record_flags != FLAG_NONE or not _is_valid_record(record):
			return _invalid_result()
		records[record_index] = record
	return {
		"valid": true,
		"version": SCHEMA_VERSION,
		"records": records,
	}


static func source_type_for_family(family: int) -> StringName:
	match family:
		FAMILY_CAPOO_RPG:
			return SOURCE_TYPE_CAPOO_RPG
		FAMILY_CAPOO_MAGE:
			return SOURCE_TYPE_CAPOO_MAGE
		_:
			return &""


static func _is_valid_record(record: Dictionary) -> bool:
	var required_keys := [
		"projectile_id", "family", "owner_peer_id", "position", "direction",
		"speed", "damage", "remaining_lifetime", "target_peer_id",
		"visual_age", "target_enemy_net_id", "source_faction_id",
		"source_credit_peer_id",
		"source_instigator_entity_id", "source_event_id", "source_type",
	]
	for key in required_keys:
		if not record.has(key):
			return false
	if not record["position"] is Vector2 or not record["direction"] is Vector2:
		return false
	var projectile_id := int(record["projectile_id"])
	var family := int(record["family"])
	var position := record["position"] as Vector2
	var direction := record["direction"] as Vector2
	var target_peer_id := int(record["target_peer_id"])
	var target_enemy_net_id := int(record["target_enemy_net_id"])
	return (
		projectile_id > 0
		and source_type_for_family(family) != &""
		and StringName(record["source_type"]) == source_type_for_family(family)
		and int(record["owner_peer_id"]) >= 0
		and position.is_finite()
		and direction.is_finite()
		and direction.length_squared() > 0.001
		and is_finite(float(record["speed"]))
		and float(record["speed"]) > 0.0
		and int(record["damage"]) >= 0
		and is_finite(float(record["remaining_lifetime"]))
		and float(record["remaining_lifetime"]) > 0.0
		and is_finite(float(record["visual_age"]))
		and float(record["visual_age"]) >= 0.0
		and target_peer_id >= 0
		and target_enemy_net_id >= 0
		and not (target_peer_id > 0 and target_enemy_net_id > 0)
		and CombatRelationService.is_valid_faction_id(
			int(record["source_faction_id"])
		)
		and int(record["source_credit_peer_id"]) >= 0
		and int(record["source_instigator_entity_id"]) >= 0
		and int(record["source_event_id"]) == projectile_id
	)


static func _quantize_angle(angle: float) -> int:
	return clampi(
		roundi(wrapf(angle, -PI, PI) * ANGLE_QUANTIZATION_SCALE),
		-ANGLE_QUANTIZATION_MAX,
		ANGLE_QUANTIZATION_MAX
	)


static func _dequantize_angle(value: int) -> float:
	return float(value) / ANGLE_QUANTIZATION_SCALE


static func _invalid_result() -> Dictionary:
	return {"valid": false}
