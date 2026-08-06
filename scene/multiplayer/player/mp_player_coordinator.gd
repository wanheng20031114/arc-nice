extends Node
class_name MpPlayerCoordinator

signal life_rpc_broadcast_requested(method_name: StringName, arguments: Array)
signal player_state_correction_requested(
	peer_id: int,
	corrected_position: Vector2,
	corrected_velocity: Vector2
)

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const GAME_RUNTIME_CLIENT_VIEW := 2
const SHARED_SNAPSHOT_COHORT_ID := -1
const PLAYER_DELTA_KEYFRAME_INTERVAL_SECONDS := 0.5
const PLAYER_REVIVE_INVINCIBILITY_SECONDS := 3.0
const HIT_DEDUP_RETENTION_SECONDS := 30.0
const FIRE_SLIME_TOUCH_TYPE: StringName = &"fire_slime_touch"
const FROST_SLIME_TOUCH_TYPE: StringName = &"frost_slime_touch"
const FROST_SORCERER_ICE_SPIKE_TYPE: StringName = &"frost_sorcerer_ice_spike"


class HostSnapshotBatch:
	extends RefCounted

	var peer_ids: Array[int] = []
	var host_timestamp := 0.0
	var data := PackedByteArray()
	var entity_count := 0

	func is_empty() -> bool:
		return peer_ids.is_empty() or data.is_empty() or entity_count <= 0


var _runtime: CombatRuntimeBase = null
var _net_manager: NetManagerStore = null
var _mode_adapter: MultiplayerModeAdapter = null
var _projectile_coordinator: MpProjectileCoordinator = null
var _get_net_time_callable := Callable()
var _cancel_tango_for_revive_schedule_callable := Callable()
var _cancel_actions_for_revive_callable := Callable()
var _clear_tiyi_lifecycle_state_callable := Callable()
var _get_revive_anchor_position_callable := Callable()
var _commit_revive_position_callable := Callable()
var _snapshot_manager := SnapshotManager.new()
var _visual_interpolators: Dictionary[int, NetInterpolator] = {}
var _teleport_cutoff_sequences: Dictionary[int, int] = {}
var _pending_authoritative_teleports: Dictionary[int, Dictionary] = {}
var _character_mismatch_warnings: Dictionary[int, bool] = {}
var _latest_client_states: Dictionary[int, Dictionary] = {}
var _applied_health_revisions: Dictionary[int, int] = {}
var _last_keyframe_time_by_peer: Dictionary[int, float] = {}
var _snapshot_cohort_peers: Dictionary[int, bool] = {}
var _host_snapshot_sequence := 0
var _snapshot_encode_count := 0
var _processed_player_hit_ids: Dictionary = {}
var _player_health_revisions: Dictionary = {}
var _dead_player_revive_times: Dictionary = {}
var _dead_player_revive_last_seconds: Dictionary = {}
var _revive_random_generator := RandomNumberGenerator.new()


func bind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	assert(runtime_instance != null, "MpPlayerCoordinator 缺少战斗运行时。")
	if _runtime == runtime_instance:
		return
	if _runtime != null:
		reset_session_state()
	_runtime = runtime_instance


func unbind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	if _runtime != runtime_instance:
		return
	_runtime = null
	_clear_life_dependencies()
	reset_session_state()


func is_bound() -> bool:
	return _runtime != null and is_instance_valid(_runtime)


func bind_life_dependencies(
	net_manager_instance: NetManagerStore,
	mode_adapter_instance: MultiplayerModeAdapter,
	projectile_coordinator_instance: MpProjectileCoordinator,
	get_net_time_callable: Callable,
	cancel_tango_for_revive_schedule_callable: Callable,
	cancel_actions_for_revive_callable: Callable,
	clear_tiyi_lifecycle_state_callable: Callable,
	get_revive_anchor_position_callable: Callable,
	commit_revive_position_callable: Callable
) -> void:
	assert(net_manager_instance != null, "MpPlayerCoordinator 缺少 NetManager。")
	assert(mode_adapter_instance != null, "MpPlayerCoordinator 缺少模式适配器。")
	assert(
		projectile_coordinator_instance != null,
		"MpPlayerCoordinator 缺少弹体协调器。"
	)
	assert(get_net_time_callable.is_valid(), "MpPlayerCoordinator 缺少网络时钟。")
	assert(
		cancel_tango_for_revive_schedule_callable.is_valid(),
		"MpPlayerCoordinator 缺少死亡阶段主动技能清理入口。"
	)
	assert(
		cancel_actions_for_revive_callable.is_valid(),
		"MpPlayerCoordinator 缺少复活阶段主动技能清理入口。"
	)
	assert(
		clear_tiyi_lifecycle_state_callable.is_valid(),
		"MpPlayerCoordinator 缺少客户端提伊生命状态清理入口。"
	)
	assert(
		get_revive_anchor_position_callable.is_valid(),
		"MpPlayerCoordinator 缺少复活锚点读取入口。"
	)
	assert(
		commit_revive_position_callable.is_valid(),
		"MpPlayerCoordinator 缺少复活位置提交入口。"
	)
	_net_manager = net_manager_instance
	_mode_adapter = mode_adapter_instance
	_projectile_coordinator = projectile_coordinator_instance
	_get_net_time_callable = get_net_time_callable
	_cancel_tango_for_revive_schedule_callable = (
		cancel_tango_for_revive_schedule_callable
	)
	_cancel_actions_for_revive_callable = cancel_actions_for_revive_callable
	_clear_tiyi_lifecycle_state_callable = clear_tiyi_lifecycle_state_callable
	_get_revive_anchor_position_callable = get_revive_anchor_position_callable
	_commit_revive_position_callable = commit_revive_position_callable


func randomize_revive_generator() -> void:
	_revive_random_generator.randomize()


func has_life_dependencies() -> bool:
	return (
		is_bound()
		and _net_manager != null
		and is_instance_valid(_net_manager)
		and _mode_adapter != null
		and is_instance_valid(_mode_adapter)
		and _projectile_coordinator != null
		and is_instance_valid(_projectile_coordinator)
		and _get_net_time_callable.is_valid()
	)


