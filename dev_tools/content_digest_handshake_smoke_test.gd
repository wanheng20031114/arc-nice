extends SceneTree

const NetConstantsScript := preload("res://scene/multiplayer/net_constants.gd")
const RuntimeContentManifestScript := preload(
	"res://resources/config/generated/runtime_content_manifest.gd"
)
const AuthenticatedRelayMultiplayerPeerScript := preload(
	"res://scene/multiplayer/transport/authenticated_relay_multiplayer_peer.gd"
)
const LOBBY_SOURCE_PATH := "res://scene/multiplayer/multiplayer_lobby.gd"
const RELAY_SERVER_SOURCE_PATH := (
	"res://relay_servers/relay_godot_project/relay_server.gd"
)

const HOST_PEER_ID := 1
const CLIENT_PEER_ID := 42
const SECOND_CLIENT_PEER_ID := 43
const RECONNECT_OLD_PEER_ID := 17
const RECONNECT_NEW_PEER_ID := 71
const RECONNECT_TOKEN := "abababababababababababababababab"


class HostProbe:
	extends NetManagerStore
	var accepted_tuples: Array[Dictionary] = []
	var content_rejections: Array[Dictionary] = []
	var deferred_disconnects := PackedInt32Array()
	var rejected_registration_replay_peers := PackedInt32Array()
	var roster_broadcast_count := 0
	var targeted_roster_peers := PackedInt32Array()

	func is_host() -> bool:
		return true

	func get_local_peer_id() -> int:
		return HOST_PEER_ID

	func _send_registration_accepted_to_peer(peer_id: int) -> void:
		accepted_tuples.append({
			"peer_id": peer_id,
			"schema": _get_local_content_manifest_schema(),
			"digest": _get_local_content_digest(),
		})

	func _send_content_rejected_to_peer(peer_id: int) -> void:
		content_rejections.append({
			"peer_id": peer_id,
			"schema": _get_local_content_manifest_schema(),
			"digest": _get_local_content_digest(),
		})

	func _disconnect_incompatible_peer(peer_id: int) -> void:
		deferred_disconnects.append(peer_id)

	func _reject_changed_relay_registration(peer_id: int) -> void:
		rejected_registration_replay_peers.append(peer_id)

	func _broadcast_player_list_to_clients() -> void:
		roster_broadcast_count += 1

	func _send_player_list_to_peer(peer_id: int) -> bool:
		targeted_roster_peers.append(peer_id)
		return true

	func is_peer_control_send_ready(_peer_id: int) -> bool:
		return true

	func seed_host_member() -> void:
		net_role = NetRole.HOST
		host_peer_id = HOST_PEER_ID
		connected_players[HOST_PEER_ID] = "Host"
		connected_player_characters[HOST_PEER_ID] = DEFAULT_CHARACTER_ID
		confirmed_character_peers[HOST_PEER_ID] = true
		_register_active_session_member(
			HOST_PEER_ID,
			"Host",
			DEFAULT_CHARACTER_ID,
			true,
			""
		)

	func seed_suspended_reconnect_member(peer_id: int, token: String) -> void:
		_register_active_session_member(
			peer_id,
			"Reconnect",
			DEFAULT_CHARACTER_ID,
			true,
			token
		)
		var member := _session_members[peer_id] as Dictionary
		member["state"] = int(SessionMemberState.SUSPENDED_GRACE)
		member["grace_expires_msec"] = Time.get_ticks_msec() + 60_000
		_session_members[peer_id] = member
		_disconnected_reconnect_slots[token] = peer_id

	func get_reconnect_slot(token: String) -> int:
		return int(_disconnected_reconnect_slots.get(token, 0))

	func has_pending_reconnect(peer_id: int) -> bool:
		return _pending_reconnect_loads.has(peer_id)


class ClientProbe:
	extends NetManagerStore
	var local_peer_id := CLIENT_PEER_ID

	func is_host() -> bool:
		return false

	func get_local_peer_id() -> int:
		return local_peer_id

	func get_host_peer_id() -> int:
		return HOST_PEER_ID


