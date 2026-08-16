extends SceneTree

var failures: Array[String] = []
var lease: PublicRoomLeaseStore = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	lease = root.get_node_or_null("PublicRoomLease") as PublicRoomLeaseStore
	_expect(lease != null, "PublicRoomLease 自动加载必须存在。")
	if lease == null:
		_finish()
		return
	_expect(
		lease.get_node_or_null("KeepaliveRequest") is HTTPRequest
		and lease.get_node_or_null("ReleaseRequest") is HTTPRequest
		and lease.get_node("KeepaliveRequest") != lease.get_node("ReleaseRequest"),
		"保活和清理必须使用两个独立的静态 HTTPRequest。"
	)
	_expect(
		not auto_accept_quit,
		"窗口关闭必须先由跨场景租约节点接管有界清理。"
	)
	_expect(lease.suspend_transport_for_fixture(true), "调试构建必须允许截断测试传输边界。")
	await _test_acquisition_before_response_and_late_success_cas()
	await _test_preflight_binds_capability_before_actual_command()
	await _test_host_lease_retry_and_phase_lifecycle()
	await _test_terminal_release_failure_is_bounded()
	await _test_remote_gone_and_terminal_keepalive_converge()
	await _test_late_lobby_success_cannot_pollute_new_generation()
	await _test_pending_lobby_command_does_not_swallow_release()
	_test_unique_source_contract()
	lease.suspend_transport_for_fixture(false)
	_finish()


func _test_acquisition_before_response_and_late_success_cas() -> void:
	var lease_generation := lease.begin_acquisition(" Client ", &"join")
	_expect(
		lease_generation > 0
		and lease.get_acquisition_token().is_empty()
		and lease.get_room_id().is_empty()
		and lease.get_lease_phase() == PublicRoomLeaseStore.LeasePhase.ACQUIRING,
		"preflight 发出前必须先持有本地 ACQUIRING generation。"
	)
	var first_generation := lease.request_release(&"fixture_acquiring_back")
	_expect(
		first_generation > 0
		and not lease.has_active_lease()
		and lease.get_pending_release_count() == 0
		and not bool(lease.get("_release_in_flight")),
		"preflight 尚未返回时必须本地立即清理，不能请求 /rooms//leave。"
	)
	_expect(
		not lease.bind_acquisition_capability(
			lease_generation,
			&"join",
			"late-signed-capability"
		)
		and not lease.adopt_room(
			"late-room",
			"Client",
			"late-member",
			"",
			false,
			"late-signed-capability"
		),
		"RELEASING 后到达的创建/加入成功不得复活旧租约。"
	)
	lease.complete_release_attempt_for_fixture(
		HTTPRequest.RESULT_SUCCESS,
		503,
		'{"detail":"stale"}'
	)
	_expect(
		not lease.has_active_lease() and lease.get_pending_release_count() == 0,
		"release 的重复迟到回调必须被 in-flight/generation 门拒绝。"
	)

	var adopted_generation := lease.begin_acquisition("Client", &"join")
	var adopted_capability := "server-signed-capability"
	_expect(
		adopted_generation > lease_generation
		and lease.bind_acquisition_capability(
			adopted_generation,
			&"join",
			adopted_capability
		)
		and lease.adopt_room(
			"room-acquired",
			"Client",
			"separate-member-token",
			"",
			false,
			adopted_capability
		)
		and lease.get_acquisition_token().is_empty()
		and lease.get_member_token() == "separate-member-token"
		and lease.get_lease_phase() == PublicRoomLeaseStore.LeasePhase.LOBBY,
		"只有同 generation/capability 的响应能接管，成员身份必须独立保存。"
	)
	lease.request_release(&"fixture_acquisition_adopted")
	var adopted_release_queue := lease.get("_release_queue") as Array[Dictionary]
	_expect(
		adopted_release_queue.size() == 1
		and str(adopted_release_queue[0].get("acquisition_token", "")).is_empty()
		and str(adopted_release_queue[0].get("room_id", "")) == "room-acquired"
		and str(adopted_release_queue[0].get("member_token", ""))
		== "separate-member-token",
		"响应接管后清理必须冻结 room/member 身份，不能继续依赖短期 capability。"
	)
	await process_frame
	lease.complete_release_attempt_for_fixture(HTTPRequest.RESULT_SUCCESS, 204)


