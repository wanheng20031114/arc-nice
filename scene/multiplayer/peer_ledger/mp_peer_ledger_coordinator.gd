extends Node
class_name MpPeerLedgerCoordinator

## CH6 可能先于 CH0 认证或 Player 运行时投影到达。该节点暂存尚未
## 能安全提交的完整权威结果；真正的事务语义与持久状态仍由各领域
## 提交回调拥有。

const NetConstants := preload("res://scene/multiplayer/net_constants.gd")

const PENDING_ENVELOPE_TTL_MSEC := 30_000
const MAX_PENDING_PEERS := NetConstants.MAX_PLAYERS
const MAX_PENDING_STREAMS_PER_PEER := 16
const MAX_PENDING_ENVELOPES := 64
const MAX_PENDING_BYTES := 256 * 1024
const MAX_APPLIED_STREAMS_PER_PEER := 64
const MAX_APPLIED_ENVELOPES := 256
const MAX_APPLIED_BYTES := 512 * 1024
const MAX_ENVELOPE_BYTES := 64 * 1024
const MAX_RESULT_TYPE_LENGTH := 64
const MAX_STREAM_ID_LENGTH := 64
const MAX_PAYLOAD_DEPTH := 16
const MAX_PAYLOAD_VALUES := 4096
const MAX_REVISION := 0x7FFFFFFF
const APPLIED_LOOKUP_MISS := -1

const REASON_INVALID_ENVELOPE := &"invalid_envelope"
const REASON_UNBOUND := &"unbound"
const REASON_STALE_GENERATION := &"stale_generation"
const REASON_INVALID_SESSION_INCARNATION := &"invalid_session_incarnation"
const REASON_STALE_SESSION_INCARNATION := &"stale_session_incarnation"
const REASON_UNKNOWN_HOST_PEER := &"unknown_host_peer"
const REASON_UNREGISTERED_PEER := &"unregistered_peer"
const REASON_STALE_REVISION := &"stale_revision"
const REASON_REVISION_CONFLICT := &"revision_conflict"
const REASON_CAPACITY_EXCEEDED := &"capacity_exceeded"
const REASON_COMMIT_REJECTED := &"commit_rejected"
const REASON_HOST_REMAP_FORBIDDEN := &"host_remap_forbidden"

enum RuntimeRole {
	UNBOUND,
	HOST,
	CLIENT,
}

enum EnvelopeResult {
	REJECTED_UNBOUND,
	APPLIED,
	BUFFERED,
	IDEMPOTENT,
	REJECTED_INVALID,
	REJECTED_STALE_GENERATION,
	REJECTED_INVALID_SESSION_INCARNATION,
	REJECTED_STALE_SESSION_INCARNATION,
	REJECTED_UNKNOWN_HOST_PEER,
	REJECTED_STALE_REVISION,
	REJECTED_REVISION_CONFLICT,
	REJECTED_CAPACITY,
	REJECTED_COMMIT,
}

enum AppliedReplayPolicy {
	# 稳定 request/session ID 或单调 state revision：可跨接收批次去重。
	TRACK_REVISION,
	# 协议缺少操作 ID：只在 pending/remap 认领窗口合并，已提交后由领域
	# 自身处理表现；不能把两次内容相同的合法操作误认为同一事务。
	DOMAIN_OWNED,
}

signal envelope_rejected(
	peer_id: int,
	stream_id: StringName,
	revision: int,
	reason: StringName
)
signal pending_envelope_expired(
	peer_id: int,
	stream_id: StringName,
	revision: int
)
signal authenticated_peer_claimed(
	peer_id: int,
	committed_count: int,
	rejected_count: int
)
@onready var _expiry_timer: Timer = $PendingExpiryTimer

var _bound := false
var _runtime_role := RuntimeRole.UNBOUND
var _run_generation := 0
var _session_incarnation := 0
var _session_owner_ref: WeakRef = null
var _session_owner_instance_id := 0
var _is_peer_registered := Callable()
var _is_envelope_ready := Callable()
var _commit_envelope := Callable()

# pending 采用 peer -> stream -> record 的两级索引。状态流只保留最高
# revision；带 request_id 的事务使用独立有界 stream，避免覆盖 UI 结算。
var _pending_by_peer: Dictionary = {}
var _pending_envelope_count := 0
var _pending_payload_bytes := 0
var _arrival_sequence := 0

# 已注册 peer 也保留一个有界的最近提交水位。同一可靠结果重放只返回
# IDEMPOTENT，不会重复触发领域 UI/实体终结；达到容量时按最旧记录淘汰。
var _applied_by_peer: Dictionary = {}
var _applied_envelope_count := 0
var _applied_payload_bytes := 0
var _applied_sequence := 0

var _metrics := {
	"received": 0,
	"applied": 0,
	"buffered": 0,
	"idempotent": 0,
	"rejected": 0,
	"session_rejections": 0,
	"revision_conflicts": 0,
	"capacity_rejections": 0,
	"expired": 0,
	"claimed": 0,
	"deferred": 0,
	"applied_evicted": 0,
	"remap_conflicts": 0,
}


func _ready() -> void:
	_update_expiry_timer()