class InvalidManifestProbe:
	extends NetManagerStore

	func _is_local_content_manifest_valid() -> bool:
		return false

	func has_transport_fixture() -> bool:
		return _enet_peer != null


var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_matching_registration_publishes_acceptance()
	_test_relay_exact_registration_replay_is_targeted()
	await _test_digest_rejection_is_zero_write_for_reconnect()
	await _test_malformed_digest_fields_are_rejected_and_disconnected()
	_test_client_requires_acceptance_and_active_roster()
	_test_wrong_sender_and_fields_fail_closed()
	_test_local_invalid_manifest_blocks_every_transport_entry()
	_test_relay_admission_client_contract()
	await _test_relay_business_state_waits_for_two_sided_authentication()
	_test_public_confirmation_waits_for_final_registration()
	_finish()


func _test_matching_registration_publishes_acceptance() -> void:
	var host := HostProbe.new()
	root.add_child(host)
	host.seed_host_member()
	host.connection_state = NetManagerStore.ConnectionState.HOSTING_LAN
	var registered := host._handle_player_registration(
		CLIENT_PEER_ID,
		"Client",
		"weishidaier",
		true,
		NetConstantsScript.PROTOCOL_VERSION,
		"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
		RuntimeContentManifestScript.SCHEMA_VERSION,
		RuntimeContentManifestScript.CONTENT_SHA256
	)
	_expect(
		registered
		and host.is_session_member_active(CLIENT_PEER_ID)
		and host.accepted_tuples == [{
			"peer_id": CLIENT_PEER_ID,
			"schema": RuntimeContentManifestScript.SCHEMA_VERSION,
			"digest": RuntimeContentManifestScript.CONTENT_SHA256,
		}]
		and host.roster_broadcast_count == 1,
		"匹配摘要的注册必须先形成 ACTIVE 成员并发送绑定 peer/schema/digest 的 accepted。"
	)
	host.free()


