extends Node
class_name EnemySimulationCoordinator

const EnemyCombatServicesScript := preload(
	"res://scene/combat/simulation/enemy_combat_services.gd"
)

## Stable, authority-agnostic owner for the staged enemy simulation handoff.
## The caller owns runtime authority checks and the atomic transition of an
## Enemy's per-node physics callback. This coordinator only owns registrations
## and invokes the explicit scheduled simulation entry point.

const INVALID_TOKEN := 0
const INVALID_SIMULATION_ID := 0
const TOMBSTONE_COMPACTION_MINIMUM := 64
const TOMBSTONE_COMPACTION_RATIO_DIVISOR := 3


class Registration:
	extends RefCounted

	var enemy: Enemy
	var instance_id: int
	var simulation_id: int
	var token: int
	var activation_physics_frame: int
	var next_decision_tick := 0
	var active_this_tick := false
	var suspended := false
	var tombstone := false
	var contact_proxy_registered := false
	var contact_faction_id := CombatRelationService.NEUTRAL
	var contact_shape_revision := -1
	var contact_attacker_proxy: CombatContactShapeProxy = null
	var contact_body_proxy: CombatContactShapeProxy = null
	var contact_attacker_shape_resource_id := 0
	var contact_body_shape_resource_id := 0


	func _init(
		registered_enemy: Enemy,
		registered_simulation_id: int,
		registered_token: int,
		registered_physics_frame: int
	) -> void:
		enemy = registered_enemy
		instance_id = registered_enemy.get_instance_id()
		simulation_id = registered_simulation_id
		token = registered_token
		activation_physics_frame = registered_physics_frame


var _mode: EnemySimulationPolicy.Mode = EnemySimulationPolicy.Mode.LEGACY

@export var mode: EnemySimulationPolicy.Mode = EnemySimulationPolicy.Mode.LEGACY:
	set(value):
		set_mode(value)
	get:
		return _mode

var _registrations: Array[Registration] = []
var _registration_by_instance_id: Dictionary[int, Registration] = {}
var _next_simulation_id := 1
var _next_token := 1
var _registered_count := 0
var _suspended_count := 0
var _tombstone_count := 0
var _simulation_tick := 0
var _is_advancing := false
var _clear_requested := false
var _pending_mode := -1
var _contact_geometry_sync_failed_this_tick := false
var _contact_service: EnemyContactService = null
var _combat_target_index: CombatTargetIndex = null
var _combat_relation_service: CombatRelationService = null
var _contact_index_candidate_buffer: Array[Enemy] = []

var _metric_registration_count := 0
var _metric_idempotent_registration_count := 0
var _metric_registration_rejection_count := 0
var _metric_unregistration_count := 0
var _metric_suspension_count := 0
var _metric_resumption_count := 0
var _metric_physics_tick_count := 0
var _metric_authoritative_step_count := 0
var _metric_event_phase_count := 0
var _metric_decision_phase_count := 0
var _metric_urgent_decision_count := 0
var _metric_motion_phase_count := 0
var _metric_contact_phase_count := 0
var _metric_contact_registration_count := 0
var _metric_contact_registration_rejection_count := 0
var _metric_activation_skip_count := 0
var _metric_suspended_skip_count := 0
var _metric_invalid_enemy_release_count := 0
var _metric_compaction_count := 0
var _metric_compacted_tombstone_count := 0
var _metric_clear_count := 0
var _metric_cleared_registration_count := 0


func _ready() -> void:
	_bind_combat_services()
	_bind_runtime_services()
	var requested_mode := EnemySimulationPolicy.resolve_mode_from_arguments(
		OS.get_cmdline_args(),
		_mode
	)
	_mode = _normalize_supported_mode(requested_mode)
	_configure_contact_service_for_mode(_mode)
	set_physics_process(
		_is_centralized_mode(_mode)
		and _registered_count > 0
	)


func get_combat_services() -> EnemyCombatServicesScript:
	return get_node_or_null("EnemyCombatServices") as EnemyCombatServicesScript


func prepare_combat_services_for_runtime_teardown() -> void:
	var combat_services := get_combat_services()
	if combat_services != null:
		combat_services.prepare_for_runtime_teardown()


func _bind_combat_services() -> void:
	var combat_services := get_combat_services()
	var combat_runtime := get_parent() as CombatRuntimeBase
	if combat_services != null and combat_runtime != null:
		combat_services.bind_context(combat_runtime, self)


