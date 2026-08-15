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

var _runtime: CombatRuntimeBase
var _run_state: RunStateStore
var _campaign_coordinator: TowerDefenseCampaignCoordinator
var _enemy_coordinator: TowerDefenseEnemyCoordinator
var _boss_container: Node2D
var _presentation_coordinator: TowerDefensePresentationCoordinator
var _multiplayer_adapter: TowerDefenseMultiplayerModeAdapter
var _resolved_remote_escape_net_ids: Dictionary = {}


func setup(
	runtime: CombatRuntimeBase,
	run_state: RunStateStore,
	home_gate_controller: HomeGateController,
	overlay_tile_map_layer: TileMapLayer,
	default_base_health: int,
	campaign_coordinator: TowerDefenseCampaignCoordinator,
	enemy_coordinator: TowerDefenseEnemyCoordinator,
	boss_container: Node2D,
	presentation_coordinator: TowerDefensePresentationCoordinator,
	multiplayer_adapter: TowerDefenseMultiplayerModeAdapter
) -> bool:
	assert(runtime != null, "HomeDefenseCoordinator 缺少 CombatRuntimeBase 运行时。")
	assert(campaign_coordinator != null, "HomeDefenseCoordinator 缺少 CampaignCoordinator。")
	assert(enemy_coordinator != null, "HomeDefenseCoordinator 缺少 EnemyCoordinator。")
	assert(boss_container != null, "HomeDefenseCoordinator 缺少 BossContainer。")
	assert(presentation_coordinator != null, "HomeDefenseCoordinator 缺少 PresentationCoordinator。")
	assert(multiplayer_adapter != null, "HomeDefenseCoordinator 缺少 MultiplayerModeAdapter。")
	_runtime = runtime
	_run_state = run_state
	_campaign_coordinator = campaign_coordinator
	_enemy_coordinator = enemy_coordinator
	_boss_container = boss_container
	_presentation_coordinator = presentation_coordinator
	_multiplayer_adapter = multiplayer_adapter
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
	_resolved_remote_escape_net_ids.clear()
	home_objective_targets.clear()
	if home_gate_controller == null:
		push_error("HomeDefenseCoordinator: HomeGateController 缺失。")
		return false
	home_gate_controller.setup(overlay_tile_map_layer)
	home_objective_targets.assign(home_gate_controller.get_objective_targets())
	_enemy_coordinator.set_home_objective_targets(home_objective_targets)
	_present_base_health(false, true)
	return true


func is_bound() -> bool:
	return (
		_runtime != null
		and _campaign_coordinator != null
		and _enemy_coordinator != null
		and _boss_container != null
		and _presentation_coordinator != null
		and _multiplayer_adapter != null
	)


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
	if _runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return false
	if has_received_remote_base_health_snapshot and new_revision <= base_health_revision:
		return false
	if not has_received_remote_base_health_snapshot and new_revision < base_health_revision:
		return false
	var previous_health := current_base_health
	maximum_base_health = maxi(new_maximum_health, 1)
	current_base_health = clampi(new_current_health, 0, maximum_base_health)
	base_health_revision = new_revision
	# Rogue 全量快照走 CH0，基地生命与流程走 CH5，两条可靠信道之间
	# 没有总顺序。Rogue 仍持有塔防运行态时，基地快照只更新本地表现；
	# 共享账本继续由 Rogue economy 真源维护，并在 pending 退出时恢复塔防核心。
	if (
		_run_state != null
		and not _multiplayer_adapter.is_rogue_tower_world_suspended()
	):
		_run_state.set_party_core_health(current_base_health, maximum_base_health, false)
	var play_damage_pulse := (
		has_received_remote_base_health_snapshot
		and current_base_health < previous_health
	)
	has_received_remote_base_health_snapshot = true
	_present_base_health(play_damage_pulse, true)
	base_health_changed.emit(current_base_health, maximum_base_health, base_health_revision)
	return true