func _test_relay_exact_registration_replay_is_targeted() -> void:
	var host := HostProbe.new()
	root.add_child(host)
	host.seed_host_member()
	host.connection_state = NetManagerStore.ConnectionState.HOSTING_LAN
	host.conn_mode = NetManagerStore.ConnMode.RELAY
	host.set("_relay_transport_admitted", true)
	var reconnect_token := "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"
	var registered := host._handle_player_registration(
		CLIENT_PEER_ID,
		"Client",
		"weishidaier",
		true,
		NetConstantsScript.PROTOCOL_VERSION,
		reconnect_token,
		RuntimeContentManifestScript.SCHEMA_VERSION,
		RuntimeContentManifestScript.CONTENT_SHA256
	)
	var revision_after_first_commit := host.get_session_membership_revision()
	var replayed := host._try_replay_relay_registration_response(
		CLIENT_PEER_ID,
		"Client",
		"weishidaier",
		true,
		NetConstantsScript.PROTOCOL_VERSION,
		reconnect_token,
		RuntimeContentManifestScript.SCHEMA_VERSION,
		RuntimeContentManifestScript.CONTENT_SHA256
	)
	var exact_fields := {
		"player_name": "Client",
		"character_id": "weishidaier",
		"character_confirmed": true,
		"protocol_version": NetConstantsScript.PROTOCOL_VERSION,
		"reconnect_token": reconnect_token,
		"content_manifest_schema": RuntimeContentManifestScript.SCHEMA_VERSION,
		"content_digest": RuntimeContentManifestScript.CONTENT_SHA256,
	}
	var field_mutations := {
		"player_name": "AnotherClient",
		"character_id": "tiyi",
		"character_confirmed": false,
		"protocol_version": NetConstantsScript.PROTOCOL_VERSION + 1,
		"reconnect_token": reconnect_token.to_upper(),
		"content_manifest_schema": RuntimeContentManifestScript.SCHEMA_VERSION + 1,
		"content_digest": "0".repeat(64),
	}
	var mismatch_results: Array[bool] = []
	for field_name_variant: Variant in field_mutations:
		host._remember_accepted_peer_registration_tuple(
			CLIENT_PEER_ID,
			str(exact_fields["player_name"]),
			str(exact_fields["character_id"]),
			bool(exact_fields["character_confirmed"]),
			int(exact_fields["protocol_version"]),
			str(exact_fields["reconnect_token"]),
			int(exact_fields["content_manifest_schema"]),
			str(exact_fields["content_digest"])
		)
		var mutated_fields := exact_fields.duplicate(true)
		var field_name := str(field_name_variant)
		mutated_fields[field_name] = field_mutations[field_name]
		mismatch_results.append(
			host._try_replay_relay_registration_response(
				CLIENT_PEER_ID,
				str(mutated_fields["player_name"]),
				str(mutated_fields["character_id"]),
				bool(mutated_fields["character_confirmed"]),
				int(mutated_fields["protocol_version"]),
				str(mutated_fields["reconnect_token"]),
				int(mutated_fields["content_manifest_schema"]),
				str(mutated_fields["content_digest"])
			)
		)
	host._remember_accepted_peer_registration_tuple(
		CLIENT_PEER_ID,
		str(exact_fields["player_name"]),
		str(exact_fields["character_id"]),
		bool(exact_fields["character_confirmed"]),
		int(exact_fields["protocol_version"]),
		str(exact_fields["reconnect_token"]),
		int(exact_fields["content_manifest_schema"]),
		str(exact_fields["content_digest"])
	)
	(host.get("_accepted_peer_registration_replay_deadlines") as Dictionary)[
		CLIENT_PEER_ID
	] = Time.get_ticks_msec() - 1
	var expired_replay := host._try_replay_relay_registration_response(
		CLIENT_PEER_ID,
		str(exact_fields["player_name"]),
		str(exact_fields["character_id"]),
		bool(exact_fields["character_confirmed"]),
		int(exact_fields["protocol_version"]),
		str(exact_fields["reconnect_token"]),
		int(exact_fields["content_manifest_schema"]),
		str(exact_fields["content_digest"])
	)
	_expect(
		registered
		and replayed
		and not expired_replay
		and mismatch_results == [false, false, false, false, false, false, false]
		and host.rejected_registration_replay_peers.size() == 7
		and host.get_session_membership_revision() == revision_after_first_commit
		and host.accepted_tuples.size() == 2
		and host.targeted_roster_peers == PackedInt32Array([CLIENT_PEER_ID])
		and host.roster_broadcast_count == 1,
		(
			"Relay 重放只有完整注册元组一致时才能定向补发 accepted/roster，"
			+ "不得重复成员提交或放大全房广播。"
		)
	)
	host.free()


func _test_digest_rejection_is_zero_write_for_reconnect() -> void:
	var host := HostProbe.new()
	root.add_child(host)
	host.seed_host_member()
	host.seed_suspended_reconnect_member(RECONNECT_OLD_PEER_ID, RECONNECT_TOKEN)
	host.connection_state = NetManagerStore.ConnectionState.IN_GAME
	host.loading_session_id = 9
	var member_ids_before := host.get_session_member_peer_ids()
	var wrong_digest := "0".repeat(64)
	if wrong_digest == RuntimeContentManifestScript.CONTENT_SHA256:
		wrong_digest = "1".repeat(64)
	var registered := host._handle_player_registration(
		RECONNECT_NEW_PEER_ID,
		"Reconnect",
		"weishidaier",
		true,
		NetConstantsScript.PROTOCOL_VERSION,
		RECONNECT_TOKEN,
		RuntimeContentManifestScript.SCHEMA_VERSION,
		wrong_digest
	)
	await process_frame
	_expect(
		not registered
		and host.get_session_member_peer_ids() == member_ids_before
		and host.get_reconnect_slot(RECONNECT_TOKEN) == RECONNECT_OLD_PEER_ID
		and not host.has_pending_reconnect(RECONNECT_NEW_PEER_ID)
		and not host.connected_players.has(RECONNECT_NEW_PEER_ID)
		and host.accepted_tuples.is_empty()
		and host.content_rejections.size() == 1
		and host.deferred_disconnects == PackedInt32Array([RECONNECT_NEW_PEER_ID]),
		"摘要不符必须保持零成员写入，且不得消费或迁移既有 reconnect slot。"
	)
	host.free()


