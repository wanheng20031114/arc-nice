extends SceneTree

var RelayServerScript: GDScript = null
const FIXTURE_SECRET := "fixture-room-admission-secret-0123456789abcdef"
const FIXTURE_TICKET := (
	"ra1.eyJleHAiOjE3MDAwMDAwNjAsImlhdCI6MTcwMDAwMDAwMCwibm9uY2UiOiJmaXh0dXJlLW5vbmNlIiwicGxheWVyX25hbWUiOiJGaXh0dXJlSG9zdCIsInJvbGUiOiJob3N0Iiwicm9vbV9pZCI6ImZpeHR1cmUtcm9vbSIsInYiOjF9"
	+ ".5e67fae058093d9b51f20b0b4afa5c7db7094550d2f66831456a1b119acfacbd"
)
const OVERLONG_NONCE_TICKET := (
	"ra1.eyJleHAiOjE3MDAwMDAwNjAsImlhdCI6MTcwMDAwMDAwMCwibm9uY2UiOiJubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubiIsInBsYXllcl9uYW1lIjoiRml4dHVyZUhvc3QiLCJyb2xlIjoiaG9zdCIsInJvb21faWQiOiJmaXh0dXJlLXJvb20iLCJ2IjoxfQ"
	+ ".c349b047fed49eacc078f1f90dc000ab63735164ecd8cb7160adfcee0ae002bf"
)
const OVERLONG_TTL_TICKET := (
	"ra1.eyJleHAiOjE3MDAwMDA2MDAsImlhdCI6MTcwMDAwMDAwMCwibm9uY2UiOiJmaXh0dXJlLW5vbmNlIiwicGxheWVyX25hbWUiOiJGaXh0dXJlSG9zdCIsInJvbGUiOiJob3N0Iiwicm9vbV9pZCI6ImZpeHR1cmUtcm9vbSIsInYiOjF9"
	+ ".4ea6f54a5be8b40edd7a5b92d14a3aaea7115716a909f6343af7503e84082e3f"
)