## session_owner 明确谁负责绑定与解绑；session_incarnation 固定本租约唯一接受的
## Host wire 世代。三个 Callable 分别回答“peer 是否已认证”、
## “该结果依赖的运行时投影是否已就绪”和“把完整权威结果提交给领域
## owner”。就绪回调签名为 (peer_id, result_type, payload) -> bool；
## 提交回调签名为：
## (peer_id, result_type, stream_id, revision, payload) -> bool。
func bind_session(
	session_owner: Object,
	runtime_role: int,
	session_incarnation: int,
	is_peer_registered: Callable,
	is_envelope_ready: Callable,
	commit_envelope: Callable
) -> int:
	if (
		session_owner == null
		or not is_instance_valid(session_owner)
		or runtime_role not in [RuntimeRole.HOST, RuntimeRole.CLIENT]
		or session_incarnation <= 0
		or session_incarnation > NetConstants.MAX_GAME_SESSION_INCARNATION
		or not is_peer_registered.is_valid()
		or not is_envelope_ready.is_valid()
		or not commit_envelope.is_valid()
	):
		return 0
	_clear_pending_envelopes()
	_reset_metrics()
	_run_generation += 1
	_bound = true
	_runtime_role = runtime_role
	_session_incarnation = session_incarnation
	_session_owner_ref = weakref(session_owner)
	_session_owner_instance_id = session_owner.get_instance_id()
	_is_peer_registered = is_peer_registered
	_is_envelope_ready = is_envelope_ready
	_commit_envelope = commit_envelope
	_update_expiry_timer()
	return _run_generation


## 只有当前 owner 能结束租约，避免旧场景的延迟清理误伤后来绑定的新一局。
func unbind_session(session_owner: Object) -> bool:
	if not is_bound_to(session_owner):
		return false
	_release_binding()
	return true


func is_bound() -> bool:
	return (
		_bound
		and _session_owner_ref != null
		and is_instance_valid(_session_owner_ref.get_ref())
		and _is_peer_registered.is_valid()
		and _is_envelope_ready.is_valid()
		and _commit_envelope.is_valid()
	)


func is_bound_to(session_owner: Object) -> bool:
	return (
		is_bound()
		and session_owner != null
		and is_instance_valid(session_owner)
		and session_owner.get_instance_id() == _session_owner_instance_id
	)


func get_run_generation() -> int:
	return _run_generation


func get_session_incarnation() -> int:
	return _session_incarnation if is_bound() else 0


func get_pending_envelope_count() -> int:
	return _pending_envelope_count


func get_pending_peer_count() -> int:
	return _pending_by_peer.size()


func get_pending_payload_bytes() -> int:
	return _pending_payload_bytes


func get_applied_envelope_count() -> int:
	return _applied_envelope_count


static func is_accepted_result(result: int) -> bool:
	return result in [
		EnvelopeResult.APPLIED,
		EnvelopeResult.BUFFERED,
		EnvelopeResult.IDEMPOTENT,
	]


func has_pending_envelope(peer_id: int, stream_id: StringName) -> bool:
	return _get_peer_streams(peer_id).has(stream_id)


func get_pending_revision(peer_id: int, stream_id: StringName) -> int:
	var peer_streams := _get_peer_streams(peer_id)
	if not peer_streams.has(stream_id):
		return -1
	return int((peer_streams[stream_id] as Dictionary).get("revision", -1))


## RPC 接收方必须同时传入本地 generation 与 Host wire session_incarnation。
## 这样即使解析或认证流程被 deferred，上一租约/上一房间的回调也只能被明确
## 拒绝，不能落入当前局的 pending。
## peer_id 必须已经由上层 participant incarnation 解析为 canonical；本节点不再
## 根据旧 transport 猜测身份。result_type 明确领域入口，payload 保存完整参数
## 但不得再携 peer_id。
func receive_authoritative_result(
	generation: int,
	session_incarnation: int,
	peer_id: int,
	result_type: StringName,
	stream_id: StringName,
	revision: int,
	payload: Dictionary,
	now_msec: int = -1,
	applied_replay_policy: int = AppliedReplayPolicy.TRACK_REVISION
) -> int:
	if not _ensure_live_binding():
		return _reject_envelope(
			peer_id,
			stream_id,
			revision,
			REASON_UNBOUND,
			EnvelopeResult.REJECTED_UNBOUND
		)
	_metrics["received"] = int(_metrics["received"]) + 1
	if generation != _run_generation:
		return _reject_envelope(
			peer_id,
			stream_id,
			revision,
			REASON_STALE_GENERATION,
			EnvelopeResult.REJECTED_STALE_GENERATION
		)
	# generation 只隔离本地节点租约；wire 世代隔离 Host 重开房间后数字身份
	# 与结果 revision 都可能再次出现的 ABA。必须先于 pending 与领域提交校验。
	if (
		session_incarnation <= 0
		or session_incarnation > NetConstants.MAX_GAME_SESSION_INCARNATION
	):
		_metrics["session_rejections"] = int(_metrics["session_rejections"]) + 1
		return _reject_envelope(
			peer_id,
			stream_id,
			revision,
			REASON_INVALID_SESSION_INCARNATION,
			EnvelopeResult.REJECTED_INVALID_SESSION_INCARNATION
		)
	if session_incarnation != _session_incarnation:
		_metrics["session_rejections"] = int(_metrics["session_rejections"]) + 1
		return _reject_envelope(
			peer_id,
			stream_id,
			revision,
			REASON_STALE_SESSION_INCARNATION,
			EnvelopeResult.REJECTED_STALE_SESSION_INCARNATION
		)
	var payload_size := _validate_and_measure_envelope(
		peer_id,
		result_type,
		stream_id,
		revision,
		payload,
		applied_replay_policy
	)
	if payload_size < 0:
		return _reject_envelope(
			peer_id,
			stream_id,
			revision,
			REASON_INVALID_ENVELOPE,
			EnvelopeResult.REJECTED_INVALID
		)
	var resolved_now_msec := _resolve_now_msec(now_msec)
	prune_expired_pending(generation, resolved_now_msec)
	var resolved_peer_id := peer_id
	var peer_registered := bool(_is_peer_registered.call(resolved_peer_id))
	if _runtime_role == RuntimeRole.HOST and not peer_registered:
		return _reject_envelope(
			resolved_peer_id,
			stream_id,
			revision,
			REASON_UNKNOWN_HOST_PEER,
			EnvelopeResult.REJECTED_UNKNOWN_HOST_PEER
		)
	if peer_registered and _is_result_envelope_ready(
		resolved_peer_id,
		result_type,
		payload
	):
		return _commit_registered_envelope(
			resolved_peer_id,
			result_type,
			stream_id,
			revision,
			payload,
			payload_size,
			applied_replay_policy
		)
	return _buffer_pending_envelope(
		resolved_peer_id,
		result_type,
		stream_id,
		revision,
		payload,
		payload_size,
		resolved_now_msec,
		applied_replay_policy
	)