func set_mode(new_mode: int) -> void:
	var safe_mode := _normalize_supported_mode(new_mode)
	if _is_advancing:
		_pending_mode = safe_mode
		return
	_apply_mode(safe_mode)


func _apply_mode(safe_mode: int) -> void:
	if _mode == safe_mode:
		return
	_mode = safe_mode
	if _mode == EnemySimulationPolicy.Mode.LEGACY:
		clear(true)
		return
	_release_incompatible_registrations_for_mode()
	if _mode == EnemySimulationPolicy.Mode.LAYERED_AREA:
		_prepare_layered_area_registrations()
	else:
		_unregister_all_contact_proxies()
	_configure_contact_service_for_mode(_mode)
	set_physics_process(_registered_count > 0)
	_claim_existing_supported_enemies()


func try_register_enemy(enemy: Enemy) -> int:
	if (
		not _mode_accepts_enemy(enemy)
		or enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_queued_for_deletion()
		or enemy.is_dead
	):
		_metric_registration_rejection_count += 1
		return INVALID_TOKEN

	var instance_id := enemy.get_instance_id()
	var existing := _registration_by_instance_id.get(instance_id) as Registration
	if existing != null:
		if (
			not existing.tombstone
			and existing.enemy == enemy
			and existing.token > INVALID_TOKEN
		):
			_metric_idempotent_registration_count += 1
			return existing.token
		_mark_tombstone(existing, false)

	var simulation_id := _allocate_simulation_id()
	var token := _allocate_token()
	if simulation_id <= INVALID_SIMULATION_ID or token <= INVALID_TOKEN:
		_metric_registration_rejection_count += 1
		return INVALID_TOKEN

	var registration := Registration.new(
		enemy,
		simulation_id,
		token,
		Engine.get_physics_frames()
	)
	_registrations.append(registration)
	_registration_by_instance_id[instance_id] = registration
	_registered_count += 1
	_metric_registration_count += 1
	if _mode == EnemySimulationPolicy.Mode.LAYERED_AREA:
		enemy.prepare_layered_area_authoritative_simulation()
		# Contact admission happens with simulation admission at the next tick
		# boundary. Registering while a phase is advancing would let a newly
		# spawned, not-yet-planned enemy alter older entries' current tick.
	set_physics_process(true)
	return token


func _claim_existing_supported_enemies() -> void:
	var runtime := get_parent() as CombatRuntimeBase
	if runtime == null or runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	var container := runtime.get_node_or_null("EnemyContainer")
	if container == null:
		return
	_claim_supported_enemies_recursive(container)


func _claim_supported_enemies_recursive(parent_node: Node) -> void:
	for child in parent_node.get_children():
		var enemy := child as Enemy
		if enemy != null:
			enemy.try_attach_to_enemy_simulation_coordinator(self)
			continue
		_claim_supported_enemies_recursive(child)


func unregister_enemy(enemy: Enemy, token: int) -> bool:
	var registration := _get_owned_registration(enemy, token)
	if registration == null:
		return false
	_mark_tombstone(registration, false)
	_metric_unregistration_count += 1
	_finish_mutation()
	return true


func suspend_enemy(enemy: Enemy, token: int) -> bool:
	var registration := _get_owned_registration(enemy, token)
	if registration == null or registration.suspended:
		return false
	registration.suspended = true
	_unregister_contact_proxy(registration)
	_suspended_count += 1
	_metric_suspension_count += 1
	return true


func resume_enemy(enemy: Enemy, token: int) -> bool:
	var registration := _get_owned_registration(enemy, token)
	if registration == null or not registration.suspended:
		return false
	registration.suspended = false
	_suspended_count = maxi(_suspended_count - 1, 0)
	_metric_resumption_count += 1
	return true


func owns_enemy(enemy: Enemy, token: int) -> bool:
	return _get_owned_registration(enemy, token) != null


func get_simulation_id(enemy: Enemy, token: int) -> int:
	var registration := _get_owned_registration(enemy, token)
	return (
		registration.simulation_id
		if registration != null
		else INVALID_SIMULATION_ID
	)


