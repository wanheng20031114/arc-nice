extends Node
class_name PublicRoomLeaseStore

signal lease_changed
signal release_finished(
	release_generation: int,
	success: bool,
	reason: StringName,
	detail: String
)
signal keepalive_failed(detail: String)

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const RELEASE_MAX_ATTEMPTS := 2
const RELEASE_RETRY_DELAY_SECONDS := 0.25
const MAX_PENDING_RELEASES := 1
const RELEASE_TOTAL_TIMEOUT_SECONDS := 4.75
const KEEPALIVE_RETRY_INTERVAL_SECONDS := 15.0
const KEEPALIVE_MAX_CONSECUTIVE_FAILURES := 3
const MAX_COMPLETED_RELEASE_RESULTS := 8

enum LeasePhase {
	EMPTY,
	ACQUIRING,
	LOBBY,
	LOADING,
	GAMEPLAY,
	RELEASING,
}

static var _autoload_instance: PublicRoomLeaseStore = null

@onready var _keepalive_request: HTTPRequest = $KeepaliveRequest
@onready var _release_request: HTTPRequest = $ReleaseRequest
@onready var _release_retry_timer: Timer = $ReleaseRetryTimer
@onready var _release_deadline_timer: Timer = $ReleaseDeadlineTimer

## 当前租约在认证清理完成前始终保留；场景和 NetManager 不再复制令牌。
var _active_lease: Dictionary = {}
## 队列冻结清理所需认证字段；只有 attempts 属于该快照的可变传输元数据。
var _release_queue: Array[Dictionary] = []
var _release_in_flight := false
var _keepalive_in_flight := false
var _keepalive_request_lease_generation := 0
var _release_request_generation := 0
var _keepalive_channel_quarantined := false
var _release_channel_quarantined := false
var _keepalive_channel_quarantine_generation := 0
var _release_channel_quarantine_generation := 0
var _keepalive_time_left := 0.0
var _keepalive_consecutive_failures := 0
var _next_lease_generation := 0
var _next_release_generation := 0
var _completed_release_results: Dictionary[int, Dictionary] = {}
var _completed_release_order: Array[int] = []
var _net_manager: NetManagerStore = null
var _shutdown_in_progress := false
var _public_lobby_api_base_url := ""
## 显式 fixture 模式只截断传输边界，状态机仍走生产路径。
var _transport_suspended_for_fixture := false


func _enter_tree() -> void:
	if name != &"PublicRoomLease" or get_parent() != get_tree().root:
		return
	assert(
		_autoload_instance == null or _autoload_instance == self,
		"PublicRoomLeaseStore 只允许一个项目级自动加载实例。"
	)
	_autoload_instance = self


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().auto_accept_quit = false
	_public_lobby_api_base_url = _NetConstants.get_public_lobby_api_base_url()
	assert(
		not _public_lobby_api_base_url.is_empty(),
		"PublicRoomLease 缺少公网大厅 API 地址。"
	)
	_keepalive_request.request_completed.connect(_on_keepalive_request_completed)
	_release_request.request_completed.connect(_on_release_request_completed)
	_release_retry_timer.timeout.connect(_dispatch_next_release)
	_release_deadline_timer.timeout.connect(_on_release_deadline_timeout)
	_net_manager = NetManagerStore.get_autoload_instance()
	assert(_net_manager != null, "PublicRoomLease 缺少 NetManager 自动加载实例。")
	if not _net_manager.connection_state_changed.is_connected(
		_on_connection_state_changed
	):
		_net_manager.connection_state_changed.connect(_on_connection_state_changed)


func _exit_tree() -> void:
	if (
		_net_manager != null
		and _net_manager.connection_state_changed.is_connected(
			_on_connection_state_changed
		)
	):
		_net_manager.connection_state_changed.disconnect(
			_on_connection_state_changed
		)
	if not _active_lease.is_empty():
		push_warning(
			"PublicRoomLease: 进程退出时公网房间清理尚未完成，room=%s phase=%d。"
			% [get_room_id(), get_lease_phase()]
		)
	if _autoload_instance == self:
		_autoload_instance = null