## CH0 完成 peer 登记（以及重连 ID 迁移）后调用；投影状态变化后可
## 再次调用。返回结构区分已提交、已延后与已拒绝，便于调用方将真实失败
## 汇入修复，而不会把正常等待投影误报成失败。
func claim_authenticated_peer(
	generation: int,
	peer_id: int,
	now_msec: int = -1
) -> Dictionary:
	var result := {
		"accepted": false,
		"committed": 0,
		"idempotent": 0,
		"deferred": 0,
		"rejected": 0,
	}
	if not _ensure_live_binding() or generation != _run_generation:
		return result
	prune_expired_pending(generation, _resolve_now_msec(now_msec))
	if peer_id <= 0 or not bool(_is_peer_registered.call(peer_id)):
		_reject_envelope(
			peer_id,
			&"",
			-1,
			(
				REASON_UNKNOWN_HOST_PEER
				if _runtime_role == RuntimeRole.HOST
				else REASON_UNREGISTERED_PEER
			),
			(
				EnvelopeResult.REJECTED_UNKNOWN_HOST_PEER
				if _runtime_role == RuntimeRole.HOST
				else EnvelopeResult.REJECTED_INVALID
			)
		)
		return result
	result["accepted"] = true
	var peer_streams := _get_peer_streams(peer_id)
	if peer_streams.is_empty():
		authenticated_peer_claimed.emit(peer_id, 0, 0)
		return result
	var ordered_records: Array[Dictionary] = []
	for stream_id_variant in peer_streams.keys():
		var record := (peer_streams[stream_id_variant] as Dictionary).duplicate()
		record["stream_id"] = StringName(stream_id_variant)
		ordered_records.append(record)
	ordered_records.sort_custom(_sort_records_by_arrival)
	for record in ordered_records:
		if not is_bound() or generation != _run_generation:
			break
		var stream_id := StringName(record["stream_id"])
		var live_record := _get_pending_record(peer_id, stream_id)
		if (
			live_record.is_empty()
			or int(live_record.get("sequence", -1))
			!= int(record.get("sequence", -2))
		):
			continue
		# 身份就绪不等于 Player/世界投影就绪。尚不可提交的
		# 记录保留原 TTL、容量和到达顺序，既不认领也不当作拒绝。
		if not _is_result_envelope_ready(
			peer_id,
			StringName(record["result_type"]),
			record["payload"] as Dictionary
		):
			result["deferred"] = int(result["deferred"]) + 1
			_metrics["deferred"] = int(_metrics["deferred"]) + 1
			continue
		_remove_pending_envelope(peer_id, stream_id)
		var replay_policy := int(record["applied_replay_policy"])
		if replay_policy == AppliedReplayPolicy.TRACK_REVISION:
			var applied_result := _classify_applied_envelope(
				peer_id,
				StringName(record["result_type"]),
				stream_id,
				int(record["revision"]),
				record["payload"] as Dictionary
			)
			if applied_result == EnvelopeResult.IDEMPOTENT:
				result["idempotent"] = int(result["idempotent"]) + 1
				continue
			if applied_result != APPLIED_LOOKUP_MISS:
				result["rejected"] = int(result["rejected"]) + 1
				continue
		var committed := bool(
			_commit_envelope.call(
				peer_id,
				StringName(record["result_type"]),
				stream_id,
				int(record["revision"]),
				(record["payload"] as Dictionary).duplicate(true)
			)
		)
		if committed:
			if replay_policy == AppliedReplayPolicy.TRACK_REVISION:
				_record_applied_envelope(
					peer_id,
					StringName(record["result_type"]),
					stream_id,
					int(record["revision"]),
					record["payload"] as Dictionary,
					int(record["payload_size"])
				)
			result["committed"] = int(result["committed"]) + 1
			_metrics["applied"] = int(_metrics["applied"]) + 1
			_metrics["claimed"] = int(_metrics["claimed"]) + 1
		else:
			result["rejected"] = int(result["rejected"]) + 1
			_reject_envelope(
				peer_id,
				stream_id,
				int(record["revision"]),
				REASON_COMMIT_REJECTED,
				EnvelopeResult.REJECTED_COMMIT
			)
	authenticated_peer_claimed.emit(
		peer_id,
		int(result["committed"]),
		int(result["rejected"])
	)
	_update_expiry_timer()
	return result