func get_metrics(reset_after_read: bool = false) -> Dictionary:
	var snapshot := {
		"mode": int(_mode),
		"simulation_tick": _simulation_tick,
		"registered_count": _registered_count,
		"active_count": maxi(_registered_count - _suspended_count, 0),
		"suspended_count": _suspended_count,
		"slot_count": _registrations.size(),
		"tombstone_count": _tombstone_count,
		"next_simulation_id": _next_simulation_id,
		"next_token": _next_token,
		"is_advancing": _is_advancing,
		"registrations": _metric_registration_count,
		"idempotent_registrations": _metric_idempotent_registration_count,
		"registration_rejections": _metric_registration_rejection_count,
		"unregistrations": _metric_unregistration_count,
		"suspensions": _metric_suspension_count,
		"resumptions": _metric_resumption_count,
		"physics_ticks": _metric_physics_tick_count,
		"authoritative_steps": _metric_authoritative_step_count,
		"event_phases": _metric_event_phase_count,
		"decision_phases": _metric_decision_phase_count,
		"urgent_decisions": _metric_urgent_decision_count,
		"motion_phases": _metric_motion_phase_count,
		"contact_phases": _metric_contact_phase_count,
		"contact_registrations": _metric_contact_registration_count,
		"contact_registration_rejections": (
			_metric_contact_registration_rejection_count
		),
		"activation_skips": _metric_activation_skip_count,
		"suspended_skips": _metric_suspended_skip_count,
		"invalid_enemy_releases": _metric_invalid_enemy_release_count,
		"compactions": _metric_compaction_count,
		"compacted_tombstones": _metric_compacted_tombstone_count,
		"clears": _metric_clear_count,
		"cleared_registrations": _metric_cleared_registration_count,
	}
	if reset_after_read:
		_reset_cumulative_metrics()
	return snapshot


func clear(restore_individual_callbacks: bool = true) -> void:
	if restore_individual_callbacks and _is_advancing:
		_pending_mode = EnemySimulationPolicy.Mode.LEGACY
		return
	var cleared_count := _registered_count
	var released_enemies: Array[Enemy] = []
	var released_tokens: Array[int] = []
	var released_processing_states: Array[bool] = []
	for registration in _registrations:
		if registration == null or registration.tombstone:
			continue
		if (
			restore_individual_callbacks
			and registration.enemy != null
			and is_instance_valid(registration.enemy)
		):
			released_enemies.append(registration.enemy)
			released_tokens.append(registration.token)
			released_processing_states.append(not registration.suspended)
		_mark_tombstone(registration, false)
	_registration_by_instance_id.clear()
	_registered_count = 0
	_suspended_count = 0
	_disable_and_clear_contact_service_at_boundary()
	_metric_clear_count += 1
	_metric_cleared_registration_count += cleared_count
	set_physics_process(false)
	if _is_advancing:
		_clear_requested = true
		return
	_clear_slot_storage()
	for release_index in range(released_enemies.size()):
		var enemy := released_enemies[release_index]
		if enemy == null or not is_instance_valid(enemy):
			continue
		enemy.on_enemy_simulation_coordinator_released(
			self,
			released_tokens[release_index],
			released_processing_states[release_index]
		)


func _physics_process(delta: float) -> void:
	if (
		not _is_centralized_mode(_mode)
		or _registered_count <= 0
	):
		set_physics_process(false)
		return

	_simulation_tick += 1
	_metric_physics_tick_count += 1
	var physics_frame := Engine.get_physics_frames()
	var initial_slot_count := _registrations.size()
	_is_advancing = true
	if _mode == EnemySimulationPolicy.Mode.LAYERED_AREA:
		_advance_layered_area(delta, physics_frame, initial_slot_count)
	else:
		_advance_compat_60(delta, physics_frame, initial_slot_count)
	_is_advancing = false
	_finish_mutation()


func _advance_compat_60(
	delta: float,
	physics_frame: int,
	initial_slot_count: int
) -> void:
	for slot_index in range(initial_slot_count):
		var registration := _registrations[slot_index]
		if not _activate_registration_for_tick(registration, physics_frame):
			continue
		var enemy := registration.enemy
		enemy.simulate_authoritative_physics_step(
			delta,
			_simulation_tick,
			registration.token
		)
		_metric_authoritative_step_count += 1


