extends Node
class_name GlobalRuntimePolicyLeaseStore

## 场景树全局运行策略的唯一租约协调器。
##
## SceneTree.physics_interpolation 属于整个场景树，不能由各玩法场景分别保存和
## 恢复快照。协调器只在首个 owner 加入时捕获一次基线，并在最后一个 owner
## 离开时恢复；owner 离树会自动释放，显式重复释放则是无副作用的失败。

signal physics_interpolation_owner_count_changed(
	owner_count: int,
	effective_enabled: bool
)
signal physics_interpolation_conflict_detected(
	owner_instance_id: int,
	requested_enabled: bool,
	active_enabled: bool,
	reason: StringName
)

const INVALID_LEASE_TOKEN := 0

static var _autoload_instance: GlobalRuntimePolicyLeaseStore = null


class PhysicsInterpolationLease:
	extends RefCounted

	var token := INVALID_LEASE_TOKEN
	var owner_instance_id := 0
	var owner_ref: WeakRef = null
	var requested_enabled := false
	var owner_exit_callback: Callable = Callable()


var _next_lease_token := 1
var _physics_interpolation_leases: Dictionary[int, PhysicsInterpolationLease] = {}
var _physics_interpolation_token_by_owner_id: Dictionary[int, int] = {}
var _physics_interpolation_baseline_captured := false
var _physics_interpolation_baseline_enabled := false
var _physics_interpolation_active_enabled := false
var _physics_interpolation_conflict_count := 0


func _enter_tree() -> void:
	if name != &"GlobalRuntimePolicyLease" or get_parent() != get_tree().root:
		return
	assert(
		_autoload_instance == null or _autoload_instance == self,
		"GlobalRuntimePolicyLeaseStore 只允许一个项目级自动加载实例。"
	)
	_autoload_instance = self


func _ready() -> void:
	set_process(not _physics_interpolation_leases.is_empty())


func _process(_delta: float) -> void:
	if _physics_interpolation_leases.is_empty():
		set_process(false)
		return
	# 活动租约持续拥有该全局值；绕过协调器的写入会在下一帧被诊断并修复。
	_repair_external_physics_interpolation_drift()


func _exit_tree() -> void:
	_shutdown_physics_interpolation_leases()
	if _autoload_instance == self:
		_autoload_instance = null


static func get_autoload_instance() -> GlobalRuntimePolicyLeaseStore:
	return _autoload_instance


## 获取物理插值租约。同一 owner 重复请求同一值会返回原 token；活动 owner
## 请求相反值会被明确拒绝并计入冲突，不允许两个局部快照争夺全局状态。
func acquire_physics_interpolation(
	owner: Node,
	requested_enabled: bool
) -> int:
	if (
		owner == null
		or not is_instance_valid(owner)
		or not owner.is_inside_tree()
		or owner.get_tree() != get_tree()
	):
		push_error("GlobalRuntimePolicyLeaseStore: owner 必须位于当前 SceneTree。")
		return INVALID_LEASE_TOKEN

	var owner_instance_id := int(owner.get_instance_id())
	var existing_token := int(
		_physics_interpolation_token_by_owner_id.get(
			owner_instance_id,
			INVALID_LEASE_TOKEN
		)
	)
	if existing_token != INVALID_LEASE_TOKEN:
		var existing_lease := (
			_physics_interpolation_leases.get(existing_token)
			as PhysicsInterpolationLease
		)
		if (
			existing_lease != null
			and existing_lease.owner_ref.get_ref() == owner
			and existing_lease.requested_enabled == requested_enabled
		):
			return existing_token
		_record_physics_interpolation_conflict(
			owner_instance_id,
			requested_enabled,
			&"owner_request_changed"
		)
		return INVALID_LEASE_TOKEN

	if not _physics_interpolation_leases.is_empty():
		_repair_external_physics_interpolation_drift()
		if requested_enabled != _physics_interpolation_active_enabled:
			_record_physics_interpolation_conflict(
				owner_instance_id,
				requested_enabled,
				&"active_owner_value_mismatch"
			)
			return INVALID_LEASE_TOKEN

	var is_first_owner := _physics_interpolation_leases.is_empty()
	if is_first_owner:
		_physics_interpolation_baseline_enabled = (
			get_tree().is_physics_interpolation_enabled()
		)
		_physics_interpolation_baseline_captured = true
		_physics_interpolation_active_enabled = requested_enabled

	var token := _next_lease_token
	_next_lease_token += 1
	var lease := PhysicsInterpolationLease.new()
	lease.token = token
	lease.owner_instance_id = owner_instance_id
	lease.owner_ref = weakref(owner)
	lease.requested_enabled = requested_enabled
	lease.owner_exit_callback = _on_physics_interpolation_owner_tree_exiting.bind(
		token
	)
	var connect_error := owner.tree_exiting.connect(
		lease.owner_exit_callback,
		CONNECT_ONE_SHOT
	)
	if connect_error != OK:
		if is_first_owner:
			_clear_physics_interpolation_baseline()
		push_error(
			"GlobalRuntimePolicyLeaseStore: 无法绑定 owner 离树清理，错误码 %d。"
			% connect_error
		)
		return INVALID_LEASE_TOKEN

	_physics_interpolation_leases[token] = lease
	_physics_interpolation_token_by_owner_id[owner_instance_id] = token
	get_tree().set_physics_interpolation_enabled(
		_physics_interpolation_active_enabled
	)
	set_process(true)
	_emit_physics_interpolation_owner_count_changed()
	return token