## CH0 已经把 RunState 的 old identity 原子迁移到 new identity 后调用。
## 这里只合并迁移 old/new 已缓存与已提交水位；未来入站必须重新由 participant
## incarnation 解析，旧 transport 不会在这里获得任何路由权限。
func remap_authenticated_peer(
	generation: int,
	old_peer_id: int,
	new_peer_id: int,
	now_msec: int = -1
) -> Dictionary:
	var result := {
		"accepted": false,
		"reason": &"",
		"resolved_peer_id": 0,
		"migrated": 0,
		"deduplicated": 0,
		"stale_discarded": 0,
		"conflicts": 0,
	}
	if not _ensure_live_binding():
		result["reason"] = &"unbound"
		return result
	if generation != _run_generation:
		result["reason"] = REASON_STALE_GENERATION
		return result
	if _runtime_role != RuntimeRole.CLIENT:
		result["reason"] = REASON_HOST_REMAP_FORBIDDEN
		return result
	if old_peer_id <= 0 or new_peer_id <= 0 or old_peer_id == new_peer_id:
		result["reason"] = REASON_INVALID_ENVELOPE
		return result
	var resolved_now_msec := _resolve_now_msec(now_msec)
	prune_expired_pending(generation, resolved_now_msec)
	var resolved_new_peer_id := new_peer_id
	if not bool(_is_peer_registered.call(resolved_new_peer_id)):
		result["reason"] = REASON_UNREGISTERED_PEER
		return result
	var old_streams := _get_peer_streams(old_peer_id)
	var new_streams := _get_peer_streams(resolved_new_peer_id)
	var merged_stream_ids: Dictionary = {}
	for stream_id_variant in old_streams.keys():
		merged_stream_ids[StringName(stream_id_variant)] = true
	for stream_id_variant in new_streams.keys():
		merged_stream_ids[StringName(stream_id_variant)] = true
	if merged_stream_ids.size() > MAX_PENDING_STREAMS_PER_PEER:
		result["reason"] = REASON_CAPACITY_EXCEEDED
		return result

	# 两个身份可能各自收到同一流的跨信道结果。合并只保留更高 revision；
	# 同 revision 相同内容去重，不同内容保留 new 侧并报告权威冲突。
	for stream_id_variant in old_streams.keys():
		var stream_id := StringName(stream_id_variant)
		var old_record := _get_pending_record(old_peer_id, stream_id)
		if old_record.is_empty():
			continue
		var new_record := _get_pending_record(resolved_new_peer_id, stream_id)
		if new_record.is_empty():
			_move_pending_envelope(
				old_peer_id,
				resolved_new_peer_id,
				stream_id
			)
			result["migrated"] = int(result["migrated"]) + 1
			continue
		var old_revision := int(old_record["revision"])
		var new_revision := int(new_record["revision"])
		if old_revision > new_revision:
			_remove_pending_envelope(resolved_new_peer_id, stream_id)
			_move_pending_envelope(
				old_peer_id,
				resolved_new_peer_id,
				stream_id
			)
			result["migrated"] = int(result["migrated"]) + 1
		elif old_revision < new_revision:
			_remove_pending_envelope(old_peer_id, stream_id)
			result["stale_discarded"] = int(result["stale_discarded"]) + 1
		elif (
			StringName(old_record["result_type"])
			== StringName(new_record["result_type"])
			and int(old_record["applied_replay_policy"])
			== int(new_record["applied_replay_policy"])
			and (old_record["payload"] as Dictionary)
			== (new_record["payload"] as Dictionary)
		):
			_remove_pending_envelope(old_peer_id, stream_id)
			result["deduplicated"] = int(result["deduplicated"]) + 1
		else:
			_remove_pending_envelope(old_peer_id, stream_id)
			result["conflicts"] = int(result["conflicts"]) + 1
			_metrics["remap_conflicts"] = int(_metrics["remap_conflicts"]) + 1
			_reject_revision_conflict(old_peer_id, stream_id, old_revision)
	_merge_applied_peer_records(old_peer_id, resolved_new_peer_id, result)
	result["accepted"] = true
	result["resolved_peer_id"] = resolved_new_peer_id
	_update_expiry_timer()
	return result


func clear_peer(generation: int, peer_id: int) -> bool:
	if not _ensure_live_binding() or generation != _run_generation or peer_id <= 0:
		return false
	_clear_identity_records({peer_id: true})
	_update_expiry_timer()
	return true


## RunState 已迁移、但 CH6 记录迁移或认领失败时，调用方会终止本次重连。
## 这里显式撤销 old/new 两侧结果记录，避免清理正确性依赖“稍后一定会
## 切场景”，也避免旧 transport 的 pending 在同局 ID 复用后被新人认领。
func abort_authenticated_peer_remap(
	generation: int,
	old_peer_id: int,
	new_peer_id: int
) -> bool:
	if (
		not _ensure_live_binding()
		or generation != _run_generation
		or old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
	):
		return false
	_clear_identity_records(
		{old_peer_id: true, new_peer_id: true}
	)
	_update_expiry_timer()
	return true


