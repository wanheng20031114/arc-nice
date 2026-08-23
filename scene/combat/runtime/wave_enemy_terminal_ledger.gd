extends RefCounted
class_name WaveEnemyTerminalLedger

## 波次敌人生命周期的唯一真源。
## objective 参与波次聚合，auxiliary（例如 Boss 召唤物）只记录实体终结。

enum EnemyRole {
	OBJECTIVE,
	AUXILIARY,
}

enum EnemyState {
	ACTIVE,
	TERMINAL,
	DETACHED,
}


class EnemyRecord extends RefCounted:
	var enemy_id: int
	var role: EnemyRole
	var state := EnemyState.ACTIVE
	var terminal_reason := -1

	func _init(p_enemy_id: int, p_role: EnemyRole) -> void:
		enemy_id = p_enemy_id
		role = p_role


class DetachResult extends RefCounted:
	var known := false
	var accepted := false
	var terminal_created := false
	var role := EnemyRole.OBJECTIVE
	var terminal_reason := -1


var _records: Dictionary[int, EnemyRecord] = {}
## `_records` 保留整波身份历史，以支持重复终结/重复离树的幂等判断；
## 以下稀疏索引只保留热生命周期集合，计数与实体枚举不再扫描历史。
var _active_objective_enemy_ids: Dictionary[int, bool] = {}
var _active_auxiliary_enemy_ids: Dictionary[int, bool] = {}
var _attached_objective_enemy_ids: Dictionary[int, bool] = {}
var _attached_auxiliary_enemy_ids: Dictionary[int, bool] = {}
var _total := 0
var _spawned := 0
var _defeated := 0
var _escaped := 0
var _removed := 0
var _resolved := 0
var _bound_objective_count := 0


func reset(
	total: int,
	spawned: int = 0,
	defeated: int = 0,
	escaped: int = 0,
	removed: int = 0
) -> bool:
	var resolved := defeated + escaped + removed
	if (
		total < 0
		or spawned < 0
		or defeated < 0
		or escaped < 0
		or removed < 0
		or spawned > total
		or resolved > spawned
	):
		return false
	_records.clear()
	_clear_lifecycle_indexes()
	_total = total
	_spawned = spawned
	_defeated = defeated
	_escaped = escaped
	_removed = removed
	_resolved = resolved
	# 快照中已 resolved 的槽位不会再拥有本地实体；把它们视为已绑定，
	# 仅允许后续实体占用 spawned - resolved 个未终结槽位。
	_bound_objective_count = resolved
	return true


func apply_snapshot(
	total: int,
	spawned: int,
	defeated: int,
	escaped: int,
	removed: int
) -> bool:
	return reset(total, spawned, defeated, escaped, removed)


func register_enemy(enemy_id: int, role: EnemyRole = EnemyRole.OBJECTIVE) -> bool:
	if enemy_id <= 0 or _records.has(enemy_id) or not _is_valid_role(role):
		return false
	if role == EnemyRole.OBJECTIVE:
		# reset(..., spawned) 可先保留已生成槽位；首个实体注册会绑定槽位，
		# 正常刷怪则在这里原子增加 spawned，调用方不再另写计数器。
		if _bound_objective_count >= _spawned:
			if _spawned >= _total:
				return false
			_spawned += 1
		_bound_objective_count += 1
	var record := EnemyRecord.new(enemy_id, role)
	_records[enemy_id] = record
	_index_registered_enemy(record)
	return true


func resolve_enemy(enemy_id: int, reason: CombatTypes.EnemyTerminalReason) -> bool:
	if not _is_valid_reason(reason):
		return false
	var record := _records.get(enemy_id) as EnemyRecord
	if record == null or record.state != EnemyState.ACTIVE:
		return false
	if record.role == EnemyRole.OBJECTIVE:
		if _resolved >= _spawned:
			return false
		match reason:
			CombatTypes.EnemyTerminalReason.DEFEATED:
				_defeated += 1
			CombatTypes.EnemyTerminalReason.ESCAPED:
				_escaped += 1
			CombatTypes.EnemyTerminalReason.REMOVED:
				_removed += 1
		_resolved += 1
	record.state = EnemyState.TERMINAL
	record.terminal_reason = reason
	_remove_active_enemy_from_index(record)
	return true


## 终局表现与整局 teardown 都不再等待仍存活的实体参与波次聚合。
## 实体继续保持 ATTACHED，直到真实 tree_exited 再完成 DETACHED。
func resolve_all_active_as_removed() -> int:
	var resolved_count := 0
	for enemy_id_variant in get_active_enemy_ids():
		if resolve_enemy(
			int(enemy_id_variant),
			CombatTypes.EnemyTerminalReason.REMOVED
		):
			resolved_count += 1
	return resolved_count


func detach_enemy(enemy_id: int) -> DetachResult:
	var result := DetachResult.new()
	var record := _records.get(enemy_id) as EnemyRecord
	if record == null:
		return result
	result.known = true
	if record.state == EnemyState.DETACHED:
		return result
	result.role = record.role
	if record.state == EnemyState.ACTIVE:
		if not resolve_enemy(enemy_id, CombatTypes.EnemyTerminalReason.REMOVED):
			return result
		result.terminal_created = true
	result.accepted = true
	result.terminal_reason = record.terminal_reason
	record.state = EnemyState.DETACHED
	_remove_attached_enemy_from_index(record)
	return result


