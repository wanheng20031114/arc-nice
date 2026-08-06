extends SceneTree

const ROUND_COUNT := 3
const EVENT_COUNT := 256
const FIXED_SEED := 0x4D50524A
const MpProjectileCoordinatorScript := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const PROJECTILE_TYPES: Array[StringName] = [
	&"player_bullet",
	&"tiyi_sniper_bullet",
	&"tango_laser_bullet",
	&"frost_sorcerer_ice_spike",
	&"probe",
]


class LegacyProjectileState:
	extends RefCounted

	const RECORD_RETENTION_SECONDS := 5.0
	const HIT_RETENTION_SECONDS := 30.0
	const SEQUENCE_BITS := 32
	const SEQUENCE_MASK: int = 0xFFFFFFFF
	const HOST_ORIGIN_BIT: int = 0x80000000
	const SEQUENCE_COUNTER_MASK: int = 0x7FFFFFFF
	const MAX_OWNER_PEER_ID: int = 0x7FFFFFFF
	const REQUEST_RATE_PER_SECOND := 256.0
	const REQUEST_RATE_BURST := 64.0

	var next_sequence := 1
	var projectile_records: Dictionary = {}
	var processed_enemy_hit_ids: Dictionary = {}
	var request_rate_buckets: Dictionary = {}

	func allocate(owner_peer_id: int, host_origin: bool) -> int:
		if owner_peer_id <= 0 or owner_peer_id > MAX_OWNER_PEER_ID:
			return 0
		if next_sequence <= 0 or next_sequence > SEQUENCE_COUNTER_MASK:
			next_sequence = 1
		var first_sequence := next_sequence
		while true:
			var sequence_counter := next_sequence
			next_sequence += 1
			if next_sequence > SEQUENCE_COUNTER_MASK:
				next_sequence = 1
			var sequence := sequence_counter
			if host_origin:
				sequence |= HOST_ORIGIN_BIT
			var projectile_id := encode(owner_peer_id, sequence)
			if projectile_id > 0 and not projectile_records.has(projectile_id):
				return projectile_id
			if next_sequence == first_sequence:
				return 0
		return 0

	func accept_client_identity(
		sender_id: int,
		projectile_id: int,
		owner_peer_id: int,
		is_suspended: bool,
		now: float
	) -> bool:
		if (
			sender_id <= 0
			or owner_peer_id != sender_id
			or is_suspended
			or projectile_records.has(projectile_id)
			or not is_valid_client_owner(projectile_id, owner_peer_id)
		):
			return false
		return consume_rate_token(sender_id, now)

	func consume_rate_token(peer_id: int, now: float) -> bool:
		if peer_id <= 0:
			return false
		var bucket: Dictionary
		if request_rate_buckets.has(peer_id):
			bucket = request_rate_buckets[peer_id] as Dictionary
		else:
			bucket = {
				"tokens": REQUEST_RATE_BURST,
				"last_time": now,
			}
			request_rate_buckets[peer_id] = bucket
		var tokens := float(bucket.get("tokens", REQUEST_RATE_BURST))
		var last_time := float(bucket.get("last_time", now))
		tokens = minf(
			REQUEST_RATE_BURST,
			tokens + maxf(now - last_time, 0.0) * REQUEST_RATE_PER_SECOND
		)
		var accepted := tokens >= 1.0
		if accepted:
			tokens -= 1.0
		bucket["tokens"] = tokens
		bucket["last_time"] = now
		return accepted

	func remember(
		projectile_id: int,
		owner_peer_id: int,
		projectile_type: StringName,
		damage: int,
		lifetime: float,
		pierces_enemies: bool,
		now: float
	) -> void:
		if projectile_id <= 0:
			return
		projectile_records[projectile_id] = {
			"owner_peer_id": owner_peer_id,
			"projectile_type": projectile_type,
			"damage": maxi(damage, 0),
			"pierces_enemies": pierces_enemies,
			"confirmed_hit_consumed": false,
			"expires_at": (
				now + maxf(lifetime, 0.0) + RECORD_RETENTION_SECONDS
			),
		}

	func prepare_hit(
		projectile_id: int,
		owner_peer_id: int,
		enemy_net_id: int,
		_reported_damage: int,
		now: float
	) -> Dictionary:
		if (
			projectile_id <= 0
			or owner_peer_id <= 0
			or enemy_net_id <= 0
			or not is_valid_owner(projectile_id, owner_peer_id)
		):
			return {}
		var record_variant: Variant = projectile_records.get(projectile_id)
		if not (record_variant is Dictionary):
			return {}
		var record := record_variant as Dictionary
		if record.is_empty() or int(record.get("owner_peer_id", 0)) != owner_peer_id:
			return {}
		var projectile_type := StringName(record.get("projectile_type", &""))
		var consumes_first_hit := (
			(
				projectile_type == &"player_bullet"
				or projectile_type == &"tiyi_sniper_bullet"
				or projectile_type == &"tango_laser_bullet"
			)
			and not bool(record.get("pierces_enemies", false))
		)
		if consumes_first_hit and bool(record.get("confirmed_hit_consumed", false)):
			return {}
		var authoritative_damage := int(record.get("damage", -1))
		if authoritative_damage <= 0:
			return {}
		var hit_key := "%d:%d" % [projectile_id, enemy_net_id]
		if (
			processed_enemy_hit_ids.has(hit_key)
			and float(processed_enemy_hit_ids[hit_key]) > now
		):
			return {}
		return {
			"projectile_type": projectile_type,
			"damage": authoritative_damage,
			"consumes": consumes_first_hit,
		}

	func commit_hit(
		projectile_id: int,
		enemy_net_id: int,
		consumes_first_hit: bool,
		now: float
	) -> void:
		if consumes_first_hit:
			var record_variant: Variant = projectile_records.get(projectile_id)
			if record_variant is Dictionary:
				var record := record_variant as Dictionary
				record["confirmed_hit_consumed"] = true
				projectile_records[projectile_id] = record
		processed_enemy_hit_ids["%d:%d" % [projectile_id, enemy_net_id]] = (
			now + HIT_RETENTION_SECONDS
		)

	func prune(now: float) -> void:
		var stale_projectile_ids: Array[int] = []
		for projectile_id_variant in projectile_records:
			var projectile_id := int(projectile_id_variant)
			var record := projectile_records[projectile_id] as Dictionary
			if record.is_empty() or float(record.get("expires_at", 0.0)) <= now:
				stale_projectile_ids.append(projectile_id)
		for projectile_id in stale_projectile_ids:
			projectile_records.erase(projectile_id)
		var expired_hit_keys: Array = []
		for hit_key in processed_enemy_hit_ids:
			if float(processed_enemy_hit_ids[hit_key]) <= now:
				expired_hit_keys.append(hit_key)
		for hit_key in expired_hit_keys:
			processed_enemy_hit_ids.erase(hit_key)

	func clear_peer(peer_id: int) -> void:
		request_rate_buckets.erase(peer_id)
		var projectile_ids: Array[int] = []
		for projectile_id_variant in projectile_records:
			var projectile_id := int(projectile_id_variant)
			var record := projectile_records[projectile_id] as Dictionary
			if record.is_empty() or int(record.get("owner_peer_id", 0)) == peer_id:
				projectile_ids.append(projectile_id)
		for projectile_id in projectile_ids:
			projectile_records.erase(projectile_id)

	func reset() -> void:
		projectile_records.clear()
		processed_enemy_hit_ids.clear()
		request_rate_buckets.clear()
		next_sequence = 1

	func get_record(projectile_id: int) -> Dictionary:
		var record_variant: Variant = projectile_records.get(projectile_id)
		return record_variant as Dictionary if record_variant is Dictionary else {}

	func metrics() -> Dictionary:
		return {
			"next_sequence": next_sequence,
			"known_projectiles": 0,
			"projectile_records": projectile_records.size(),
			"request_rate_buckets": request_rate_buckets.size(),
			"enemy_hit_dedupe": processed_enemy_hit_ids.size(),
		}

	static func encode(owner_peer_id: int, sequence: int) -> int:
		if (
			owner_peer_id <= 0
			or owner_peer_id > MAX_OWNER_PEER_ID
			or sequence <= 0
			or sequence > SEQUENCE_MASK
		):
			return 0
		return (owner_peer_id << SEQUENCE_BITS) | sequence

	static func decode_owner(projectile_id: int) -> int:
		return projectile_id >> SEQUENCE_BITS if projectile_id > 0 else 0

	static func decode_sequence(projectile_id: int) -> int:
		return projectile_id & SEQUENCE_MASK if projectile_id > 0 else 0

	static func is_valid_owner(projectile_id: int, owner_peer_id: int) -> bool:
		return (
			owner_peer_id > 0
			and owner_peer_id <= MAX_OWNER_PEER_ID
			and decode_owner(projectile_id) == owner_peer_id
			and decode_sequence(projectile_id) > 0
		)

	static func is_valid_client_owner(
		projectile_id: int,
		owner_peer_id: int
	) -> bool:
		return (
			is_valid_owner(projectile_id, owner_peer_id)
			and (decode_sequence(projectile_id) & HOST_ORIGIN_BIT) == 0
		)


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var combined_hash := 17
	for round_index in range(ROUND_COUNT):
		var legacy_hash := _run_trace(true, FIXED_SEED + round_index)
		var extracted_hash := _run_trace(false, FIXED_SEED + round_index)
		_expect(
			legacy_hash == extracted_hash,
			"第 %d 轮弹体状态轨迹不一致：legacy=%d extracted=%d。"
			% [round_index + 1, legacy_hash, extracted_hash]
		)
		combined_hash = _combine_hash(combined_hash, extracted_hash)
	if failures.is_empty():
		print(
			"MP_PROJECTILE_COORDINATOR_AB_PROBE_OK rounds=%d trajectory_hash=%d"
			% [ROUND_COUNT, combined_hash]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_trace(use_legacy: bool, seed: int) -> int:
	var random := RandomNumberGenerator.new()
	random.seed = seed
	var legacy := LegacyProjectileState.new()
	var extracted := MpProjectileCoordinatorScript.new()
	var tracked_ids: Array[int] = []
	var trace_hash := 23
	var now := 100.0
	for _event_index in range(EVENT_COUNT):
		var operation := random.randi_range(0, 6)
		trace_hash = _combine_hash(trace_hash, operation)
		match operation:
			0:
				var owner_peer_id := random.randi_range(2, 6)
				var host_origin := random.randi_range(0, 1) == 1
				var projectile_id := (
					legacy.allocate(owner_peer_id, host_origin)
					if use_legacy
					else extracted.allocate_projectile_id(
						owner_peer_id,
						host_origin
					)
				)
				trace_hash = _combine_hash(trace_hash, projectile_id)
				if projectile_id > 0 and random.randi_range(0, 2) == 0:
					var projectile_type := PROJECTILE_TYPES[
						random.randi_range(0, PROJECTILE_TYPES.size() - 1)
					]
					var damage := random.randi_range(1, 200)
					var lifetime := random.randf_range(-0.5, 3.0)
					var pierces := random.randi_range(0, 1) == 1
					_remember(
						use_legacy,
						legacy,
						extracted,
						projectile_id,
						owner_peer_id,
						projectile_type,
						damage,
						lifetime,
						pierces,
						now
					)
					tracked_ids.append(projectile_id)
			1:
				now += random.randf_range(0.0, 0.02)
				var owner_peer_id := random.randi_range(2, 6)
				var sender_id := owner_peer_id
				if random.randi_range(0, 7) == 0:
					sender_id += 10
				var sequence := random.randi_range(1, 96)
				if random.randi_range(0, 7) == 0:
					sequence |= MpProjectileCoordinatorScript.PROJECTILE_ID_HOST_ORIGIN_BIT
				var projectile_id := MpProjectileCoordinatorScript.encode_projectile_id(
					owner_peer_id,
					sequence
				)
				var suspended := random.randi_range(0, 9) == 0
				var accepted := (
					legacy.accept_client_identity(
						sender_id,
						projectile_id,
						owner_peer_id,
						suspended,
						now
					)
					if use_legacy
					else extracted.accept_client_projectile_request_identity(
						sender_id,
						projectile_id,
						owner_peer_id,
						suspended,
						now
					)
				)
				trace_hash = _combine_hash(trace_hash, 1 if accepted else 0)
			2:
				var owner_peer_id := random.randi_range(2, 6)
				var sequence := random.randi_range(1, 96)
				if random.randi_range(0, 1) == 1:
					sequence |= MpProjectileCoordinatorScript.PROJECTILE_ID_HOST_ORIGIN_BIT
				var projectile_id := MpProjectileCoordinatorScript.encode_projectile_id(
					owner_peer_id,
					sequence
				)
				var projectile_type := PROJECTILE_TYPES[
					random.randi_range(0, PROJECTILE_TYPES.size() - 1)
				]
				_remember(
					use_legacy,
					legacy,
					extracted,
					projectile_id,
					owner_peer_id,
					projectile_type,
					random.randi_range(-20, 200),
					random.randf_range(-0.5, 3.0),
					random.randi_range(0, 1) == 1,
					now
				)
				tracked_ids.append(projectile_id)
			3:
				now += random.randf_range(0.0, 4.0)
				if use_legacy:
					legacy.prune(now)
				else:
					extracted.prune_records(now)
			4:
				var peer_id := random.randi_range(2, 6)
				if use_legacy:
					legacy.clear_peer(peer_id)
				else:
					extracted.clear_peer(peer_id)
			5:
				if use_legacy:
					legacy.reset()
				else:
					extracted.reset_session_state()
			6:
				var admission_hash := 0
				if not tracked_ids.is_empty():
					var projectile_id := tracked_ids[
						random.randi_range(0, tracked_ids.size() - 1)
					]
					var owner_peer_id := (
						LegacyProjectileState.decode_owner(projectile_id)
					)
					if random.randi_range(0, 7) == 0:
						owner_peer_id += 1
					var enemy_net_id := random.randi_range(1, 12)
					var admission := _prepare_hit(
						use_legacy,
						legacy,
						extracted,
						projectile_id,
						owner_peer_id,
						enemy_net_id,
						random.randi_range(1, 999),
						now
					)
					admission_hash = _admission_hash(admission)
					var should_commit := random.randi_range(0, 1) == 1
					if not admission.is_empty() and should_commit:
						if use_legacy:
							legacy.commit_hit(
								projectile_id,
								enemy_net_id,
								bool(admission.get("consumes", false)),
								now
							)
						else:
							extracted.commit_enemy_hit(
								projectile_id,
								enemy_net_id,
								bool(admission.get("consumes", false)),
								now
							)
				trace_hash = _combine_hash(trace_hash, admission_hash)
		trace_hash = _append_state_hash(
			trace_hash,
			use_legacy,
			legacy,
			extracted,
			tracked_ids
		)
	extracted.free()
	return trace_hash


func _remember(
	use_legacy: bool,
	legacy: LegacyProjectileState,
	extracted: MpProjectileCoordinatorScript,
	projectile_id: int,
	owner_peer_id: int,
	projectile_type: StringName,
	damage: int,
	lifetime: float,
	pierces: bool,
	now: float
) -> void:
	if use_legacy:
		legacy.remember(
			projectile_id,
			owner_peer_id,
			projectile_type,
			damage,
			lifetime,
			pierces,
			now
		)
	else:
		extracted.remember_projectile_record(
			projectile_id,
			owner_peer_id,
			projectile_type,
			damage,
			lifetime,
			pierces,
			now
		)


func _prepare_hit(
	use_legacy: bool,
	legacy: LegacyProjectileState,
	extracted: MpProjectileCoordinatorScript,
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	reported_damage: int,
	now: float
) -> Dictionary:
	if use_legacy:
		return legacy.prepare_hit(
			projectile_id,
			owner_peer_id,
			enemy_net_id,
			reported_damage,
			now
		)
	var admission := extracted.prepare_enemy_hit(
		projectile_id,
		owner_peer_id,
		enemy_net_id,
		reported_damage,
		now
	)
	if admission == null:
		return {}
	return {
		"projectile_type": admission.projectile_type,
		"damage": admission.authoritative_damage,
		"consumes": admission.consumes_first_confirmed_hit,
	}


func _append_state_hash(
	current: int,
	use_legacy: bool,
	legacy: LegacyProjectileState,
	extracted: MpProjectileCoordinatorScript,
	tracked_ids: Array[int]
) -> int:
	var metrics := (
		legacy.metrics() if use_legacy else extracted.get_state_metrics()
	)
	var result := current
	for key in [
		"next_sequence",
		"known_projectiles",
		"projectile_records",
		"request_rate_buckets",
		"enemy_hit_dedupe",
	]:
		result = _combine_hash(result, int(metrics.get(key, -1)))
	if tracked_ids.is_empty():
		return _combine_hash(result, 0)
	var projectile_id := tracked_ids[tracked_ids.size() - 1]
	var record := (
		legacy.get_record(projectile_id)
		if use_legacy
		else extracted.get_projectile_record(projectile_id)
	)
	result = _combine_hash(result, 0 if record.is_empty() else 1)
	if record.is_empty():
		return result
	result = _combine_hash(result, int(record.get("owner_peer_id", 0)))
	result = _combine_hash(result, int(record.get("damage", 0)))
	result = _combine_hash(
		result,
		1 if bool(record.get("pierces_enemies", false)) else 0
	)
	result = _combine_hash(
		result,
		1 if bool(record.get("confirmed_hit_consumed", false)) else 0
	)
	result = _combine_hash(
		result,
		roundi(float(record.get("expires_at", 0.0)) * 1000.0)
	)
	return _combine_hash(
		result,
		String(record.get("projectile_type", &"")).hash()
	)


func _admission_hash(admission: Dictionary) -> int:
	if admission.is_empty():
		return 0
	var result := int(admission.get("damage", 0))
	result = _combine_hash(
		result,
		1 if bool(admission.get("consumes", false)) else 0
	)
	return _combine_hash(
		result,
		String(admission.get("projectile_type", &"")).hash()
	)


func _combine_hash(current: int, value: int) -> int:
	return int((current * 65599 + value) & 0x7fffffff)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