func _test_malformed_digest_fields_are_rejected_and_disconnected() -> void:
	var host := HostProbe.new()
	root.add_child(host)
	host.seed_host_member()
	host.connection_state = NetManagerStore.ConnectionState.HOSTING_LAN
	var member_ids_before := host.get_session_member_peer_ids()
	var results := [
		host._handle_player_registration(
			SECOND_CLIENT_PEER_ID,
			"Uppercase",
			"weishidaier",
			true,
			NetConstantsScript.PROTOCOL_VERSION,
			"dededededededededededededededede",
			RuntimeContentManifestScript.SCHEMA_VERSION,
			RuntimeContentManifestScript.CONTENT_SHA256.to_upper()
		),
		host._handle_player_registration(
			SECOND_CLIENT_PEER_ID + 1,
			"Oversized",
			"weishidaier",
			true,
			NetConstantsScript.PROTOCOL_VERSION,
			"efefefefefefefefefefefefefefefef",
			RuntimeContentManifestScript.SCHEMA_VERSION,
			"0".repeat(65)
		),
	]
	await process_frame
	_expect(
		results == [false, false]
		and host.get_session_member_peer_ids() == member_ids_before
		and host.content_rejections.size() == 2
		and host.deferred_disconnects
		== PackedInt32Array([SECOND_CLIENT_PEER_ID, SECOND_CLIENT_PEER_ID + 1]),
		"非小写或超长摘要必须走 content_rejected 并断开，不得静默占用 transport。"
	)
	host.free()


func _test_client_requires_acceptance_and_active_roster() -> void:
	var client := _make_registering_client(CLIENT_PEER_ID)
	client.conn_mode = NetManagerStore.ConnMode.RELAY
	var accepted := client._handle_registration_accepted(
		HOST_PEER_ID,
		CLIENT_PEER_ID,
		RuntimeContentManifestScript.SCHEMA_VERSION,
		RuntimeContentManifestScript.CONTENT_SHA256
	)
	_expect(
		accepted
		and client.connection_state == NetManagerStore.ConnectionState.REGISTERING
		and int(client.get("_registration_started_msec")) > 0,
		(
			"accepted 先到但本地尚无 ACTIVE roster 时不得进入大厅，"
			+ "Relay 必须继续转发已认证元组以补回可能丢失的 roster。"
		)
	)
	_expect(
		client._apply_authoritative_start_game(NetManagerStore.GameMode.STANDARD, 7)
		and client.connection_state == NetManagerStore.ConnectionState.REGISTERING
		and not (client.get("_pending_authoritative_start_game") as Dictionary).is_empty(),
		"REGISTERING 客户端只能缓存 Host 启动状态，不得越过成员门直接加载。"
	)
	_apply_active_roster(client, CLIENT_PEER_ID)
	_expect(
		client.connection_state == NetManagerStore.ConnectionState.LOADING_GAME
		and client.loading_session_id == 7
		and client.is_session_member_active(CLIENT_PEER_ID)
		and client.connected_players.has(CLIENT_PEER_ID)
		and int(client.get("_registration_started_msec")) == 0,
		"只有 accepted 三元组与本地 ACTIVE roster 同时成立后，才能提交缓存的启动状态进入加载。"
	)
	client.free()