func clear_entities() -> void:
	_records.clear()
	_clear_lifecycle_indexes()
	_bound_objective_count = _resolved


func has_enemy(enemy_id: int) -> bool:
	return _records.has(enemy_id)


func is_enemy_active(enemy_id: int) -> bool:
	var record := _records.get(enemy_id) as EnemyRecord
	return record != null and record.state == EnemyState.ACTIVE


func is_enemy_attached(enemy_id: int) -> bool:
	var record := _records.get(enemy_id) as EnemyRecord
	return record != null and record.state != EnemyState.DETACHED


func get_enemy_role(enemy_id: int) -> EnemyRole:
	var record := _records.get(enemy_id) as EnemyRecord
	return record.role if record != null else EnemyRole.OBJECTIVE


func get_terminal_reason(enemy_id: int) -> int:
	var record := _records.get(enemy_id) as EnemyRecord
	return record.terminal_reason if record != null else -1


func get_active_enemy_ids(role_filter: int = -1) -> Dictionary:
	return _copy_role_index(
		role_filter,
		_active_objective_enemy_ids,
		_active_auxiliary_enemy_ids
	)


func get_attached_enemy_ids(role_filter: int = -1) -> Dictionary:
	return _copy_role_index(
		role_filter,
		_attached_objective_enemy_ids,
		_attached_auxiliary_enemy_ids
	)


func get_active_enemy_count(role_filter: int = -1) -> int:
	return _get_role_index_count(
		role_filter,
		_active_objective_enemy_ids,
		_active_auxiliary_enemy_ids
	)


func get_attached_enemy_count(role_filter: int = -1) -> int:
	return _get_role_index_count(
		role_filter,
		_attached_objective_enemy_ids,
		_attached_auxiliary_enemy_ids
	)


func get_total() -> int:
	return _total


func get_spawned() -> int:
	return _spawned


func get_defeated() -> int:
	return _defeated


func get_escaped() -> int:
	return _escaped


func get_removed() -> int:
	return _removed


func get_resolved() -> int:
	return _resolved


func is_complete() -> bool:
	return _spawned >= _total and _resolved == _total


func get_snapshot() -> Dictionary:
	return {
		"total": _total,
		"spawned": _spawned,
		"defeated": _defeated,
		"escaped": _escaped,
		"removed": _removed,
		"resolved": _resolved,
	}


func _is_valid_reason(reason: int) -> bool:
	return reason in [
		CombatTypes.EnemyTerminalReason.DEFEATED,
		CombatTypes.EnemyTerminalReason.ESCAPED,
		CombatTypes.EnemyTerminalReason.REMOVED,
	]


func _is_valid_role(role: int) -> bool:
	return role == EnemyRole.OBJECTIVE or role == EnemyRole.AUXILIARY


func _index_registered_enemy(record: EnemyRecord) -> void:
	match record.role:
		EnemyRole.OBJECTIVE:
			_active_objective_enemy_ids[record.enemy_id] = true
			_attached_objective_enemy_ids[record.enemy_id] = true
		EnemyRole.AUXILIARY:
			_active_auxiliary_enemy_ids[record.enemy_id] = true
			_attached_auxiliary_enemy_ids[record.enemy_id] = true


func _remove_active_enemy_from_index(record: EnemyRecord) -> void:
	match record.role:
		EnemyRole.OBJECTIVE:
			_active_objective_enemy_ids.erase(record.enemy_id)
		EnemyRole.AUXILIARY:
			_active_auxiliary_enemy_ids.erase(record.enemy_id)


func _remove_attached_enemy_from_index(record: EnemyRecord) -> void:
	match record.role:
		EnemyRole.OBJECTIVE:
			_attached_objective_enemy_ids.erase(record.enemy_id)
		EnemyRole.AUXILIARY:
			_attached_auxiliary_enemy_ids.erase(record.enemy_id)


func _clear_lifecycle_indexes() -> void:
	_active_objective_enemy_ids.clear()
	_active_auxiliary_enemy_ids.clear()
	_attached_objective_enemy_ids.clear()
	_attached_auxiliary_enemy_ids.clear()


func _get_role_index_count(
	role_filter: int,
	objective_ids: Dictionary,
	auxiliary_ids: Dictionary
) -> int:
	if role_filter < 0:
		return objective_ids.size() + auxiliary_ids.size()
	match role_filter:
		EnemyRole.OBJECTIVE:
			return objective_ids.size()
		EnemyRole.AUXILIARY:
			return auxiliary_ids.size()
	return 0


func _copy_role_index(
	role_filter: int,
	objective_ids: Dictionary,
	auxiliary_ids: Dictionary
) -> Dictionary:
	match role_filter:
		EnemyRole.OBJECTIVE:
			return objective_ids.duplicate()
		EnemyRole.AUXILIARY:
			return auxiliary_ids.duplicate()
	if role_filter >= 0:
		return {}
	var result := objective_ids.duplicate()
	result.merge(auxiliary_ids)
	return result
