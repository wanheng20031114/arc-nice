extends Node
class_name TowerDefenseHomeDefenseCoordinator

signal base_health_changed(current_health: int, maximum_health: int, revision: int)
signal enemy_escaped(enemy: Enemy, resolved_wave: bool, resolved_boss: bool)
signal base_defeated
signal boss_escaped
signal wave_escape_finished

var home_objective_targets: Array[Node2D] = []
var maximum_base_health := 100
var current_base_health := 100
var base_health_revision := 0
var has_received_remote_base_health_snapshot := false
var resolved_home_enemy_ids: Dictionary = {}
var last_change_play_damage_pulse := true
var last_change_was_remote := false

var _runtime_mode := CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
var _run_state: RunStateStore
var _flow_state_query: Callable
var _active_enemy_query: Callable
var _active_boss_query: Callable


func setup(
	runtime_mode: int,
	run_state: RunStateStore,
	home_gate_controller: HomeGateController,
	overlay_tile_map_layer: TileMapLayer,
	default_base_health: int,
	flow_state_query: Callable,
	active_enemy_query: Callable,
	active_boss_query: Callable
) -> bool:
	assert(flow_state_query.is_valid(), "HomeDefenseCoordinator 缺少流程状态查询。")
	assert(active_enemy_query.is_valid(), "HomeDefenseCoordinator 缺少活动敌人查询。")
	assert(active_boss_query.is_valid(), "HomeDefenseCoordinator 缺少活动 Boss 查询。")
	_runtime_mode = runtime_mode
	_run_state = run_state
	_flow_state_query = flow_state_query
	_active_enemy_query = active_enemy_query
	_active_boss_query = active_boss_query
	if _run_state != null:
		_run_state.ensure_run_started()
		maximum_base_health = _run_state.get_party_core_maximum_health()
		current_base_health = _run_state.get_party_core_health()
	else:
		maximum_base_health = maxi(default_base_health, 1)
		current_base_health = maximum_base_health
	base_health_revision = 0
	has_received_remote_base_health_snapshot = false
	resolved_home_enemy_ids.clear()
	home_objective_targets.clear()
	if home_gate_controller == null:
		push_error("HomeDefenseCoordinator: HomeGateController 缺失。")
		return false
	home_gate_controller.setup(overlay_tile_map_layer)
	home_objective_targets.assign(home_gate_controller.get_objective_targets())
	return true


func get_home_targets() -> Array[Node2D]:
	return home_objective_targets.duplicate()


func get_nearest_home_target(from_position: Vector2) -> Node2D:
	var nearest_target: Node2D = null
	var nearest_distance_squared := INF
	for target in home_objective_targets:
		if target == null or not is_instance_valid(target):
			continue
		var distance_squared := from_position.distance_squared_to(target.global_position)
		if distance_squared < nearest_distance_squared:
			nearest_distance_squared = distance_squared
			nearest_target = target
	return nearest_target


func get_base_health_snapshot() -> Dictionary:
	return {
		"current_health": current_base_health,
		"maximum_health": maximum_base_health,
		"revision": base_health_revision,
	}


func apply_remote_base_health(
	new_current_health: int,
	new_maximum_health: int,
	new_revision: int
) -> bool:
	if _runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return false
	if has_received_remote_base_health_snapshot and new_revision <= base_health_revision:
		return false
	if not has_received_remote_base_health_snapshot and new_revision < base_health_revision:
		return false
	var previous_health := current_base_health
	maximum_base_health = maxi(new_maximum_health, 1)
	current_base_health = clampi(new_current_health, 0, maximum_base_health)
	base_health_revision = new_revision
	if _run_state != null:
		_run_state.set_party_core_health(current_base_health, maximum_base_health, false)
	last_change_play_damage_pulse = (
		has_received_remote_base_health_snapshot
		and current_base_health < previous_health
	)
	last_change_was_remote = true
	has_received_remote_base_health_snapshot = true
	base_health_changed.emit(current_base_health, maximum_base_health, base_health_revision)
	return true


func apply_remote_enemy_escape(enemy: Enemy) -> bool:
	if (
		_runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or enemy == null
		or not is_instance_valid(enemy)
	):
		return false
	enemy.remove_for_home_escape()
	return true


func apply_base_damage(amount: int) -> int:
	if amount <= 0 or current_base_health <= 0:
		return 0
	var previous_health := current_base_health
	var request := DamageRequest.new(amount, CombatTypes.DamageType.PHYSICAL)
	request.with_flag(CombatTypes.DamageFlag.BYPASS_MITIGATION)
	var result := DamageResolver.resolve(
		request,
		DamageTargetProfile.new(current_base_health)
	)
	if not result.accepted:
		return 0
	current_base_health = result.health_after
	if _run_state != null and _runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		if not _run_state.set_party_core_health(current_base_health, maximum_base_health):
			push_error("HomeDefenseCoordinator: 无法回写本局共享核心生命。")
			return 0
		current_base_health = _run_state.get_party_core_health()
		maximum_base_health = _run_state.get_party_core_maximum_health()
	base_health_revision += 1
	last_change_play_damage_pulse = true
	last_change_was_remote = false
	base_health_changed.emit(current_base_health, maximum_base_health, base_health_revision)
	if current_base_health <= 0:
		base_defeated.emit()
	return previous_health - current_base_health


func clear_resolved_enemy_ids() -> void:
	resolved_home_enemy_ids.clear()


func on_enemy_reached_home(enemy: Enemy, _gate_cell: Vector2i) -> void:
	if _runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	var flow_state := int(_flow_state_query.call())
	if flow_state in [CombatFlowState.State.VICTORY, CombatFlowState.State.DEFEAT]:
		return
	if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
		return
	var enemy_id := enemy.get_instance_id()
	if resolved_home_enemy_ids.has(enemy_id):
		return
	resolved_home_enemy_ids[enemy_id] = true
	var resolves_active_wave := (
		flow_state == CombatFlowState.State.WAVE_ACTIVE
		and bool(_active_enemy_query.call(enemy_id))
	)
	var active_boss := _active_boss_query.call() as Enemy
	var resolves_boss_step := (
		flow_state == CombatFlowState.State.BOSS_ACTIVE
		and enemy == active_boss
		and bool(_active_enemy_query.call(enemy_id))
	)
	enemy_escaped.emit(enemy, resolves_active_wave, resolves_boss_step)
	var home_damage := (
		current_base_health
		if resolves_boss_step
		else enemy.config.home_damage if enemy.config != null else 1
	)
	apply_base_damage(maxi(home_damage, 1))
	if resolves_active_wave:
		wave_escape_finished.emit()
	if (
		resolves_boss_step
		and int(_flow_state_query.call()) != CombatFlowState.State.DEFEAT
	):
		boss_escaped.emit()