func _test_wrong_sender_and_fields_fail_closed() -> void:
	var client := _make_registering_client(SECOND_CLIENT_PEER_ID)
	_apply_active_roster(client, SECOND_CLIENT_PEER_ID)
	_expect(
		client.connection_state == NetManagerStore.ConnectionState.REGISTERING,
		"只有 roster、没有 accepted 时必须继续停在 REGISTERING。"
	)
	var digest := RuntimeContentManifestScript.CONTENT_SHA256
	_expect(
		not client._handle_registration_accepted(
			HOST_PEER_ID + 1,
			SECOND_CLIENT_PEER_ID,
			RuntimeContentManifestScript.SCHEMA_VERSION,
			digest
		)
		and not client._handle_registration_accepted(
			HOST_PEER_ID,
			SECOND_CLIENT_PEER_ID + 1,
			RuntimeContentManifestScript.SCHEMA_VERSION,
			digest
		)
		and not client._handle_registration_accepted(
			HOST_PEER_ID,
			SECOND_CLIENT_PEER_ID,
			RuntimeContentManifestScript.SCHEMA_VERSION + 1,
			digest
		)
		and not client._handle_registration_accepted(
			HOST_PEER_ID,
			SECOND_CLIENT_PEER_ID,
			RuntimeContentManifestScript.SCHEMA_VERSION,
			digest.to_upper()
		)
		and client.connection_state == NetManagerStore.ConnectionState.REGISTERING,
		"错误 sender、peer、schema 或非小写摘要不得提交 accepted。"
	)
	var rejection_reasons: Array[String] = []
	client.connection_failed.connect(func(reason: String) -> void: rejection_reasons.append(reason))
	_expect(
		not client._handle_content_rejected(
			HOST_PEER_ID + 1,
			RuntimeContentManifestScript.SCHEMA_VERSION,
			digest
		)
		and not client._handle_content_rejected(
			HOST_PEER_ID,
			0,
			digest.to_upper()
		)
		and client.connection_state == NetManagerStore.ConnectionState.REGISTERING,
		"错误 sender 或字段的 content_rejected 必须被忽略。"
	)
	_expect(
		client._handle_content_rejected(
			HOST_PEER_ID,
			RuntimeContentManifestScript.SCHEMA_VERSION,
			digest
		)
		and rejection_reasons.size() == 1
		and client.connection_state == NetManagerStore.ConnectionState.DISCONNECTED,
		"合法 Host 的 content_rejected 必须解释失败并完整断开。"
	)
	client.free()


func _test_local_invalid_manifest_blocks_every_transport_entry() -> void:
	var probe := InvalidManifestProbe.new()
	root.add_child(probe)
	var reasons: Array[String] = []
	probe.connection_failed.connect(func(reason: String) -> void: reasons.append(reason))
	var results := [
		probe.host_create_lan_server(29170, 2),
		probe.client_connect_lan("127.0.0.1", 29170),
		probe.host_create_relay_room("127.0.0.1", 40001, 2, "fixture", "fixture"),
		probe.client_join_relay_room("127.0.0.1", 40001, 2, "fixture", "fixture"),
	]
	_expect(
		results.all(func(result: Error) -> bool: return result == ERR_FILE_CORRUPT)
		and reasons.size() == 4
		and probe.connection_state == NetManagerStore.ConnectionState.DISCONNECTED
		and probe.net_role == NetManagerStore.NetRole.NONE
		and not probe.has_transport_fixture(),
		"本地生成清单无效时，LAN/Relay 的创建与加入都必须在分配 transport 前 fail-close。"
	)
	probe.free()