func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST or _shutdown_in_progress:
		return
	_shutdown_in_progress = true
	call_deferred("_release_before_window_shutdown")


func _process(delta: float) -> void:
	if not should_send_keepalive():
		_keepalive_time_left = 0.0
		return
	if _keepalive_in_flight:
		return
	_keepalive_time_left -= maxf(delta, 0.0)
	if _keepalive_time_left <= 0.0:
		_dispatch_keepalive()


static func get_autoload_instance() -> PublicRoomLeaseStore:
	return _autoload_instance


## preflight 发出前先持有本地 generation；服务端 capability 尚未返回时取消无需联网。
func begin_acquisition(player_name: String, action: StringName) -> int:
	var normalized_player_name := player_name.strip_edges()
	if (
		normalized_player_name.is_empty()
		or action not in [&"create", &"join", &"quick_match"]
		or not _active_lease.is_empty()
		or not _release_queue.is_empty()
	):
		return 0
	_next_lease_generation += 1
	_active_lease = {
		"lease_generation": _next_lease_generation,
		"release_generation": 0,
		"acquisition_token": "",
		"acquisition_action": action,
		"room_id": "",
		"player_name": normalized_player_name,
		"member_token": "",
		"host_token": "",
		"is_host": false,
		"phase": LeasePhase.ACQUIRING,
	}
	lease_changed.emit()
	return _next_lease_generation


## 只允许同一 ACQUIRING generation 接管服务端签发的 capability。
func bind_acquisition_capability(
	lease_generation: int,
	action: StringName,
	acquisition_token: String
) -> bool:
	var normalized_token := acquisition_token.strip_edges()
	if (
		_active_lease.is_empty()
		or get_lease_phase() != LeasePhase.ACQUIRING
		or get_lease_generation() != lease_generation
		or StringName(_active_lease.get("acquisition_action", &"")) != action
		or not get_acquisition_token().is_empty()
		or normalized_token.is_empty()
		or normalized_token.length() > 256
	):
		return false
	_active_lease["acquisition_token"] = normalized_token
	lease_changed.emit()
	return true


## 响应只能接管同一 generation 的 acquisition；RELEASING 后的迟到成功不能复活。
func adopt_room(
	room_id: String,
	player_name: String,
	member_token: String,
	host_token: String,
	is_host: bool,
	acquisition_token: String = ""
) -> bool:
	var normalized_room_id := room_id.strip_edges()
	var normalized_player_name := player_name.strip_edges()
	var normalized_member_token := member_token.strip_edges()
	var normalized_host_token := host_token.strip_edges()
	var normalized_acquisition_token := acquisition_token.strip_edges()
	if (
		normalized_room_id.is_empty()
		or normalized_player_name.is_empty()
		or normalized_member_token.is_empty()
		or (is_host and normalized_host_token.is_empty())
	):
		return false
	if not _release_queue.is_empty():
		return false
	if not _active_lease.is_empty():
		if (
			get_lease_phase() != LeasePhase.ACQUIRING
			or normalized_acquisition_token.is_empty()
			or normalized_acquisition_token != get_acquisition_token()
			or str(_active_lease.get("player_name", ""))
			!= normalized_player_name
		):
			return false
		_active_lease["room_id"] = normalized_room_id
		_active_lease["member_token"] = normalized_member_token
		_active_lease["host_token"] = normalized_host_token
		_active_lease["is_host"] = is_host
		_active_lease["phase"] = LeasePhase.LOBBY
		# 响应后释放改用精确成员身份；短期 capability 不再参与 Relay 连接时序。
		_active_lease["acquisition_token"] = ""
	else:
		# 只保留给旧 fixture/旧协议的直接接管；生产大厅总是先 begin_acquisition。
		if not normalized_acquisition_token.is_empty():
			return false
		_next_lease_generation += 1
		_active_lease = {
			"lease_generation": _next_lease_generation,
			"release_generation": 0,
			"acquisition_token": "",
			"acquisition_action": &"legacy",
			"room_id": normalized_room_id,
			"player_name": normalized_player_name,
			"member_token": normalized_member_token,
			"host_token": normalized_host_token,
			"is_host": is_host,
			"phase": LeasePhase.LOBBY,
		}
	_keepalive_time_left = _NetConstants.PUBLIC_ROOM_KEEPALIVE_INTERVAL_SECONDS
	lease_changed.emit()
	return true