func prune_expired_pending(generation: int, now_msec: int = -1) -> int:
	if not _bound or generation != _run_generation:
		return 0
	var resolved_now_msec := _resolve_now_msec(now_msec)
	var expired_records: Array[Dictionary] = []
	for peer_id_variant in _pending_by_peer.keys():
		var peer_id := int(peer_id_variant)
		var peer_streams := _pending_by_peer[peer_id] as Dictionary
		for stream_id_variant in peer_streams.keys():
			var record := peer_streams[stream_id_variant] as Dictionary
			if int(record.get("expires_at_msec", 0)) <= resolved_now_msec:
				expired_records.append({
					"peer_id": peer_id,
					"stream_id": StringName(stream_id_variant),
					"revision": int(record.get("revision", -1)),
				})
	for record in expired_records:
		var peer_id := int(record["peer_id"])
		var stream_id := StringName(record["stream_id"])
		var revision := int(record["revision"])
		_remove_pending_envelope(peer_id, stream_id)
		_metrics["expired"] = int(_metrics["expired"]) + 1
		pending_envelope_expired.emit(peer_id, stream_id, revision)
	_update_expiry_timer()
	return expired_records.size()


func export_metrics() -> Dictionary:
	var snapshot := _metrics.duplicate()
	snapshot["bound"] = is_bound()
	snapshot["runtime_role"] = _runtime_role
	snapshot["run_generation"] = _run_generation
	snapshot["pending_peers"] = _pending_by_peer.size()
	snapshot["pending_envelopes"] = _pending_envelope_count
	snapshot["pending_payload_bytes"] = _pending_payload_bytes
	snapshot["applied_envelopes"] = _applied_envelope_count
	snapshot["applied_payload_bytes"] = _applied_payload_bytes
	return snapshot


## 就绪判定只描述运行时投影边界，不取代领域的协议校验。
## 传入深拷贝保证该纯查询不能改写 pending 中的权威信封。
func _is_result_envelope_ready(
	peer_id: int,
	result_type: StringName,
	payload: Dictionary
) -> bool:
	return bool(
		_is_envelope_ready.call(
			peer_id,
			result_type,
			payload.duplicate(true)
		)
	)


func _commit_registered_envelope(
	peer_id: int,
	result_type: StringName,
	stream_id: StringName,
	revision: int,
	payload: Dictionary,
	payload_size: int,
	applied_replay_policy: int
) -> int:
	if applied_replay_policy == AppliedReplayPolicy.TRACK_REVISION:
		var applied_result := _classify_applied_envelope(
			peer_id,
			result_type,
			stream_id,
			revision,
			payload
		)
		if applied_result != APPLIED_LOOKUP_MISS:
			return applied_result
	var pending_record := _get_pending_record(peer_id, stream_id)
	if not pending_record.is_empty():
		var pending_revision := int(pending_record["revision"])
		if revision < pending_revision:
			return _reject_envelope(
				peer_id,
				stream_id,
				revision,
				REASON_STALE_REVISION,
				EnvelopeResult.REJECTED_STALE_REVISION
			)
		if revision == pending_revision:
			if (
				StringName(pending_record["result_type"]) == result_type
				and int(pending_record["applied_replay_policy"])
				== applied_replay_policy
				and (pending_record["payload"] as Dictionary) == payload
			):
				# peer 已经完成认证但认领调用尚未执行时，重复包仍要把此前
				# 只存在于 pending 的内容提交一次，不能误报为“已经落账”。
				_remove_pending_envelope(peer_id, stream_id)
			else:
				return _reject_revision_conflict(peer_id, stream_id, revision)
		else:
			# 新快照完整覆盖同一流的旧 pending；其他流仍由认证边界统一认领。
			_remove_pending_envelope(peer_id, stream_id)
	var committed := bool(
		_commit_envelope.call(
			peer_id,
			result_type,
			stream_id,
			revision,
			payload.duplicate(true)
		)
	)
	if not committed:
		return _reject_envelope(
			peer_id,
			stream_id,
			revision,
			REASON_COMMIT_REJECTED,
			EnvelopeResult.REJECTED_COMMIT
		)
	if applied_replay_policy == AppliedReplayPolicy.TRACK_REVISION:
		_record_applied_envelope(
			peer_id,
			result_type,
			stream_id,
			revision,
			payload,
			payload_size
		)
	_metrics["applied"] = int(_metrics["applied"]) + 1
	return EnvelopeResult.APPLIED


