extends SceneTree

const RATE_PER_SECOND := 256.0
const BURST := 64
const LEGAL_SEMANTIC_RATE_PER_SECOND := 210.0


class ProjectileRateLimitMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var test_net_time := 0.0

	func _get_net_time() -> float:
		return test_net_time


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
	var mp_game := ProjectileRateLimitMpGame.new()
	var accepted_count := 0
	for sequence in range(1, BURST + 1):
		if _try_request(mp_game, 2, sequence):
			accepted_count += 1
	var retained_bucket := _get_peer_bucket(mp_game, 2)
	_expect(
		accepted_count == BURST and not _try_request(mp_game, 2, BURST + 1),
		"A peer must receive exactly the 64-request burst before request 65 is limited."
	)

	# Ten milliseconds replenishes 2.56 tokens: exactly two more whole requests.
	mp_game.test_net_time = 0.01
	var first_refill := _try_request(mp_game, 2, BURST + 2)
	var second_refill := _try_request(mp_game, 2, BURST + 3)
	var third_refill := _try_request(mp_game, 2, BURST + 4)
	var bucket := _get_peer_bucket(mp_game, 2)
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
	mp_game.free()


func _test_peer_isolation() -> void:
	var mp_game := ProjectileRateLimitMpGame.new()
	for sequence in range(1, BURST + 1):
		_try_request(mp_game, 2, sequence)
	_expect(
		not _try_request(mp_game, 2, BURST + 1)
		and _try_request(mp_game, 3, 1)
		and not _try_request(mp_game, 2, BURST + 2),
		"Exhausting one peer's projectile budget must not reduce another peer's budget."
	)
	var buckets := mp_game.get("_client_projectile_request_rate_buckets") as Dictionary
	_expect(
		buckets.has(2)
		and buckets.has(3)
		and is_equal_approx(
			float((buckets[3] as Dictionary).get("tokens", -1.0)),
			float(BURST - 1)
		),
		"Projectile request buckets must be stored independently per peer."
	)
	mp_game.free()


func _test_legal_sustained_rate_boundary() -> void:
	var mp_game := ProjectileRateLimitMpGame.new()
	var all_accepted := true
	var request_count := int(LEGAL_SEMANTIC_RATE_PER_SECOND * 2.0)
	for request_index in range(request_count):
		mp_game.test_net_time = (
			float(request_index) / LEGAL_SEMANTIC_RATE_PER_SECOND
		)
		if not _try_request(mp_game, 4, request_index + 1):
			all_accepted = false
			break
	var bucket := _get_peer_bucket(mp_game, 4)
	_expect(
		all_accepted
		and float(bucket.get("tokens", 0.0)) >= float(BURST - 1) - 0.001,
		"The 210/s semantic gameplay ceiling must remain sustainable without draining the bucket."
	)
	mp_game.free()


func _test_duplicate_identity_does_not_consume_token() -> void:
	var mp_game := ProjectileRateLimitMpGame.new()
	var projectile_id := _projectile_id(mp_game, 5, 1)
	_expect(
		bool(mp_game.call(
			"_try_accept_client_projectile_request_identity",
			5,
			projectile_id,
			5
		)),
		"The first valid client-lane identity must reach the rate bucket."
	)
	var before_bucket := _get_peer_bucket(mp_game, 5).duplicate()
	var records := mp_game.get("_projectile_records") as Dictionary
	records[projectile_id] = {"owner_peer_id": 5}
	var duplicate_accepted := bool(mp_game.call(
		"_try_accept_client_projectile_request_identity",
		5,
		projectile_id,
		5
	))
	var after_bucket := _get_peer_bucket(mp_game, 5)
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
	mp_game.free()


func _test_bucket_cleanup() -> void:
	var mp_game := ProjectileRateLimitMpGame.new()
	_try_request(mp_game, 2, 1)
	_try_request(mp_game, 3, 1)
	mp_game.call("_clear_peer_network_state", 2)
	var buckets := mp_game.get("_client_projectile_request_rate_buckets") as Dictionary
	_expect(
		not buckets.has(2) and buckets.has(3),
		"Disconnect cleanup must erase only the departing peer's projectile bucket."
	)
	mp_game.free()

	var exit_game := ProjectileRateLimitMpGame.new()
	_try_request(exit_game, 6, 1)
	exit_game.call("_exit_tree")
	_expect(
		(exit_game.get("_client_projectile_request_rate_buckets") as Dictionary).is_empty(),
		"Exiting MpGame must clear every client projectile bucket."
	)
	exit_game.free()


func _test_remote_entry_scope_and_order() -> void:
	var source := FileAccess.get_file_as_string("res://scene/multiplayer/mp_game.gd")
	var remote_body := _get_function_body(
		source,
		"func _rpc_projectile_fired_from_client("
	)
	var identity_gate_position := remote_body.find(
		"_try_accept_client_projectile_request_identity("
	)
	var direction_position := remote_body.find("_get_valid_client_projectile_direction(")
	var parameter_position := remote_body.find(
		"_get_authoritative_client_projectile_parameters("
	)
	_expect(
		identity_gate_position >= 0
		and direction_position > identity_gate_position
		and parameter_position > direction_position,
		"Remote projectile requests must spend their token after cheap identity checks and before expensive validation."
	)
	var local_body := _get_function_body(source, "func register_local_projectile(")
	var linglan_body := _get_function_body(
		source,
		"func register_local_linglan_skill1_ring("
	)
	var tango_body := _get_function_body(
		source,
		"func register_local_tango_laser_volley("
	)
	var broadcast_body := _get_function_body(source, "func net_projectile_fired(")
	var client_parameters_body := _get_function_body(
		source,
		"func _get_authoritative_client_projectile_parameters("
	)
	var return_to_lobby_body := _get_function_body(source, "func _return_to_lobby(")
	_expect(
		not local_body.contains("_client_projectile_request_rate_buckets")
		and not linglan_body.contains("_client_projectile_request_rate_buckets")
		and not tango_body.contains("_client_projectile_request_rate_buckets")
		and not broadcast_body.contains("_client_projectile_request_rate_buckets"),
		"Host-local registration, Host batches, and projectile broadcasts must bypass the client request bucket."
	)
	_expect(
		not client_parameters_body.contains("TANGO_LASER_PROJECTILE_TYPE")
		and not client_parameters_body.contains("tango_laser_bullet"),
		"Clients must not author Tango laser bullets through the generic projectile request RPC."
	)
	_expect(
		return_to_lobby_body.contains(
			"_client_projectile_request_rate_buckets.clear()"
		),
		"Returning to the lobby must clear every client projectile bucket."
	)


func _try_request(
	mp_game: ProjectileRateLimitMpGame,
	peer_id: int,
	sequence: int
) -> bool:
	return bool(mp_game.call(
		"_try_accept_client_projectile_request_identity",
		peer_id,
		_projectile_id(mp_game, peer_id, sequence),
		peer_id
	))


func _projectile_id(
	mp_game: ProjectileRateLimitMpGame,
	peer_id: int,
	sequence: int
) -> int:
	return int(mp_game.call("_encode_projectile_id", peer_id, sequence))


func _get_peer_bucket(
	mp_game: ProjectileRateLimitMpGame,
	peer_id: int
) -> Dictionary:
	var buckets := mp_game.get("_client_projectile_request_rate_buckets") as Dictionary
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
