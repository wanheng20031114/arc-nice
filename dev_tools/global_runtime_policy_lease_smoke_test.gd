extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := (
		root.get_node_or_null("GlobalRuntimePolicyLease")
		as GlobalRuntimePolicyLeaseStore
	)
	_expect(coordinator != null, "必须装配全局运行策略租约 autoload。")
	if coordinator == null:
		_finish()
		return
	var original_interpolation := physics_interpolation
	await _test_arbitrary_release_order(coordinator)
	await _test_owner_exit_auto_release(coordinator)
	await _test_idempotency_and_conflict_observability(coordinator)
	physics_interpolation = original_interpolation
	_finish()


func _test_arbitrary_release_order(
	coordinator: GlobalRuntimePolicyLeaseStore
) -> void:
	physics_interpolation = false
	var first_owner := Node.new()
	var second_owner := Node.new()
	first_owner.name = "FirstPolicyOwner"
	second_owner.name = "SecondPolicyOwner"
	root.add_child(first_owner)
	root.add_child(second_owner)
	var first_token := coordinator.acquire_physics_interpolation(first_owner, true)
	var second_token := coordinator.acquire_physics_interpolation(second_owner, true)
	_expect(
		first_token != GlobalRuntimePolicyLeaseStore.INVALID_LEASE_TOKEN
		and second_token != GlobalRuntimePolicyLeaseStore.INVALID_LEASE_TOKEN
		and coordinator.get_physics_interpolation_owner_count() == 2
		and physics_interpolation,
		"两个同值 owner 必须共享一次全局物理插值覆盖。"
	)
	_expect(
		coordinator.release_physics_interpolation(first_token)
		and coordinator.get_physics_interpolation_owner_count() == 1
		and physics_interpolation,
		"先释放首 owner 时仍须保留第二个 owner 的活动策略。"
	)
	_expect(
		not coordinator.release_physics_interpolation(first_token)
		and coordinator.get_physics_interpolation_owner_count() == 1
		and physics_interpolation,
		"重复释放旧 token 必须无副作用。"
	)
	_expect(
		coordinator.release_physics_interpolation(second_token)
		and coordinator.get_physics_interpolation_owner_count() == 0
		and not physics_interpolation,
		"最后一个 owner 释放后必须恢复首 owner 捕获的基线。"
	)
	first_owner.queue_free()
	second_owner.queue_free()
	await process_frame


func _test_owner_exit_auto_release(
	coordinator: GlobalRuntimePolicyLeaseStore
) -> void:
	physics_interpolation = true
	var owner := Node.new()
	owner.name = "AutoReleasePolicyOwner"
	root.add_child(owner)
	var token := coordinator.acquire_physics_interpolation(owner, false)
	_expect(
		token != GlobalRuntimePolicyLeaseStore.INVALID_LEASE_TOKEN
		and not physics_interpolation
		and coordinator.has_physics_interpolation_owner(owner),
		"租约应允许显式关闭策略，并可查询 owner 身份。"
	)
	root.remove_child(owner)
	_expect(
		coordinator.get_physics_interpolation_owner_count() == 0
		and physics_interpolation,
		"owner 离树必须同步自动释放并恢复 true 基线。"
	)
	owner.free()
	await process_frame


func _test_idempotency_and_conflict_observability(
	coordinator: GlobalRuntimePolicyLeaseStore
) -> void:
	physics_interpolation = false
	var owner := Node.new()
	var conflicting_owner := Node.new()
	owner.name = "IdempotentPolicyOwner"
	conflicting_owner.name = "ConflictingPolicyOwner"
	root.add_child(owner)
	root.add_child(conflicting_owner)
	var conflict_count_before := (
		coordinator.get_physics_interpolation_conflict_count()
	)
	var token := coordinator.acquire_physics_interpolation(owner, true)
	var repeated_token := coordinator.acquire_physics_interpolation(owner, true)
	var rejected_token := coordinator.acquire_physics_interpolation(
		conflicting_owner,
		false
	)
	_expect(
		token == repeated_token
		and coordinator.get_physics_interpolation_owner_count() == 1,
		"同一 owner 的同值重复获取必须幂等，不能增加 owner 计数。"
	)
	_expect(
		rejected_token == GlobalRuntimePolicyLeaseStore.INVALID_LEASE_TOKEN
		and coordinator.get_physics_interpolation_conflict_count()
		== conflict_count_before + 1
		and physics_interpolation,
		"相反值请求必须被拒绝、可观察，且不能改写活动策略。"
	)
	physics_interpolation = false
	await process_frame
	_expect(
		physics_interpolation
		and coordinator.get_physics_interpolation_conflict_count()
		== conflict_count_before + 2,
		"活动租约必须在下一帧诊断并修复绕过协调器的全局写入。"
	)
	coordinator.release_physics_interpolation(token)
	owner.queue_free()
	conflicting_owner.queue_free()
	await process_frame
	_expect(
		coordinator.get_physics_interpolation_owner_count() == 0
		and not physics_interpolation,
		"冲突测试清理后不得遗留 owner 或覆盖状态。"
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("GLOBAL RUNTIME POLICY LEASE SMOKE PASS")
		quit(0)
		return
	print("GLOBAL RUNTIME POLICY LEASE SMOKE FAIL (%d)" % failures.size())
	for failure in failures:
		print(" - %s" % failure)
	quit(1)