func _buffer_pending_envelope(
	peer_id: int,
	result_type: StringName,
	stream_id: StringName,
	revision: int,
	payload: Dictionary,
	payload_size: int,
	now_msec: int,
	applied_replay_policy: int
) -> int:
	var peer_streams := _get_peer_streams(peer_id)
	var existing_record: Dictionary = {}
	if peer_streams.has(stream_id):
		existing_record = peer_streams[stream_id] as Dictionary
		var existing_revision := int(existing_record["revision"])
		if revision < existing_revision:
			return _reject_envelope(
				peer_id,
				stream_id,
				revision,
				REASON_STALE_REVISION,
				EnvelopeResult.REJECTED_STALE_REVISION
			)
		if revision == existing_revision:
			if (
				StringName(existing_record["result_type"]) == result_type
				and int(existing_record["applied_replay_policy"])
				== applied_replay_policy
				and (existing_record["payload"] as Dictionary) == payload
			):
				_metrics["idempotent"] = int(_metrics["idempotent"]) + 1
				return EnvelopeResult.IDEMPOTENT
			return _reject_revision_conflict(peer_id, stream_id, revision)
	var replacing_existing := not existing_record.is_empty()
	var previous_size := int(existing_record.get("payload_size", 0))
	if not replacing_existing:
		if peer_streams.is_empty() and _pending_by_peer.size() >= MAX_PENDING_PEERS:
			return _reject_capacity(peer_id, stream_id, revision)
		if (
			not peer_streams.is_empty()
			and peer_streams.size() >= MAX_PENDING_STREAMS_PER_PEER
		):
			return _reject_capacity(peer_id, stream_id, revision)
		if _pending_envelope_count >= MAX_PENDING_ENVELOPES:
			return _reject_capacity(peer_id, stream_id, revision)
	if _pending_payload_bytes - previous_size + payload_size > MAX_PENDING_BYTES:
		return _reject_capacity(peer_id, stream_id, revision)
	if peer_streams.is_empty():
		peer_streams = {}
		_pending_by_peer[peer_id] = peer_streams
	if not replacing_existing:
		_pending_envelope_count += 1
	_pending_payload_bytes = _pending_payload_bytes - previous_size + payload_size
	_arrival_sequence += 1
	peer_streams[stream_id] = {
		"result_type": result_type,
		"applied_replay_policy": applied_replay_policy,
		"revision": revision,
		"payload": payload.duplicate(true),
		"payload_size": payload_size,
		"expires_at_msec": now_msec + PENDING_ENVELOPE_TTL_MSEC,
		"sequence": _arrival_sequence,
	}
	_metrics["buffered"] = int(_metrics["buffered"]) + 1
	_update_expiry_timer()
	return EnvelopeResult.BUFFERED


func _classify_applied_envelope(
	peer_id: int,
	result_type: StringName,
	stream_id: StringName,
	revision: int,
	payload: Dictionary
) -> int:
	var applied_record := _get_applied_record(peer_id, stream_id)
	if applied_record.is_empty():
		return APPLIED_LOOKUP_MISS
	var applied_revision := int(applied_record["revision"])
	if revision < applied_revision:
		return _reject_envelope(
			peer_id,
			stream_id,
			revision,
			REASON_STALE_REVISION,
			EnvelopeResult.REJECTED_STALE_REVISION
		)
	if revision > applied_revision:
		return APPLIED_LOOKUP_MISS
	if (
		StringName(applied_record["result_type"]) == result_type
		and (applied_record["payload"] as Dictionary) == payload
	):
		_metrics["idempotent"] = int(_metrics["idempotent"]) + 1
		return EnvelopeResult.IDEMPOTENT
	return _reject_revision_conflict(peer_id, stream_id, revision)


func _record_applied_envelope(
	peer_id: int,
	result_type: StringName,
	stream_id: StringName,
	revision: int,
	payload: Dictionary,
	payload_size: int
) -> void:
	# 同一 stream 的更高水位原子替换旧记录；request_id 型 stream 则由
	# per-peer/global LRU 上限共同约束，避免可靠幂等表随长局无限增长。
	_remove_applied_envelope(peer_id, stream_id)
	var peer_streams := _get_applied_streams(peer_id)
	while peer_streams.size() >= MAX_APPLIED_STREAMS_PER_PEER:
		var oldest_peer_stream := _find_oldest_applied_stream_for_peer(peer_id)
		if oldest_peer_stream == &"":
			break
		_evict_applied_envelope(peer_id, oldest_peer_stream)
		peer_streams = _get_applied_streams(peer_id)
	while (
		_applied_envelope_count >= MAX_APPLIED_ENVELOPES
		or _applied_payload_bytes + payload_size > MAX_APPLIED_BYTES
	):
		var oldest := _find_oldest_applied_envelope()
		if oldest.is_empty():
			break
		_evict_applied_envelope(
			int(oldest["peer_id"]),
			StringName(oldest["stream_id"])
		)
	if _applied_payload_bytes + payload_size > MAX_APPLIED_BYTES:
		# MAX_ENVELOPE_BYTES 当前小于 applied 总预算；保留防御式边界，失败
		# 时不制造一个假记录，领域结果本身已经真实提交。
		return
	peer_streams = _get_applied_streams(peer_id)
	if peer_streams.is_empty():
		peer_streams = {}
		_applied_by_peer[peer_id] = peer_streams
	_applied_sequence += 1
	peer_streams[stream_id] = {
		"result_type": result_type,
		"revision": revision,
		"payload": payload.duplicate(true),
		"payload_size": payload_size,
		"sequence": _applied_sequence,
	}
	_applied_envelope_count += 1
	_applied_payload_bytes += payload_size


func _get_applied_record(peer_id: int, stream_id: StringName) -> Dictionary:
	var peer_streams := _get_applied_streams(peer_id)
	if not peer_streams.has(stream_id):
		return {}
	return peer_streams[stream_id] as Dictionary


func _get_applied_streams(peer_id: int) -> Dictionary:
	return _applied_by_peer.get(peer_id, {}) as Dictionary


func _remove_applied_envelope(peer_id: int, stream_id: StringName) -> void:
	var peer_streams := _get_applied_streams(peer_id)
	if not peer_streams.has(stream_id):
		return
	var record := peer_streams[stream_id] as Dictionary
	_applied_payload_bytes = maxi(
		_applied_payload_bytes - int(record.get("payload_size", 0)),
		0
	)
	_applied_envelope_count = maxi(_applied_envelope_count - 1, 0)
	peer_streams.erase(stream_id)
	if peer_streams.is_empty():
		_applied_by_peer.erase(peer_id)