func request_multiplayer_player_damage(
	source_id: int,
	target_peer_id: int,
	damage: int,
	source_type: StringName,
	damage_type_or_source_direction: Variant = EnemyConfig.DamageType.PHYSICAL,
	source_direction_or_is_ranged: Variant = Vector2.ZERO,
	is_ranged: bool = false,
	contact_preconsumed: bool = false
) -> bool:
	if (
		not has_life_dependencies()
		or source_id <= 0
		or target_peer_id <= 0
		or damage <= 0
	):
		return false
	var resolved_damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
	var source_direction := Vector2.ZERO
	var resolved_is_ranged := is_ranged
	if damage_type_or_source_direction is Vector2:
		source_direction = damage_type_or_source_direction as Vector2
		if source_direction_or_is_ranged is bool:
			resolved_is_ranged = bool(source_direction_or_is_ranged)
	elif damage_type_or_source_direction is int:
		resolved_damage_type = int(
			damage_type_or_source_direction
		) as EnemyConfig.DamageType
		if source_direction_or_is_ranged is Vector2:
			source_direction = source_direction_or_is_ranged as Vector2
		elif source_direction_or_is_ranged is bool:
			resolved_is_ranged = bool(source_direction_or_is_ranged)
	var is_frost_ice_spike := source_type == FROST_SORCERER_ICE_SPIKE_TYPE
	var is_fire_slime_touch := source_type == FIRE_SLIME_TOUCH_TYPE
	var is_frost_slime_touch := source_type == FROST_SLIME_TOUCH_TYPE
	if is_frost_ice_spike:
		var authoritative_damage := (
			_projectile_coordinator.get_frost_ice_spike_record_damage(
				source_id,
				source_type
			)
		)
		if authoritative_damage <= 0:
			return false
		damage = authoritative_damage
		resolved_damage_type = EnemyConfig.DamageType.MAGIC
	elif is_fire_slime_touch or is_frost_slime_touch:
		resolved_damage_type = EnemyConfig.DamageType.MAGIC
	var impact_direction := Vector2.ZERO
	if source_direction.is_finite() and source_direction.length_squared() > 0.001:
		impact_direction = -source_direction.normalized()
	var hit_key := _get_multiplayer_player_hit_key(
		source_id,
		target_peer_id,
		source_type
	)
	var now := _get_net_time()
	var player_node := _runtime.get_player_for_peer(target_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return false
	if _is_recent_player_hit_cached(hit_key, now):
		return true
	var fire_source_bit := _get_fire_sorcerer_fireball_source_bit(source_type)
	var contact_was_consumed := false
	if fire_source_bit != 0:
		contact_was_consumed = (
			_projectile_coordinator.is_fire_sorcerer_fireball_contact_consumed(
				source_id,
				source_type
			)
			if contact_preconsumed
			else _projectile_coordinator.try_consume_fire_sorcerer_fireball_contact(
				source_id,
				source_type
			)
		)
		if not contact_was_consumed:
			return true
	elif is_frost_ice_spike:
		contact_was_consumed = (
			_projectile_coordinator.is_frost_ice_spike_contact_consumed(
				source_id,
				source_type
			)
			if contact_preconsumed
			else _projectile_coordinator.try_consume_frost_sorcerer_ice_spike_contact(
				source_id,
				source_type
			)
		)
		if not contact_was_consumed:
			return true
	if _net_manager.is_client():
		if target_peer_id != _net_manager.get_local_peer_id():
			return true
		if player_node.is_dead:
			return true
		_remember_player_hit(hit_key, now)
		return true
	if _net_manager.is_host():
		if player_node.is_dead:
			return true
		apply_player_hit_report(
			source_id,
			target_peer_id,
			damage,
			source_type,
			impact_direction,
			resolved_damage_type,
			CombatTypes.DamageFlag.RANGED if resolved_is_ranged else 0,
			contact_was_consumed
		)
		return true
	return false


func request_multiplayer_player_burn_tick(
	player_peer_id: int,
	source_family: StringName
) -> bool:
	var trusted_family := CombatAttackRegistry.get_burn_family(source_family)
	var trusted_burn_level := CombatAttackRegistry.get_burn_tick_damage(
		trusted_family
	)
	if trusted_family == &"" or trusted_burn_level <= 0:
		return false
	return request_multiplayer_player_damage_over_time_tick(
		player_peer_id,
		&"burn",
		trusted_family,
		trusted_burn_level
	)


func request_multiplayer_player_damage_over_time_tick(
	player_peer_id: int,
	status_id: StringName,
	source_family: StringName,
	tick_damage: int
) -> bool:
	if (
		not has_life_dependencies()
		or not _net_manager.is_host()
		or player_peer_id <= 0
		or source_family == &""
		or tick_damage <= 0
	):
		return false
	var damage_type := EnemyConfig.DamageType.PHYSICAL
	match status_id:
		&"burn":
			var trusted_family := CombatAttackRegistry.get_burn_family(source_family)
			var trusted_burn_level := CombatAttackRegistry.get_burn_tick_damage(
				trusted_family
			)
			if (
				trusted_family == &""
				or trusted_burn_level <= 0
				or tick_damage != trusted_burn_level
			):
				return false
			damage_type = EnemyConfig.DamageType.MAGIC
		&"bleed":
			damage_type = EnemyConfig.DamageType.PHYSICAL
		_:
			return false
	var player_node := _runtime.get_player_for_peer(player_peer_id)
	if (
		player_node == null
		or not is_instance_valid(player_node)
		or player_node.is_dead
	):
		return false
	var request := DamageRequest.new(tick_damage, int(damage_type))
	request.with_source(null, 0, source_family)
	request.flags = (
		CombatTypes.DamageFlag.PERIODIC
		| CombatTypes.DamageFlag.BYPASS_INVULNERABILITY
		| CombatTypes.DamageFlag.BYPASS_DODGE
		| CombatTypes.DamageFlag.NO_HIT_INVINCIBILITY
	)
	var result := player_node.apply_combat_damage(request)
	if not result.accepted:
		return false
	var confirmed_damage := result.applied_damage
	var confirmed_dead := result.lethal
	_show_confirmed_player_damage_number(
		player_node,
		confirmed_damage,
		Vector2.ZERO,
		damage_type
	)
	if confirmed_dead and player_node is PlayerTiyi:
		_clear_tiyi_projectiles(player_peer_id)
	var health_revision := _next_player_health_revision(player_peer_id)
	if confirmed_dead:
		schedule_player_revive(player_peer_id)
	var event_arguments := [
		player_peer_id,
		result.health_after,
		confirmed_dead,
		health_revision,
		confirmed_damage,
		Vector2.ZERO,
		int(damage_type),
		false,
	]
	life_rpc_broadcast_requested.emit(
		&"net_player_damage_applied",
		event_arguments
	)
	apply_player_damage_confirmation(
		player_peer_id,
		result.health_after,
		confirmed_dead,
		health_revision,
		confirmed_damage,
		Vector2.ZERO,
		int(damage_type),
		false
	)
	return true


func apply_luoxi_direct_health_loss(
	target_player: Player,
	amount: int,
	minimum_health: int = 0
) -> int:
	if (
		not has_life_dependencies()
		or not _net_manager.is_host()
		or target_player == null
		or not is_instance_valid(target_player)
		or target_player.peer_id <= 0
		or target_player.is_dead
		or amount <= 0
	):
		return 0
	var applied_loss := target_player.apply_direct_health_loss(
		amount,
		minimum_health
	)
	if applied_loss <= 0:
		return 0
	_show_confirmed_player_damage_number(
		target_player,
		applied_loss,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL
	)
	var confirmed_dead := target_player.is_dead
	if confirmed_dead and target_player is PlayerTiyi:
		_clear_tiyi_projectiles(target_player.peer_id)
	var health_revision := _next_player_health_revision(target_player.peer_id)
	if confirmed_dead:
		schedule_player_revive(target_player.peer_id)
	var event_arguments := [
		target_player.peer_id,
		target_player.current_health,
		confirmed_dead,
		health_revision,
		applied_loss,
		Vector2.ZERO,
		int(EnemyConfig.DamageType.PHYSICAL),
		false,
		false,
		CombatTypes.DamageRejectionReason.NONE,
	]
	life_rpc_broadcast_requested.emit(
		&"net_player_damage_applied",
		event_arguments
	)
	apply_player_damage_confirmation(
		target_player.peer_id,
		target_player.current_health,
		confirmed_dead,
		health_revision,
		applied_loss,
		Vector2.ZERO,
		int(EnemyConfig.DamageType.PHYSICAL),
		false,
		false,
		CombatTypes.DamageRejectionReason.NONE
	)
	return applied_loss


func reject_untrusted_player_hit_report(
	_sender_id: int,
	_source_id: int,
	_player_peer_id: int,
	_attack_wire_id: int,
	_impact_direction: Vector2,
	_damage_flags: int
) -> void:
	pass


func apply_player_hit_report(
	source_id: int,
	player_peer_id: int,
	damage: int,
	source_type: StringName,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	damage_flags: int,
	contact_preconsumed: bool = false
) -> DamageResult:
	var request := _build_player_damage_request(
		damage,
		int(damage_type),
		source_id,
		source_type,
		impact_direction,
		CombatTypes.has_flag(damage_flags, CombatTypes.DamageFlag.RANGED)
	)
	if not has_life_dependencies() or source_id <= 0 or player_peer_id <= 0:
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.INVALID_REQUEST
		)
	var player_node := _runtime.get_player_for_peer(player_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.TARGET_UNAVAILABLE
		)
	if damage <= 0:
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.INVALID_AMOUNT,
			player_node.current_health
		)
	var is_fire_sorcerer_fireball := (
		_get_fire_sorcerer_fireball_source_bit(source_type) != 0
	)
	var is_frost_ice_spike := source_type == FROST_SORCERER_ICE_SPIKE_TYPE
	var is_fire_slime_touch := source_type == FIRE_SLIME_TOUCH_TYPE
	var is_frost_slime_touch := source_type == FROST_SLIME_TOUCH_TYPE
	if is_frost_ice_spike:
		var authoritative_damage := (
			_projectile_coordinator.get_frost_ice_spike_record_damage(
				source_id,
				source_type
			)
		)
		if authoritative_damage <= 0:
			return DamageResult.rejected(
				request,
				CombatTypes.DamageRejectionReason.UNTRUSTED_SOURCE,
				player_node.current_health
			)
		damage = authoritative_damage
		request.amount = damage
	var hit_key := _get_multiplayer_player_hit_key(
		source_id,
		player_peer_id,
		source_type
	)
	var now := _get_net_time()
	if _is_recent_player_hit_cached(hit_key, now):
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.DUPLICATE_EVENT,
			player_node.current_health
		)
	if player_node.is_dead:
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.TARGET_DEAD,
			player_node.current_health
		)
	if is_fire_sorcerer_fireball:
		var contact_consumed := (
			_projectile_coordinator.is_fire_sorcerer_fireball_contact_consumed(
				source_id,
				source_type
			)
			if contact_preconsumed
			else _projectile_coordinator.try_consume_fire_sorcerer_fireball_contact(
				source_id,
				source_type
			)
		)
		if not contact_consumed:
			return DamageResult.rejected(
				request,
				CombatTypes.DamageRejectionReason.DUPLICATE_EVENT,
				player_node.current_health
			)
	elif is_frost_ice_spike:
		var contact_consumed := (
			_projectile_coordinator.is_frost_ice_spike_contact_consumed(
				source_id,
				source_type
			)
			if contact_preconsumed
			else _projectile_coordinator.try_consume_frost_sorcerer_ice_spike_contact(
				source_id,
				source_type
			)
		)
		if not contact_consumed:
			return DamageResult.rejected(
				request,
				CombatTypes.DamageRejectionReason.DUPLICATE_EVENT,
				player_node.current_health
			)
	_remember_player_hit(hit_key, now)
	var result := player_node.apply_combat_damage(request)
	var confirmed_dead := result.lethal
	var confirmed_damage := result.applied_damage
	var confirmed_impact_direction := Vector2.ZERO
	if impact_direction.is_finite() and impact_direction.length_squared() > 0.001:
		confirmed_impact_direction = impact_direction.normalized()
	var confirmed_damage_type := (
		EnemyConfig.DamageType.MAGIC
		if (
			is_frost_ice_spike
			or is_fire_slime_touch
			or is_frost_slime_touch
			or damage_type == EnemyConfig.DamageType.MAGIC
		)
		else EnemyConfig.DamageType.PHYSICAL
	)
	var confirmed_cold_applied := false
	if result.accepted and confirmed_damage > 0 and not confirmed_dead:
		var burn_family := CombatAttackRegistry.get_burn_family(source_type)
		var burn_level := CombatAttackRegistry.get_burn_tick_damage(burn_family)
		if burn_family != &"" and burn_level > 0:
			player_node.apply_burn_status(
				burn_family,
				CombatAttackRegistry.get_burn_duration(burn_family),
				burn_level
			)
		if CombatAttackRegistry.applies_cold(source_type):
			confirmed_cold_applied = player_node.apply_cold_status()
	_show_confirmed_player_damage_number(
		player_node,
		confirmed_damage,
		confirmed_impact_direction,
		confirmed_damage_type
	)
	if confirmed_dead and player_node is PlayerTiyi:
		_clear_tiyi_projectiles(player_peer_id)
	var health_revision := _next_player_health_revision(player_peer_id)
	if confirmed_dead:
		schedule_player_revive(player_peer_id)
	if (
		not _NetConstants.is_valid_network_combat_value(result.health_after)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_damage)
	):
		push_error("MpPlayerCoordinator: 玩家伤害结果超出网络 signed int32 契约，已拒绝发送。")
		return result
	life_rpc_broadcast_requested.emit(
		&"net_player_damage_applied",
		[
			player_peer_id,
			result.health_after,
			confirmed_dead,
			health_revision,
			confirmed_damage,
			confirmed_impact_direction,
			int(confirmed_damage_type),
			result.accepted and not confirmed_dead,
			confirmed_cold_applied,
			result.rejection_reason,
		]
	)
	apply_player_damage_confirmation(
		player_peer_id,
		result.health_after,
		confirmed_dead,
		health_revision,
		confirmed_damage,
		confirmed_impact_direction,
		int(confirmed_damage_type),
		result.accepted and not confirmed_dead,
		confirmed_cold_applied,
		result.rejection_reason
	)
	return result