func _advance_layered_area(
	delta: float,
	physics_frame: int,
	initial_slot_count: int
) -> void:
	_contact_geometry_sync_failed_this_tick = false
	# Capture exact current enemy-enemy overlap before any event consults contact.
	# This snapshot contains no future sweep prediction.
	_admit_layered_contact_proxies_for_tick(physics_frame, initial_slot_count)
	_sync_layered_contact_proxy_geometry()
	_step_layered_current_contact_service()

	# Phase 1: every admitted enemy advances its 60 Hz timers and observes current
	# Area2D/shared contact state. No movement is submitted before every enemy has
	# completed this event phase.
	for slot_index in range(initial_slot_count):
		var registration := _registrations[slot_index]
		if not _activate_registration_for_tick(registration, physics_frame):
			continue
		var enemy := registration.enemy
		if enemy.simulate_layered_area_event_phase(
			delta,
			_simulation_tick,
			registration.token
		):
			_metric_event_phase_count += 1
			_metric_authoritative_step_count += 1

	# Phase 2: only due or explicitly urgent enemies refresh their planned
	# direction. Registration order is simulation-ID order, so decision/RNG order
	# stays deterministic even when callbacks unregister later entries.
	for slot_index in range(initial_slot_count):
		var registration := _registrations[slot_index]
		if not _registration_remains_active_this_tick(registration):
			continue
		var enemy := registration.enemy
		var urgent := enemy.is_layered_area_decision_urgent()
		if not urgent and _simulation_tick < registration.next_decision_tick:
			continue
		if enemy.simulate_layered_area_decision_phase(
			delta,
			_simulation_tick,
			registration.token
		):
			_metric_decision_phase_count += 1
			if urgent:
				_metric_urgent_decision_count += 1
			registration.next_decision_tick = _get_next_staggered_decision_tick(
				_simulation_tick,
				enemy.get_layered_area_decision_interval_frames(),
				registration.simulation_id
			)

	# Continuous enemy-enemy contact is predicted only after every movement plan
	# is final. The resulting directed TOI fractions clip this tick's displacement;
	# they never masquerade as current contact during event/decision phases.
	_step_layered_planned_contact_service(delta)
	if _contact_geometry_sync_failed_this_tick:
		# A cohort cannot mix stale/no proxy geometry with authoritative planned
		# motion. Freeze the complete admitted cohort for this one tick; the queued
		# COMPAT_60 transition commits at _finish_mutation().
		for slot_index in range(initial_slot_count):
			var registration := _registrations[slot_index]
			if not _registration_remains_active_this_tick(registration):
				continue
			registration.enemy.velocity = Vector2.ZERO
		return

	# Phase 3: CharacterBody2D motion remains 60 Hz. The exact physics delta is
	# passed through rather than being read from a disabled per-enemy callback.
	for slot_index in range(initial_slot_count):
		var registration := _registrations[slot_index]
		if not _registration_remains_active_this_tick(registration):
			continue
		var enemy := registration.enemy
		if enemy.simulate_layered_area_motion_phase(
			delta,
			_simulation_tick,
			registration.token
		):
			_metric_motion_phase_count += 1


func _activate_registration_for_tick(
	registration: Registration,
	physics_frame: int
) -> bool:
	if registration == null or registration.tombstone:
		return false
	registration.active_this_tick = false
	var enemy := registration.enemy
	if (
		enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_queued_for_deletion()
		or enemy.is_dead
	):
		_mark_tombstone(registration, true)
		return false
	if not _registration_matches_owner(registration, enemy):
		_mark_tombstone(registration, true)
		return false
	if registration.suspended:
		_metric_suspended_skip_count += 1
		return false
	if physics_frame <= registration.activation_physics_frame:
		_metric_activation_skip_count += 1
		return false
	registration.active_this_tick = true
	return true


func _registration_remains_active_this_tick(
	registration: Registration
) -> bool:
	if (
		registration == null
		or registration.tombstone
		or not registration.active_this_tick
	):
		return false
	var enemy := registration.enemy
	if (
		enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_queued_for_deletion()
		or enemy.is_dead
		or not _registration_matches_owner(registration, enemy)
	):
		_mark_tombstone(registration, true)
		return false
	return true


func _get_next_staggered_decision_tick(
	completed_tick: int,
	requested_interval: int,
	simulation_id: int
) -> int:
	var interval := maxi(requested_interval, 1)
	var next_tick := completed_tick + 1
	if interval <= 1:
		return next_tick
	var desired_remainder := posmod(simulation_id, interval)
	var current_remainder := posmod(next_tick, interval)
	if current_remainder != desired_remainder:
		next_tick += posmod(desired_remainder - current_remainder, interval)
	return next_tick