func _evict_applied_envelope(peer_id: int, stream_id: StringName) -> void:
	if _get_applied_record(peer_id, stream_id).is_empty():
		return
	_remove_applied_envelope(peer_id, stream_id)
	_metrics["applied_evicted"] = int(_metrics["applied_evicted"]) + 1


func _find_oldest_applied_stream_for_peer(peer_id: int) -> StringName:
	var oldest_stream := &""
	var oldest_sequence := 0x7FFFFFFF
	for stream_id_variant in _get_applied_streams(peer_id).keys():
		var stream_id := StringName(stream_id_variant)
		var record := _get_applied_record(peer_id, stream_id)
		var sequence := int(record.get("sequence", 0))
		if sequence < oldest_sequence:
			oldest_sequence = sequence
			oldest_stream = stream_id
	return oldest_stream


func _find_oldest_applied_envelope() -> Dictionary:
	var oldest: Dictionary = {}
	var oldest_sequence := 0x7FFFFFFF
	for peer_id_variant in _applied_by_peer.keys():
		var peer_id := int(peer_id_variant)
		for stream_id_variant in _get_applied_streams(peer_id).keys():
			var stream_id := StringName(stream_id_variant)
			var record := _get_applied_record(peer_id, stream_id)
			var sequence := int(record.get("sequence", 0))
			if sequence < oldest_sequence:
				oldest_sequence = sequence
				oldest = {
					"peer_id": peer_id,
					"stream_id": stream_id,
				}
	return oldest


func _get_pending_record(peer_id: int, stream_id: StringName) -> Dictionary:
	var peer_streams := _get_peer_streams(peer_id)
	if not peer_streams.has(stream_id):
		return {}
	return peer_streams[stream_id] as Dictionary


func _remove_pending_envelope(peer_id: int, stream_id: StringName) -> void:
	var peer_streams := _get_peer_streams(peer_id)
	if not peer_streams.has(stream_id):
		return
	var record := peer_streams[stream_id] as Dictionary
	_pending_payload_bytes = maxi(
		_pending_payload_bytes - int(record.get("payload_size", 0)),
		0
	)
	_pending_envelope_count = maxi(_pending_envelope_count - 1, 0)
	peer_streams.erase(stream_id)
	if peer_streams.is_empty():
		_pending_by_peer.erase(peer_id)


func _move_pending_envelope(
	source_peer_id: int,
	target_peer_id: int,
	stream_id: StringName
) -> void:
	var source_streams := _get_peer_streams(source_peer_id)
	if not source_streams.has(stream_id):
		return
	var target_streams := _get_peer_streams(target_peer_id)
	if target_streams.is_empty():
		target_streams = {}
		_pending_by_peer[target_peer_id] = target_streams
	target_streams[stream_id] = source_streams[stream_id]
	source_streams.erase(stream_id)
	if source_streams.is_empty():
		_pending_by_peer.erase(source_peer_id)


func _merge_applied_peer_records(
	old_peer_id: int,
	new_peer_id: int,
	result: Dictionary
) -> void:
	var old_streams := _get_applied_streams(old_peer_id)
	for stream_id_variant in old_streams.keys():
		var stream_id := StringName(stream_id_variant)
		var old_record := _get_applied_record(old_peer_id, stream_id)
		if old_record.is_empty():
			continue
		var new_record := _get_applied_record(new_peer_id, stream_id)
		if new_record.is_empty():
			_move_applied_envelope(old_peer_id, new_peer_id, stream_id)
			result["migrated"] = int(result["migrated"]) + 1
			continue
		var old_revision := int(old_record["revision"])
		var new_revision := int(new_record["revision"])
		if old_revision > new_revision:
			_remove_applied_envelope(new_peer_id, stream_id)
			_move_applied_envelope(old_peer_id, new_peer_id, stream_id)
			result["migrated"] = int(result["migrated"]) + 1
		elif old_revision < new_revision:
			_remove_applied_envelope(old_peer_id, stream_id)
			result["stale_discarded"] = int(result["stale_discarded"]) + 1
		elif (
			StringName(old_record["result_type"])
			== StringName(new_record["result_type"])
			and (old_record["payload"] as Dictionary)
			== (new_record["payload"] as Dictionary)
		):
			_remove_applied_envelope(old_peer_id, stream_id)
			result["deduplicated"] = int(result["deduplicated"]) + 1
		else:
			_remove_applied_envelope(old_peer_id, stream_id)
			result["conflicts"] = int(result["conflicts"]) + 1
			_metrics["remap_conflicts"] = int(_metrics["remap_conflicts"]) + 1
			_reject_revision_conflict(old_peer_id, stream_id, old_revision)
	while _get_applied_streams(new_peer_id).size() > MAX_APPLIED_STREAMS_PER_PEER:
		var oldest_stream := _find_oldest_applied_stream_for_peer(new_peer_id)
		if oldest_stream == &"":
			break
		_evict_applied_envelope(new_peer_id, oldest_stream)


func _move_applied_envelope(
	source_peer_id: int,
	target_peer_id: int,
	stream_id: StringName
) -> void:
	var source_streams := _get_applied_streams(source_peer_id)
	if not source_streams.has(stream_id):
		return
	var target_streams := _get_applied_streams(target_peer_id)
	if target_streams.is_empty():
		target_streams = {}
		_applied_by_peer[target_peer_id] = target_streams
	target_streams[stream_id] = source_streams[stream_id]
	source_streams.erase(stream_id)
	if source_streams.is_empty():
		_applied_by_peer.erase(source_peer_id)


