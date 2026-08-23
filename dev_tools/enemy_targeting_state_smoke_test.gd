extends SceneTree

const Descriptor := preload(
	"res://scene/combat/targeting/combat_target_descriptor.gd"
)
const TargetingState := preload(
	"res://scene/combat/targeting/enemy_targeting_state.gd"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_assignment_revision_ordering()
	_test_entity_and_assignment_revisions_are_independent()
	_test_automatic_target_hysteresis()
	_test_priority_and_prepared_fallback()
	_test_unreachable_confirmation_cache_and_recovery()
	_test_immediate_assignment_suppression()
	if failures.is_empty():
		print("ENEMY_TARGETING_STATE_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_assignment_revision_ordering() -> void:
	var state := TargetingState.new()
	var first := Descriptor.create_enemy(101, 1, Vector2(10.0, 0.0))
	var stale := Descriptor.create_player(2, 0, Vector2(3.0, 0.0))
	var conflicting_equal := Descriptor.create_plant(303, 1, Vector2(4.0, 0.0))
	_expect(
		state.apply_assignment(first)
		and state.has_assigned_target()
		and state.is_active_target_assigned()
		and state.active_target.same_identity(first),
		"首个宿主指定目标必须取得最高优先级。"
	)
	_expect(
		not state.apply_assignment(stale)
		and not state.apply_assignment(conflicting_equal)
		and state.assigned_target.same_identity(first),
		"低 revision 与相同 revision 的乱序/冲突赋值必须被拒绝。"
	)
	var ordered_clear := Descriptor.create_none(2)
	_expect(
		state.apply_assignment(ordered_clear)
		and not state.has_assigned_target()
		and not state.has_active_target()
		and state.assignment_revision == 2,
		"带正 revision 的 NONE 必须按序清除指定目标。"
	)


func _test_entity_and_assignment_revisions_are_independent() -> void:
	var state := TargetingState.new()
	var faction_revision_seven := Descriptor.create_enemy(
		501,
		7,
		Vector2(12.0, 8.0)
	)
	var same_entity_revision_new_position := Descriptor.create_enemy(
		501,
		7,
		Vector2(18.0, 8.0)
	)
	var newer_entity_revision := Descriptor.create_enemy(
		501,
		8,
		Vector2(24.0, 8.0)
	)
	_expect(
		state.apply_assignment(faction_revision_seven, 20)
		and state.apply_assignment(same_entity_revision_new_position, 21)
		and state.assignment_revision == 21
		and state.assigned_target.revision == 7
		and state.assigned_target.fallback_position == Vector2(18.0, 8.0)
		and not state.apply_assignment(newer_entity_revision, 20),
		"entity revision 必须随描述符保存，assignment revision 必须独立执行乱序 CAS。"
	)


func _test_automatic_target_hysteresis() -> void:
	var state := TargetingState.new()
	var first := Descriptor.create_player(1, 0, Vector2(100.0, 0.0))
	var candidate := Descriptor.create_enemy(8, 0, Vector2(75.0, 0.0))
	_expect(
		state.consider_automatic_target(first, INF, 100.0)
		and state.active_target.same_identity(first),
		"空目标必须接纳首个有效自动候选。"
	)
	_expect(
		not state.consider_automatic_target(candidate, 100.0, 75.01)
		and state.active_target.same_identity(first),
		"不足 25% 的距离改善不得触发切换。"
	)
	_expect(
		state.consider_automatic_target(candidate, 100.0, 75.0)
		and state.active_target.same_identity(candidate),
		"恰好近 25% 的候选必须允许切换。"
	)
	var refreshed := Descriptor.create_enemy(8, 9, Vector2(61.0, 0.0))
	_expect(
		state.consider_automatic_target(refreshed, 75.0, 90.0)
		and state.active_target.same_identity(candidate)
		and state.active_target.revision == 9
		and state.active_target.fallback_position == Vector2(61.0, 0.0),
		"同身份候选应刷新 revision/fallback，不应被迟滞门槛阻挡。"
	)
	var assigned := Descriptor.create_plant(99, 1, Vector2.ZERO)
	_expect(
		state.apply_assignment(assigned)
		and not state.consider_automatic_target(first, 1.0, 0.1)
		and state.active_target.same_identity(assigned),
		"可用的宿主指定目标必须阻止任何自动候选抢占。"
	)


func _test_unreachable_confirmation_cache_and_recovery() -> void:
	var state := TargetingState.new()
	var assigned := Descriptor.create_enemy(500, 1, Vector2(90.0, 10.0))
	state.apply_assignment(assigned)
	_expect(
		state.observe_assignment_reachability(
			TargetingState.ReachabilityResult.UNREACHABLE,
			10
		) == TargetingState.ReachabilityUpdate.CONFIRMING_UNREACHABLE
		and state.consecutive_unreachable_confirmations == 1,
		"第一次确定不可达只能累积确认，不能立即回退。"
	)

	_expect(
		state.observe_assignment_reachability(
			TargetingState.ReachabilityResult.DEFERRED,
			11
		) == TargetingState.ReachabilityUpdate.DEFERRED_IGNORED
		and state.consecutive_unreachable_confirmations == 1,
		"导航预算 DEFERRED 不得计作不可达，也不得清除已有确认。"
	)
	state.observe_assignment_reachability(
		TargetingState.ReachabilityResult.UNREACHABLE,
		12
	)
	var cached_update := state.observe_assignment_reachability(
		TargetingState.ReachabilityResult.UNREACHABLE,
		13
	)
	_expect(
		cached_update == TargetingState.ReachabilityUpdate.NEGATIVE_CACHED
		and state.negative_cache_until_tick == 49
		and state.is_assignment_negative_cached(48)
		and not state.has_active_target(),
		"连续三次不可达必须清除指定活动目标并缓存恰好 36 tick。"
	)
	var automatic := Descriptor.create_player(1, 0, Vector2(30.0, 0.0))
	_expect(
		state.consider_automatic_target(automatic, INF, 30.0)
		and state.active_target.same_identity(automatic)
		and state.observe_assignment_reachability(
			TargetingState.ReachabilityResult.REACHABLE,
			30
		) == TargetingState.ReachabilityUpdate.CACHE_ACTIVE,
		"负缓存期间必须允许自动补位，并忽略过早探测结果。"
	)
	_expect(
		state.should_probe_assignment(49)
		and state.observe_assignment_reachability(
			TargetingState.ReachabilityResult.DEFERRED,
			49
		) == TargetingState.ReachabilityUpdate.DEFERRED_IGNORED
		and state.active_target.same_identity(automatic),
		"缓存到期后的预算延迟应保留自动目标并允许后续重试。"
	)
	_expect(
		state.observe_assignment_reachability(
			TargetingState.ReachabilityResult.UNREACHABLE,
			50
		) == TargetingState.ReachabilityUpdate.NEGATIVE_CACHED
		and state.negative_cache_until_tick == 86,
		"到期复查仍不可达时应直接续期，不重复三连确认。"
	)
	_expect(
		state.observe_assignment_reachability(
			TargetingState.ReachabilityResult.REACHABLE,
			86
		) == TargetingState.ReachabilityUpdate.RESTORED
		and state.is_active_target_assigned()
		and state.active_target.same_identity(assigned)
		and state.consecutive_unreachable_confirmations == 0,
		"指定目标恢复可达后必须重新取得绝对优先级。"
	)


func _test_priority_and_prepared_fallback() -> void:
	var state := TargetingState.new()
	var player := Descriptor.create_player(1, 0, Vector2(20.0, 0.0))
	var plant := Descriptor.create_plant(7, 0, Vector2(80.0, 0.0))
	_expect(
		state.consider_automatic_target(player, INF, 20.0, 1)
		and state.consider_automatic_target(plant, 20.0, 80.0, 0)
		and state.active_target.same_identity(plant),
		"更高的家族目标层级必须优先于距离迟滞，保持 Plant/Combatant 原优先级。"
	)
	var assigned := Descriptor.create_enemy(99, 1, Vector2(120.0, 0.0))
	var fallback := Descriptor.create_player(2, 0, Vector2(30.0, 0.0))
	state.clear_automatic_target()
	state.apply_assignment(assigned)
	_expect(
		not state.consider_automatic_target(fallback, INF, 30.0, 1)
		and state.is_active_target_assigned(),
		"指定目标持有绝对优先权时，也必须预先保存自动补位而不抢占。"
	)
	state.suppress_assignment(50)
	_expect(
		state.active_target.same_identity(fallback)
		and not state.is_active_target_assigned(),
		"指定目标失效时必须在同一决策中启用已准备的自动补位。"
	)


func _test_immediate_assignment_suppression() -> void:
	var state := TargetingState.new()
	var assigned := Descriptor.create_enemy(88, 4, Vector2.ZERO)
	state.apply_assignment(assigned)
	_expect(
		state.suppress_assignment(200)
		and state.negative_cache_until_tick == 236
		and not state.has_active_target(),
		"死亡、转友方或不可攻击的指定目标应立即进入统一负缓存。"
	)
	var replacement := Descriptor.create_enemy(89, 5, Vector2.ONE)
	_expect(
		state.apply_assignment(replacement)
		and state.has_assignment_priority()
		and not state.is_assignment_negative_cached(201)
		and state.active_target.same_identity(replacement),
		"更新的宿主赋值必须清除旧目标的负缓存状态。"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