func apply_remote_enemy_escape(net_id: int) -> bool:
	if (
		_runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or net_id <= 0
		or _resolved_remote_escape_net_ids.has(net_id)
	):
		return false
	var enemy := _enemy_coordinator.take_remote_enemy_for_escape(net_id)
	if enemy == null or not is_instance_valid(enemy):
		return false
	_resolved_remote_escape_net_ids[net_id] = true
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
	if (
		_run_state != null
		and _runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		if not _run_state.set_party_core_health(current_base_health, maximum_base_health):
			push_error("HomeDefenseCoordinator: 无法回写本局共享核心生命。")
			return 0
		current_base_health = _run_state.get_party_core_health()
		maximum_base_health = _run_state.get_party_core_maximum_health()
	base_health_revision += 1
	_present_base_health(true, false)
	base_health_changed.emit(current_base_health, maximum_base_health, base_health_revision)
	if current_base_health <= 0:
		base_defeated.emit()
	return previous_health - current_base_health


func set_authoritative_base_health(
	new_maximum_health: int,
	new_current_health: int
) -> bool:
	if _runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return false
	maximum_base_health = maxi(new_maximum_health, 1)
	current_base_health = clampi(
		new_current_health,
		0,
		maximum_base_health
	)
	base_health_revision += 1
	_present_base_health(false, false)
	base_health_changed.emit(
		current_base_health,
		maximum_base_health,
		base_health_revision
	)
	return true


func clear_resolved_enemy_ids() -> void:
	resolved_home_enemy_ids.clear()
	_resolved_remote_escape_net_ids.clear()


func on_enemy_reached_home(enemy: Enemy, _gate_cell: Vector2i) -> void:
	if _runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	var flow_state := _campaign_coordinator.wave_state
	if flow_state in [CombatFlowState.State.VICTORY, CombatFlowState.State.DEFEAT]:
		return
	if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
		return
	var enemy_id := enemy.get_instance_id()
	if resolved_home_enemy_ids.has(enemy_id):
		return
	resolved_home_enemy_ids[enemy_id] = true
	var is_registered_active := _enemy_coordinator.has_active_enemy(enemy_id)
	var resolves_active_wave := (
		flow_state == CombatFlowState.State.WAVE_ACTIVE
		and is_registered_active
	)
	var active_boss := _get_active_boss()
	var resolves_boss_step := (
		flow_state == CombatFlowState.State.BOSS_ACTIVE
		and enemy == active_boss
		and is_registered_active
	)
	# 所有已登记实体都必须先提交唯一 ESCAPED 原因；是否推进普通波次或
	# Boss 步骤是另一层策略，Boss 召唤物也不能绕过实体终结账本。
	if is_registered_active:
		var recorded_escape := _enemy_coordinator.try_resolve_active_enemy_escape(
			enemy_id
		)
		resolves_active_wave = resolves_active_wave and recorded_escape
		resolves_boss_step = resolves_boss_step and recorded_escape
	_enemy_coordinator.remove_hud_alive_enemy(enemy_id)
	_enemy_coordinator.emit_multiplayer_enemy_escaped(enemy)
	enemy.remove_for_home_escape()
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
		and _campaign_coordinator.wave_state != CombatFlowState.State.DEFEAT
	):
		boss_escaped.emit()


func _present_base_health(
	play_damage_pulse: bool,
	was_remote: bool
) -> void:
	_presentation_coordinator.show_base_health(
		current_base_health,
		maximum_base_health,
		play_damage_pulse
	)
	if play_damage_pulse:
		_presentation_coordinator.play_gate_damage_warning()
	if not was_remote:
		_multiplayer_adapter.publish_authoritative_base_health(
			current_base_health,
			maximum_base_health,
			base_health_revision
		)


func _get_active_boss() -> Enemy:
	for child in _boss_container.get_children():
		var candidate := child as Enemy
		if candidate != null and is_instance_valid(candidate) and not candidate.is_dead:
			return candidate
	return null