func _get_owned_registration(enemy: Enemy, token: int) -> Registration:
	if (
		enemy == null
		or token <= INVALID_TOKEN
		or not is_instance_valid(enemy)
	):
		return null
	var registration := (
		_registration_by_instance_id.get(enemy.get_instance_id()) as Registration
	)
	if (
		registration == null
		or registration.tombstone
		or registration.enemy != enemy
		or registration.token != token
	):
		return null
	return registration


func _registration_matches_owner(
	registration: Registration,
	enemy: Enemy
) -> bool:
	if registration.token <= INVALID_TOKEN:
		return false
	return (
		_registration_by_instance_id.get(registration.instance_id)
		== registration
		and registration.enemy == enemy
		and enemy.get_instance_id() == registration.instance_id
	)


func _mark_tombstone(
	registration: Registration,
	invalid_enemy_release: bool
) -> void:
	if registration == null or registration.tombstone:
		return
	_unregister_contact_proxy(registration)
	if (
		_registration_by_instance_id.get(registration.instance_id)
		== registration
	):
		_registration_by_instance_id.erase(registration.instance_id)
	if registration.suspended:
		_suspended_count = maxi(_suspended_count - 1, 0)
	registration.suspended = false
	registration.active_this_tick = false
	registration.tombstone = true
	registration.enemy = null
	_registered_count = maxi(_registered_count - 1, 0)
	_tombstone_count += 1
	if invalid_enemy_release:
		_metric_invalid_enemy_release_count += 1


func _finish_mutation() -> void:
	if _is_advancing:
		return
	if _clear_requested:
		_clear_requested = false
		_clear_slot_storage()
	elif _should_compact_tombstones():
		_compact_tombstones()
	if _registered_count <= 0:
		set_physics_process(false)
	if _pending_mode >= 0:
		var next_mode := _pending_mode
		_pending_mode = -1
		_apply_mode(next_mode)


func _should_compact_tombstones() -> bool:
	if _tombstone_count <= 0:
		return false
	if _registered_count <= 0:
		return true
	return (
		_tombstone_count >= TOMBSTONE_COMPACTION_MINIMUM
		and _tombstone_count * TOMBSTONE_COMPACTION_RATIO_DIVISOR
			>= _registrations.size()
	)


func _compact_tombstones() -> void:
	var previous_tombstone_count := _tombstone_count
	var compacted: Array[Registration] = []
	compacted.resize(_registered_count)
	var write_index := 0
	for registration in _registrations:
		if registration == null or registration.tombstone:
			continue
		compacted[write_index] = registration
		write_index += 1
	if write_index < compacted.size():
		compacted.resize(write_index)
	_registrations = compacted
	_tombstone_count = 0
	_metric_compaction_count += 1
	_metric_compacted_tombstone_count += previous_tombstone_count


func _clear_slot_storage() -> void:
	_registrations.clear()
	_registration_by_instance_id.clear()
	_tombstone_count = 0
	_registered_count = 0
	_suspended_count = 0
	_clear_requested = false


func _allocate_simulation_id() -> int:
	if _next_simulation_id <= INVALID_SIMULATION_ID:
		push_error("EnemySimulationCoordinator exhausted positive simulation IDs.")
		return INVALID_SIMULATION_ID
	var simulation_id := _next_simulation_id
	_next_simulation_id += 1
	return simulation_id


func _allocate_token() -> int:
	if _next_token <= INVALID_TOKEN:
		push_error("EnemySimulationCoordinator exhausted positive ownership tokens.")
		return INVALID_TOKEN
	var token := _next_token
	_next_token += 1
	return token


func _bind_runtime_services() -> void:
	var runtime := get_parent() as CombatRuntimeBase
	if runtime == null:
		return
	_contact_service = runtime.get_enemy_contact_service()
	_combat_target_index = runtime.combat_target_index
	_combat_relation_service = runtime.get_combat_relation_service()
	if _contact_service == null:
		return
	# The coordinator owns the exact phase ordering. A separately scheduled
	# physics callback would produce a second, order-dependent contact snapshot.
	_contact_service.automatic_physics_step = false
	_contact_service.set_physics_process(false)
	_contact_service.set_relation_service(_combat_relation_service)
	_contact_service.set_hostile_aabb_query(Callable(
		self,
		&"_query_hostile_enemy_contact_candidates"
	))


