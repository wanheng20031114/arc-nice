extends RefCounted
class_name EnemyTargetingState

const TargetDescriptor := preload(
	"res://scene/combat/targeting/combat_target_descriptor.gd"
)

## A navigation request can be postponed because its per-tick budget is spent.
## DEFERRED is intentionally distinct from an authoritative path failure.
enum ReachabilityResult {
	REACHABLE,
	UNREACHABLE,
	DEFERRED,
}

enum ReachabilityUpdate {
	NO_ASSIGNMENT,
	REACHABLE_ACCEPTED,
	CONFIRMING_UNREACHABLE,
	NEGATIVE_CACHED,
	CACHE_ACTIVE,
	DEFERRED_IGNORED,
	RESTORED,
}

const REQUIRED_UNREACHABLE_CONFIRMATIONS := 3
const DEFAULT_NEGATIVE_CACHE_TICKS := 36
const AUTOMATIC_SWITCH_DISTANCE_RATIO := 0.75
const NO_AUTOMATIC_PRIORITY := 2147483647

var assigned_target: CombatTargetDescriptor = TargetDescriptor.create_none()
var active_target: CombatTargetDescriptor = TargetDescriptor.create_none()
var automatic_target: CombatTargetDescriptor = TargetDescriptor.create_none()
var assignment_revision := -1
var consecutive_unreachable_confirmations := 0
var negative_cache_until_tick := -1
var automatic_priority := NO_AUTOMATIC_PRIORITY
var active_automatic_priority := NO_AUTOMATIC_PRIORITY
var _negative_cache_armed := false
var _active_is_assigned := false


func reset() -> void:
	assigned_target = TargetDescriptor.create_none()
	active_target = TargetDescriptor.create_none()
	automatic_target = TargetDescriptor.create_none()
	assignment_revision = -1
	consecutive_unreachable_confirmations = 0
	negative_cache_until_tick = -1
	automatic_priority = NO_AUTOMATIC_PRIORITY
	active_automatic_priority = NO_AUTOMATIC_PRIORITY
	_negative_cache_armed = false
	_active_is_assigned = false


## Applies a host-authored assignment only when its assignment revision is
## newer. Descriptor.revision belongs to the target entity (for Enemy targets it
## is the faction revision) and must never be reused as transport ordering.
## Omitting next_assignment_revision preserves the pre-v94 local API.
func apply_assignment(
	next_target: CombatTargetDescriptor,
	next_assignment_revision: int = -1
) -> bool:
	var resolved_assignment_revision := next_assignment_revision
	if resolved_assignment_revision < 0 and next_target != null:
		resolved_assignment_revision = next_target.revision
	if (
		next_target == null
		or not next_target.is_valid()
		or resolved_assignment_revision < 0
		or resolved_assignment_revision <= assignment_revision
	):
		return false
	assignment_revision = resolved_assignment_revision
	assigned_target = next_target.duplicate()
	consecutive_unreachable_confirmations = 0
	negative_cache_until_tick = -1
	_negative_cache_armed = false
	if assigned_target.kind == TargetDescriptor.Kind.NONE:
		if _active_is_assigned:
			_restore_automatic_target_or_clear()
		_active_is_assigned = false
		return true
	active_target = assigned_target.duplicate()
	active_automatic_priority = NO_AUTOMATIC_PRIORITY
	_active_is_assigned = true
	return true


func has_assigned_target() -> bool:
	return assigned_target.kind != TargetDescriptor.Kind.NONE


func has_active_target() -> bool:
	return active_target.kind != TargetDescriptor.Kind.NONE


func is_active_target_assigned() -> bool:
	return _active_is_assigned and has_active_target()


## An armed negative cache keeps automatic fallback active even after its timer
## expires. At expiry the caller probes the designation once; only REACHABLE
## restores its absolute priority.
func has_assignment_priority() -> bool:
	return has_assigned_target() and not _negative_cache_armed


func is_assignment_negative_cached(current_tick: int) -> bool:
	return (
		has_assigned_target()
		and _negative_cache_armed
		and current_tick < negative_cache_until_tick
	)


func should_probe_assignment(current_tick: int) -> bool:
	return (
		has_assigned_target()
		and _negative_cache_armed
		and current_tick >= negative_cache_until_tick
	)


func can_evaluate_assignment(current_tick: int) -> bool:
	return (
		has_assigned_target()
		and (
			not _negative_cache_armed
			or current_tick >= negative_cache_until_tick
		)
	)