func has_active_lease() -> bool:
	return not _active_lease.is_empty()


func get_room_id() -> String:
	return str(_active_lease.get("room_id", ""))


func get_acquisition_token() -> String:
	return str(_active_lease.get("acquisition_token", ""))


func get_host_token() -> String:
	return str(_active_lease.get("host_token", ""))


func get_member_token() -> String:
	return str(_active_lease.get("member_token", ""))


func get_player_name() -> String:
	return str(_active_lease.get("player_name", ""))


func get_public_lobby_api_base_url() -> String:
	return _public_lobby_api_base_url


func is_public_host() -> bool:
	return bool(_active_lease.get("is_host", false))


func get_lease_phase() -> LeasePhase:
	return int(_active_lease.get("phase", LeasePhase.EMPTY)) as LeasePhase


func get_pending_release_count() -> int:
	return _release_queue.size()


func get_current_release_generation() -> int:
	return int(_active_lease.get("release_generation", 0))


func get_lease_generation() -> int:
	return int(_active_lease.get("lease_generation", 0))


func mark_lobby_phase() -> bool:
	return _mark_phase(LeasePhase.LOBBY)


func mark_loading_phase() -> bool:
	return _mark_phase(LeasePhase.LOADING)


func mark_gameplay_phase() -> bool:
	return _mark_phase(LeasePhase.GAMEPLAY)


func _mark_phase(phase: LeasePhase) -> bool:
	if _active_lease.is_empty() or get_lease_phase() == LeasePhase.RELEASING:
		return false
	if get_lease_phase() == phase:
		return true
	_active_lease["phase"] = phase
	lease_changed.emit()
	return true


## 幂等申请：重复按钮、断线信号和失败回调共享同一个 release generation。
func request_release(reason: StringName) -> int:
	if _active_lease.is_empty():
		return 0
	var existing_generation := get_current_release_generation()
	if existing_generation > 0:
		return existing_generation
	_next_release_generation += 1
	var release_generation := _next_release_generation
	_active_lease["release_generation"] = release_generation
	_active_lease["phase"] = LeasePhase.RELEASING
	var release_snapshot := _active_lease.duplicate(true)
	release_snapshot["reason"] = reason
	release_snapshot["attempts"] = 0
	assert(
		_release_queue.size() < MAX_PENDING_RELEASES,
		"单活动租约不能产生多个并行清理快照。"
	)
	_release_queue.append(release_snapshot)
	_cancel_keepalive_request()
	lease_changed.emit()
	if (
		str(release_snapshot.get("acquisition_token", "")).is_empty()
		and str(release_snapshot.get("room_id", "")).is_empty()
	):
		# preflight 从未返回就没有服务端资源；本地立即结束，绝不拼出 /rooms//leave。
		_finish_current_release(true, "preflight 尚未签发 capability，无需远端清理。")
		return release_generation
	_release_deadline_timer.start(RELEASE_TOTAL_TIMEOUT_SECONDS)
	call_deferred("_dispatch_next_release")
	return release_generation


## 调用者只等待有限 HTTP 尝试；无论远端成功与否，本地最终都能继续退出。
func release_current_and_wait(reason: StringName) -> Dictionary:
	var release_generation := request_release(reason)
	if release_generation <= 0:
		return {
			"release_generation": 0,
			"success": true,
			"reason": reason,
			"detail": "没有活动的公网房间租约。",
		}
	while not _completed_release_results.has(release_generation):
		await release_finished
	return (_completed_release_results[release_generation] as Dictionary).duplicate(true)


func should_send_keepalive() -> bool:
	return (
		not _active_lease.is_empty()
		# 服务端只在 IN_GAME 建立 idle deadline；大厅由绝对租约与 Relay
		# 启动租约保护，提前 heartbeat 会被正确拒绝。
		and get_lease_phase() in [LeasePhase.LOADING, LeasePhase.GAMEPLAY]
		and is_public_host()
		and not get_room_id().is_empty()
		and not get_host_token().is_empty()
	)