func _test_relay_admission_client_contract() -> void:
	var ticket := "ra1.e30.%s" % "a".repeat(64)
	_expect(
		NetManagerStore._is_valid_relay_admission_configuration(
			"room_01",
			ticket
		)
		and not NetManagerStore._is_valid_relay_admission_configuration(
			" room_01",
			ticket
		)
		and not NetManagerStore._is_valid_relay_admission_configuration(
			"room_01",
			"ra1.e30.invalid"
		)
		and not NetManagerStore._is_valid_relay_admission_configuration(
			"room_01",
			ticket + "."
		)
		and not NetManagerStore._is_valid_relay_admission_configuration(
			"room_01",
			"ra1.e30..%s" % "a".repeat(64)
		),
		(
			"Relay transport must reject malformed room ids, signatures, trailing "
			+ "segments, and empty envelope segments locally."
		)
	)
	var ack := {
		"v": NetManagerStore.RELAY_AUTH_SCHEMA_VERSION,
		"ok": true,
		"room_id": "room_01",
		"role": "member",
		"player_name": "Client",
		"peer_id": CLIENT_PEER_ID,
	}
	var ack_with_extra_field := ack.duplicate()
	ack_with_extra_field["unexpected"] = true
	var fractional_version_ack := ack.duplicate()
	fractional_version_ack["v"] = 1.9
	var fractional_peer_ack := ack.duplicate()
	fractional_peer_ack["peer_id"] = float(CLIENT_PEER_ID) + 0.9
	_expect(
		NetManagerStore._is_valid_relay_authentication_ack(
			ack,
			"room_01",
			&"member",
			"Client",
			CLIENT_PEER_ID
		)
		and not NetManagerStore._is_valid_relay_authentication_ack(
			ack,
			"another_room",
			&"member",
			"Client",
			CLIENT_PEER_ID
		)
		and not NetManagerStore._is_valid_relay_authentication_ack(
			ack,
			"room_01",
			&"host",
			"Client",
			CLIENT_PEER_ID
		)
		and not NetManagerStore._is_valid_relay_authentication_ack(
			ack_with_extra_field,
			"room_01",
			&"member",
			"Client",
			CLIENT_PEER_ID
		)
		and not NetManagerStore._is_valid_relay_authentication_ack(
			fractional_version_ack,
			"room_01",
			&"member",
			"Client",
			CLIENT_PEER_ID
		)
		and not NetManagerStore._is_valid_relay_authentication_ack(
			fractional_peer_ack,
			"room_01",
			&"member",
			"Client",
			CLIENT_PEER_ID
		),
		(
			"Relay auth acknowledgement must use an exact schema and bind room, "
			+ "role, player, and an integral actual peer id."
		)
	)
	var manager_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/net_manager.gd"
	)
	var lobby_source := FileAccess.get_file_as_string(LOBBY_SOURCE_PATH)
	var relay_server_source := FileAccess.get_file_as_string(
		RELAY_SERVER_SOURCE_PATH
	)
	_expect(
		manager_source.contains("auth_callback")
		and manager_source.contains("peer_authenticating")
		and manager_source.contains("send_auth")
		and manager_source.contains("complete_auth")
		and manager_source.contains('"content_manifest_schema"')
		and manager_source.contains('"content_digest"')
		and manager_source.contains("_rpc_relay_player_registration_forward")
		and relay_server_source.contains("_rpc_relay_player_registration_forward")
		and manager_source.contains("conn_mode == ConnMode.DIRECT")
		and manager_source.contains("_relay_transport_admitted = true")
		and lobby_source.contains("relay_admission_ticket"),
		(
			"Public Relay identity must use SceneMultiplayer authentication before "
			+ "the lobby transport can enter the game RPC surface; the authenticated "
			+ "registration tuple must be relayed once after ordered topology publication."
		)
	)


