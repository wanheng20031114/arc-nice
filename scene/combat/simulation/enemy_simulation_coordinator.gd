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
	var suspended := false
	var tombstone := false


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

var _metric_registration_count := 0
var _metric_idempotent_registration_count := 0
var _metric_registration_rejection_count := 0
var _metric_unregistration_count := 0
var _metric_suspension_count := 0
var _metric_resumption_count := 0
var _metric_physics_tick_count := 0
var _metric_authoritative_step_count := 0
var _metric_activation_skip_count := 0
var _metric_suspended_skip_count := 0
var _metric_invalid_enemy_release_count := 0
var _metric_compaction_count := 0
var _metric_compacted_tombstone_count := 0
var _metric_clear_count := 0
var _metric_cleared_registration_count := 0


func _ready() -> void:
	_bind_combat_services()
	var requested_mode := EnemySimulationPolicy.resolve_mode_from_arguments(
		OS.get_cmdline_args(),
		_mode
	)
	_mode = _normalize_supported_mode(requested_mode)
	set_physics_process(
		_mode == EnemySimulationPolicy.Mode.COMPAT_60
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
	set_physics_process(_registered_count > 0)
	_claim_existing_supported_enemies()


func try_register_enemy(enemy: Enemy) -> int:
	if (
		_mode != EnemySimulationPolicy.Mode.COMPAT_60
		or enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_queued_for_deletion()
		or enemy.is_dead
		or not enemy.supports_centralized_authoritative_simulation()
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
		_mode != EnemySimulationPolicy.Mode.COMPAT_60
		or _registered_count <= 0
	):
		set_physics_process(false)
		return

	_simulation_tick += 1
	_metric_physics_tick_count += 1
	var physics_frame := Engine.get_physics_frames()
	var initial_slot_count := _registrations.size()
	_is_advancing = true
	for slot_index in range(initial_slot_count):
		var registration := _registrations[slot_index]
		if registration == null or registration.tombstone:
			continue
		var enemy := registration.enemy
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or enemy.is_queued_for_deletion()
			or enemy.is_dead
		):
			_mark_tombstone(registration, true)
			continue
		if not _registration_matches_owner(registration, enemy):
			_mark_tombstone(registration, true)
			continue
		if registration.suspended:
			_metric_suspended_skip_count += 1
			continue
		if physics_frame <= registration.activation_physics_frame:
			_metric_activation_skip_count += 1
			continue
		enemy.simulate_authoritative_physics_step(
			delta,
			_simulation_tick,
			registration.token
		)
		_metric_authoritative_step_count += 1
	_is_advancing = false
	_finish_mutation()


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
	if (
		_registration_by_instance_id.get(registration.instance_id)
		== registration
	):
		_registration_by_instance_id.erase(registration.instance_id)
	if registration.suspended:
		_suspended_count = maxi(_suspended_count - 1, 0)
	registration.suspended = false
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


func _normalize_supported_mode(value: int) -> EnemySimulationPolicy.Mode:
	if value == EnemySimulationPolicy.Mode.COMPAT_60:
		return EnemySimulationPolicy.Mode.COMPAT_60
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