func _test_host_lease_retry_and_phase_lifecycle() -> void:
	_expect(
		lease.adopt_room(" room-a ", " Host ", " member-a ", " host-a ", true),
		"完整创建响应必须能移交房主租约。"
	)
	_expect(
		lease.get_room_id() == "room-a"
		and lease.get_host_token() == "host-a"
		and lease.is_public_host()
		and lease.get_lease_phase() == PublicRoomLeaseStore.LeasePhase.LOBBY,
		"租约必须规范化身份并从大厅阶段开始。"
	)
	_expect(
		not lease.should_send_keepalive(),
		"服务端尚未建立 idle deadline 时，大厅阶段不得发送无效续租。"
	)
	lease.mark_loading_phase()
	_expect(
		lease.should_send_keepalive() and lease.dispatch_keepalive_for_fixture(),
		"服务端进入游戏后，加载阶段必须由跨场景节点续租。"
	)
	lease.complete_keepalive_for_fixture(
		HTTPRequest.RESULT_SUCCESS,
		200,
		'{"relay_running":true}'
	)
	lease.complete_keepalive_for_fixture(
		HTTPRequest.RESULT_SUCCESS,
		410,
		'{"detail":"stale"}'
	)
	_expect(
		is_equal_approx(
			lease.get_keepalive_time_left(),
			60.0
		) and not lease.is_keepalive_in_flight(),
		"成功保活必须恢复 60 秒节奏并释放 in-flight。"
	)
	_expect(
		lease.mark_gameplay_phase()
		and lease.should_send_keepalive(),
		"加载与游戏阶段必须消费同一个保活租约。"
	)

	var generation := lease.request_release(&"fixture_retry")
	_expect(
		generation > 0
		and lease.request_release(&"duplicate") == generation
		and lease.get_pending_release_count() == 1
		and lease.get_lease_phase() == PublicRoomLeaseStore.LeasePhase.RELEASING,
		"重复退出来源必须合并到同一个有界清理 generation。"
	)
	await process_frame
	lease.complete_release_attempt_for_fixture(
		HTTPRequest.RESULT_SUCCESS,
		503,
		'{"detail":"busy"}'
	)
	_expect(
		lease.has_active_lease() and lease.get_pending_release_count() == 1,
		"首次可重试失败必须保留认证上下文。"
	)
	await (lease.get_node("ReleaseRetryTimer") as Timer).timeout
	await process_frame
	_expect(bool(lease.get("_release_in_flight")), "退避结束后必须发起第二次清理尝试。")
	lease.complete_release_attempt_for_fixture(
		HTTPRequest.RESULT_SUCCESS,
		204
	)
	_expect(
		not lease.has_active_lease() and lease.get_pending_release_count() == 0,
		"第二次成功必须在远端确认后清空唯一真源。"
	)