func is_keepalive_in_flight() -> bool:
	return _keepalive_in_flight


func get_keepalive_time_left() -> float:
	return _keepalive_time_left


func _dispatch_keepalive() -> void:
	if (
		not should_send_keepalive()
		or _keepalive_in_flight
		or _keepalive_channel_quarantined
	):
		return
	_keepalive_in_flight = true
	_keepalive_request_lease_generation = int(
		_active_lease.get("lease_generation", 0)
	)
	if _transport_suspended_for_fixture:
		return
	var headers := PackedStringArray(["Content-Type: application/json"])
	var error := _keepalive_request.request(
		"%s/rooms/%s/keepalive"
		% [_public_lobby_api_base_url, get_room_id()],
		headers,
		HTTPClient.METHOD_POST,
		JSON.stringify({"host_token": get_host_token()})
	)
	if error == OK:
		return
	_keepalive_in_flight = false
	_quarantine_keepalive_channel()
	_keepalive_time_left = KEEPALIVE_RETRY_INTERVAL_SECONDS
	_keepalive_consecutive_failures += 1
	var detail := "续租请求启动失败: %s" % error_string(error)
	_report_keepalive_failure(detail)
	if _keepalive_consecutive_failures >= KEEPALIVE_MAX_CONSECUTIVE_FAILURES:
		_begin_terminal_lease_loss(&"keepalive_transport_failed", detail)


func _on_keepalive_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	# HTTPRequest 的内部完成函数是 deferred；它会先 cancel_request 再发信号。
	# 本轮消息队列排空前禁止复用节点，避免重复旧回调先取消下一次请求。
	_quarantine_keepalive_channel()
	if (
		not _keepalive_in_flight
		or _active_lease.is_empty()
		or int(_active_lease.get("lease_generation", 0))
		!= _keepalive_request_lease_generation
	):
		return
	_keepalive_in_flight = false
	if not should_send_keepalive():
		_keepalive_time_left = 0.0
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_keepalive_time_left = KEEPALIVE_RETRY_INTERVAL_SECONDS
		var detail := "续租失败 result=%d status=%d body=%s" % [
			result,
			response_code,
			body.get_string_from_utf8().left(160),
		]
		_keepalive_consecutive_failures += 1
		_report_keepalive_failure(detail)
		if (
			response_code in [403, 404, 409, 410]
			or _keepalive_consecutive_failures
			>= KEEPALIVE_MAX_CONSECUTIVE_FAILURES
		):
			_begin_terminal_lease_loss(&"keepalive_rejected", detail)
		return
	_keepalive_consecutive_failures = 0
	_keepalive_time_left = _NetConstants.PUBLIC_ROOM_KEEPALIVE_INTERVAL_SECONDS
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var response := parsed as Dictionary
	if response != null and response.has("relay_running") and not bool(response["relay_running"]):
		var detail := "续租成功，但云端 Relay 已不在运行。"
		_report_keepalive_failure(detail)
		_begin_terminal_lease_loss(&"relay_not_running", detail)


func _report_keepalive_failure(detail: String) -> void:
	push_warning("PublicRoomLease: %s" % detail)
	keepalive_failed.emit(detail)


func _begin_terminal_lease_loss(reason: StringName, detail: String) -> void:
	if not has_active_lease() or get_lease_phase() == LeasePhase.RELEASING:
		return
	push_warning(
		"PublicRoomLease: 公网租约已不可继续，开始有界退出，reason=%s detail=%s"
		% [reason, detail]
	)
	call_deferred("_release_after_terminal_lease_loss", reason)


func _release_after_terminal_lease_loss(reason: StringName) -> void:
	await release_current_and_wait(reason)
	if _net_manager != null and _net_manager.is_multiplayer_active():
		_net_manager.disconnect_from_game()


