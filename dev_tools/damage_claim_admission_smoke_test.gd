extends SceneTree

## Security contract for player damage ingress. Protocol v21 retains a
## five-field RPC compatibility shell, but both the client sender and Host
## receiver are fail-closed: canonical hits come only from Host simulation.

var failures: Array[String] = []
var legacy_claim_bytes: int = 0
var bounded_claim_bytes: int = 0
var disabled_enemy_claim_bytes: int = 0
var legacy_client_state_bytes: int = 0
var bounded_client_state_bytes: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_attack_registry_wire_contract()
	_test_player_hit_claim_lane_is_disabled()
	_test_enemy_hit_claim_lane_is_disabled()
	_test_client_state_combat_fields_removed()
	_test_player_hit_wire_payload_ab()

	if failures.is_empty():
		print(
			"DAMAGE_CLAIM_ADMISSION_SMOKE_TEST_OK legacy_player_bytes=%d production_player_bytes=0 bounded_player_shell_bytes=%d disabled_enemy_bytes=%d production_enemy_bytes=0 legacy_state_bytes=%d bounded_state_bytes=%d"
			% [legacy_claim_bytes, bounded_claim_bytes, disabled_enemy_claim_bytes, legacy_client_state_bytes, bounded_client_state_bytes]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_attack_registry_wire_contract() -> void:
	var physical := CombatTypes.DamageType.PHYSICAL
	var magic := CombatTypes.DamageType.MAGIC
	var cases: Array[Dictionary] = [
		_case(&"yuanshi_fire_projectile", 1, physical),
		_case(&"capoo_ak47_bullet", 2, physical),
		_case(&"capoo_smg_bullet", 3, physical),
		_case(&"capoo_rpg_rocket", 4, physical),
		_case(&"capoo_mage_fireball", 5, magic),
		_case(&"fire_sorcerer_fireball_a", 6, magic, &"fire_sorcerer_fireball_volley"),
		_case(&"fire_sorcerer_fireball_b", 7, magic, &"fire_sorcerer_fireball_volley"),
		_case(&"fire_sorcerer_fireball_c", 8, magic, &"fire_sorcerer_fireball_volley"),
		_case(
			&"fire_sorcerer_elite_fireball_a",
			9,
			magic,
			&"fire_sorcerer_elite_fireball_volley"
		),
		_case(
			&"fire_sorcerer_elite_fireball_b",
			10,
			magic,
			&"fire_sorcerer_elite_fireball_volley"
		),
		_case(
			&"fire_sorcerer_elite_fireball_c",
			11,
			magic,
			&"fire_sorcerer_elite_fireball_volley"
		),
		_case(&"frost_sorcerer_ice_spike", 12, magic),
		_case(&"linglan_skill1", 13, physical),
		_case(&"linglan_skill2_rocket", 14, physical),
		_case(&"linglan_skill3_orb", 15, magic),
		_case(&"linglan_skill4_orb", 16, magic),
	]
	_expect(
		cases.size() == CombatAttackRegistry.PlayerHitWireId.size() - 1,
		"The compatibility registry table must cover every non-INVALID wire ID."
	)
	for case_data in cases:
		var source_type := case_data["source_type"] as StringName
		var wire_id := int(case_data["wire_id"])
		_expect(
			CombatAttackRegistry.encode_player_hit_source(source_type) == wire_id
			and CombatAttackRegistry.decode_player_hit_source(wire_id) == source_type,
			"Wire ID %d must round-trip source %s." % [wire_id, source_type]
		)
		_expect(
			CombatAttackRegistry.get_damage_type(wire_id)
			== int(case_data["damage_type"]),
			"Wire ID %d must retain its declared damage type." % wire_id
		)
		_expect(
			CombatAttackRegistry.get_certificate_projectile_type(wire_id)
			== case_data["projectile_type"],
			"Wire ID %d must retain its recorded projectile type." % wire_id
		)

	for source_type in [
		&"fire_slime_touch",
		&"frost_slime_touch",
		&"enemy_contact",
		&"totally_unknown_attack",
	]:
		_expect(
			CombatAttackRegistry.encode_player_hit_source(source_type)
			== CombatAttackRegistry.PlayerHitWireId.INVALID,
			"Host-only or unknown source %s must have no wire ID." % source_type
		)


func _test_player_hit_claim_lane_is_disabled() -> void:
	var source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_game.gd"
	)
	var signature := _normalize_whitespace(
		_get_function_signature(source, "_rpc_player_hit_report")
	)
	var expected_signature := _normalize_whitespace(
		"func _rpc_player_hit_report("
		+ "_source_id: int, _player_peer_id: int, _attack_wire_id: int, "
		+ "_impact_direction: Vector2, _damage_flags: int) -> void:"
	)
	_expect(
		signature == expected_signature,
		"The protocol-v21 compatibility RPC must remain exactly five fields. actual=%s"
		% signature
	)
	var request_body := _get_function_body(
		source,
		"func request_player_hit_report("
	)
	var rpc_body := _get_function_body(
		source,
		"func _rpc_player_hit_report("
	)
	_expect(
		not request_body.contains("_rpc_player_hit_report.rpc_id")
		and not request_body.contains("_apply_player_hit_report"),
		"The client compatibility shell must not send or settle a hit claim."
	)
	_expect(
		not rpc_body.contains("_apply_player_hit_report")
		and not rpc_body.contains("_consume_peer_rate_token")
		and rpc_body.contains("return"),
		"The Host compatibility RPC must fail closed without touching combat state."
	)
	var multiplayer_damage_body := _get_function_body(
		source,
		"func request_multiplayer_player_damage("
	)
	_expect(
		not multiplayer_damage_body.contains("request_player_hit_report("),
		"Client contact detection must not enqueue any player-hit claim."
	)
	var client_branch_start := multiplayer_damage_body.find(
		"if net_manager.is_client():"
	)
	var host_branch_start := multiplayer_damage_body.find(
		"if net_manager.is_host():",
		client_branch_start + 1
	)
	var client_branch := (
		multiplayer_damage_body.substr(
			client_branch_start,
			host_branch_start - client_branch_start
		)
		if client_branch_start >= 0 and host_branch_start > client_branch_start
		else ""
	)
	_expect(
		not client_branch.contains("apply_combat_damage(")
		and not client_branch.contains("apply_damage(")
		and not client_branch.contains("current_health =")
		and not client_branch.contains("_die("),
		"Client contact detection must not mutate health or enter death lifecycle."
	)