func _test_preflight_binds_capability_before_actual_command() -> void:
	var lobby_scene := load(
		"res://scene/multiplayer/multiplayer_lobby.tscn"
	) as PackedScene
	var lobby := lobby_scene.instantiate()
	root.add_child(lobby)
	await process_frame
	var acquisition_generation := lease.begin_acquisition("Host", &"create")
	var signed_capability := "server-issued-create-capability"
	lobby.set(
		"_pending_public_acquisition_command",
		{
			"lease_generation": acquisition_generation,
			"action_name": &"create",
			"request_action": 3,
			"path": "/rooms",
			"body": {"host_name": "Host"},
		}
	)
	# ACQUISITION_PREFLIGHT=9；模拟服务端签发成功而不触达真实网络。
	lobby.set("pending_public_request", 9)
	lobby.set("_public_request_in_flight", true)
	lobby.set(
		"_pending_public_request_lease_generation",
		acquisition_generation
	)
	lobby.set("_pending_public_request_acquisition_token", "")
	lobby.call(
		"_on_public_lobby_request_completed",
		HTTPRequest.RESULT_SUCCESS,
		200,
		PackedStringArray(),
		JSON.stringify(
			{"acquisition_token": signed_capability, "expires_at": 9999999999}
		).to_utf8_buffer()
	)
	var queued := lobby.get("_queued_public_request") as Dictionary
	var queued_body: Variant = JSON.parse_string(str(queued.get("body_text", "")))
	_expect(
		lease.get_acquisition_token() == signed_capability
		and int(lobby.get("pending_public_request")) == 3
		and queued_body is Dictionary
		and str((queued_body as Dictionary).get("acquisition_token", ""))
		== signed_capability,
		"preflight capability 必须先绑定同 generation，再冻结进实际命令。"
	)
	lobby.call("_cancel_pending_public_command_for_release")
	lease.request_release(&"fixture_preflight_bound_cleanup")
	await process_frame
	lease.complete_release_attempt_for_fixture(HTTPRequest.RESULT_SUCCESS, 200)
	lobby.queue_free()
	await process_frame


func _test_terminal_release_failure_is_bounded() -> void:
	_expect(
		lease.adopt_room("room-b", "Client", "member-b", "", false),
		"成员租约必须能在上一租约完成后重新取得。"
	)
	var generation := lease.request_release(&"fixture_terminal_failure")
	await process_frame
	lease.complete_release_attempt_for_fixture(
		HTTPRequest.RESULT_SUCCESS,
		403,
		'{"detail":"invalid token"}'
	)
	_expect(
		generation > 0
		and not lease.has_active_lease()
		and lease.get_pending_release_count() == 0,
		"不可重试认证失败也必须到达本地有界终点。"
	)


func _test_remote_gone_and_terminal_keepalive_converge() -> void:
	_expect(
		lease.adopt_room("room-c", "Client", "member-c", "", false),
		"404 幂等测试必须取得成员租约。"
	)
	var gone_generation := lease.request_release(&"fixture_remote_gone")
	await process_frame
	lease.complete_release_attempt_for_fixture(
		HTTPRequest.RESULT_SUCCESS,
		404,
		'{"detail":"gone"}'
	)
	var completed_results := lease.get("_completed_release_results") as Dictionary
	_expect(
		not lease.has_active_lease()
		and bool((completed_results[gone_generation] as Dictionary).get("success", false)),
		"404/410 房间已不存在必须作为幂等释放成功。"
	)

	_expect(
		lease.adopt_room("room-d", "Host", "member-d", "host-d", true)
		and lease.mark_loading_phase()
		and lease.dispatch_keepalive_for_fixture(),
		"终态保活测试必须进入加载期续租。"
	)
	lease.complete_keepalive_for_fixture(
		HTTPRequest.RESULT_SUCCESS,
		200,
		'{"relay_running":false}'
	)
	await process_frame
	await process_frame
	_expect(
		lease.get_lease_phase() == PublicRoomLeaseStore.LeasePhase.RELEASING,
		"Relay 已死亡必须从告警收敛为有界退出。"
	)
	lease.complete_release_attempt_for_fixture(
		HTTPRequest.RESULT_SUCCESS,
		410,
		'{"detail":"expired"}'
	)
	await process_frame
	_expect(not lease.has_active_lease(), "终态保活失败必须最终清理本地租约。")

	_expect(
		lease.adopt_room("room-e", "Client", "member-e", "", false),
		"总时限测试必须取得成员租约。"
	)
	lease.request_release(&"fixture_total_deadline")
	await process_frame
	lease.expire_release_deadline_for_fixture()
	_expect(
		not lease.has_active_lease() and lease.get_pending_release_count() == 0,
		"即使 HTTPRequest 不回调，总时限也必须终结本地退出。"
	)