func _configure_contact_service_for_mode(simulation_mode: int) -> void:
	if _contact_service == null:
		_bind_runtime_services()
	if _contact_service == null:
		return
	if simulation_mode == EnemySimulationPolicy.Mode.LAYERED_AREA:
		_contact_service.request_mode(
			EnemyContactService.Mode.HYBRID_ENEMY_CONTACT
		)
		return
	_unregister_all_contact_proxies()
	_disable_and_clear_contact_service_at_boundary()


func _disable_and_clear_contact_service_at_boundary() -> void:
	if _contact_service == null:
		return
	_contact_service.request_mode(EnemyContactService.Mode.DISABLED)
	# Mode requests are committed only from step(). This call is made either
	# between physics ticks or from _finish_mutation after the current tick has
	# completed, so rollback cannot expose a half-old contact snapshot.
	_contact_service.step(_simulation_tick)
	_contact_service.clear()


func _register_contact_proxy(registration: Registration) -> bool:
	if (
		registration == null
		or registration.tombstone
		or registration.suspended
		or registration.contact_proxy_registered
		or _mode != EnemySimulationPolicy.Mode.LAYERED_AREA
	):
		return registration != null and registration.contact_proxy_registered
	if _contact_service == null:
		_bind_runtime_services()
	if _contact_service == null:
		_metric_contact_registration_rejection_count += 1
		return false
	var enemy := registration.enemy
	if enemy == null or not is_instance_valid(enemy):
		_metric_contact_registration_rejection_count += 1
		return false
	# Only the authored touch shell is eligible. Falling back to the body shape
	# would silently shrink attacks and invalidate shadow comparisons.
	var shape_node := enemy.touch_damage_shape
	if shape_node == null or not is_instance_valid(shape_node):
		_metric_contact_registration_rejection_count += 1
		return false
	var body_shape_node := enemy.collision_shape
	if body_shape_node == null or not is_instance_valid(body_shape_node):
		_metric_contact_registration_rejection_count += 1
		return false
	var attacker_proxy := CombatContactShapeProxy.from_collision_shape(shape_node)
	var body_proxy := CombatContactShapeProxy.from_collision_shape(body_shape_node)
	if (
		attacker_proxy == null
		or not attacker_proxy.is_supported()
		or body_proxy == null
		or not body_proxy.is_supported()
	):
		_metric_contact_registration_rejection_count += 1
		return false
	var faction_id := enemy.get_combat_faction_id()
	var registered := _contact_service.register_enemy(
		enemy,
		registration.simulation_id,
		faction_id,
		attacker_proxy,
		body_proxy,
		Callable(shape_node, &"get_global_position"),
		Callable(body_shape_node, &"get_global_position"),
		Callable(enemy, &"get_layered_area_planned_touch_position"),
		Callable(enemy, &"get_layered_area_planned_body_position"),
		Callable(enemy, &"is_layered_area_contact_plan_certified"),
		Callable(enemy, &"get_layered_area_contact_target")
	)
	if not registered:
		registered = _contact_service.owns_enemy(
			enemy,
			registration.simulation_id
		)
	if not registered:
		_metric_contact_registration_rejection_count += 1
		return false
	registration.contact_proxy_registered = true
	registration.contact_faction_id = faction_id
	registration.contact_shape_revision = enemy.get_contact_shape_revision()
	registration.contact_attacker_proxy = attacker_proxy
	registration.contact_body_proxy = body_proxy
	registration.contact_attacker_shape_resource_id = shape_node.shape.get_instance_id()
	registration.contact_body_shape_resource_id = body_shape_node.shape.get_instance_id()
	_metric_contact_registration_count += 1
	return true


func _unregister_contact_proxy(registration: Registration) -> void:
	if registration == null or not registration.contact_proxy_registered:
		return
	var enemy := registration.enemy
	if (
		_contact_service != null
		and enemy != null
		and is_instance_valid(enemy)
	):
		_contact_service.unregister_enemy(enemy, registration.simulation_id)
	registration.contact_proxy_registered = false
	registration.contact_shape_revision = -1
	registration.contact_attacker_proxy = null
	registration.contact_body_proxy = null
	registration.contact_attacker_shape_resource_id = 0
	registration.contact_body_shape_resource_id = 0


func _unregister_all_contact_proxies() -> void:
	for registration in _registrations:
		_unregister_contact_proxy(registration)


func _step_layered_current_contact_service() -> void:
	if _contact_service == null:
		_bind_runtime_services()
	if _contact_service == null:
		return
	_sync_layered_contact_factions()
	_contact_service.step(_simulation_tick)
	_metric_contact_phase_count += 1