func _test_enemy_hit_claim_lane_is_disabled() -> void:
	var source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_game.gd"
	)
	var signature := _normalize_whitespace(
		_get_function_signature(source, "_rpc_enemy_hit_report")
	)
	var expected_signature := _normalize_whitespace(
		"func _rpc_enemy_hit_report("
		+ "_projectile_id: int, _owner_peer_id: int, _enemy_net_id: int, "
		+ "_damage: int, _impact_direction: Vector2) -> void:"
	)
	_expect(
		signature == expected_signature,
		"The protocol-v21 enemy-hit compatibility RPC must retain its exact shape. actual=%s"
		% signature
	)
	var request_body := _get_function_body(
		source,
		"func request_enemy_hit_report("
	)
	var rpc_body := _get_function_body(
		source,
		"func _rpc_enemy_hit_report("
	)
	_expect(
		not request_body.contains("_rpc_enemy_hit_report.rpc_id")
		and request_body.contains("net_manager.is_host()")
		and request_body.contains("_apply_enemy_hit_report("),
		"Only Host-local projectile collision may enter enemy damage settlement."
	)
	_expect(
		not rpc_body.contains("_apply_enemy_hit_report(")
		and not rpc_body.contains("_get_host_enemy_for_net_id(")
		and rpc_body.contains("return"),
		"The enemy-hit RPC compatibility shell must fail closed."
	)