func _test_pending_lobby_command_does_not_swallow_release() -> void:
	var lobby_scene := load(
		"res://scene/multiplayer/multiplayer_lobby.tscn"
	) as PackedScene
	var lobby := lobby_scene.instantiate()
	root.add_child(lobby)
	await process_frame
	_expect(
		lease.adopt_room("room-f", "Host", "member-f", "host-f", true),
		"并发清理测试必须取得房主租约。"
	)
	# UPDATE_ROOM=8；模拟开局状态请求仍占用大厅普通传输。
	lobby.set("pending_public_request", 8)
	lobby.set("pending_start_after_public_status", true)
	lobby.call("_cancel_pending_public_command_for_release")
	_expect(
		int(lobby.get("pending_public_request")) == 0
		and not bool(lobby.get("pending_start_after_public_status"))
		and lease.has_active_lease(),
		"取消普通命令只能撤销其副作用，不能吞掉独立公网租约。"
	)
	lease.request_release(&"fixture_pending_command")
	await process_frame
	lease.complete_release_attempt_for_fixture(
		HTTPRequest.RESULT_SUCCESS,
		204
	)
	_expect(not lease.has_active_lease(), "普通请求在途时清理仍必须独立完成。")
	lobby.queue_free()
	await process_frame


func _test_late_lobby_success_cannot_pollute_new_generation() -> void:
	var lobby_scene := load(
		"res://scene/multiplayer/multiplayer_lobby.tscn"
	) as PackedScene
	var lobby := lobby_scene.instantiate()
	root.add_child(lobby)
	await process_frame
	var old_generation := lease.begin_acquisition("Host", &"create")
	var old_token := "old-server-capability"
	_expect(
		lease.bind_acquisition_capability(old_generation, &"create", old_token),
		"旧 generation 必须先绑定服务端 capability。"
	)
	lease.request_release(&"fixture_old_generation")
	await process_frame
	lease.complete_release_attempt_for_fixture(HTTPRequest.RESULT_SUCCESS, 200)
	var new_generation := lease.begin_acquisition("Host", &"create")
	# CREATE_ROOM=3；模拟旧 HTTPRequest 的成功信号晚于下一 generation 到达。
	lobby.set("pending_public_request", 3)
	lobby.set("_public_request_in_flight", true)
	lobby.set("_pending_public_request_lease_generation", old_generation)
	lobby.set("_pending_public_request_acquisition_token", old_token)
	lobby.call(
		"_on_public_lobby_request_completed",
		HTTPRequest.RESULT_SUCCESS,
		200,
		PackedStringArray(),
		JSON.stringify(
			{
				"room_id": "late-room",
				"relay_ip": "127.0.0.1",
				"relay_port": 40001,
				"member_token": "late-member-token",
				"host_token": "late-host",
				"acquisition_token": old_token,
			}
		).to_utf8_buffer()
	)
	_expect(
		lease.get_lease_generation() == new_generation
		and lease.get_acquisition_token().is_empty()
		and lease.get_room_id().is_empty()
		and lease.get_lease_phase() == PublicRoomLeaseStore.LeasePhase.ACQUIRING,
		"旧 HTTP 成功回调不得接管或终结下一 generation 的 acquisition。"
	)
	lease.request_release(&"fixture_new_generation_cleanup")
	lobby.queue_free()
	await process_frame