func _step_layered_planned_contact_service(delta: float) -> void:
	if _contact_service == null:
		return
	# Decision can mirror authored collision shapes. Republish both proxies before
	# planned providers are sampled; motion performs no later facing mutation.
	_sync_layered_contact_proxy_geometry()
	if _contact_geometry_sync_failed_this_tick:
		return
	# Events/decisions can change faction. Planned filtering must consume the
	# post-decision relation snapshot rather than the one captured before events.
	_sync_layered_contact_factions()
	_contact_service.step_planned(delta, _simulation_tick)


func _sync_layered_contact_proxy_geometry() -> void:
	for registration in _registrations:
		if (
			registration == null
			or registration.tombstone
			or registration.suspended
			or not registration.contact_proxy_registered
		):
			continue
		var enemy := registration.enemy
		if enemy == null or not is_instance_valid(enemy):
			continue
		var attacker_shape_node := enemy.touch_damage_shape
		var body_shape_node := enemy.collision_shape
		if (
			attacker_shape_node == null
			or not is_instance_valid(attacker_shape_node)
			or body_shape_node == null
			or not is_instance_valid(body_shape_node)
		):
			_unregister_contact_proxy(registration)
			_contact_geometry_sync_failed_this_tick = true
			_pending_mode = EnemySimulationPolicy.Mode.COMPAT_60
			continue
		var geometry_changed := (
			registration.contact_shape_revision
			!= enemy.get_contact_shape_revision()
			or attacker_shape_node.shape == null
			or body_shape_node.shape == null
			or registration.contact_attacker_shape_resource_id
				!= attacker_shape_node.shape.get_instance_id()
			or registration.contact_body_shape_resource_id
				!= body_shape_node.shape.get_instance_id()
			or registration.contact_attacker_proxy == null
			or registration.contact_body_proxy == null
			or not registration.contact_attacker_proxy
				.is_translation_transform_supported(
					attacker_shape_node.global_transform
				)
			or not registration.contact_body_proxy
				.is_translation_transform_supported(
					body_shape_node.global_transform
				)
		)
		if not geometry_changed:
			continue
		var attacker_proxy := CombatContactShapeProxy.from_collision_shape(
			attacker_shape_node
		)
		var body_proxy := CombatContactShapeProxy.from_collision_shape(
			body_shape_node
		)
		if (
			attacker_proxy == null
			or not attacker_proxy.is_supported()
			or body_proxy == null
			or not body_proxy.is_supported()
			or not _contact_service.update_shape_proxies(
				enemy,
				attacker_proxy,
				body_proxy
			)
		):
			# Unsupported runtime geometry cannot retain LAYERED contact authority.
			# Finish this stable tick without the stale proxy, then fall back to the
			# already verified COMPAT_60 path at the boundary.
			_unregister_contact_proxy(registration)
			_contact_geometry_sync_failed_this_tick = true
			_pending_mode = EnemySimulationPolicy.Mode.COMPAT_60
			continue
		registration.contact_attacker_proxy = attacker_proxy
		registration.contact_body_proxy = body_proxy
		registration.contact_shape_revision = enemy.get_contact_shape_revision()
		registration.contact_attacker_shape_resource_id = (
			attacker_shape_node.shape.get_instance_id()
		)
		registration.contact_body_shape_resource_id = (
			body_shape_node.shape.get_instance_id()
		)


func _admit_layered_contact_proxies_for_tick(
	physics_frame: int,
	initial_slot_count: int
) -> void:
	for slot_index in range(initial_slot_count):
		var registration := _registrations[slot_index]
		if (
			registration == null
			or registration.tombstone
			or registration.suspended
			or registration.contact_proxy_registered
			or physics_frame <= registration.activation_physics_frame
		):
			continue
		var enemy := registration.enemy
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or enemy.is_queued_for_deletion()
			or enemy.is_dead
			or not _registration_matches_owner(registration, enemy)
		):
			continue
		_register_contact_proxy(registration)


func _sync_layered_contact_factions() -> void:
	for registration in _registrations:
		if (
			registration == null
			or registration.tombstone
			or registration.suspended
			or not registration.contact_proxy_registered
		):
			continue
		var enemy := registration.enemy
		if enemy == null or not is_instance_valid(enemy):
			continue
		var next_faction_id := enemy.get_combat_faction_id()
		if next_faction_id == registration.contact_faction_id:
			continue
		if _contact_service.update_faction(
			enemy,
			registration.contact_faction_id,
			next_faction_id
		):
			registration.contact_faction_id = next_faction_id