func _initialize() -> void:
	var loaded_relay_script: Resource = load("res://relay_server.gd")
	if not (loaded_relay_script is GDScript):
		push_error("Relay server script failed to load")
		quit(1)
		return
	RelayServerScript = loaded_relay_script as GDScript
	var claims: Dictionary = RelayServerScript.verify_admission_ticket(
		FIXTURE_TICKET,
		FIXTURE_SECRET,
		"fixture-room",
		1_700_000_010
	)
	_assert(not claims.is_empty(), "Python-issued fixture must verify in Godot")
	_assert(str(claims.get("role")) == "host", "Fixture role must remain host")
	_assert(
		str(claims.get("player_name")) == "FixtureHost",
		"Fixture player identity must survive decoding"
	)
	var valid_host_auth_request := {
		"v": RelayServerScript.AUTH_PROTOCOL_VERSION,
		"ticket": FIXTURE_TICKET,
		"player_name": "FixtureHost",
		"character_id": "weishidaier",
		"character_confirmed": true,
		"protocol_version": RelayServerScript.PROTOCOL_VERSION,
		"reconnect_token": "0".repeat(32),
		"content_manifest_schema": 1,
		"content_digest": "a".repeat(64),
	}
	_assert(
		RelayServerScript._has_exact_auth_request_schema(
			valid_host_auth_request
		),
		"Relay auth request must use the exact nine-key schema"
	)
	var extra_key_request: Dictionary = valid_host_auth_request.duplicate(true)
	extra_key_request["unexpected"] = true
	_assert(
		not RelayServerScript._has_exact_auth_request_schema(extra_key_request),
		"Relay auth request must reject unknown keys"
	)
	var missing_key_request: Dictionary = valid_host_auth_request.duplicate(true)
	missing_key_request.erase("content_digest")
	_assert(
		not RelayServerScript._has_exact_auth_request_schema(missing_key_request),
		"Relay auth request must reject missing registration fields"
	)
	var parsed_registration: Dictionary = (
		RelayServerScript._parse_registration_request(valid_host_auth_request)
	)
	_assert(
		not parsed_registration.is_empty()
		and RelayServerScript._registration_matches_claims(
			parsed_registration,
			claims
		),
		"A valid Host request must preserve and bind its raw registration tuple"
	)
	var mismatched_registration: Dictionary = parsed_registration.duplicate(true)
	mismatched_registration["player_name"] = "DifferentName"
	_assert(
		not RelayServerScript._registration_matches_claims(
			mismatched_registration,
			claims
		),
		"Ticket identity and registration player_name must match exactly"
	)
	var malformed_registration_requests: Array[Dictionary] = []
	var invalid_bool_request: Dictionary = valid_host_auth_request.duplicate(true)
	invalid_bool_request["character_confirmed"] = "true"
	malformed_registration_requests.append(invalid_bool_request)
	var overlong_character_request: Dictionary = valid_host_auth_request.duplicate(true)
	overlong_character_request["character_id"] = "x".repeat(65)
	malformed_registration_requests.append(overlong_character_request)
	var fractional_protocol_request: Dictionary = valid_host_auth_request.duplicate(true)
	fractional_protocol_request["protocol_version"] = 90.5
	malformed_registration_requests.append(fractional_protocol_request)
	var invalid_token_request: Dictionary = valid_host_auth_request.duplicate(true)
	invalid_token_request["reconnect_token"] = "A" + "0".repeat(31)
	malformed_registration_requests.append(invalid_token_request)
	var short_digest_request: Dictionary = valid_host_auth_request.duplicate(true)
	short_digest_request["content_digest"] = "a".repeat(63)
	malformed_registration_requests.append(short_digest_request)
	for malformed_request: Dictionary in malformed_registration_requests:
		_assert(
			RelayServerScript._parse_registration_request(
				malformed_request
			).is_empty(),
			"Malformed registration field type/length must fail closed"
		)
	_assert(
		RelayServerScript.verify_admission_ticket(
			FIXTURE_TICKET + "0",
			FIXTURE_SECRET,
			"fixture-room",
			1_700_000_010
		).is_empty(),
		"Tampered ticket must fail closed"
	)
	for malformed_envelope: String in [
		FIXTURE_TICKET + ".",
		FIXTURE_TICKET.replace(".5e67", "..5e67"),
	]:
		_assert(
			RelayServerScript.verify_admission_ticket(
				malformed_envelope,
				FIXTURE_SECRET,
				"fixture-room",
				1_700_000_010
			).is_empty(),
			"Empty ticket envelope segments must fail closed"
		)
	_assert(
		RelayServerScript.verify_admission_ticket(
			FIXTURE_TICKET,
			FIXTURE_SECRET,
			"wrong-room",
			1_700_000_010
		).is_empty(),
		"Cross-room replay must fail closed"
	)
	_assert(
		RelayServerScript.verify_admission_ticket(
			FIXTURE_TICKET,
			FIXTURE_SECRET,
			"fixture-room",
			1_700_000_060
		).is_empty(),
		"Expiration boundary must be exclusive"
	)
	_assert(
		RelayServerScript.verify_admission_ticket(
			OVERLONG_NONCE_TICKET,
			FIXTURE_SECRET,
			"fixture-room",
			1_700_000_010
		).is_empty(),
		"Godot verifier must enforce the same 64-character nonce bound as Python"
	)
	_assert(
		RelayServerScript.verify_admission_ticket(
			OVERLONG_TTL_TICKET,
			FIXTURE_SECRET,
			"fixture-room",
			1_700_000_100
		).is_empty(),
		"Godot verifier must reject signed tickets beyond the 120-second window"
	)
	var consumed_nonces := {}
	_assert(
		RelayServerScript.try_consume_ticket_nonce(
			claims,
			consumed_nonces,
			1_700_000_010
		),
		"A fresh ticket nonce must be consumed once"
	)
	_assert(
		not RelayServerScript.try_consume_ticket_nonce(
			claims,
			consumed_nonces,
			1_700_000_011
		),
		"The same ticket nonce must fail closed on replay"
	)
	var full_nonce_ledger := {}
	for index: int in RelayServerScript.MAX_CONSUMED_TICKET_NONCES:
		full_nonce_ledger["used-%03d" % index] = 1_700_000_060
	var fresh_claims: Dictionary = claims.duplicate()
	fresh_claims["nonce"] = "fresh-at-capacity"
	_assert(
		not RelayServerScript.try_consume_ticket_nonce(
			fresh_claims,
			full_nonce_ledger,
			1_700_000_010
		),
		"A full nonce ledger must fail closed instead of growing"
	)
	full_nonce_ledger["used-000"] = 1_700_000_010
	_assert(
		RelayServerScript.try_consume_ticket_nonce(
			fresh_claims,
			full_nonce_ledger,
			1_700_000_010
		),
		"An expired nonce must be pruned before the capacity check"
	)
	_assert(
		full_nonce_ledger.size() == RelayServerScript.MAX_CONSUMED_TICKET_NONCES,
		"Nonce ledger must stay at its hard capacity after pruning"
	)
	_assert(
		RelayServerScript.consumed_nonce_capacity_for_room(2)
		< RelayServerScript.consumed_nonce_capacity_for_room(8)
		and RelayServerScript.consumed_nonce_capacity_for_room(8)
		== RelayServerScript.MAX_CONSUMED_TICKET_NONCES,
		"Public Relay nonce capacity must scale through the supported eight-player bound"
	)
	_assert(
		RelayServerScript.transport_capacity_for_room(2) == 10
		and RelayServerScript.transport_capacity_for_room(8) == 16,
		"Relay transport must add eight pending-auth reserves without exceeding sixteen sockets"
	)
	_assert(
		RelayServerScript.can_accept_auth_pending(8)
		and not RelayServerScript.can_accept_auth_pending(9),
		"A full pending-auth reserve must reject the next unauthenticated peer"
	)
	_assert(
		RelayServerScript.has_authenticated_room_capacity(1, 2)
		and not RelayServerScript.has_authenticated_room_capacity(2, 2)
		and RelayServerScript.has_authenticated_room_capacity(7, 8)
		and not RelayServerScript.has_authenticated_room_capacity(8, 8),
		"Authenticated public admission must honor each room capacity through eight players"
	)
	_assert(
		RelayServerScript.CH_MEMBERSHIP == 8
		and RelayServerScript.RELAY_CONTROL_CHANNEL == 9
		and RelayServerScript.RELAY_SERVICE_CHANNEL == 9
		and RelayServerScript.ENET_MAX_CHANNEL == 9
		and RelayServerScript.CHANNEL_COUNT == 9,
		"Relay must keep application CH0..CH8 and order topology plus service on CH9"
	)
	_assert(
		RelayServerScript.is_admission_claim_allowed("host", "Host", 0, {}),
		"A valid host role may claim an empty room"
	)
	_assert(
		not RelayServerScript.is_admission_claim_allowed(
			"host", "ReplacementHost", 0, {}, true
		),
		"A Relay generation must never accept a second Host"
	)
	_assert(
		not RelayServerScript.is_admission_claim_allowed("member", "First", 0, {}),
		"The first connector must not become host without a host ticket"
	)
	_assert(
		not RelayServerScript.is_admission_claim_allowed(
			"member", "EarlyMember", 7, {}, false
		),
		"A server-half-authenticated host must not open member admission"
	)
	_assert(
		RelayServerScript.is_admission_claim_allowed(
			"member", "Member", 7, {}, true
		),
		"A member may authenticate only after the host completed both auth sides"
	)
	var authenticated_identities := {
		2: {"role": "host", "player_name": "Host"},
		3: {"role": "member", "player_name": "BoundMember"},
	}
	var connected_identity_peers := PackedInt32Array([2, 3])
	_assert(
		RelayServerScript.is_authorized_host_control_sender(
			2, 2, connected_identity_peers
		)
		and RelayServerScript.is_authorized_host_identity_lookup_target(
			2, 3, connected_identity_peers, authenticated_identities
		),
		"Only the live Host may look up a live authenticated member identity"
	)
	_assert(
		not RelayServerScript.is_authorized_host_control_sender(
			2, 3, connected_identity_peers
		)
		and not RelayServerScript.is_authorized_host_identity_lookup_target(
			2, 2, connected_identity_peers, authenticated_identities
		),
		"Members cannot query identities and the Host cannot be registered as a member"
	)
	var connected_control_peers := PackedInt32Array([2, 3, 4])
	_assert(
		RelayServerScript.is_authorized_host_kick_request(
			2, 2, 3, connected_control_peers
		),
		"The registered live Host may kick another live room member"
	)
	_assert(
		not RelayServerScript.is_authorized_host_kick_request(
			2, 3, 4, connected_control_peers
		)
		and not RelayServerScript.is_authorized_host_kick_request(
			2, 2, 2, connected_control_peers
		)
		and not RelayServerScript.is_authorized_host_kick_request(
			2, 2, 9, connected_control_peers
		),
		"Members, self-targets, and disconnected targets must not pass Relay kick admission"
	)
	print("RELAY_ADMISSION_SMOKE_TEST_OK")
	quit(0)


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	quit(1)