func _get_peer_streams(peer_id: int) -> Dictionary:
	return _pending_by_peer.get(peer_id, {}) as Dictionary


func _clear_identity_records(peer_ids: Dictionary) -> void:
	for peer_id_variant in peer_ids.keys():
		var peer_id := int(peer_id_variant)
		var pending_streams := _get_peer_streams(peer_id)
		for stream_id_variant in pending_streams.keys().duplicate():
			_remove_pending_envelope(peer_id, StringName(stream_id_variant))
		var applied_streams := _get_applied_streams(peer_id)
		for stream_id_variant in applied_streams.keys().duplicate():
			_remove_applied_envelope(peer_id, StringName(stream_id_variant))


func _validate_and_measure_envelope(
	peer_id: int,
	result_type: StringName,
	stream_id: StringName,
	revision: int,
	payload: Dictionary,
	applied_replay_policy: int
) -> int:
	if (
		peer_id <= 0
		or result_type == &""
		or String(result_type).length() > MAX_RESULT_TYPE_LENGTH
		or stream_id == &""
		or String(stream_id).length() > MAX_STREAM_ID_LENGTH
		or revision < 0
		or revision > MAX_REVISION
		or applied_replay_policy not in [
			AppliedReplayPolicy.TRACK_REVISION,
			AppliedReplayPolicy.DOMAIN_OWNED,
		]
	):
		return -1
	var value_budget := [0]
	if not _is_wire_safe_value(payload, 0, value_budget):
		return -1
	var payload_size := var_to_bytes([result_type, payload]).size()
	if payload_size <= 0 or payload_size > MAX_ENVELOPE_BYTES:
		return -1
	return payload_size


func _is_wire_safe_value(value: Variant, depth: int, value_budget: Array) -> bool:
	if depth > MAX_PAYLOAD_DEPTH:
		return false
	value_budget[0] = int(value_budget[0]) + 1
	if int(value_budget[0]) > MAX_PAYLOAD_VALUES:
		return false
	match typeof(value):
		TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return false
		TYPE_ARRAY:
			for child_value in value as Array:
				if not _is_wire_safe_value(
					child_value,
					depth + 1,
					value_budget
				):
					return false
		TYPE_DICTIONARY:
			for key_value in (value as Dictionary).keys():
				if (
					(
						typeof(key_value) in [TYPE_STRING, TYPE_STRING_NAME]
						and str(key_value) == "peer_id"
					)
					or
					not _is_wire_safe_value(key_value, depth + 1, value_budget)
					or not _is_wire_safe_value(
						(value as Dictionary)[key_value],
						depth + 1,
						value_budget
					)
				):
					return false
	return true


func _reject_revision_conflict(
	peer_id: int,
	stream_id: StringName,
	revision: int
) -> int:
	_metrics["revision_conflicts"] = int(_metrics["revision_conflicts"]) + 1
	return _reject_envelope(
		peer_id,
		stream_id,
		revision,
		REASON_REVISION_CONFLICT,
		EnvelopeResult.REJECTED_REVISION_CONFLICT
	)


func _reject_capacity(
	peer_id: int,
	stream_id: StringName,
	revision: int
) -> int:
	_metrics["capacity_rejections"] = int(_metrics["capacity_rejections"]) + 1
	return _reject_envelope(
		peer_id,
		stream_id,
		revision,
		REASON_CAPACITY_EXCEEDED,
		EnvelopeResult.REJECTED_CAPACITY
	)


func _reject_envelope(
	peer_id: int,
	stream_id: StringName,
	revision: int,
	reason: StringName,
	result_code: int
) -> int:
	_metrics["rejected"] = int(_metrics["rejected"]) + 1
	envelope_rejected.emit(peer_id, stream_id, revision, reason)
	return result_code


func _ensure_live_binding() -> bool:
	if is_bound():
		return true
	if _bound:
		_release_binding()
	return false


func _release_binding() -> void:
	_clear_pending_envelopes()
	_bound = false
	_runtime_role = RuntimeRole.UNBOUND
	_session_incarnation = 0
	_session_owner_ref = null
	_session_owner_instance_id = 0
	_is_peer_registered = Callable()
	_is_envelope_ready = Callable()
	_commit_envelope = Callable()
	_update_expiry_timer()


func _clear_pending_envelopes() -> void:
	_pending_by_peer.clear()
	_applied_by_peer.clear()
	_pending_envelope_count = 0
	_pending_payload_bytes = 0
	_arrival_sequence = 0
	_applied_envelope_count = 0
	_applied_payload_bytes = 0
	_applied_sequence = 0
	_update_expiry_timer()


func _reset_metrics() -> void:
	for key in _metrics.keys():
		_metrics[key] = 0


func _resolve_now_msec(now_msec: int) -> int:
	return Time.get_ticks_msec() if now_msec < 0 else now_msec


func _sort_records_by_arrival(left: Dictionary, right: Dictionary) -> bool:
	return int(left.get("sequence", 0)) < int(right.get("sequence", 0))


func _update_expiry_timer() -> void:
	if _expiry_timer == null:
		return
	if _bound and _pending_envelope_count > 0:
		if _expiry_timer.is_stopped():
			_expiry_timer.start()
	elif not _expiry_timer.is_stopped():
		_expiry_timer.stop()


func _on_pending_expiry_timer_timeout() -> void:
	if not _ensure_live_binding():
		return
	prune_expired_pending(_run_generation)