func _test_unique_source_contract() -> void:
	var lease_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/public_room/public_room_lease.gd"
	)
	var constants_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/net_constants.gd"
	)
	var net_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/net_manager.gd"
	)
	var lobby_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/multiplayer_lobby.gd"
	)
	var session_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/session/mp_session_coordinator.gd"
	)
	var mp_game_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_game.gd"
	)
	var rogue_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_rogue_route.gd"
	)
	var loading_source := FileAccess.get_file_as_string(
		"res://scene/loading/game_load_coordinator.gd"
	)
	_expect(
		not net_source.contains("var public_room_id")
		and not net_source.contains("var public_host_token")
		and not lobby_source.contains("var current_public_member_token")
		and not lobby_source.contains("var current_public_host_token"),
		"NetManager 和大厅不得再复制公网认证身份。"
	)
	_expect(
		constants_source.contains("TEST_SERVER_PUBLIC_LOBBY_API_BASE_URL")
		and constants_source.contains("ARC_PUBLIC_LOBBY_API_BASE_URL")
		and constants_source.contains("func get_public_lobby_api_base_url")
		and lease_source.contains("_NetConstants.get_public_lobby_api_base_url()")
		and lobby_source.contains(
			"public_room_lease.get_public_lobby_api_base_url()"
		),
		"测试服 HTTP 地址必须只有一个可覆盖配置读取口，lease 与大厅不得各自硬编码。"
	)
	_expect(
		not session_source.contains("/keepalive")
		and not FileAccess.get_file_as_string(
			"res://scene/multiplayer/mp_game.tscn"
		).contains("PublicRoomKeepaliveRequest"),
		"场景内保活实现必须完全移交给跨场景租约节点。"
	)
	_expect(
		lease_source.contains("_keepalive_channel_quarantined")
		and lease_source.contains("_release_channel_quarantined")
		and lease_source.contains("_keepalive_request_lease_generation")
		and lease_source.contains("_release_request_generation"),
		"保活与释放通道必须同时用 generation 和 deferred 排空门拒绝旧回调。"
	)
	_expect(
		lobby_source.contains("_cancel_pending_public_command_for_release")
		and lobby_source.contains("public_room_lease.release_current_and_wait")
		and lobby_source.contains('"/acquisitions/preflight"')
		and lobby_source.contains("bind_acquisition_capability")
		and lobby_source.contains('body["acquisition_token"] = acquisition_token')
		and lobby_source.contains("_public_request_channel_quarantined")
		and lobby_source.contains("_public_request_in_flight")
		and lobby_source.contains("_request_public_member_confirmation()")
		and lobby_source.contains("STATE_CONNECTED_IN_LOBBY:"),
		"大厅退出必须取消普通命令，排空旧 HTTP 回调后走独立租约清理通道。"
	)
	_expect(
		lease_source.contains("preflight 尚未签发 capability，无需远端清理")
		and lease_source.contains("get_member_token")
		and lobby_source.contains('"member_token": member_token')
		and lobby_source.contains('"room_id": room_id')
		and lobby_source.contains('"player_name": player_name'),
		"tokenless preflight 取消必须本地完成；Relay 后确认必须使用独立成员三元组。"
	)
	var client_begin_start := lobby_source.find("func _begin_public_client_room")
	var client_begin_end := lobby_source.find(
		"func _request_public_member_confirmation",
		client_begin_start
	)
	var client_begin_source := lobby_source.substr(
		client_begin_start,
		client_begin_end - client_begin_start
	)
	_expect(
		client_begin_start >= 0
		and client_begin_end > client_begin_start
		and client_begin_source.contains("client_join_relay_room")
		and not client_begin_source.contains("PublicRequest.CONFIRM_ACQUISITION"),
		"成员必须先连接 Relay，再由 CONNECTED_IN_LOBBY 确认 provisional 身份。"
	)
	_expect(
		mp_game_source.contains(
			"await public_room_lease.release_current_and_wait(&\"mp_game_return_to_lobby\")"
		)
		and rogue_source.contains(
			"await public_room_lease.release_current_and_wait(&\"rogue_return_to_lobby\")"
		)
		and loading_source.contains(
			"await _public_room_lease.release_current_and_wait(&\"multiplayer_load_failed\")"
		),
		"Standard/Tower、P3 与多人加载失败必须共享清理门。"
	)
	_expect(
		loading_source.contains("if _back_navigation_in_progress:")
		and mp_game_source.contains(
			"if embedded_runtime:\n\t\t# 内嵌战斗不拥有 SceneTree"
		),
		"加载返回必须去重；内嵌 MpGame 失败不得与外层争抢 change_scene。"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PUBLIC_ROOM_LEASE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
