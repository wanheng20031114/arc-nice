extends SceneTree

const MpProjectileCoordinator := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const RATE_PER_SECOND := 256.0
const BURST := 64
const LEGAL_SEMANTIC_RATE_PER_SECOND := 210.0


class ProjectileRateLimitCoordinator:
	extends MpProjectileCoordinator

	var test_net_time := 0.0


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_burst_boundary_and_refill()
	_test_peer_isolation()
	_test_legal_sustained_rate_boundary()
	_test_duplicate_identity_does_not_consume_token()
	_test_bucket_cleanup()
	_test_remote_entry_scope_and_order()
	if failures.is_empty():
		print("CLIENT_PROJECTILE_RATE_LIMIT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_burst_boundary_and_refill() -> void:
	var coordinator := ProjectileRateLimitCoordinator.new()
	var accepted_count := 0
	for sequence in range(1, BURST + 1):
		if _try_request(coordinator, 2, sequence):
			accepted_count += 1
	var retained_bucket := _get_peer_bucket(coordinator, 2)
	_expect(
		accepted_count == BURST and not _try_request(coordinator, 2, BURST + 1),
		"A peer must receive exactly the 64-request burst before request 65 is limited."
	)

	# Ten milliseconds replenishes 2.56 tokens: exactly two more whole requests.
	coordinator.test_net_time = 0.01
	var first_refill := _try_request(coordinator, 2, BURST + 2)
	var second_refill := _try_request(coordinator, 2, BURST + 3)
	var third_refill := _try_request(coordinator, 2, BURST + 4)
	var bucket := _get_peer_bucket(coordinator, 2)
	var expected_remaining_tokens := 0.01 * RATE_PER_SECOND - 2.0
	_expect(
		first_refill
		and second_refill
		and not third_refill
		and is_same(retained_bucket, bucket)
		and is_equal_approx(
			float(bucket.get("tokens", -1.0)),
			expected_remaining_tokens
		),
		"Elapsed time must replenish the same allocation-free bucket at exactly 256 tokens per second."
	)
	coordinator.free()


func _test_peer_isolation() -> void:
	var coordinator := ProjectileRateLimitCoordinator.new()
	for sequence in range(1, BURST + 1):
		_try_request(coordinator, 2, sequence)
	_expect(
		not _try_request(coordinator, 2, BURST + 1)
		and _try_request(coordinator, 3, 1)
		and not _try_request(coordinator, 2, BURST + 2),
		"Exhausting one peer's projectile budget must not reduce another peer's budget."
	)
	var buckets := coordinator.get("_client_projectile_request_rate_buckets") as Dictionary
	_expect(
		buckets.has(2)
		and buckets.has(3)
		and is_equal_approx(
			float((buckets[3] as Dictionary).get("tokens", -1.0)),
			float(BURST - 1)
		),
		"Projectile request buckets must be stored independently per peer."
	)
	coordinator.free()


func _test_legal_sustained_rate_boundary() -> void:
	var coordinator := ProjectileRateLimitCoordinator.new()
	var all_accepted := true
	var request_count := int(LEGAL_SEMANTIC_RATE_PER_SECOND * 2.0)
	for request_index in range(request_count):
		coordinator.test_net_time = (
			float(request_index) / LEGAL_SEMANTIC_RATE_PER_SECOND
		)
		if not _try_request(coordinator, 4, request_index + 1):
			all_accepted = false
			break
	var bucket := _get_peer_bucket(coordinator, 4)
	_expect(
		all_accepted
		and float(bucket.get("tokens", 0.0)) >= float(BURST - 1) - 0.001,
		"The 210/s semantic gameplay ceiling must remain sustainable without draining the bucket."
	)
	coordinator.free()


func _test_duplicate_identity_does_not_consume_token() -> void:
	var coordinator := ProjectileRateLimitCoordinator.new()
	var projectile_id := _projectile_id(5, 1)
	_expect(
		coordinator.accept_client_projectile_request_identity(
			5,
			projectile_id,
			5,
			false,
			coordinator.test_net_time
		),
		"The first valid client-lane identity must reach the rate bucket."
	)
	var before_bucket := _get_peer_bucket(coordinator, 5).duplicate()
	coordinator.remember_projectile_record(
		projectile_id,
		5,
		&"player_bullet",
		1,
		1.0,
		false,
		coordinator.test_net_time
	)
	var duplicate_accepted := coordinator.accept_client_projectile_request_identity(
		5,
		projectile_id,
		5,
		false,
		coordinator.test_net_time
	)
	var after_bucket := _get_peer_bucket(coordinator, 5)
	_expect(
		not duplicate_accepted
		and is_equal_approx(
			float(after_bucket.get("tokens", -1.0)),
			float(before_bucket.get("tokens", -2.0))
		)
		and is_equal_approx(
			float(after_bucket.get("last_time", -1.0)),
			float(before_bucket.get("last_time", -2.0))
		),
		"A duplicate known projectile identity must be rejected before consuming a token."
	)
	coordinator.free()


func _test_bucket_cleanup() -> void:
	var coordinator := ProjectileRateLimitCoordinator.new()
	_try_request(coordinator, 2, 1)
	_try_request(coordinator, 3, 1)
	coordinator.clear_peer(2)
	var buckets := coordinator.get("_client_projectile_request_rate_buckets") as Dictionary
	_expect(
		not buckets.has(2) and buckets.has(3),
		"Disconnect cleanup must erase only the departing peer's projectile bucket."
	)
	coordinator.free()

	var reset_coordinator := ProjectileRateLimitCoordinator.new()
	_try_request(reset_coordinator, 6, 1)
	reset_coordinator.reset_session_state()
	_expect(
		(reset_coordinator.get("_client_projectile_request_rate_buckets") as Dictionary).is_empty(),
		"Resetting the projectile coordinator must clear every client request bucket."
	)
	reset_coordinator.free()


func _test_remote_entry_scope_and_order() -> void:
	var source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
	)
	var remote_body := _get_function_body(
		source,
		"func accept_client_projectile_request_identity("
	)
	var identity_gate_position := remote_body.find(
		"is_projectile_id_valid_for_client_owner("
	)
	var bucket_position := remote_body.find("_consume_peer_rate_token(")
	_expect(
		identity_gate_position >= 0
		and bucket_position > identity_gate_position,
		"Remote projectile requests must spend their token only after cheap identity checks."
	)
	var client_parameters_body := _get_function_body(
		source,
		"func get_authoritative_client_projectile_parameters("
	)
	_expect(
		not client_parameters_body.contains("TANGO_LASER_PROJECTILE_TYPE")
		and not client_parameters_body.contains("tango_laser_bullet"),
		"Clients must not author Tango laser bullets through the generic projectile request RPC."
	)
	var reset_body := _get_function_body(source, "func reset_session_state(")
	_expect(
		reset_body.contains("_client_projectile_request_rate_buckets.clear()"),
		"Coordinator session reset must clear every client projectile bucket."
	)


func _try_request(
	coordinator: ProjectileRateLimitCoordinator,
	peer_id: int,
	sequence: int
) -> bool:
	return coordinator.accept_client_projectile_request_identity(
		peer_id,
		_projectile_id(peer_id, sequence),
		peer_id,
		false,
		coordinator.test_net_time
	)


func _projectile_id(
	peer_id: int,
	sequence: int
) -> int:
	return MpProjectileCoordinator.encode_projectile_id(peer_id, sequence)


func _get_peer_bucket(
	coordinator: ProjectileRateLimitCoordinator,
	peer_id: int
) -> Dictionary:
	var buckets := coordinator.get("_client_projectile_request_rate_buckets") as Dictionary
	return buckets.get(peer_id, {}) as Dictionary


func _get_function_body(source: String, signature: String) -> String:
	var function_start := source.find(signature)
	var function_end := source.find("\n\nfunc ", function_start + 1)
	if function_start < 0:
		return ""
	if function_end < 0:
		return source.substr(function_start)
	return source.substr(function_start, function_end - function_start)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