func _test_client_state_combat_fields_removed() -> void:
	var source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_game.gd"
	)
	var signature := _normalize_whitespace(
		_get_function_signature(source, "_rpc_client_player_state")
	)
	var expected_signature := _normalize_whitespace(
		"func _rpc_client_player_state("
		+ "sequence: int, reported_position: Vector2, reported_velocity: Vector2, "
		+ "move_input: Vector2, shoot_input: Vector2, buttons: int, "
		+ "dash_request_sequence: int, dash_direction: Vector2, "
		+ "dash_start_move_input: Vector2) -> void:"
	)
	_expect(
		signature == expected_signature,
		"The high-frequency client state RPC must contain only movement/input evidence. actual=%s"
		% signature
	)
	var sender_body := _get_function_body(
		source,
		"func _client_send_input_if_needed("
	)
	var receiver_body := _get_function_body(
		source,
		"func _rpc_client_player_state("
	)
	for forbidden_field in [
		"player_node.current_health",
		"player_node.max_health",
		"player_node.current_xirang",
		"player_node.invincibility_time_left",
		"player_node.skill1_charge",
		"get_multiplayer_form_mode()",
		"get_multiplayer_shot_pattern()",
	]:
		_expect(
			not sender_body.contains(forbidden_field),
			"Client state sender must not transmit combat field %s." % forbidden_field
		)
	_expect(
		receiver_body.contains("player_node.is_dead")
		and not receiver_body.contains("if is_dead")
		and not receiver_body.contains("current_health <= 0"),
		"Host input admission must use only Host-owned death state."
	)
	var legacy_state_shape := [
		77, Vector2(100.0, 200.0), Vector2(20.0, 0.0),
		Vector2.RIGHT, Vector2.UP, 0, 12, Vector2.RIGHT, Vector2.RIGHT,
		72, 100, 250, false, 0.15, true, 1.5, 4.0, 2, 1,
	]
	var bounded_state_shape := legacy_state_shape.slice(0, 9)
	legacy_client_state_bytes = var_to_bytes(legacy_state_shape).size()
	bounded_client_state_bytes = var_to_bytes(bounded_state_shape).size()
	_expect(
		bounded_client_state_bytes < legacy_client_state_bytes,
		"Bounded client state payload must be smaller than the legacy combat-wide payload."
	)


func _test_player_hit_wire_payload_ab() -> void:
	# Variant arrays provide identical framing for the legacy report and the
	# bounded compatibility shape. Production sends neither and therefore uses
	# zero client->Host bytes for this lane.
	var legacy_result_report := [
		123456,
		2,
		72,
		"fire_sorcerer_elite_fireball_c",
		928,
		false,
		47,
		72,
		Vector2(-0.8, 0.6),
		CombatTypes.DamageType.MAGIC,
	]
	var bounded_compatibility_shape := [
		123456,
		2,
		CombatAttackRegistry.PlayerHitWireId.FIRE_SORCERER_ELITE_FIREBALL_C,
		Vector2(-0.8, 0.6),
		CombatTypes.DamageFlag.RANGED,
	]
	legacy_claim_bytes = var_to_bytes(legacy_result_report).size()
	bounded_claim_bytes = var_to_bytes(bounded_compatibility_shape).size()
	disabled_enemy_claim_bytes = var_to_bytes([
		123456,
		2,
		9001,
		72,
		Vector2(-0.8, 0.6),
	]).size()
	_expect(
		bounded_claim_bytes < legacy_claim_bytes,
		"Even the disabled compatibility shape must remain smaller than the legacy client result report."
	)


func _case(
	source_type: StringName,
	wire_id: int,
	damage_type: int,
	projectile_type: StringName = &""
) -> Dictionary:
	return {
		"source_type": source_type,
		"wire_id": wire_id,
		"damage_type": damage_type,
		"projectile_type": source_type if projectile_type == &"" else projectile_type,
	}


func _get_function_signature(source: String, function_name: String) -> String:
	var start := source.find("func %s(" % function_name)
	if start < 0:
		return ""
	var finish := source.find(") -> void:", start)
	if finish < 0:
		return ""
	return source.substr(start, finish + len(") -> void:") - start)


func _get_function_body(source: String, signature_start: String) -> String:
	var start := source.find(signature_start)
	if start < 0:
		return ""
	var next_function := source.find("\n\nfunc ", start + 1)
	var next_rpc := source.find("\n\n@rpc", start + 1)
	var finish := next_function
	if finish < 0 or (next_rpc >= 0 and next_rpc < finish):
		finish = next_rpc
	if finish < 0:
		return source.substr(start)
	return source.substr(start, finish - start)


func _normalize_whitespace(value: String) -> String:
	var regex := RegEx.new()
	regex.compile("\\s+")
	return (
		regex.sub(value, " ", true)
		.strip_edges()
		.replace("( ", "(")
		.replace(" )", ")")
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