func _query_hostile_enemy_contact_candidates(
	world_aabb: Rect2,
	source_faction_id: int,
	excluded_entity: Node2D,
	result: Array[Node2D]
) -> void:
	result.clear()
	if _combat_target_index == null or not is_instance_valid(_combat_target_index):
		return
	# Contact performs its own stable simulation-ID canonicalization. Query the
	# enemy partition directly so the hot path does not pay the facade's general
	# Player/Plant merge sort and then immediately sort the same candidates again.
	_contact_index_candidate_buffer.clear()
	_combat_target_index.query_hostile_world_aabb_unordered_into(
		world_aabb,
		source_faction_id,
		_contact_index_candidate_buffer,
		excluded_entity as Enemy,
		_combat_relation_service
	)
	for enemy in _contact_index_candidate_buffer:
		result.append(enemy)


func _is_centralized_mode(value: int) -> bool:
	return (
		value == EnemySimulationPolicy.Mode.COMPAT_60
		or value == EnemySimulationPolicy.Mode.LAYERED_AREA
	)


func _mode_accepts_enemy(enemy: Enemy) -> bool:
	if (
		enemy == null
		or not is_instance_valid(enemy)
		or not enemy.supports_centralized_authoritative_simulation()
	):
		return false
	if _mode == EnemySimulationPolicy.Mode.COMPAT_60:
		return true
	return (
		_mode == EnemySimulationPolicy.Mode.LAYERED_AREA
		and enemy.supports_layered_area_authoritative_simulation()
	)


func _release_incompatible_registrations_for_mode() -> void:
	var released_enemies: Array[Enemy] = []
	var released_tokens: Array[int] = []
	var released_processing_states: Array[bool] = []
	for registration in _registrations:
		if registration == null or registration.tombstone:
			continue
		var enemy := registration.enemy
		if enemy != null and is_instance_valid(enemy) and _mode_accepts_enemy(enemy):
			continue
		if enemy != null and is_instance_valid(enemy):
			released_enemies.append(enemy)
			released_tokens.append(registration.token)
			released_processing_states.append(not registration.suspended)
		_mark_tombstone(registration, enemy == null or not is_instance_valid(enemy))
	_finish_mutation()
	for release_index in range(released_enemies.size()):
		var released_enemy := released_enemies[release_index]
		if released_enemy == null or not is_instance_valid(released_enemy):
			continue
		released_enemy.on_enemy_simulation_coordinator_released(
			self,
			released_tokens[release_index],
			released_processing_states[release_index]
		)


func _prepare_layered_area_registrations() -> void:
	for registration in _registrations:
		if registration == null or registration.tombstone:
			continue
		registration.next_decision_tick = 0
		registration.active_this_tick = false
		var enemy := registration.enemy
		if enemy != null and is_instance_valid(enemy):
			enemy.prepare_layered_area_authoritative_simulation()


func _normalize_supported_mode(value: int) -> EnemySimulationPolicy.Mode:
	if (
		value == EnemySimulationPolicy.Mode.COMPAT_60
		or value == EnemySimulationPolicy.Mode.LAYERED_AREA
	):
		return value
	return EnemySimulationPolicy.Mode.LEGACY


func _reset_cumulative_metrics() -> void:
	_metric_registration_count = 0
	_metric_idempotent_registration_count = 0
	_metric_registration_rejection_count = 0
	_metric_unregistration_count = 0
	_metric_suspension_count = 0
	_metric_resumption_count = 0
	_metric_physics_tick_count = 0
	_metric_authoritative_step_count = 0
	_metric_event_phase_count = 0
	_metric_decision_phase_count = 0
	_metric_urgent_decision_count = 0
	_metric_motion_phase_count = 0
	_metric_contact_phase_count = 0
	_metric_contact_registration_count = 0
	_metric_contact_registration_rejection_count = 0
	_metric_activation_skip_count = 0
	_metric_suspended_skip_count = 0
	_metric_invalid_enemy_release_count = 0
	_metric_compaction_count = 0
	_metric_compacted_tombstone_count = 0
	_metric_clear_count = 0
	_metric_cleared_registration_count = 0


func _exit_tree() -> void:
	prepare_combat_services_for_runtime_teardown()
	clear(false)