func _dispatch_next_release() -> void:
	if (
		_release_in_flight
		or _release_queue.is_empty()
		or _release_channel_quarantined
	):
		return
	var snapshot := _release_queue.front() as Dictionary
	snapshot["attempts"] = int(snapshot.get("attempts", 0)) + 1
	_release_in_flight = true
	_release_request_generation = int(snapshot.get("release_generation", 0))
	if _transport_suspended_for_fixture:
		return
	var acquisition_token := str(snapshot.get("acquisition_token", ""))
	var room_id := str(snapshot.get("room_id", ""))
	var member_token := str(snapshot.get("member_token", ""))
	var method := HTTPClient.METHOD_POST
	var path := ""
	var body := {
		"player_name": str(snapshot["player_name"]),
		"member_token": member_token,
	}
	# 响应前 room_id 未知，只能用 capability 全局取消迟到提交。
	if room_id.is_empty() and not acquisition_token.is_empty():
		path = "/acquisitions/release"
		body = {"acquisition_token": acquisition_token}
	elif not room_id.is_empty() and not member_token.is_empty():
		path = "/rooms/%s/leave" % room_id
	else:
		_finish_current_release(false, "公网房间清理身份不完整。")
		return
	var error := _release_request.request(
		_public_lobby_api_base_url + path,
		PackedStringArray(["Content-Type: application/json"]),
		method,
		JSON.stringify(body)
	)
	if error == OK:
		return
	_release_in_flight = false
	_quarantine_release_channel()
	_handle_release_attempt_failure(0, "请求启动失败: %s" % error_string(error), true)


func _on_release_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	_quarantine_release_channel()
	if (
		not _release_in_flight
		or _release_queue.is_empty()
		or int((_release_queue.front() as Dictionary).get("release_generation", 0))
		!= _release_request_generation
	):
		return
	_release_in_flight = false
	_release_request_generation = 0
	if result == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300:
		_finish_current_release(true, "公网房间身份已释放。")
		return
	# 房间已不存在与“释放完成”等价；退出重放必须保持幂等。
	if result == HTTPRequest.RESULT_SUCCESS and response_code in [404, 410]:
		_finish_current_release(true, "公网房间已不存在，无需重复释放。")
		return
	var detail := "释放失败 result=%d status=%d body=%s" % [
		result,
		response_code,
		body.get_string_from_utf8().left(160),
	]
	var retryable := (
		result != HTTPRequest.RESULT_SUCCESS
		or response_code == 0
		or response_code == 408
		or response_code == 429
		or response_code >= 500
	)
	_handle_release_attempt_failure(response_code, detail, retryable)


func _handle_release_attempt_failure(
	_response_code: int,
	detail: String,
	retryable: bool
) -> void:
	var snapshot := _release_queue.front() as Dictionary
	if retryable and int(snapshot.get("attempts", 0)) < RELEASE_MAX_ATTEMPTS:
		push_warning("PublicRoomLease: %s；将在短暂退避后重试。" % detail)
		_release_retry_timer.start(RELEASE_RETRY_DELAY_SECONDS)
		return
	_finish_current_release(false, detail)


func _finish_current_release(success: bool, detail: String) -> void:
	if _release_queue.is_empty():
		return
	var snapshot := _release_queue.pop_front() as Dictionary
	var release_generation := int(snapshot["release_generation"])
	var reason := StringName(snapshot.get("reason", &"unspecified"))
	if (
		not _active_lease.is_empty()
		and int(_active_lease.get("lease_generation", 0))
		== int(snapshot.get("lease_generation", -1))
	):
		_active_lease.clear()
	_keepalive_time_left = 0.0
	_keepalive_in_flight = false
	_keepalive_request_lease_generation = 0
	_keepalive_consecutive_failures = 0
	_release_in_flight = false
	_release_request_generation = 0
	_release_retry_timer.stop()
	_release_deadline_timer.stop()
	var result := {
		"release_generation": release_generation,
		"success": success,
		"reason": reason,
		"detail": detail,
	}
	_completed_release_results[release_generation] = result
	_completed_release_order.append(release_generation)
	while _completed_release_order.size() > MAX_COMPLETED_RELEASE_RESULTS:
		_completed_release_results.erase(_completed_release_order.pop_front())
	if not success:
		push_warning(
			"PublicRoomLease: 有界清理结束但远端未确认，reason=%s detail=%s"
			% [reason, detail]
		)
	lease_changed.emit()
	release_finished.emit(release_generation, success, reason, detail)
	call_deferred("_dispatch_next_release")