## 释放指定 token。任意 owner 都可先退出；只有最后一个 token 消失时才恢复
## 首 owner 捕获的基线。重复或过期 token 返回 false，且不会触碰全局状态。
func release_physics_interpolation(token: int) -> bool:
	return _release_physics_interpolation(token, true)


func get_physics_interpolation_owner_count() -> int:
	return _physics_interpolation_leases.size()


func get_physics_interpolation_conflict_count() -> int:
	return _physics_interpolation_conflict_count


func has_physics_interpolation_owner(owner: Node) -> bool:
	if owner == null or not is_instance_valid(owner):
		return false
	var owner_instance_id := int(owner.get_instance_id())
	var token := int(
		_physics_interpolation_token_by_owner_id.get(
			owner_instance_id,
			INVALID_LEASE_TOKEN
		)
	)
	if token == INVALID_LEASE_TOKEN:
		return false
	var lease := (
		_physics_interpolation_leases.get(token) as PhysicsInterpolationLease
	)
	return lease != null and lease.owner_ref.get_ref() == owner


func _on_physics_interpolation_owner_tree_exiting(token: int) -> void:
	_release_physics_interpolation(token, false)


func _release_physics_interpolation(
	token: int,
	disconnect_owner_signal: bool
) -> bool:
	var lease := (
		_physics_interpolation_leases.get(token) as PhysicsInterpolationLease
	)
	if lease == null:
		return false
	if disconnect_owner_signal:
		_disconnect_physics_interpolation_owner_signal(lease)
	_physics_interpolation_leases.erase(token)
	_physics_interpolation_token_by_owner_id.erase(lease.owner_instance_id)

	if _physics_interpolation_leases.is_empty():
		set_process(false)
		if _physics_interpolation_baseline_captured:
			get_tree().set_physics_interpolation_enabled(
				_physics_interpolation_baseline_enabled
			)
		_clear_physics_interpolation_baseline()
	else:
		_repair_external_physics_interpolation_drift()
	_emit_physics_interpolation_owner_count_changed()
	return true


func _disconnect_physics_interpolation_owner_signal(
	lease: PhysicsInterpolationLease
) -> void:
	var owner := lease.owner_ref.get_ref() as Node
	if (
		owner != null
		and is_instance_valid(owner)
		and owner.tree_exiting.is_connected(lease.owner_exit_callback)
	):
		owner.tree_exiting.disconnect(lease.owner_exit_callback)


func _repair_external_physics_interpolation_drift() -> void:
	var effective_enabled := get_tree().is_physics_interpolation_enabled()
	if effective_enabled == _physics_interpolation_active_enabled:
		return
	_record_physics_interpolation_conflict(
		0,
		_physics_interpolation_active_enabled,
		&"external_state_drift"
	)
	get_tree().set_physics_interpolation_enabled(
		_physics_interpolation_active_enabled
	)


func _record_physics_interpolation_conflict(
	owner_instance_id: int,
	requested_enabled: bool,
	reason: StringName
) -> void:
	_physics_interpolation_conflict_count += 1
	physics_interpolation_conflict_detected.emit(
		owner_instance_id,
		requested_enabled,
		_physics_interpolation_active_enabled,
		reason
	)
	push_warning(
		"GlobalRuntimePolicyLeaseStore: 物理插值租约冲突（owner=%d, 请求=%s, 活动=%s, 原因=%s）。"
		% [
			owner_instance_id,
			requested_enabled,
			_physics_interpolation_active_enabled,
			reason,
		]
	)


func _emit_physics_interpolation_owner_count_changed() -> void:
	physics_interpolation_owner_count_changed.emit(
		_physics_interpolation_leases.size(),
		get_tree().is_physics_interpolation_enabled()
	)


func _clear_physics_interpolation_baseline() -> void:
	_physics_interpolation_baseline_captured = false
	_physics_interpolation_baseline_enabled = false
	_physics_interpolation_active_enabled = false


func _shutdown_physics_interpolation_leases() -> void:
	set_process(false)
	for lease_value in _physics_interpolation_leases.values():
		var lease := lease_value as PhysicsInterpolationLease
		if lease != null:
			_disconnect_physics_interpolation_owner_signal(lease)
	if _physics_interpolation_baseline_captured:
		get_tree().set_physics_interpolation_enabled(
			_physics_interpolation_baseline_enabled
		)
	_physics_interpolation_leases.clear()
	_physics_interpolation_token_by_owner_id.clear()
	_clear_physics_interpolation_baseline()