## Records one completed reachability decision. Three consecutive authoritative
## UNREACHABLE results arm the 36-tick cache. A budget DEFERRED result neither
## increments nor resets the count. Once cached, each expired probe either
## restores the assignment or renews the cache for another interval.
func observe_assignment_reachability(
	result: ReachabilityResult,
	current_tick: int,
	negative_cache_ticks: int = DEFAULT_NEGATIVE_CACHE_TICKS
) -> ReachabilityUpdate:
	if not has_assigned_target():
		return ReachabilityUpdate.NO_ASSIGNMENT
	if is_assignment_negative_cached(current_tick):
		return ReachabilityUpdate.CACHE_ACTIVE
	if result == ReachabilityResult.DEFERRED:
		return ReachabilityUpdate.DEFERRED_IGNORED
	if result == ReachabilityResult.REACHABLE:
		var restored := _negative_cache_armed
		consecutive_unreachable_confirmations = 0
		negative_cache_until_tick = -1
		_negative_cache_armed = false
		active_target = assigned_target.duplicate()
		active_automatic_priority = NO_AUTOMATIC_PRIORITY
		_active_is_assigned = true
		return (
			ReachabilityUpdate.RESTORED
			if restored
			else ReachabilityUpdate.REACHABLE_ACCEPTED
		)
	if result != ReachabilityResult.UNREACHABLE:
		return ReachabilityUpdate.DEFERRED_IGNORED
	if _negative_cache_armed:
		_begin_negative_cache(current_tick, negative_cache_ticks)
		return ReachabilityUpdate.NEGATIVE_CACHED
	consecutive_unreachable_confirmations += 1
	if (
		consecutive_unreachable_confirmations
		< REQUIRED_UNREACHABLE_CONFIRMATIONS
	):
		return ReachabilityUpdate.CONFIRMING_UNREACHABLE
	_begin_negative_cache(current_tick, negative_cache_ticks)
	return ReachabilityUpdate.NEGATIVE_CACHED


## Dead, newly friendly or otherwise ineligible designated targets do not need
## three path probes. They enter the same bounded fallback/recheck lifecycle.
func suppress_assignment(
	current_tick: int,
	negative_cache_ticks: int = DEFAULT_NEGATIVE_CACHE_TICKS
) -> bool:
	if not has_assigned_target():
		return false
	consecutive_unreachable_confirmations = REQUIRED_UNREACHABLE_CONFIRMATIONS
	_begin_negative_cache(current_tick, negative_cache_ticks)
	return true


## Returns true only when the automatic candidate became (or refreshed) the
## active target. A different candidate must be at least 25% nearer in linear
## distance. Same-identity refreshes update revision/fallback without jitter.
func consider_automatic_target(
	candidate: CombatTargetDescriptor,
	current_distance: float,
	candidate_distance: float,
	candidate_priority: int = 0
) -> bool:
	if (
		candidate == null
		or not candidate.is_valid()
		or candidate.kind == TargetDescriptor.Kind.NONE
		or not is_finite(candidate_distance)
		or candidate_distance < 0.0
	):
		return false
	var safe_priority := maxi(candidate_priority, 0)
	var automatic_changed := false
	if automatic_target.same_identity(candidate):
		automatic_target = candidate.duplicate()
		automatic_priority = safe_priority
		automatic_changed = true
	elif (
		automatic_target.kind == TargetDescriptor.Kind.NONE
		or safe_priority < automatic_priority
		or (
			safe_priority == automatic_priority
			and (
				not is_finite(current_distance)
				or current_distance < 0.0
				or candidate_distance
					<= current_distance * AUTOMATIC_SWITCH_DISTANCE_RATIO
			)
		)
	):
		automatic_target = candidate.duplicate()
		automatic_priority = safe_priority
		automatic_changed = true
	if has_assignment_priority():
		return false
	if not has_active_target():
		active_target = automatic_target.duplicate()
		active_automatic_priority = automatic_priority
		_active_is_assigned = false
		return true
	if active_target.same_identity(candidate):
		active_target = candidate.duplicate()
		active_automatic_priority = safe_priority
		_active_is_assigned = false
		return true
	if not automatic_changed:
		return false
	if safe_priority > active_automatic_priority:
		return false
	if (
		safe_priority == active_automatic_priority
		and (
			not is_finite(current_distance)
			or current_distance < 0.0
			or candidate_distance
				> current_distance * AUTOMATIC_SWITCH_DISTANCE_RATIO
		)
	):
		return false
	active_target = automatic_target.duplicate()
	active_automatic_priority = automatic_priority
	_active_is_assigned = false
	return true


func clear_automatic_target(expected: CombatTargetDescriptor = null) -> bool:
	if automatic_target.kind == TargetDescriptor.Kind.NONE:
		return false
	if expected != null and not automatic_target.same_identity(expected):
		return false
	var was_active := (
		not _active_is_assigned
		and active_target.same_identity(automatic_target)
	)
	automatic_target = TargetDescriptor.create_none()
	automatic_priority = NO_AUTOMATIC_PRIORITY
	if was_active:
		active_target = TargetDescriptor.create_none()
		active_automatic_priority = NO_AUTOMATIC_PRIORITY
	return true


func clear_active_target(expected: CombatTargetDescriptor = null) -> bool:
	if not has_active_target():
		return false
	if expected != null and not active_target.same_identity(expected):
		return false
	active_target = TargetDescriptor.create_none()
	active_automatic_priority = NO_AUTOMATIC_PRIORITY
	_active_is_assigned = false
	return true


func _begin_negative_cache(current_tick: int, cache_ticks: int) -> void:
	_negative_cache_armed = true
	negative_cache_until_tick = current_tick + maxi(cache_ticks, 1)
	if _active_is_assigned:
		_restore_automatic_target_or_clear()
		_active_is_assigned = false


func _restore_automatic_target_or_clear() -> void:
	if automatic_target.kind != TargetDescriptor.Kind.NONE:
		active_target = automatic_target.duplicate()
		active_automatic_priority = automatic_priority
		return
	active_target = TargetDescriptor.create_none()
	active_automatic_priority = NO_AUTOMATIC_PRIORITY