func _on_release_deadline_timeout() -> void:
	if _release_queue.is_empty():
		return
	if _release_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_release_request.cancel_request()
	_release_in_flight = false
	_release_request_generation = 0
	_quarantine_release_channel()
	_release_retry_timer.stop()
	_finish_current_release(false, "公网房间清理超过 4.75 秒总时限。")


func _cancel_keepalive_request() -> void:
	if (
		_keepalive_request != null
		and _keepalive_request.get_http_client_status()
		!= HTTPClient.STATUS_DISCONNECTED
	):
		_keepalive_request.cancel_request()
	_keepalive_in_flight = false
	_keepalive_request_lease_generation = 0
	_keepalive_time_left = 0.0
	_quarantine_keepalive_channel()


## cancel_request 不会撤销已经排队的 _request_done；用 generation 合并连续隔离。
func _quarantine_keepalive_channel() -> void:
	_keepalive_channel_quarantine_generation += 1
	_keepalive_channel_quarantined = true
	_finish_keepalive_channel_quarantine.call_deferred(
		_keepalive_channel_quarantine_generation
	)


func _finish_keepalive_channel_quarantine(generation: int) -> void:
	if generation != _keepalive_channel_quarantine_generation:
		return
	_keepalive_channel_quarantined = false


func _quarantine_release_channel() -> void:
	_release_channel_quarantine_generation += 1
	_release_channel_quarantined = true
	_finish_release_channel_quarantine.call_deferred(
		_release_channel_quarantine_generation
	)


func _finish_release_channel_quarantine(generation: int) -> void:
	if generation != _release_channel_quarantine_generation:
		return
	_release_channel_quarantined = false
	_dispatch_next_release()


func _on_connection_state_changed(
	new_state: NetManagerStore.ConnectionState
) -> void:
	match new_state:
		NetManagerStore.ConnectionState.CONNECTING_LAN, \
		NetManagerStore.ConnectionState.HOSTING_LAN, \
		NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY:
			mark_lobby_phase()
		NetManagerStore.ConnectionState.LOADING_GAME:
			mark_loading_phase()
		NetManagerStore.ConnectionState.IN_GAME:
			mark_gameplay_phase()
		NetManagerStore.ConnectionState.DISCONNECTED:
			if has_active_lease() and get_lease_phase() != LeasePhase.RELEASING:
				request_release(&"transport_disconnected")


func _release_before_window_shutdown() -> void:
	await release_current_and_wait(&"window_close")
	if _net_manager != null and _net_manager.is_multiplayer_active():
		_net_manager.disconnect_from_game()
	get_tree().quit()


## 以下 fixture API 只允许调试构建驱动真实状态机，不提供给生产 UI。
func suspend_transport_for_fixture(enabled: bool) -> bool:
	if not OS.is_debug_build():
		return false
	_transport_suspended_for_fixture = enabled
	return true


func complete_release_attempt_for_fixture(
	result: int,
	response_code: int,
	body_text: String = ""
) -> bool:
	if not OS.is_debug_build() or not _transport_suspended_for_fixture:
		return false
	_on_release_request_completed(
		result,
		response_code,
		PackedStringArray(),
		body_text.to_utf8_buffer()
	)
	return true


func expire_release_deadline_for_fixture() -> bool:
	if not OS.is_debug_build() or not _transport_suspended_for_fixture:
		return false
	_on_release_deadline_timeout()
	return true


func dispatch_keepalive_for_fixture() -> bool:
	if not OS.is_debug_build() or not _transport_suspended_for_fixture:
		return false
	_keepalive_time_left = 0.0
	_dispatch_keepalive()
	return _keepalive_in_flight


func complete_keepalive_for_fixture(
	result: int,
	response_code: int,
	body_text: String = ""
) -> bool:
	if not OS.is_debug_build() or not _transport_suspended_for_fixture:
		return false
	_on_keepalive_request_completed(
		result,
		response_code,
		PackedStringArray(),
		body_text.to_utf8_buffer()
	)
	return true