func apply_player_damage_confirmation(
	player_peer_id: int,
	current_health: int,
	is_dead: bool,
	health_revision: int,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: int,
	grant_hit_invincibility: bool = true,
	apply_confirmed_cold: bool = false,
	combat_outcome: int = 0
) -> void:
	if (
		player_peer_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_damage)
		or not is_bound()
	):
		return
	var player_node := _runtime.get_player_for_peer(player_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if health_revision <= int(_player_health_revisions.get(player_peer_id, 0)):
		return
	_player_health_revisions[player_peer_id] = health_revision
	var applied_life_state := _try_apply_player_health_event(
		player_node,
		player_peer_id,
		current_health,
		is_dead,
		health_revision
	)
	if (
		combat_outcome == CombatTypes.DamageRejectionReason.DODGED
		and confirmed_damage <= 0
		and not is_dead
		and _net_manager != null
		and _net_manager.is_client()
	):
		player_node.play_confirmed_dodge_feedback()
	if apply_confirmed_cold and confirmed_damage > 0 and not is_dead:
		player_node.apply_cold_status()
	_show_confirmed_player_damage_number(
		player_node,
		clampi(confirmed_damage, 0, player_node.max_health),
		impact_direction.normalized()
		if impact_direction.is_finite() and impact_direction.length_squared() > 0.001
		else Vector2.ZERO,
		EnemyConfig.DamageType.MAGIC
		if damage_type == EnemyConfig.DamageType.MAGIC
		else EnemyConfig.DamageType.PHYSICAL
	)
	if is_dead and applied_life_state and player_node is PlayerTiyi:
		_clear_tiyi_lifecycle_state_callable.call(player_peer_id)
		_clear_tiyi_projectiles(player_peer_id)
	if (
		grant_hit_invincibility
		and applied_life_state
		and int(_runtime.runtime_mode) == GAME_RUNTIME_CLIENT_VIEW
		and player_peer_id == _get_client_view_local_peer_id()
		and not player_node.is_dead
		and player_node.current_health < player_node.max_health
	):
		player_node.start_multiplayer_invincibility(
			player_node.invincibility_duration
		)


func _show_confirmed_player_damage_number(
	player_node: Player,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> void:
	if (
		not is_bound()
		or player_node == null
		or not is_instance_valid(player_node)
		or confirmed_damage <= 0
	):
		return
	_runtime.show_damage_number(
		confirmed_damage,
		player_node.global_position,
		impact_direction,
		damage_type,
		DamageNumberPool.DisplayPriority.IMPORTANT
	)


func apply_multiplayer_player_heal(
	target_player: Player,
	heal_amount: int
) -> bool:
	if (
		not has_life_dependencies()
		or not _net_manager.is_host()
		or target_player == null
		or not is_instance_valid(target_player)
		or heal_amount <= 0
		or target_player.peer_id <= 0
	):
		return false
	if not target_player._try_heal(heal_amount, false):
		return false
	report_multiplayer_player_healing(
		target_player,
		target_player.last_healing_received
	)
	return true


func report_multiplayer_player_healing(
	target_player: Player,
	confirmed_healing: int
) -> void:
	if (
		not has_life_dependencies()
		or not _net_manager.is_host()
		or target_player == null
		or not is_instance_valid(target_player)
		or confirmed_healing <= 0
		or target_player.peer_id <= 0
		or target_player.is_dead
	):
		return
	var health_revision := _next_player_health_revision(target_player.peer_id)
	if (
		not _NetConstants.is_valid_network_combat_value(target_player.current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_healing)
	):
		push_error("MpPlayerCoordinator: 玩家治疗结果超出网络 signed int32 契约，已拒绝发送。")
		return
	target_player.queue_healing_number(confirmed_healing)
	life_rpc_broadcast_requested.emit(
		&"net_player_healed",
		[
			target_player.peer_id,
			target_player.current_health,
			health_revision,
			confirmed_healing,
		]
	)


func apply_player_heal_confirmation(
	peer_id: int,
	current_health: int,
	health_revision: int,
	confirmed_healing: int
) -> void:
	if (
		peer_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_healing)
		or not is_bound()
	):
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if health_revision <= int(_player_health_revisions.get(peer_id, 0)):
		return
	if player_node.is_dead:
		return
	_player_health_revisions[peer_id] = health_revision
	_try_apply_player_health_event(
		player_node,
		peer_id,
		current_health,
		false,
		health_revision
	)
	player_node.queue_healing_number(confirmed_healing)


func apply_authoritative_player_heal(
	target_player: Player,
	heal_amount: int
) -> bool:
	return apply_multiplayer_player_heal(target_player, heal_amount)


func schedule_player_revive(peer_id: int) -> void:
	if peer_id <= 0:
		return
	if _cancel_tango_for_revive_schedule_callable.is_valid():
		_cancel_tango_for_revive_schedule_callable.call(peer_id)
	if (
		not has_life_dependencies()
		or not _mode_adapter.allows_player_respawn(peer_id)
		or _dead_player_revive_times.has(peer_id)
		or _mode_adapter.is_terminal_combat_state()
	):
		return
	erase_latest_client_state(peer_id)
	var revive_delay := _mode_adapter.consume_next_player_respawn_delay(peer_id)
	revive_delay = maxf(revive_delay, 0.0)
	_dead_player_revive_times[peer_id] = _get_net_time() + revive_delay
	_dead_player_revive_last_seconds[peer_id] = -1
	var seconds_left := int(ceil(revive_delay))
	life_rpc_broadcast_requested.emit(
		&"net_player_revive_countdown",
		[peer_id, seconds_left]
	)
	apply_player_revive_countdown(peer_id, seconds_left)


func update_player_revives() -> void:
	if (
		not has_life_dependencies()
		or not _net_manager.is_host()
		or _mode_adapter.is_terminal_combat_state()
	):
		return
	var now := _get_net_time()
	var due_peers: Array[int] = []
	var disallowed_peers: Array[int] = []
	for peer_id_variant in _dead_player_revive_times:
		var peer_id := int(peer_id_variant)
		if not _mode_adapter.allows_player_respawn(peer_id):
			disallowed_peers.append(peer_id)
			continue
		var revive_at := float(_dead_player_revive_times[peer_id])
		var seconds_left := maxi(ceili(revive_at - now), 0)
		if seconds_left != int(
			_dead_player_revive_last_seconds.get(peer_id, -1)
		):
			_dead_player_revive_last_seconds[peer_id] = seconds_left
			life_rpc_broadcast_requested.emit(
				&"net_player_revive_countdown",
				[peer_id, seconds_left]
			)
			apply_player_revive_countdown(peer_id, seconds_left)
		if now >= revive_at:
			due_peers.append(peer_id)
	for peer_id in disallowed_peers:
		_dead_player_revive_times.erase(peer_id)
		_dead_player_revive_last_seconds.erase(peer_id)
		_mode_adapter.clear_player_respawn_countdown(peer_id)
	if due_peers.is_empty():
		return
	var revive_positions := _collect_living_player_revive_positions()
	for peer_id in due_peers:
		var revive_position: Variant = _resolve_multiplayer_revive_position(
			peer_id,
			revive_positions
		)
		if revive_position is Vector2:
			_revive_player_peer(peer_id, revive_position as Vector2)


func revive_all_players() -> void:
	if not has_life_dependencies() or not _net_manager.is_host():
		return
	clear_pending_revives()
	var revive_positions := _collect_living_player_revive_positions()
	for peer_id_variant in _runtime.peer_players:
		var peer_id := int(peer_id_variant)
		if not _mode_adapter.allows_player_respawn(peer_id):
			continue
		var player_node := _runtime.peer_players[peer_id_variant] as Player
		if (
			player_node == null
			or not is_instance_valid(player_node)
			or not player_node.is_dead
		):
			continue
		var revive_position: Variant = _resolve_multiplayer_revive_position(
			peer_id,
			revive_positions
		)
		if revive_position is Vector2:
			_revive_player_peer(peer_id, revive_position as Vector2)


func apply_player_revive_countdown(peer_id: int, seconds_left: int) -> void:
	if not is_bound() or peer_id <= 0:
		return
	if _mode_adapter == null or not _mode_adapter.allows_player_respawn(peer_id):
		if _mode_adapter != null:
			_mode_adapter.clear_player_respawn_countdown(peer_id)
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if _mode_adapter is TowerDefenseMultiplayerModeAdapter:
		_mode_adapter.update_player_respawn_countdown(peer_id, seconds_left)
	else:
		player_node.set_multiplayer_revive_countdown(seconds_left)


func apply_player_revived(
	peer_id: int,
	revive_position: Vector2,
	current_health: int,
	invincible_seconds: float,
	health_revision: int
) -> void:
	if (
		peer_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not is_bound()
		or _mode_adapter == null
		or not _mode_adapter.allows_player_respawn(peer_id)
	):
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if health_revision <= int(_player_health_revisions.get(peer_id, 0)):
		return
	_player_health_revisions[peer_id] = health_revision
	mark_health_revision_applied(peer_id, health_revision)
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	_clear_tiyi_lifecycle_state_callable.call(peer_id)
	player_node.revive_multiplayer(
		revive_position,
		current_health,
		invincible_seconds
	)
	_mode_adapter.clear_player_respawn_countdown(peer_id)
	if (
		int(_runtime.runtime_mode) == GAME_RUNTIME_CLIENT_VIEW
		and peer_id != _get_client_view_local_peer_id()
	):
		reset_visual_interpolator_to_state(
			peer_id,
			revive_position,
			Vector2.ZERO,
			player_node.get_multiplayer_facing_id(),
			player_node.get_multiplayer_anim_state(),
			_get_net_time()
		)


func clear_pending_revives() -> void:
	_dead_player_revive_times.clear()
	_dead_player_revive_last_seconds.clear()


func get_health_revisions_for_snapshot() -> Dictionary:
	return _player_health_revisions


func get_health_revision(peer_id: int) -> int:
	return int(_player_health_revisions.get(peer_id, 0))


func has_pending_revive(peer_id: int) -> bool:
	return _dead_player_revive_times.has(peer_id)


func capture_reconnect_life_state(peer_id: int) -> Dictionary:
	return {
		"revive_at": float(_dead_player_revive_times.get(peer_id, -1.0)),
		"revive_last_seconds": int(
			_dead_player_revive_last_seconds.get(peer_id, -1)
		),
		"health_revision": get_health_revision(peer_id),
		"applied_health_revision": get_applied_health_revision(peer_id),
	}


func restore_reconnect_life_state(
	peer_id: int,
	reconnect_state: Dictionary,
	is_host: bool
) -> void:
	if peer_id <= 0:
		return
	_player_health_revisions[peer_id] = int(
		reconnect_state.get("health_revision", 0)
	)
	set_applied_health_revision(
		peer_id,
		int(reconnect_state.get("applied_health_revision", 0))
	)
	var revive_at := float(reconnect_state.get("revive_at", -1.0))
	if (
		is_host
		and revive_at >= 0.0
		and _mode_adapter != null
		and _mode_adapter.allows_player_respawn(peer_id)
	):
		_dead_player_revive_times[peer_id] = revive_at
		_dead_player_revive_last_seconds[peer_id] = int(
			reconnect_state.get("revive_last_seconds", -1)
		)


func prune_recent_player_hit_events(now: float) -> void:
	var expired_keys: Array = []
	for key in _processed_player_hit_ids:
		if float(_processed_player_hit_ids[key]) <= now:
			expired_keys.append(key)
	for key in expired_keys:
		_processed_player_hit_ids.erase(key)


func _revive_player_peer(peer_id: int, revive_position: Vector2) -> void:
	if (
		not has_life_dependencies()
		or peer_id <= 0
		or not _mode_adapter.allows_player_respawn(peer_id)
	):
		_dead_player_revive_times.erase(peer_id)
		_dead_player_revive_last_seconds.erase(peer_id)
		if _mode_adapter != null:
			_mode_adapter.clear_player_respawn_countdown(peer_id)
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	_cancel_actions_for_revive_callable.call(peer_id)
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	var now := _get_net_time()
	_commit_revive_position_callable.call(peer_id, revive_position, now)
	var health_revision := _next_player_health_revision(peer_id)
	player_node.revive_multiplayer(
		revive_position,
		player_node.max_health,
		PLAYER_REVIVE_INVINCIBILITY_SECONDS
	)
	if (
		not _NetConstants.is_valid_network_combat_value(player_node.current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
	):
		push_error("MpPlayerCoordinator: 玩家复活生命值超出网络 signed int32 契约，已拒绝发送。")
		return
	var host_peer_id := _net_manager.get_host_peer_id()
	if peer_id != host_peer_id:
		remember_latest_client_state(
			true,
			peer_id,
			revive_position,
			Vector2.ZERO,
			player_node.get_multiplayer_facing_id(),
			player_node.get_multiplayer_anim_state()
		)
		player_state_correction_requested.emit(
			peer_id,
			revive_position,
			Vector2.ZERO
		)
	life_rpc_broadcast_requested.emit(
		&"net_player_revived",
		[
			peer_id,
			revive_position,
			player_node.current_health,
			PLAYER_REVIVE_INVINCIBILITY_SECONDS,
			health_revision,
		]
	)
	apply_player_revived(
		peer_id,
		revive_position,
		player_node.current_health,
		PLAYER_REVIVE_INVINCIBILITY_SECONDS,
		health_revision
	)


func _collect_living_player_revive_positions() -> Array[Vector2]:
	var positions: Array[Vector2] = []
	if not is_bound():
		return positions
	for peer_id_variant in _runtime.peer_players:
		var peer_id := int(peer_id_variant)
		var player_node := _runtime.peer_players[peer_id_variant] as Player
		if (
			player_node == null
			or not is_instance_valid(player_node)
			or player_node.is_dead
		):
			continue
		var anchor: Variant = _get_revive_anchor_position_callable.call(
			peer_id,
			player_node
		)
		positions.append(
			anchor as Vector2 if anchor is Vector2 else player_node.global_position
		)
	return positions


func _pick_multiplayer_revive_position(
	revive_positions: Array[Vector2]
) -> Vector2:
	if revive_positions.is_empty():
		return Vector2.ZERO
	return revive_positions[
		_revive_random_generator.randi_range(0, revive_positions.size() - 1)
	]


func _resolve_multiplayer_revive_position(
	peer_id: int,
	living_player_positions: Array[Vector2]
) -> Variant:
	if (
		not has_life_dependencies()
		or peer_id <= 0
		or not _mode_adapter.allows_player_respawn(peer_id)
	):
		return null
	var fixed_position: Variant = (
		_mode_adapter.get_fixed_multiplayer_respawn_position(peer_id)
	)
	if fixed_position is Vector2:
		return fixed_position
	if living_player_positions.is_empty():
		return null
	return _pick_multiplayer_revive_position(living_player_positions)


func _build_player_damage_request(
	damage: int,
	damage_type: int,
	source_id: int,
	source_type: StringName,
	impact_direction: Vector2,
	is_ranged: bool
) -> DamageRequest:
	var request := DamageRequest.new(damage, damage_type)
	request.with_source(null, source_id, source_type)
	request.with_directions(impact_direction, -impact_direction)
	request.with_flag(CombatTypes.DamageFlag.RANGED, is_ranged)
	return request


func _next_player_health_revision(peer_id: int) -> int:
	var next_revision := int(_player_health_revisions.get(peer_id, 0)) + 1
	_player_health_revisions[peer_id] = next_revision
	mark_health_revision_applied(peer_id, next_revision)
	return next_revision


func _try_apply_player_health_event(
	player_node: Player,
	peer_id: int,
	current_health: int,
	is_dead: bool,
	health_revision: int
) -> bool:
	if (
		player_node == null
		or peer_id <= 0
		or health_revision < get_applied_health_revision(peer_id)
	):
		return false
	player_node.set_multiplayer_health_state(current_health, is_dead)
	mark_health_revision_applied(peer_id, health_revision)
	return true


func _get_multiplayer_player_hit_key(
	source_id: int,
	target_peer_id: int,
	source_type: StringName
) -> String:
	if (
		_get_fire_sorcerer_fireball_source_bit(source_type) != 0
		or source_type == FROST_SORCERER_ICE_SPIKE_TYPE
	):
		return "%d:%s" % [source_id, String(source_type)]
	return "%d:%d:%s" % [source_id, target_peer_id, String(source_type)]


func _get_fire_sorcerer_fireball_source_bit(source_type: StringName) -> int:
	match source_type:
		&"fire_sorcerer_fireball_a", \
		&"fire_sorcerer_elite_fireball_a":
			return 1
		&"fire_sorcerer_fireball_b", \
		&"fire_sorcerer_elite_fireball_b":
			return 2
		&"fire_sorcerer_fireball_c", \
		&"fire_sorcerer_elite_fireball_c":
			return 4
		_:
			return 0


func _is_recent_player_hit_cached(hit_key: String, now: float) -> bool:
	var expires_at_variant: Variant = _processed_player_hit_ids.get(hit_key)
	if expires_at_variant == null:
		return false
	var expires_at := float(expires_at_variant)
	if expires_at > now:
		return true
	_processed_player_hit_ids.erase(hit_key)
	return false


func _remember_player_hit(hit_key: String, now: float) -> void:
	_processed_player_hit_ids[hit_key] = now + HIT_DEDUP_RETENTION_SECONDS


func _clear_tiyi_projectiles(peer_id: int) -> void:
	_projectile_coordinator.clear_projectiles_for_peer(peer_id)
	_projectile_coordinator.clear_projectile_records_for_peer(peer_id)


func _get_client_view_local_peer_id() -> int:
	if _net_manager != null:
		var local_peer_id := _net_manager.get_local_peer_id()
		if local_peer_id > 0:
			return local_peer_id
	return int(_runtime.multiplayer_local_peer_id) if is_bound() else 0


func _get_net_time() -> float:
	if not _get_net_time_callable.is_valid():
		return 0.0
	return float(_get_net_time_callable.call())


func _clear_life_dependencies() -> void:
	_net_manager = null
	_mode_adapter = null
	_projectile_coordinator = null
	_get_net_time_callable = Callable()
	_cancel_tango_for_revive_schedule_callable = Callable()
	_cancel_actions_for_revive_callable = Callable()
	_clear_tiyi_lifecycle_state_callable = Callable()
	_get_revive_anchor_position_callable = Callable()
	_commit_revive_position_callable = Callable()


func sync_snapshot_cohort_readiness(ready_peer_ids: Array[int]) -> void:
	var ready_lookup: Dictionary[int, bool] = {}
	for peer_id in ready_peer_ids:
		if peer_id > 0:
			ready_lookup[peer_id] = true
	for peer_id_variant in _snapshot_cohort_peers.keys():
		var peer_id := int(peer_id_variant)
		if ready_lookup.has(peer_id):
			continue
		_snapshot_cohort_peers.erase(peer_id)
		_last_keyframe_time_by_peer.erase(peer_id)
	if _snapshot_cohort_peers.is_empty():
		_snapshot_manager.clear_player_send_baseline(SHARED_SNAPSHOT_COHORT_ID)


func build_host_snapshot_batch(
	states: Array[SnapshotManager.PlayerState],
	ready_peer_ids: Array[int],
	host_timestamp: float,
	health_revisions: Dictionary
) -> HostSnapshotBatch:
	if not is_bound() or ready_peer_ids.is_empty() or states.is_empty():
		return null
	_apply_latest_client_states(states)
	_host_snapshot_sequence += 1
	for state in states:
		if state == null:
			continue
		state.sequence = _host_snapshot_sequence
		state.health_revision = int(health_revisions.get(state.peer_id, 0))
	var force_keyframe := _snapshot_cohort_requires_keyframe(
		ready_peer_ids,
		host_timestamp
	)
	var data := _snapshot_manager.encode_player_snapshots_for_cohort(
		SHARED_SNAPSHOT_COHORT_ID,
		states,
		force_keyframe
	)
	if data.is_empty():
		return null
	_snapshot_encode_count += 1
	_commit_snapshot_cohort_send(
		ready_peer_ids,
		host_timestamp,
		force_keyframe
	)
	var batch := HostSnapshotBatch.new()
	batch.peer_ids.assign(ready_peer_ids)
	batch.host_timestamp = host_timestamp
	batch.data = data
	batch.entity_count = states.size()
	return batch


func apply_authoritative_snapshot(
	snapshot_time: float,
	data: PackedByteArray,
	local_peer_id: int,
	local_tango_prediction_active: bool
) -> PackedInt32Array:
	var stale_peer_ids := PackedInt32Array()
	if not is_bound() or int(_runtime.runtime_mode) != GAME_RUNTIME_CLIENT_VIEW:
		return stale_peer_ids
	var states := _snapshot_manager.decode_player_snapshots_with_baseline(data)
	var snapshot_has_full_roster := _is_complete_snapshot_batch(data, states.size())
	var seen_player_ids: Dictionary[int, bool] = {}
	for state in states:
		var player_state := state as SnapshotManager.PlayerState
		if player_state == null or player_state.peer_id <= 0:
			continue
		seen_player_ids[player_state.peer_id] = true
		var player_node := _runtime.get_player_for_peer(player_state.peer_id)
		if player_node != null and is_instance_valid(player_node):
			try_apply_pending_authoritative_teleport(
				player_state.peer_id,
				local_peer_id,
				snapshot_time
			)
			player_node = _runtime.get_player_for_peer(player_state.peer_id)
		var accept_motion := accept_snapshot_motion_after_teleport(
			player_state.peer_id,
			player_state.sequence
		)
		if player_node != null and is_instance_valid(player_node):
			if player_node.get_character_id() != player_state.character_id:
				_warn_character_snapshot_mismatch(
					player_state.peer_id,
					player_node.get_character_id(),
					player_state.character_id
				)
				continue
			_apply_primary_cooldown_ratio(
				player_node,
				player_state.primary_cooldown_ratio,
				player_state.facing,
				player_state.peer_id == local_peer_id
				and local_tango_prediction_active
			)
		if player_state.peer_id == local_peer_id:
			_apply_realtime_snapshot(player_node, player_state)
			continue
		if not accept_motion:
			_apply_realtime_snapshot(player_node, player_state)
			continue
		var interpolator := _visual_interpolators.get(
			player_state.peer_id
		) as NetInterpolator
		if interpolator == null:
			interpolator = _create_interpolator()
			_visual_interpolators[player_state.peer_id] = interpolator
		interpolator.push_snapshot(
			snapshot_time,
			player_state.position,
			player_state.velocity,
			player_state.facing,
			player_state.anim_state,
			0,
			false
		)
		_apply_realtime_snapshot(player_node, player_state)
	if not snapshot_has_full_roster or seen_player_ids.is_empty():
		return stale_peer_ids
	var resolved_local_peer_id := local_peer_id
	if resolved_local_peer_id <= 0:
		resolved_local_peer_id = _runtime.multiplayer_local_peer_id
	for peer_id_variant in _runtime.peer_players.keys():
		var peer_id := int(peer_id_variant)
		if peer_id == resolved_local_peer_id or seen_player_ids.has(peer_id):
			continue
		stale_peer_ids.append(peer_id)
	return stale_peer_ids


func interpolate_remote_players(current_time: float, local_peer_id: int) -> void:
	if not is_bound() or int(_runtime.runtime_mode) != GAME_RUNTIME_CLIENT_VIEW:
		return
	for peer_id_variant in _visual_interpolators:
		var peer_id := int(peer_id_variant)
		if peer_id == local_peer_id:
			continue
		var interpolator := _visual_interpolators.get(peer_id) as NetInterpolator
		var player_node := _runtime.get_player_for_peer(peer_id)
		if interpolator == null or player_node == null or not is_instance_valid(player_node):
			continue
		var frame_state := interpolator.get_current_state(current_time)
		player_node.apply_multiplayer_snapshot_motion(
			interpolator.get_interpolated_position(current_time),
			interpolator.get_interpolated_velocity(current_time),
			frame_state.facing,
			frame_state.anim_state
		)


func remember_latest_client_state(
	is_host: bool,
	peer_id: int,
	player_position: Vector2,
	player_velocity: Vector2,
	facing_id: int,
	anim_state: int
) -> void:
	if not is_host or peer_id <= 0:
		return
	_latest_client_states[peer_id] = {
		"position": player_position,
		"velocity": player_velocity,
		"facing": facing_id,
		"anim_state": anim_state,
	}


func erase_latest_client_state(peer_id: int) -> void:
	_latest_client_states.erase(peer_id)


func has_latest_client_state(peer_id: int) -> bool:
	return _latest_client_states.has(peer_id)


func get_latest_client_state(peer_id: int) -> Dictionary:
	return (_latest_client_states.get(peer_id, {}) as Dictionary).duplicate(true)


func queue_authoritative_teleport(
	peer_id: int,
	target_position: Vector2,
	snapshot_sequence_cutoff: int,
	local_peer_id: int,
	snapshot_time: float
) -> bool:
	if (
		peer_id <= 0
		or snapshot_sequence_cutoff < 0
		or not _is_finite_vector2(target_position)
	):
		return false
	_teleport_cutoff_sequences[peer_id] = maxi(
		snapshot_sequence_cutoff,
		int(_teleport_cutoff_sequences.get(peer_id, -1))
	)
	_pending_authoritative_teleports[peer_id] = {
		"position": target_position,
		"snapshot_sequence_cutoff": snapshot_sequence_cutoff,
	}
	try_apply_pending_authoritative_teleport(
		peer_id,
		local_peer_id,
		snapshot_time
	)
	return true


func try_apply_pending_authoritative_teleport(
	peer_id: int,
	local_peer_id: int,
	snapshot_time: float
) -> bool:
	if not is_bound() or peer_id <= 0:
		return false
	var pending := _pending_authoritative_teleports.get(peer_id, {}) as Dictionary
	if pending.is_empty():
		return false
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return false
	var target_position := pending.get("position", Vector2.ZERO) as Vector2
	apply_authoritative_teleport_to_player(player_node, target_position)
	if int(_runtime.runtime_mode) == GAME_RUNTIME_CLIENT_VIEW and peer_id != local_peer_id:
		reset_visual_interpolator_to_state(
			peer_id,
			target_position,
			Vector2.ZERO,
			player_node.get_multiplayer_facing_id(),
			player_node.get_multiplayer_anim_state(),
			snapshot_time
		)
	_pending_authoritative_teleports.erase(peer_id)
	return true


func accept_snapshot_motion_after_teleport(
	peer_id: int,
	snapshot_sequence: int
) -> bool:
	var cutoff := int(_teleport_cutoff_sequences.get(peer_id, -1))
	if cutoff < 0:
		return true
	if snapshot_sequence <= cutoff:
		return false
	_teleport_cutoff_sequences.erase(peer_id)
	return true


func reset_visual_interpolator_to_state(
	peer_id: int,
	player_position: Vector2,
	player_velocity: Vector2,
	facing_id: int,
	anim_state: int,
	snapshot_time: float
) -> void:
	if peer_id <= 0:
		return
	var interpolator := _visual_interpolators.get(peer_id) as NetInterpolator
	if interpolator == null:
		interpolator = _create_interpolator()
		_visual_interpolators[peer_id] = interpolator
	interpolator.clear()
	interpolator.push_snapshot(
		snapshot_time,
		player_position,
		player_velocity,
		facing_id,
		anim_state,
		0,
		false
	)


func apply_authoritative_teleport_to_player(
	player_node: Player,
	target_position: Vector2
) -> bool:
	if (
		player_node == null
		or not is_instance_valid(player_node)
		or not _is_finite_vector2(target_position)
	):
		return false
	var smoothing_was_enabled := player_node.is_multiplayer_visual_smoothing_enabled()
	if smoothing_was_enabled:
		player_node.set_multiplayer_visual_smoothing_enabled(false)
	player_node.global_position = target_position
	player_node.velocity = Vector2.ZERO
	player_node.reset_physics_interpolation()
	if smoothing_was_enabled:
		player_node.set_multiplayer_visual_smoothing_enabled(true)
	return true


func apply_local_state_correction(
	corrected_position: Vector2,
	corrected_velocity: Vector2
) -> void:
	if not is_bound() or _runtime.player == null:
		return
	_runtime.player.global_position = corrected_position
	_runtime.player.velocity = corrected_velocity


func restore_reconnected_player_snapshot(
	player_node: Player,
	player_state: SnapshotManager.PlayerState,
	snapshot_time: float,
	is_host: bool,
	local_peer_id: int,
	local_tango_prediction_active: bool
) -> void:
	if player_node == null or player_state == null or not is_instance_valid(player_node):
		return
	player_node.apply_multiplayer_snapshot_motion(
		player_state.position,
		player_state.velocity,
		player_state.facing,
		player_state.anim_state
	)
	_apply_primary_cooldown_ratio(
		player_node,
		player_state.primary_cooldown_ratio,
		player_state.facing,
		player_state.peer_id == local_peer_id and local_tango_prediction_active
	)
	_apply_realtime_snapshot(player_node, player_state)
	if is_host:
		remember_latest_client_state(
			true,
			player_state.peer_id,
			player_state.position,
			player_state.velocity,
			player_state.facing,
			player_state.anim_state
		)
	else:
		reset_visual_interpolator_to_state(
			player_state.peer_id,
			player_state.position,
			player_state.velocity,
			player_state.facing,
			player_state.anim_state,
			snapshot_time
		)


func get_host_snapshot_sequence() -> int:
	return _host_snapshot_sequence


func get_snapshot_encode_count() -> int:
	return _snapshot_encode_count


func get_snapshot_cohort_size() -> int:
	return _snapshot_cohort_peers.size()


func get_applied_health_revision(peer_id: int) -> int:
	return int(_applied_health_revisions.get(peer_id, 0))


func set_applied_health_revision(peer_id: int, health_revision: int) -> void:
	if peer_id <= 0 or health_revision < 0:
		return
	_applied_health_revisions[peer_id] = health_revision


func mark_health_revision_applied(peer_id: int, health_revision: int) -> void:
	if peer_id <= 0 or health_revision < 0:
		return
	_applied_health_revisions[peer_id] = maxi(
		get_applied_health_revision(peer_id),
		health_revision
	)


func get_visual_interpolator(peer_id: int) -> NetInterpolator:
	return _visual_interpolators.get(peer_id) as NetInterpolator


func has_visual_interpolator(peer_id: int) -> bool:
	return _visual_interpolators.has(peer_id)


func get_visual_interpolator_count() -> int:
	return _visual_interpolators.size()


func has_pending_authoritative_teleport(peer_id: int) -> bool:
	return _pending_authoritative_teleports.has(peer_id)


func clear_peer(peer_id: int) -> void:
	if peer_id <= 0:
		return
	_snapshot_manager.clear_peer_delta_cache(peer_id)
	_snapshot_cohort_peers.erase(peer_id)
	_last_keyframe_time_by_peer.erase(peer_id)
	if _snapshot_cohort_peers.is_empty():
		_snapshot_manager.clear_player_send_baseline(SHARED_SNAPSHOT_COHORT_ID)
	_visual_interpolators.erase(peer_id)
	_teleport_cutoff_sequences.erase(peer_id)
	_pending_authoritative_teleports.erase(peer_id)
	_character_mismatch_warnings.erase(peer_id)
	_latest_client_states.erase(peer_id)
	_applied_health_revisions.erase(peer_id)
	_player_health_revisions.erase(peer_id)
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)


func reset_session_state() -> void:
	_snapshot_manager.reset_delta_cache()
	_visual_interpolators.clear()
	_teleport_cutoff_sequences.clear()
	_pending_authoritative_teleports.clear()
	_character_mismatch_warnings.clear()
	_latest_client_states.clear()
	_applied_health_revisions.clear()
	_last_keyframe_time_by_peer.clear()
	_snapshot_cohort_peers.clear()
	_processed_player_hit_ids.clear()
	_player_health_revisions.clear()
	_dead_player_revive_times.clear()
	_dead_player_revive_last_seconds.clear()
	_host_snapshot_sequence = 0
	_snapshot_encode_count = 0


func _apply_latest_client_states(states: Array[SnapshotManager.PlayerState]) -> void:
	if _latest_client_states.is_empty():
		return
	for state in states:
		if state == null or state.is_dead:
			continue
		var latest := _latest_client_states.get(state.peer_id, {}) as Dictionary
		if latest.is_empty():
			continue
		state.position = latest.get("position", state.position) as Vector2
		state.velocity = latest.get("velocity", state.velocity) as Vector2
		state.facing = int(latest.get("facing", state.facing))
		state.anim_state = int(latest.get("anim_state", state.anim_state))


func _snapshot_cohort_requires_keyframe(
	ready_peer_ids: Array[int],
	snapshot_time: float
) -> bool:
	if ready_peer_ids.is_empty():
		return false
	if _snapshot_cohort_peers.size() != ready_peer_ids.size():
		return true
	for peer_id in ready_peer_ids:
		if (
			not _snapshot_cohort_peers.has(peer_id)
			or not _last_keyframe_time_by_peer.has(peer_id)
		):
			return true
		var last_keyframe_time := float(
			_last_keyframe_time_by_peer.get(peer_id, -INF)
		)
		if snapshot_time - last_keyframe_time >= PLAYER_DELTA_KEYFRAME_INTERVAL_SECONDS:
			return true
	return false


func _commit_snapshot_cohort_send(
	ready_peer_ids: Array[int],
	snapshot_time: float,
	was_keyframe: bool
) -> void:
	_snapshot_cohort_peers.clear()
	for peer_id in ready_peer_ids:
		if peer_id <= 0:
			continue
		_snapshot_cohort_peers[peer_id] = true
		if was_keyframe:
			_last_keyframe_time_by_peer[peer_id] = snapshot_time


func _apply_primary_cooldown_ratio(
	player_node: Player,
	ratio: float,
	facing_id: int,
	suppress_local_tango_snapshot: bool
) -> void:
	if player_node == null or not is_instance_valid(player_node):
		return
	var tango_player := player_node as PlayerTango
	if tango_player != null:
		if suppress_local_tango_snapshot:
			return
		tango_player.apply_multiplayer_tango_charge_snapshot(
			clampf(ratio, 0.0, 1.0),
			facing_id
		)
		return
	player_node.apply_multiplayer_primary_cooldown_ratio(clampf(ratio, 0.0, 1.0))


func _apply_realtime_snapshot(
	player_node: Player,
	player_state: SnapshotManager.PlayerState
) -> void:
	if player_node == null or player_state == null or not is_instance_valid(player_node):
		return
	var apply_snapshot_health := (
		player_state.health_revision
		>= get_applied_health_revision(player_state.peer_id)
	)
	player_node.apply_multiplayer_realtime_state(
		player_state.current_health if apply_snapshot_health else player_node.current_health,
		player_state.max_health if apply_snapshot_health else player_node.max_health,
		player_state.current_xirang,
		player_state.is_dead if apply_snapshot_health else player_node.is_dead,
		(
			player_state.invincibility_time_left
			if apply_snapshot_health
			else player_node.invincibility_time_left
		),
		player_state.skill1_unlocked,
		player_state.skill1_charge,
		player_state.skill1_charge_duration,
		player_state.form_mode,
		player_state.shot_pattern,
		player_state.skill1_upgrade_level,
		player_state.ammo_capacity,
		player_state.current_ammo,
		player_state.is_reloading,
		player_state.reload_progress
	)
	player_node.apply_multiplayer_effective_move_speed_multiplier(
		player_state.effective_move_speed_multiplier
	)
	if apply_snapshot_health:
		mark_health_revision_applied(
			player_state.peer_id,
			player_state.health_revision
		)


func _warn_character_snapshot_mismatch(
	peer_id: int,
	local_character_id: StringName,
	host_character_id: StringName
) -> void:
	if _character_mismatch_warnings.has(peer_id):
		return
	_character_mismatch_warnings[peer_id] = true
	push_warning(
		"MpPlayerCoordinator: peer %d 角色不一致 local=%s host=%s，忽略该角色快照。"
		% [peer_id, local_character_id, host_character_id]
	)


func _is_complete_snapshot_batch(data: PackedByteArray, decoded_count: int) -> bool:
	if data.is_empty():
		return false
	var expected_count := int(data[0])
	return expected_count > 0 and decoded_count == expected_count


func _create_interpolator() -> NetInterpolator:
	return NetInterpolator.new(
		1.0 / float(_NetConstants.PLAYER_SNAPSHOT_HZ),
		_NetConstants.PLAYER_INTERPOLATION_DELAY_FACTOR,
		_NetConstants.PLAYER_MAX_EXTRAPOLATION_SECONDS
	)


func _is_finite_vector2(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)