func _test_relay_business_state_waits_for_two_sided_authentication() -> void:
	var early_client := ClientProbe.new()
	root.add_child(early_client)
	early_client.conn_mode = NetManagerStore.ConnMode.RELAY
	early_client.net_role = NetManagerStore.NetRole.CLIENT
	early_client.connection_state = NetManagerStore.ConnectionState.CONNECTING_LAN
	early_client._begin_connection_attempt(1000, "fixture relay")
	var early_failures: Array[String] = []
	early_client.connection_failed.connect(
		func(reason: String) -> void: early_failures.append(reason)
	)
	early_client._on_connected_to_server()
	_expect(
		early_client.connection_state
		== NetManagerStore.ConnectionState.CONNECTING_LAN
		and not bool(early_client.get("_relay_transport_admitted"))
		and bool(early_client.get("_relay_auth_failure_queued"))
		and early_failures.size() == 1,
		(
			"A raw or premature connected signal must not advance Relay business "
			+ "state before local complete_auth."
		)
	)
	await process_frame
	_expect(
		early_client.connection_state
		== NetManagerStore.ConnectionState.DISCONNECTED,
		"Premature Relay admission must fail closed on the same attempt generation."
	)
	early_client.free()

	var admitted_client := ClientProbe.new()
	root.add_child(admitted_client)
	admitted_client.conn_mode = NetManagerStore.ConnMode.RELAY
	admitted_client.net_role = NetManagerStore.NetRole.CLIENT
	admitted_client.host_peer_id = HOST_PEER_ID
	admitted_client.connection_state = NetManagerStore.ConnectionState.CONNECTING_LAN
	admitted_client._begin_connection_attempt(1000, "fixture relay")
	admitted_client.set("_relay_auth_locally_completed", true)
	admitted_client.set(
		"_relay_peer",
		AuthenticatedRelayMultiplayerPeerScript.new()
	)
	admitted_client._on_connected_to_server()
	_expect(
		bool(admitted_client.get("_relay_transport_admitted"))
		and admitted_client.connection_state
		== NetManagerStore.ConnectionState.REGISTERING,
		(
			"Only connected_to_server after local complete_auth may advance Relay "
			+ "into the registration gate."
		)
	)
	admitted_client.free()


func _test_public_confirmation_waits_for_final_registration() -> void:
	var lobby_source := FileAccess.get_file_as_string(LOBBY_SOURCE_PATH)
	var registering_case := lobby_source.find("\t\tSTATE_REGISTERING:")
	var connected_case := lobby_source.find("\t\tSTATE_CONNECTED_IN_LOBBY:")
	var loading_case := lobby_source.find("\t\tSTATE_LOADING_GAME:")
	_expect(
		registering_case >= 0
		and connected_case > registering_case
		and loading_case > connected_case,
		"大厅状态机必须显式区分 REGISTERING 与 CONNECTED_IN_LOBBY。"
	)
	if registering_case < 0 or connected_case < 0 or loading_case < 0:
		return
	var registering_block := lobby_source.substr(
		registering_case,
		connected_case - registering_case
	)
	var connected_block := lobby_source.substr(connected_case, loading_case - connected_case)
	_expect(
		not registering_block.contains("_request_public_member_confirmation")
		and connected_block.contains("_request_public_member_confirmation"),
		"公网 provisional 成员不得在 accepted 前确认，只能由最终 CONNECTED 状态确认。"
	)


func _make_registering_client(peer_id: int) -> ClientProbe:
	var client := ClientProbe.new()
	client.local_peer_id = peer_id
	root.add_child(client)
	client.net_role = NetManagerStore.NetRole.CLIENT
	client.host_peer_id = HOST_PEER_ID
	client._begin_registration_handshake()
	return client


func _apply_active_roster(client: ClientProbe, local_peer_id: int) -> void:
	client._rpc_sync_player_list(
		[
			{
				"id": HOST_PEER_ID,
				"participant_incarnation": 1,
				"name": "Host",
				"character_id": "weishidaier",
				"character_confirmed": true,
				"session_state": int(NetManagerStore.SessionMemberState.ACTIVE),
			},
			{
				"id": local_peer_id,
				"participant_incarnation": 2,
				"name": "Client",
				"character_id": "weishidaier",
				"character_confirmed": true,
				"session_state": int(NetManagerStore.SessionMemberState.ACTIVE),
			},
		],
		HOST_PEER_ID,
		int(NetManagerStore.GameMode.STANDARD),
		4,
		1
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("CONTENT_DIGEST_HANDSHAKE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
