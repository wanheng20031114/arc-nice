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
# Plant geometry is static between index revisions, so one broad query can
# certify the complete movement envelope for several ticks. Forty-eight ticks
# is the measured knee for 300 enemies/100 buildings: longer horizons add many
# candidates for only a marginal reduction in queries, while this keeps exact
# shape checks and revision invalidation unchanged.
const INDEXED_TOUCH_STATIC_IDLE_QUERY_TICKS := 48
const INDEXED_TOUCH_STATIC_ENVELOPE_EPSILON := 0.25
## Displacements above this explicit per-tick envelope are teleports/dashes for
## Player broadphase purposes and retain the all-player compatibility slow path.
## At 60 Hz this still admits ordinary authored movement up to 7,680 px/s.
const INDEXED_TOUCH_MAX_NORMAL_MOTION_PER_TICK := 128.0
const DECISION_DUE_BUCKET_POOL_LIMIT := 128
const AUTHORITY_CONTAINER_PATHS: Array[NodePath] = [
	NodePath("BossContainer"),
	NodePath("EnemyContainer"),
]

const INDEXED_TOUCH_DIRTY_INITIAL := 1 << 0
const INDEXED_TOUCH_DIRTY_PLAYER := 1 << 1
const INDEXED_TOUCH_DIRTY_PLANT_GEOMETRY := 1 << 2
const INDEXED_TOUCH_DIRTY_RELATION := 1 << 3
const INDEXED_TOUCH_DIRTY_FACTION := 1 << 4
const INDEXED_TOUCH_DIRTY_CONTACT_GEOMETRY := 1 << 5
const INDEXED_TOUCH_DIRTY_TRANSFORM := 1 << 6

const INDEXED_TOUCH_SEPARATION_NONE := -1
const INDEXED_TOUCH_SEPARATION_LEFT := 0
const INDEXED_TOUCH_SEPARATION_RIGHT := 1
const INDEXED_TOUCH_SEPARATION_ABOVE := 2
const INDEXED_TOUCH_SEPARATION_BELOW := 3


class Registration:
	extends RefCounted

	var enemy: Enemy
	var instance_id: int
	var simulation_id: int
	var token: int
	var activation_physics_frame: int
	var uses_anchored_compat_simulation := false
	var last_authoritative_physics_frame := -1
	var next_decision_tick := 0
	var uses_physics_phase_decisions := false
	var decision_interval_frames := 1
	var decision_phase_offset := 0
	var scheduled_decision_physics_frame := -1
	var urgent_decision_enqueued := false
	var decision_work_physics_frame := -1
	var event_ready_enqueued := false
	var event_work_physics_frame := -1
	var scheduled_event_physics_frame := -1
	var event_sleep_counted := false
	var event_admission_physics_frame := -1
	var trusted_sleep_wake_after_event_physics_frame := -1
	var motion_listed := false
	var compat_decision_listed := false
	var uses_trusted_layered_phase_entrypoints := false
	var activation_check_physics_frame := -1
	var active_this_tick := false
	var suspended := false
	var tombstone := false
	var contact_proxy_registered := false
	var indexed_touch_authority_capable := false
	var indexed_touch_dirty := false
	var indexed_touch_dirty_reasons := 0
	var contact_geometry_dirty := false
	var contact_faction_id := CombatRelationService.NEUTRAL
	var contact_shape_revision := -1
	var contact_attacker_proxy: CombatContactShapeProxy = null
	var contact_body_proxy: CombatContactShapeProxy = null
	var contact_attacker_shape: Shape2D = null
	var contact_attacker_local_transform := Transform2D()
	var contact_body_local_transform := Transform2D()
	var contact_attacker_bounding_radius := 0.0
	var indexed_touch_enemy_extent := 0.0
	var contact_attacker_shape_resource_ids := PackedInt64Array()
	var contact_body_shape_resource_ids := PackedInt64Array()
	var contact_attacker_shape_local_transforms: Array[Transform2D] = []
	var contact_body_shape_local_transforms: Array[Transform2D] = []
	var indexed_touch_plant_geometry_revision := -1
	var indexed_touch_plant_safe_envelope := Rect2()
	var indexed_touch_plant_safe_position_bounds := Rect2()
	var indexed_touch_plant_candidates: Array[StaticBody2D] = []
	var indexed_touch_plant_candidate_aabbs: Array[Rect2] = []
	var indexed_touch_exact_geometry_revision := -1
	var indexed_touch_exact_transform := Transform2D()
	var indexed_touch_exact_transform_valid := false
	var indexed_touch_exact_plants: Array[PlantDefense] = []
	var indexed_touch_complete_snapshot_valid := false
	var indexed_touch_complete_transform := Transform2D()
	var indexed_touch_complete_plant_geometry_revision := -1
	var indexed_touch_complete_relation_revision := -1
	var indexed_touch_complete_faction_id := CombatRelationService.NEUTRAL
	var indexed_touch_complete_contact_shape_revision := -1
	var indexed_touch_safe_position_minimum := Vector2.ZERO
	var indexed_touch_safe_position_maximum := Vector2.ZERO
	var indexed_touch_player_snapshot_empty_cache := false
	var indexed_touch_player_snapshot_nonempty_slot := -1
	var indexed_touch_snapshot_empty_cache := false
	var indexed_touch_empty_corridor_fast := false
	var indexed_touch_last_observed_transform := Transform2D()
	var indexed_touch_last_observed_transform_valid := false
	var indexed_touch_motion_from_position := Vector2.ZERO
	var indexed_touch_motion_to_position := Vector2.ZERO
	var indexed_touch_motion_world_aabb := Rect2()
	var indexed_touch_motion_pending := false
	var indexed_touch_moved_generation := -1


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
		uses_anchored_compat_simulation = (
			registered_enemy.uses_anchored_compat_simulation()
		)


	func reset_indexed_touch_plant_cache() -> void:
		indexed_touch_plant_geometry_revision = -1
		indexed_touch_plant_safe_envelope = Rect2()
		indexed_touch_plant_safe_position_bounds = Rect2()
		indexed_touch_plant_candidates.clear()
		indexed_touch_plant_candidate_aabbs.clear()
		indexed_touch_exact_geometry_revision = -1
		indexed_touch_exact_transform = Transform2D()
		indexed_touch_exact_transform_valid = false
		indexed_touch_exact_plants.clear()
		indexed_touch_complete_snapshot_valid = false
		indexed_touch_complete_transform = Transform2D()
		indexed_touch_complete_plant_geometry_revision = -1
		indexed_touch_complete_relation_revision = -1
		indexed_touch_complete_faction_id = CombatRelationService.NEUTRAL
		indexed_touch_complete_contact_shape_revision = -1
		indexed_touch_safe_position_minimum = Vector2.ZERO
		indexed_touch_safe_position_maximum = Vector2.ZERO
		indexed_touch_player_snapshot_empty_cache = false
		indexed_touch_snapshot_empty_cache = false
		indexed_touch_empty_corridor_fast = false


var _mode: EnemySimulationPolicy.Mode = EnemySimulationPolicy.Mode.LAYERED_CONTACT

@export var mode: EnemySimulationPolicy.Mode = EnemySimulationPolicy.Mode.LAYERED_CONTACT:
	set(value):
		set_mode(value)
	get:
		return _mode

var _registrations: Array[Registration] = []
var _registration_by_instance_id: Dictionary[int, Registration] = {}
var _next_simulation_id := 1
var _next_token := 1
## A mode requested from inside the coordinator's physics callback commits at
## that tick boundary, but newly compatible individual enemies must finish their
## own callback later in the same SceneTree physics pass. Ownership is therefore
## claimed from the deferred idle boundary, before the next physics frame.
var _deferred_claim_mode := -1
var _registered_count := 0
var _suspended_count := 0
var _tombstone_count := 0
var _simulation_tick := 0
var _last_simulation_physics_frame := -1
var _last_main_dispatch_physics_frame := -1
var _is_advancing := false
var _clear_requested := false
var _pending_mode := -1
var _contact_geometry_sync_failed_this_tick := false
var _contact_service: EnemyContactService = null
var _combat_target_index: CombatTargetIndex = null
var _combat_relation_service: CombatRelationService = null
var _damageable_spatial_index: EnemyDamageableSpatialIndex = null
var _contact_index_candidate_buffer: Array[Enemy] = []
var _pending_contact_admissions: Array[Registration] = []
var _dirty_contact_geometries: Array[Registration] = []
var _dirty_indexed_touch_registrations: Array[Registration] = []
var _dirty_indexed_touch_work_registrations: Array[Registration] = []
var _dirty_indexed_touch_queue_ordered := true
var _dirty_indexed_touch_queue_last_simulation_id := INVALID_SIMULATION_ID
var _indexed_touch_moved_registrations: Array[Registration] = []
var _indexed_touch_moved_work_registrations: Array[Registration] = []
var _indexed_touch_slow_path_registrations: Array[Registration] = []
var _indexed_touch_moved_queue_ordered := true
var _indexed_touch_moved_queue_last_simulation_id := INVALID_SIMULATION_ID
var _indexed_touch_nonempty_player_registrations: Array[Registration] = []
var _indexed_touch_living_players: Array[Player] = []
var _indexed_touch_player_instance_ids: Array[int] = []
var _indexed_touch_player_shapes: Array[Shape2D] = []
var _indexed_touch_player_transforms: Array[Transform2D] = []
var _indexed_touch_player_positions: Array[Vector2] = []
var _indexed_touch_player_extents: Array[float] = []
var _indexed_touch_player_shape_rects: Array[Rect2] = []
var _indexed_touch_player_world_aabbs: Array[Rect2] = []
var _indexed_touch_player_swept_world_aabbs: Array[Rect2] = []
var _indexed_touch_player_state_changed_flags: Array[bool] = []
var _indexed_touch_any_player_state_changed_this_tick := false
var _indexed_touch_previous_player_instance_ids: Array[int] = []
var _indexed_touch_previous_player_shapes: Array[Shape2D] = []
var _indexed_touch_previous_player_transforms: Array[Transform2D] = []
var _indexed_touch_previous_player_positions: Array[Vector2] = []
var _indexed_touch_previous_player_extents: Array[float] = []
var _indexed_touch_previous_player_shape_rects: Array[Rect2] = []
var _indexed_touch_previous_player_world_aabbs: Array[Rect2] = []
var _indexed_touch_player_enemy_candidates: Array[Enemy] = []
var _indexed_touch_players: Array[Player] = []
var _indexed_touch_plants: Array = []
var _indexed_touch_has_registered_plants_this_tick := false
var _indexed_touch_plant_geometry_revision_this_tick := -1
var _indexed_touch_relation_revision_this_tick := -1
var _maximum_indexed_touch_enemy_extent := 0.0
var _maximum_indexed_touch_enemy_extent_dirty := false
var _decision_due_by_physics_frame: Dictionary = {}
var _decision_due_bucket_pool: Array = []
var _urgent_decision_registrations: Array[Registration] = []
var _decision_work_registrations: Array[Registration] = []
var _decision_phase_active := false
var _decision_phase_physics_frame := -1
var _decision_phase_cursor := -1
var _decision_phase_current_simulation_id := INVALID_SIMULATION_ID
var _event_ready_registrations: Array[Registration] = []
var _event_due_by_physics_frame: Dictionary = {}
var _event_due_bucket_pool: Array = []
var _event_work_registrations: Array[Registration] = []
var _event_phase_active := false
var _event_phase_physics_frame := -1
var _event_phase_cursor := -1
var _event_phase_current_simulation_id := INVALID_SIMULATION_ID
var _event_phase_completed_physics_frame := -1
var _event_sleep_ack_metric_physics_frame := -1
var _sleeping_event_registration_count := 0
var _motion_active_registrations: Array[Registration] = []
var _compat_decision_registrations: Array[Registration] = []

var _metric_registration_count := 0
var _metric_idempotent_registration_count := 0
var _metric_registration_rejection_count := 0
var _metric_unregistration_count := 0
var _metric_suspension_count := 0
var _metric_resumption_count := 0
var _metric_physics_tick_count := 0
var _metric_authoritative_step_count := 0
var _metric_event_phase_count := 0
var _metric_event_sleep_ack_count := 0
var _metric_touch_cooldown_deadline_wake_count := 0
var _metric_decision_phase_count := 0
var _metric_urgent_decision_count := 0
var _metric_motion_phase_count := 0
var _metric_contact_phase_count := 0
var _metric_contact_registration_count := 0
var _metric_contact_registration_rejection_count := 0
var _metric_contact_atomic_rollback_count := 0
var _metric_indexed_touch_sync_count := 0
var _metric_indexed_touch_authority_count := 0
var _metric_indexed_touch_plant_broadphase_count := 0
var _metric_indexed_touch_plant_exact_candidate_count := 0
var _metric_indexed_touch_plant_exact_shape_hit_count := 0
var _metric_indexed_touch_plant_candidate_check_count := 0
var _metric_indexed_touch_plant_sleep_skip_count := 0
var _metric_indexed_touch_plant_exact_cache_hit_count := 0
var _metric_indexed_touch_empty_snapshot_skip_count := 0
var _metric_indexed_touch_unchanged_snapshot_skip_count := 0
var _metric_indexed_touch_complete_snapshot_skip_count := 0
var _metric_indexed_touch_empty_corridor_skip_count := 0
var _metric_indexed_touch_nonempty_plant_certificate_build_count := 0
var _metric_indexed_touch_nonempty_plant_certificate_reuse_count := 0
var _metric_indexed_touch_nonempty_plant_certificate_reject_count := 0
var _metric_indexed_touch_dirty_enqueue_count := 0
var _metric_indexed_touch_dirty_drain_count := 0
var _metric_indexed_touch_dirty_ordered_drain_count := 0
var _metric_indexed_touch_dirty_sort_count := 0
var _metric_indexed_touch_moved_ordered_drain_count := 0
var _metric_indexed_touch_moved_sort_count := 0
var _metric_indexed_touch_player_invalidation_count := 0
var _metric_indexed_touch_global_invalidation_count := 0
var _metric_indexed_touch_player_index_query_count := 0
var _metric_indexed_touch_player_index_candidate_count := 0
var _metric_indexed_touch_player_aabb_pair_check_count := 0
var _metric_indexed_touch_player_aabb_pair_hit_count := 0
var _metric_indexed_touch_player_exact_shape_check_count := 0
var _metric_indexed_touch_player_exact_shape_hit_count := 0
var _metric_indexed_touch_player_slow_path_mover_count := 0
var _metric_indexed_touch_contact_enter_count := 0
var _metric_indexed_touch_contact_exit_count := 0
var _metric_touch_damage_attempt_count := 0
var _metric_touch_damage_accepted_count := 0
var _metric_touch_damage_rejected_count := 0
var _metric_activation_skip_count := 0
var _metric_suspended_skip_count := 0
var _metric_invalid_enemy_release_count := 0
var _metric_compaction_count := 0
var _metric_compacted_tombstone_count := 0
var _metric_clear_count := 0
var _metric_cleared_registration_count := 0
var _metric_profile_contact_setup_usec := 0
var _metric_profile_contact_admission_usec := 0
var _metric_profile_contact_geometry_usec := 0
var _metric_profile_contact_service_usec := 0
var _metric_profile_indexed_player_refresh_usec := 0
var _metric_profile_indexed_dirty_drain_usec := 0
var _metric_profile_event_phase_usec := 0
var _metric_profile_decision_phase_usec := 0
var _metric_profile_planned_contact_usec := 0
var _metric_profile_motion_phase_usec := 0


func _ready() -> void:
	_bind_combat_services()
	_bind_runtime_services()
	var requested_mode := _resolve_requested_mode_from_command_line()
	# Scene deserialization may already have assigned the requested centralized
	# mode through the export setter. Force the complete mode application once at
	# ready so CLI overrides, contact ownership and existing-enemy claims all use
	# the same transition path instead of silently skipping an equal mode.
	_apply_mode(_normalize_supported_mode(requested_mode), true)


func _resolve_requested_mode_from_command_line() -> EnemySimulationPolicy.Mode:
	var authored_fallback := _mode
	var user_arguments := OS.get_cmdline_user_args()
	# Godot places project arguments following `--` only in the user-argument
	# collection. Give that explicit A/B channel priority over the legacy engine
	# argument location, including its authored fallback for an unknown value.
	for argument in user_arguments:
		if argument.begins_with(EnemySimulationPolicy.MODE_ARGUMENT_PREFIX):
			return EnemySimulationPolicy.resolve_mode_from_arguments(
				user_arguments,
				EnemySimulationPolicy.Mode.LEGACY
			)
	for argument in OS.get_cmdline_args():
		if argument.begins_with(EnemySimulationPolicy.MODE_ARGUMENT_PREFIX):
			return EnemySimulationPolicy.resolve_mode_from_arguments(
				OS.get_cmdline_args(),
				EnemySimulationPolicy.Mode.LEGACY
			)
	return EnemySimulationPolicy.resolve_mode_from_arguments(
		OS.get_cmdline_args(),
		authored_fallback
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


func _apply_mode(
	safe_mode: int,
	force_configuration: bool = false,
	claim_existing_immediately: bool = true
) -> void:
	var mode_changed := _mode != safe_mode
	if not mode_changed and not force_configuration:
		return
	if claim_existing_immediately:
		_deferred_claim_mode = -1
	_mode = safe_mode
	if not _uses_shared_contact_mode(_mode):
		_disable_all_indexed_touch_authority()
	if _mode == EnemySimulationPolicy.Mode.LEGACY:
		_deferred_claim_mode = -1
		if mode_changed or _registered_count > 0:
			clear(true)
		else:
			# Initial LEGACY application has no ownership to release. Configure the
			# shared contact boundary without reporting a synthetic runtime clear.
			_configure_contact_service_for_mode(_mode)
			set_physics_process(false)
		return
	_release_incompatible_registrations_for_mode()
	if _is_layered_mode(_mode):
		_prepare_layered_area_registrations()
	else:
		_reset_layered_scheduler_state()
	if not _uses_shared_contact_mode(_mode):
		_unregister_all_contact_proxies()
	_configure_contact_service_for_mode(_mode)
	set_physics_process(_registered_count > 0)
	if claim_existing_immediately:
		_claim_existing_supported_enemies()
		return
	_deferred_claim_mode = _mode
	# call_deferred runs after every remaining node has completed this physics
	# pass. New registrations then carry the old frame as their activation fence
	# and are eligible for coordinator dispatch on the very next 60 Hz tick.
	call_deferred(&"_claim_existing_supported_enemies_after_boundary", _mode)
	set_physics_process(true)


func _claim_existing_supported_enemies_after_boundary(expected_mode: int) -> void:
	if _deferred_claim_mode != expected_mode or _mode != expected_mode:
		return
	_deferred_claim_mode = -1
	if not _is_centralized_mode(_mode):
		return
	_claim_existing_supported_enemies()
	set_physics_process(_registered_count > 0)


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
	var faction_callback := Callable(
		self,
		&"_on_registered_enemy_combat_faction_changed"
	)
	if not enemy.combat_faction_changed.is_connected(faction_callback):
		enemy.combat_faction_changed.connect(faction_callback)
	_registered_count += 1
	_metric_registration_count += 1
	if registration.uses_anchored_compat_simulation:
		# Anchored families retain their authored Area2D contact authority and run
		# their complete COMPAT step from the scene-local phase anchor.
		enemy.set_indexed_touch_authority(false)
	elif _is_layered_mode(_mode):
		enemy.prepare_layered_area_authoritative_simulation()
		_configure_registration_decision_schedule(registration, enemy)
		_enqueue_event_ready_registration(registration)
		_register_compat_decision_registration(registration)
		_schedule_next_physics_decision(
			registration,
			Engine.get_physics_frames()
		)
		_enqueue_urgent_decision_registration(registration)
		# Contact admission happens with simulation admission at the next tick
		# boundary. Registering while a phase is advancing would let a newly
		# spawned, not-yet-planned enemy alter older entries' current tick.
		if (
			_uses_shared_contact_mode(_mode)
			and _registration_supports_shared_contact_authority(registration)
		):
			_pending_contact_admissions.append(registration)
	set_physics_process(true)
	return token


func _claim_existing_supported_enemies() -> void:
	var runtime := get_parent() as CombatRuntimeBase
	if runtime == null or runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	# Container order is part of the deterministic simulation-ID contract. Bosses
	# are claimed first, followed by ordinary enemies; descendants retain authored
	# tree order within each container.
	for container_path in AUTHORITY_CONTAINER_PATHS:
		var container := runtime.get_node_or_null(container_path)
		if container == null:
			continue
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
	# Lazily invalidate exact-frame queue entries. The old bucket retains only a
	# stale Registration stamp and is recycled when its frame arrives.
	registration.scheduled_decision_physics_frame = -1
	registration.urgent_decision_enqueued = false
	registration.scheduled_event_physics_frame = -1
	registration.event_ready_enqueued = false
	_set_event_sleep_counted(registration, false)
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
	if _is_layered_mode(_mode) and not registration.uses_anchored_compat_simulation:
		enemy.layered_area_event_phase_sleeping = false
		enemy.layered_area_event_sleep_until_physics_frame = -1
		_enqueue_event_ready_registration(registration)
	if _is_layered_mode(_mode) and registration.uses_physics_phase_decisions:
		var current_physics_frame := Engine.get_physics_frames()
		var schedule_after_physics_frame := (
			current_physics_frame
			if _last_main_dispatch_physics_frame >= current_physics_frame
			else current_physics_frame - 1
		)
		_schedule_next_physics_decision(
			registration,
			schedule_after_physics_frame
		)
	if (
		_uses_shared_contact_mode(_mode)
		and not registration.uses_anchored_compat_simulation
		and _registration_supports_shared_contact_authority(registration)
	):
		_pending_contact_admissions.append(registration)
	if _is_layered_mode(_mode) and enemy.layered_area_decision_urgent:
		mark_enemy_layered_decision_urgent(enemy, token)
	_metric_resumption_count += 1
	return true


## Called by an owned enemy after it marks its cached decision as urgent. The
## sparse queue preserves the old full-scan rule: a request raised before the
## target's simulation-ID slot executes can still run this frame; requests for
## an already-processed slot remain pending for the next physics frame.
func mark_enemy_layered_decision_urgent(enemy: Enemy, token: int) -> bool:
	var registration := _get_owned_registration(enemy, token)
	if (
		registration == null
		or not _is_layered_mode(_mode)
		or registration.uses_anchored_compat_simulation
	):
		return false
	_wake_event_registration(registration)
	if (
		_decision_phase_active
		and _decision_phase_physics_frame == Engine.get_physics_frames()
		and registration.simulation_id
			> _decision_phase_current_simulation_id
	):
		_insert_decision_work_registration(
			registration,
			_decision_phase_physics_frame,
			true,
			_decision_phase_cursor + 1
		)
		return true
	if registration.uses_physics_phase_decisions:
		return _enqueue_urgent_decision_registration(registration)
	# Compatibility decisions are enumerated by their persistent family list; the
	# urgent bit remains on Enemy until that stable-ID slot executes.
	return registration.compat_decision_listed


func owns_enemy(enemy: Enemy, token: int) -> bool:
	return _get_owned_registration(enemy, token) != null


func get_simulation_id(enemy: Enemy, token: int) -> int:
	var registration := _get_owned_registration(enemy, token)
	return (
		registration.simulation_id
		if registration != null
		else INVALID_SIMULATION_ID
	)


## Advances one phase-anchored enemy at its authored SceneTree position. The
## public boundary deliberately accepts no caller-provided token: it validates
## the exact token and coordinator stored on the Enemy before admitting a step.
## Duplicate/reentrant calls fail closed and never invoke the family runner.
func advance_anchored_compat_enemy(enemy: Enemy, delta: float) -> bool:
	if not _is_centralized_mode(_mode) or _is_advancing:
		return false
	if (
		enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_queued_for_deletion()
		or enemy.enemy_simulation_coordinator != self
		or enemy.authoritative_simulation_driver
			!= Enemy.AuthoritativeSimulationDriver.SCHEDULED_ACTIVE
	):
		return false
	var registration := _get_owned_registration(
		enemy,
		enemy.enemy_simulation_token
	)
	if (
		registration == null
		or not registration.uses_anchored_compat_simulation
		or not enemy.uses_anchored_compat_simulation()
	):
		return false
	var physics_frame := Engine.get_physics_frames()
	if not _ensure_simulation_tick_for_physics_frame(physics_frame):
		return false

	_is_advancing = true
	if not _activate_registration_for_tick(registration, physics_frame):
		_is_advancing = false
		_finish_mutation()
		return false
	enemy.admit_scheduled_authoritative_tick(
		self,
		registration.token,
		_simulation_tick
	)
	enemy.simulate_authoritative_physics_step(
		delta,
		_simulation_tick,
		registration.token
	)
	_metric_authoritative_step_count += 1
	if not registration.tombstone:
		registration.active_this_tick = false
	_is_advancing = false
	_finish_mutation()
	return true


func mark_enemy_contact_geometry_dirty(enemy: Enemy, token: int) -> bool:
	var registration := _get_owned_registration(enemy, token)
	if (
		registration == null
		or not _uses_shared_contact_mode(_mode)
		or not registration.contact_proxy_registered
	):
		return false
	if registration.contact_geometry_dirty:
		_enqueue_indexed_touch_dirty(
			registration,
			INDEXED_TOUCH_DIRTY_CONTACT_GEOMETRY
		)
		return true
	registration.contact_geometry_dirty = true
	_dirty_contact_geometries.append(registration)
	_enqueue_indexed_touch_dirty(
		registration,
		INDEXED_TOUCH_DIRTY_CONTACT_GEOMETRY
	)
	return true


## Root Transform notifications arrive only for actual Node2D writes. Player
## contact is invalidated from the relative old-to-new sweep on the next current
## contact phase; the cached static-Plant corridor remains an independent fast
## proof and never inherits a global Player revision.
func mark_enemy_indexed_touch_transform_dirty(
	enemy: Enemy,
	token: int
) -> bool:
	var registration := _get_owned_registration(enemy, token)
	if (
		registration == null
		or not _uses_shared_contact_mode(_mode)
		or not registration.contact_proxy_registered
	):
		return false
	if (
		registration.contact_attacker_proxy == null
	):
		return mark_enemy_contact_geometry_dirty(enemy, token)
	var current_transform := (
		enemy.global_transform
			* registration.contact_attacker_local_transform
	)
	if (
		registration.contact_attacker_proxy == null
		or not registration.contact_attacker_proxy
			.is_translation_transform_supported(current_transform)
	):
		# Rotation/scale/shape-basis changes invalidate the immutable contact proxy.
		# The geometry queue performs the exact proxy recapture at the tick boundary.
		registration.indexed_touch_last_observed_transform = current_transform
		registration.indexed_touch_last_observed_transform_valid = true
		return mark_enemy_contact_geometry_dirty(enemy, token)
	if not registration.indexed_touch_authority_capable:
		# Shared enemy contact reads the translated root/shape anchor directly;
		# only rotation or scale requires immutable compound recapture above.
		return true
	if registration.contact_attacker_shape == null:
		_enqueue_indexed_touch_dirty(
			registration,
			INDEXED_TOUCH_DIRTY_TRANSFORM
		)
		return true
	_record_indexed_touch_enemy_translation(
		registration,
		current_transform
	)
	if _can_reuse_indexed_touch_safe_corridor(registration, enemy):
		_metric_indexed_touch_empty_corridor_skip_count += 1
		return true
	_enqueue_indexed_touch_dirty(
		registration,
		INDEXED_TOUCH_DIRTY_TRANSFORM
	)
	return true


func _record_indexed_touch_enemy_translation(
	registration: Registration,
	current_transform: Transform2D
) -> void:
	if registration == null or not current_transform.origin.is_finite():
		return
	if not registration.indexed_touch_last_observed_transform_valid:
		registration.indexed_touch_last_observed_transform = current_transform
		registration.indexed_touch_last_observed_transform_valid = true
		return
	var previous_position := (
		registration.indexed_touch_last_observed_transform.origin
	)
	var current_position := current_transform.origin
	registration.indexed_touch_last_observed_transform = current_transform
	if previous_position.is_equal_approx(current_position):
		return
	var segment_aabb := (
		registration.contact_attacker_proxy.get_swept_world_aabb(
			previous_position,
			current_position
		).grow(INDEXED_TOUCH_STATIC_ENVELOPE_EPSILON)
	)
	if not registration.indexed_touch_motion_pending:
		registration.indexed_touch_motion_from_position = previous_position
		registration.indexed_touch_motion_world_aabb = segment_aabb
		_enqueue_indexed_touch_moved_registration(registration)
	else:
		registration.indexed_touch_motion_world_aabb = (
			registration.indexed_touch_motion_world_aabb.merge(segment_aabb)
		)
	registration.indexed_touch_motion_to_position = current_position


func _enqueue_indexed_touch_moved_registration(
	registration: Registration
) -> bool:
	if registration == null or registration.indexed_touch_motion_pending:
		return false
	registration.indexed_touch_motion_pending = true
	var simulation_id := registration.simulation_id
	if (
		not _indexed_touch_moved_registrations.is_empty()
		and simulation_id
			< _indexed_touch_moved_queue_last_simulation_id
	):
		_indexed_touch_moved_queue_ordered = false
	_indexed_touch_moved_registrations.append(registration)
	_indexed_touch_moved_queue_last_simulation_id = simulation_id
	return true


func get_metrics(reset_after_read: bool = false) -> Dictionary:
	var snapshot := {
		"mode": int(_mode),
		"simulation_tick": _simulation_tick,
		"registered_count": _registered_count,
		"active_count": maxi(_registered_count - _suspended_count, 0),
		"suspended_count": _suspended_count,
		"slot_count": _registrations.size(),
		"tombstone_count": _tombstone_count,
		"decision_due_bucket_count": _decision_due_by_physics_frame.size(),
		"decision_urgent_queue_count": _urgent_decision_registrations.size(),
		"decision_due_bucket_pool_count": _decision_due_bucket_pool.size(),
		"event_ready_queue_count": _event_ready_registrations.size(),
		"event_due_bucket_count": _event_due_by_physics_frame.size(),
		"event_sleeping_count": _sleeping_event_registration_count,
		# Retained as zero-valued compatibility keys for older benchmark parsers.
		"touch_timer_projection_active_count": 0,
		"motion_active_count": _motion_active_registrations.size(),
		"compat_decision_count": _compat_decision_registrations.size(),
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
		"event_sleep_acks": _metric_event_sleep_ack_count,
		"touch_timer_projection_ticks": 0,
		"touch_cooldown_deadline_wakes": (
			_metric_touch_cooldown_deadline_wake_count
		),
		"decision_phases": _metric_decision_phase_count,
		"urgent_decisions": _metric_urgent_decision_count,
		"motion_phases": _metric_motion_phase_count,
		"contact_phases": _metric_contact_phase_count,
		"contact_registrations": _metric_contact_registration_count,
		"contact_registration_rejections": (
			_metric_contact_registration_rejection_count
		),
		"contact_atomic_rollbacks": _metric_contact_atomic_rollback_count,
		"indexed_touch_syncs": _metric_indexed_touch_sync_count,
		"indexed_touch_authority_enables": (
			_metric_indexed_touch_authority_count
		),
		"indexed_touch_plant_broadphases": (
			_metric_indexed_touch_plant_broadphase_count
		),
		"indexed_touch_plant_exact_candidates": (
			_metric_indexed_touch_plant_exact_candidate_count
		),
		"indexed_touch_plant_exact_shape_hits": (
			_metric_indexed_touch_plant_exact_shape_hit_count
		),
		"indexed_touch_plant_candidate_checks": (
			_metric_indexed_touch_plant_candidate_check_count
		),
		"indexed_touch_plant_sleep_skips": (
			_metric_indexed_touch_plant_sleep_skip_count
		),
		"indexed_touch_plant_exact_cache_hits": (
			_metric_indexed_touch_plant_exact_cache_hit_count
		),
		"indexed_touch_empty_snapshot_skips": (
			_metric_indexed_touch_empty_snapshot_skip_count
		),
		"indexed_touch_unchanged_snapshot_skips": (
			_metric_indexed_touch_unchanged_snapshot_skip_count
		),
		"indexed_touch_complete_snapshot_skips": (
			_metric_indexed_touch_complete_snapshot_skip_count
		),
		"indexed_touch_empty_corridor_skips": (
			_metric_indexed_touch_empty_corridor_skip_count
		),
		"indexed_touch_nonempty_plant_certificate_builds": (
			_metric_indexed_touch_nonempty_plant_certificate_build_count
		),
		"indexed_touch_nonempty_plant_certificate_reuses": (
			_metric_indexed_touch_nonempty_plant_certificate_reuse_count
		),
		"indexed_touch_nonempty_plant_certificate_rejects": (
			_metric_indexed_touch_nonempty_plant_certificate_reject_count
		),
		"indexed_touch_dirty_enqueues": (
			_metric_indexed_touch_dirty_enqueue_count
		),
		"indexed_touch_dirty_drains": (
			_metric_indexed_touch_dirty_drain_count
		),
		"indexed_touch_dirty_ordered_drains": (
			_metric_indexed_touch_dirty_ordered_drain_count
		),
		"indexed_touch_dirty_sorts": (
			_metric_indexed_touch_dirty_sort_count
		),
		"indexed_touch_moved_ordered_drains": (
			_metric_indexed_touch_moved_ordered_drain_count
		),
		"indexed_touch_moved_sorts": (
			_metric_indexed_touch_moved_sort_count
		),
		"indexed_touch_player_invalidations": (
			_metric_indexed_touch_player_invalidation_count
		),
		"indexed_touch_global_invalidations": (
			_metric_indexed_touch_global_invalidation_count
		),
		"indexed_touch_player_index_queries": (
			_metric_indexed_touch_player_index_query_count
		),
		"indexed_touch_player_index_candidates": (
			_metric_indexed_touch_player_index_candidate_count
		),
		"indexed_touch_player_aabb_pair_checks": (
			_metric_indexed_touch_player_aabb_pair_check_count
		),
		"indexed_touch_player_aabb_pair_hits": (
			_metric_indexed_touch_player_aabb_pair_hit_count
		),
		"indexed_touch_player_exact_shape_checks": (
			_metric_indexed_touch_player_exact_shape_check_count
		),
		"indexed_touch_player_exact_shape_hits": (
			_metric_indexed_touch_player_exact_shape_hit_count
		),
		"indexed_touch_exact_shape_checks": (
			_metric_indexed_touch_player_exact_shape_check_count
				+ _metric_indexed_touch_plant_exact_candidate_count
		),
		"indexed_touch_exact_shape_hits": (
			_metric_indexed_touch_player_exact_shape_hit_count
				+ _metric_indexed_touch_plant_exact_shape_hit_count
		),
		"indexed_touch_player_slow_path_movers": (
			_metric_indexed_touch_player_slow_path_mover_count
		),
		"indexed_touch_contact_enters": (
			_metric_indexed_touch_contact_enter_count
		),
		"indexed_touch_contact_exits": (
			_metric_indexed_touch_contact_exit_count
		),
		"touch_damage_attempts": _metric_touch_damage_attempt_count,
		"touch_damage_accepted": _metric_touch_damage_accepted_count,
		"touch_damage_rejected": _metric_touch_damage_rejected_count,
		"indexed_touch_dirty_queue_count": (
			_dirty_indexed_touch_registrations.size()
		),
		"activation_skips": _metric_activation_skip_count,
		"suspended_skips": _metric_suspended_skip_count,
		"invalid_enemy_releases": _metric_invalid_enemy_release_count,
		"compactions": _metric_compaction_count,
		"compacted_tombstones": _metric_compacted_tombstone_count,
		"clears": _metric_clear_count,
		"cleared_registrations": _metric_cleared_registration_count,
		"profile_contact_setup_usec": _metric_profile_contact_setup_usec,
		"profile_contact_admission_usec": (
			_metric_profile_contact_admission_usec
		),
		"profile_contact_geometry_usec": _metric_profile_contact_geometry_usec,
		"profile_contact_service_usec": _metric_profile_contact_service_usec,
		"profile_indexed_player_refresh_usec": (
			_metric_profile_indexed_player_refresh_usec
		),
		"profile_indexed_dirty_drain_usec": (
			_metric_profile_indexed_dirty_drain_usec
		),
		"profile_event_phase_usec": _metric_profile_event_phase_usec,
		"profile_decision_phase_usec": _metric_profile_decision_phase_usec,
		"profile_planned_contact_usec": _metric_profile_planned_contact_usec,
		"profile_motion_phase_usec": _metric_profile_motion_phase_usec,
	}
	if reset_after_read:
		_reset_cumulative_metrics()
	return snapshot


func record_touch_damage_attempt(accepted: bool) -> void:
	_metric_touch_damage_attempt_count += 1
	if accepted:
		_metric_touch_damage_accepted_count += 1
	else:
		_metric_touch_damage_rejected_count += 1


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
		if registration.enemy != null and is_instance_valid(registration.enemy):
			released_enemies.append(registration.enemy)
			released_tokens.append(registration.token)
			released_processing_states.append(
				restore_individual_callbacks and not registration.suspended
			)
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

	var physics_frame := Engine.get_physics_frames()
	if physics_frame <= _last_main_dispatch_physics_frame:
		return
	if (
		_is_layered_mode(_mode)
		and _last_main_dispatch_physics_frame >= 0
		and physics_frame > _last_main_dispatch_physics_frame + 1
	):
		_recover_sparse_event_deadlines_after_frame_gap(physics_frame)
		_recover_sparse_decision_cadence_after_frame_gap(physics_frame)
	if not _ensure_simulation_tick_for_physics_frame(physics_frame):
		return
	_last_main_dispatch_physics_frame = physics_frame
	var initial_slot_count := _registrations.size()
	_is_advancing = true
	if _is_layered_mode(_mode):
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
	var completed_steps := 0
	for slot_index in range(initial_slot_count):
		var registration := _registrations[slot_index]
		if (
			registration != null
			and registration.uses_anchored_compat_simulation
		):
			continue
		if not _activate_registration_for_tick(registration, physics_frame):
			continue
		var enemy := registration.enemy
		enemy.admit_scheduled_authoritative_tick(
			self,
			registration.token,
			_simulation_tick
		)
		enemy.simulate_authoritative_physics_step(
			delta,
			_simulation_tick,
			registration.token
		)
		completed_steps += 1
	_metric_authoritative_step_count += completed_steps


func _advance_layered_area(
	delta: float,
	physics_frame: int,
	initial_slot_count: int
) -> void:
	var uses_shared_contact := _uses_shared_contact_mode(_mode)
	var profile_started_usec := (
		Time.get_ticks_usec() if Enemy.performance_metrics_enabled else 0
	)
	if uses_shared_contact:
		_contact_geometry_sync_failed_this_tick = false
		var contact_substep_started_usec := (
			Time.get_ticks_usec() if Enemy.performance_metrics_enabled else 0
		)
		# Capture exact current enemy-enemy overlap before any event consults contact.
		# This snapshot contains no future sweep prediction.
		_admit_layered_contact_proxies_for_tick(physics_frame, initial_slot_count)
		if Enemy.performance_metrics_enabled:
			_metric_profile_contact_admission_usec += (
				Time.get_ticks_usec() - contact_substep_started_usec
			)
			contact_substep_started_usec = Time.get_ticks_usec()
		if _contact_geometry_sync_failed_this_tick:
			# Admission is a tick precondition, not a best-effort side lane. No
			# contact snapshot, timer, event, decision or movement may observe a
			# partially admitted cohort. _finish_mutation() commits COMPAT_60 and
			# releases every proxy/Area takeover at this physics boundary.
			if Enemy.performance_metrics_enabled:
				_metric_profile_contact_setup_usec += (
					Time.get_ticks_usec() - profile_started_usec
				)
			return
		# Dirty geometry also feeds indexed Player/Plant contact envelopes, so drain
		# this sparse queue even when no enemy factions currently oppose each other.
		_sync_layered_contact_proxy_geometry()
		if Enemy.performance_metrics_enabled:
			_metric_profile_contact_geometry_usec += (
				Time.get_ticks_usec() - contact_substep_started_usec
			)
			contact_substep_started_usec = Time.get_ticks_usec()
		if _contact_geometry_sync_failed_this_tick:
			# Recapture has the same all-or-nothing admission contract. The old proxy
			# remains untouched until the boundary rollback, so this return is before
			# every gameplay-capable phase in the failed tick.
			if Enemy.performance_metrics_enabled:
				_metric_profile_contact_setup_usec += (
					Time.get_ticks_usec() - profile_started_usec
				)
			return
		_refresh_layered_relation_revision(true)
		_step_layered_current_contact_service()
		if Enemy.performance_metrics_enabled:
			_metric_profile_contact_service_usec += (
				Time.get_ticks_usec() - contact_substep_started_usec
			)
			contact_substep_started_usec = Time.get_ticks_usec()
		_refresh_indexed_touch_player_candidates()
		if Enemy.performance_metrics_enabled:
			_metric_profile_indexed_player_refresh_usec += (
				Time.get_ticks_usec() - contact_substep_started_usec
			)
			contact_substep_started_usec = Time.get_ticks_usec()
		_drain_indexed_touch_dirty_queue()
		if Enemy.performance_metrics_enabled:
			_metric_profile_indexed_dirty_drain_usec += (
				Time.get_ticks_usec() - contact_substep_started_usec
			)
	else:
		_refresh_layered_relation_revision(false)
	if Enemy.performance_metrics_enabled:
		_metric_profile_contact_setup_usec += (
			Time.get_ticks_usec() - profile_started_usec
		)
		profile_started_usec = Time.get_ticks_usec()
	# Phase 1: only awake or exact-deadline registrations are visited. Trusted
	# sleepers are represented by an O(1) count until contact/target mutation or a
	# deadline wakes them; moving sleepers remain in the independent 60 Hz motion
	# list below. No movement is submitted before every due event has completed.
	_collect_sparse_event_work(physics_frame)
	_event_sleep_ack_metric_physics_frame = physics_frame
	_metric_event_sleep_ack_count += _sleeping_event_registration_count
	_event_phase_completed_physics_frame = -1
	_event_phase_active = true
	_event_phase_physics_frame = physics_frame
	_event_phase_cursor = 0
	while _event_phase_cursor < _event_work_registrations.size():
		var registration := _event_work_registrations[_event_phase_cursor]
		_event_phase_current_simulation_id = registration.simulation_id
		if not _ensure_registration_active_for_tick(registration, physics_frame):
			if (
				registration != null
				and not registration.tombstone
				and not registration.suspended
			):
				_enqueue_event_ready_registration(registration)
			_event_phase_cursor += 1
			continue
		var enemy := registration.enemy
		registration.event_admission_physics_frame = physics_frame
		# Trusted family entry points are reachable only after this exact
		# Registration has been admitted above. They deliberately do not consult
		# the public token cache, so rewriting its coordinator/token/tick triplet
		# for every enemy and every frame is dead work. Keep the cache for the
		# checked path used by non-trusted families and test harnesses.
		if not registration.uses_trusted_layered_phase_entrypoints:
			enemy.admit_scheduled_authoritative_tick(
				self,
				registration.token,
				_simulation_tick
			)
		var event_completed := false
		if registration.uses_trusted_layered_phase_entrypoints:
			# Ready/deadline collection invalidates the previous sleep certificate.
			# The family may publish a fresh one after advancing its due event.
			enemy.layered_area_event_phase_sleeping = false
			enemy.layered_area_event_sleep_until_physics_frame = -1
			event_completed = enemy.simulate_trusted_layered_area_event_phase(
				delta,
				_simulation_tick
			)
		elif enemy.can_sleep_layered_area_event_phase():
			event_completed = enemy.acknowledge_sleeping_layered_area_event_phase(
				_simulation_tick,
				registration.token
			)
		else:
			event_completed = enemy.simulate_layered_area_event_phase(
				delta,
				_simulation_tick,
				registration.token
			)
		if event_completed:
			_metric_event_phase_count += 1
			_metric_authoritative_step_count += 1
		_reconcile_event_registration(registration, physics_frame)
		_reconcile_motion_registration(registration)
		_event_phase_cursor += 1
	_event_phase_active = false
	_event_phase_physics_frame = -1
	_event_phase_cursor = -1
	_event_phase_current_simulation_id = INVALID_SIMULATION_ID
	_event_sleep_ack_metric_physics_frame = -1
	_event_phase_completed_physics_frame = physics_frame
	if Enemy.performance_metrics_enabled:
		_metric_profile_event_phase_usec += (
			Time.get_ticks_usec() - profile_started_usec
		)
		profile_started_usec = Time.get_ticks_usec()

	# Phase 2: physics-cadence families arrive through exact due-frame/urgent
	# queues. Non-physics compatibility families live in their own stable sparse
	# list, so this phase never scans the master Registration table.
	_collect_sparse_physics_decision_work(physics_frame)
	_collect_compat_decision_work(physics_frame)

	_decision_phase_active = true
	_decision_phase_physics_frame = physics_frame
	_decision_phase_cursor = 0
	while _decision_phase_cursor < _decision_work_registrations.size():
		var registration := (
			_decision_work_registrations[_decision_phase_cursor]
		)
		_decision_phase_current_simulation_id = registration.simulation_id
		if not _registration_has_event_admission_for_decision(
			registration,
			physics_frame
		):
			if (
				registration != null
				and not registration.tombstone
				and not registration.suspended
				and registration.uses_physics_phase_decisions
			):
				_schedule_next_physics_decision(registration, physics_frame)
				var deferred_enemy := registration.enemy
				if (
					deferred_enemy != null
					and is_instance_valid(deferred_enemy)
					and deferred_enemy.layered_area_decision_urgent
				):
					_enqueue_urgent_decision_registration(registration)
			_decision_phase_cursor += 1
			continue
		if not _ensure_registration_active_for_tick(registration, physics_frame):
			if (
				registration != null
				and not registration.tombstone
				and registration.uses_physics_phase_decisions
				and registration.scheduled_decision_physics_frame < 0
			):
				_schedule_next_physics_decision(registration, physics_frame)
			_decision_phase_cursor += 1
			continue
		var enemy := registration.enemy
		var urgent := (
			enemy.layered_area_decision_urgent
			if registration.uses_physics_phase_decisions
			else enemy.is_layered_area_decision_urgent()
		)
		var decision_completed := (
			enemy.simulate_trusted_layered_area_decision_phase(
				delta,
				_simulation_tick
			)
			if registration.uses_trusted_layered_phase_entrypoints
			else enemy.simulate_layered_area_decision_phase(
				delta,
				_simulation_tick,
				registration.token
			)
		)
		if decision_completed:
			_metric_decision_phase_count += 1
			if urgent:
				_metric_urgent_decision_count += 1
			# Physics-phase families use their cached interval/offset directly and
			# never read next_decision_tick. Avoid a virtual interval lookup and two
			# modulo operations on every completed Yuanshi decision.
			if not registration.uses_physics_phase_decisions:
				registration.next_decision_tick = _get_next_staggered_decision_tick(
					_simulation_tick,
					enemy.get_layered_area_decision_interval_frames(),
					registration.simulation_id
				)
		if registration.uses_physics_phase_decisions:
			_schedule_next_physics_decision(registration, physics_frame)
			if enemy.layered_area_decision_urgent:
				_enqueue_urgent_decision_registration(registration)
		# A decision may enter an authored attack state and revoke the event sleep
		# certificate without routing through request_layered_area_urgent_decision().
		_reconcile_event_registration(registration, physics_frame)
		_reconcile_motion_registration(registration)
		_decision_phase_cursor += 1
	_decision_phase_active = false
	_decision_phase_physics_frame = -1
	_decision_phase_cursor = -1
	_decision_phase_current_simulation_id = INVALID_SIMULATION_ID
	if Enemy.performance_metrics_enabled:
		_metric_profile_decision_phase_usec += (
			Time.get_ticks_usec() - profile_started_usec
		)
		profile_started_usec = Time.get_ticks_usec()

	# Facing and authored attack-state transitions may legitimately change a
	# compound contact shape during the decision phase. Recapture only that sparse
	# dirty set before planned contact so the same tick can still submit motion.
	# update_shape_proxies() is fail-before-mutation for each registration; if any
	# capture is unsupported, no later contact/motion phase runs and the complete
	# cohort commits its existing COMPAT_60 fallback at this tick boundary.
	if uses_shared_contact and not _dirty_contact_geometries.is_empty():
		_sync_layered_contact_proxy_geometry()
		if Enemy.performance_metrics_enabled:
			_metric_profile_contact_geometry_usec += (
				Time.get_ticks_usec() - profile_started_usec
			)
			profile_started_usec = Time.get_ticks_usec()
		if _contact_geometry_sync_failed_this_tick:
			return

	# Continuous enemy-enemy contact is predicted only after every movement plan
	# is final. The resulting directed TOI fractions clip this tick's displacement;
	# they never masquerade as current contact during event/decision phases.
	if uses_shared_contact:
		_step_layered_planned_contact_service(delta)
	if Enemy.performance_metrics_enabled:
		_metric_profile_planned_contact_usec += (
			Time.get_ticks_usec() - profile_started_usec
		)
		profile_started_usec = Time.get_ticks_usec()
	# Phase 3: CharacterBody2D motion remains 60 Hz. The exact physics delta is
	# passed through rather than being read from a disabled per-enemy callback.
	# The persistent list is compacted in-place while preserving simulation-ID
	# order; static enemies disappear without a master-table scan.
	_advance_persistent_motion(delta, physics_frame)
	if Enemy.performance_metrics_enabled:
		_metric_profile_motion_phase_usec += (
			Time.get_ticks_usec() - profile_started_usec
		)


func _activate_registration_for_tick(
	registration: Registration,
	physics_frame: int
) -> bool:
	# COMPAT/anchor entry points require a unique callback, whereas layered phases
	# share one admission across event, decision and motion. Keep this wrapper's
	# duplicate rejection while the sparse phases use the idempotent ensure helper.
	if (
		registration != null
		and registration.activation_check_physics_frame == physics_frame
	):
		return false
	return _ensure_registration_active_for_tick(registration, physics_frame)


func _ensure_registration_active_for_tick(
	registration: Registration,
	physics_frame: int
) -> bool:
	if registration == null or registration.tombstone:
		return false
	if registration.activation_check_physics_frame == physics_frame:
		return _registration_remains_active_this_tick(
			registration,
			physics_frame
		)
	registration.activation_check_physics_frame = physics_frame
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
	if registration.suspended:
		_metric_suspended_skip_count += 1
		return false
	if physics_frame <= registration.activation_physics_frame:
		_metric_activation_skip_count += 1
		return false
	registration.last_authoritative_physics_frame = physics_frame
	registration.active_this_tick = true
	return true


func _ensure_simulation_tick_for_physics_frame(physics_frame: int) -> bool:
	if physics_frame < 0 or physics_frame < _last_simulation_physics_frame:
		return false
	if physics_frame == _last_simulation_physics_frame:
		return true
	_last_simulation_physics_frame = physics_frame
	_simulation_tick += 1
	_metric_physics_tick_count += 1
	return true


func _registration_remains_active_this_tick(
	registration: Registration,
	physics_frame: int
) -> bool:
	if (
		registration == null
		or registration.tombstone
		or not registration.active_this_tick
		or registration.activation_check_physics_frame != physics_frame
		or registration.last_authoritative_physics_frame != physics_frame
		or registration.suspended
	):
		return false
	var enemy := registration.enemy
	if (
		enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_queued_for_deletion()
		or enemy.is_dead
	):
		_mark_tombstone(registration, true)
		return false
	return true


func _registration_has_event_admission_for_decision(
	registration: Registration,
	physics_frame: int
) -> bool:
	if registration == null or registration.tombstone or registration.suspended:
		return false
	if registration.event_admission_physics_frame == physics_frame:
		return true
	return (
		registration.uses_trusted_layered_phase_entrypoints
		and (
			registration.event_sleep_counted
			or registration.trusted_sleep_wake_after_event_physics_frame
				== physics_frame
		)
	)


func _set_event_sleep_counted(
	registration: Registration,
	counted: bool
) -> void:
	if registration == null or registration.event_sleep_counted == counted:
		return
	registration.event_sleep_counted = counted
	if counted:
		_sleeping_event_registration_count += 1
	else:
		_sleeping_event_registration_count = maxi(
			_sleeping_event_registration_count - 1,
			0
		)


func _enqueue_event_ready_registration(registration: Registration) -> bool:
	if (
		registration == null
		or registration.tombstone
		or registration.suspended
		or registration.uses_anchored_compat_simulation
	):
		return false
	registration.scheduled_event_physics_frame = -1
	_set_event_sleep_counted(registration, false)
	if registration.event_ready_enqueued:
		return true
	registration.event_ready_enqueued = true
	_event_ready_registrations.append(registration)
	return true


func _insert_event_work_registration(
	registration: Registration,
	physics_frame: int,
	minimum_index: int = 0
) -> void:
	if registration == null or registration.tombstone:
		return
	if registration.event_work_physics_frame == physics_frame:
		return
	registration.event_work_physics_frame = physics_frame
	registration.event_ready_enqueued = false
	var low := clampi(minimum_index, 0, _event_work_registrations.size())
	var high := _event_work_registrations.size()
	while low < high:
		var middle := (low + high) >> 1
		if (
			_event_work_registrations[middle].simulation_id
			< registration.simulation_id
		):
			low = middle + 1
		else:
			high = middle
	_event_work_registrations.insert(low, registration)


func _wake_event_registration(registration: Registration) -> bool:
	if (
		registration == null
		or registration.tombstone
		or registration.suspended
		or registration.uses_anchored_compat_simulation
	):
		return false
	var physics_frame := Engine.get_physics_frames()
	var was_counted_sleeping := registration.event_sleep_counted
	if (
		was_counted_sleeping
		and _event_phase_completed_physics_frame == physics_frame
	):
		# The old full scan had already acknowledged this trusted sleeper before
		# decisions began. Preserve that admission when an earlier decision wakes a
		# higher-ID registration after Phase 1 has closed.
		registration.trusted_sleep_wake_after_event_physics_frame = physics_frame
	registration.scheduled_event_physics_frame = -1
	_set_event_sleep_counted(registration, false)
	var enemy := registration.enemy
	if enemy != null and is_instance_valid(enemy):
		enemy.layered_area_event_phase_sleeping = false
		enemy.layered_area_event_sleep_until_physics_frame = -1
	if (
		_event_phase_active
		and _event_phase_physics_frame == physics_frame
		and registration.event_work_physics_frame != physics_frame
		and registration.simulation_id > _event_phase_current_simulation_id
	):
		if (
			was_counted_sleeping
			and _event_sleep_ack_metric_physics_frame == physics_frame
		):
			# The aggregate O(1) sleep metric was recorded before event callbacks.
			# This registration now executes a real event in the same tick, so remove
			# exactly its provisional acknowledgement.
			_metric_event_sleep_ack_count = maxi(
				_metric_event_sleep_ack_count - 1,
				0
			)
		registration.event_ready_enqueued = false
		_insert_event_work_registration(
			registration,
			physics_frame,
			_event_phase_cursor + 1
		)
		return true
	if (
		_event_phase_active
		and _event_phase_physics_frame == physics_frame
		and registration.event_work_physics_frame == physics_frame
		and registration.simulation_id > _event_phase_current_simulation_id
	):
		return true
	return _enqueue_event_ready_registration(registration)


func _schedule_event_deadline(
	registration: Registration,
	due_frame: int
) -> void:
	if (
		registration == null
		or registration.tombstone
		or registration.suspended
		or due_frame < 0
	):
		return
	if registration.scheduled_event_physics_frame == due_frame:
		return
	registration.scheduled_event_physics_frame = due_frame
	if not _event_due_by_physics_frame.has(due_frame):
		var recycled_bucket: Array = (
			_event_due_bucket_pool.pop_back()
			if not _event_due_bucket_pool.is_empty()
			else []
		)
		_event_due_by_physics_frame[due_frame] = recycled_bucket
	var due_registrations: Array = _event_due_by_physics_frame[due_frame]
	due_registrations.append(registration)


func _collect_sparse_event_work(physics_frame: int) -> void:
	_event_work_registrations.clear()
	if _event_due_by_physics_frame.has(physics_frame):
		var due_registrations: Array = _event_due_by_physics_frame[physics_frame]
		_event_due_by_physics_frame.erase(physics_frame)
		for due_variant in due_registrations:
			var registration := due_variant as Registration
			if (
				registration == null
				or registration.tombstone
				or registration.suspended
				or registration.scheduled_event_physics_frame != physics_frame
			):
				continue
			registration.scheduled_event_physics_frame = -1
			_set_event_sleep_counted(registration, false)
			var enemy := registration.enemy
			if enemy != null and is_instance_valid(enemy):
				if (
					enemy.get_touch_damage_cooldown_deadline_physics_frame()
						== physics_frame
				):
					_metric_touch_cooldown_deadline_wake_count += 1
				enemy.layered_area_event_phase_sleeping = false
				enemy.layered_area_event_sleep_until_physics_frame = -1
			_insert_event_work_registration(registration, physics_frame)
		due_registrations.clear()
		if _event_due_bucket_pool.size() < DECISION_DUE_BUCKET_POOL_LIMIT:
			_event_due_bucket_pool.append(due_registrations)

	var ready_count := _event_ready_registrations.size()
	for ready_index in range(ready_count):
		var registration := _event_ready_registrations[ready_index]
		if (
			registration == null
			or registration.tombstone
			or registration.suspended
			or not registration.event_ready_enqueued
		):
			continue
		registration.event_ready_enqueued = false
		_insert_event_work_registration(registration, physics_frame)
	_event_ready_registrations.clear()


func _reconcile_event_registration(
	registration: Registration,
	physics_frame: int
) -> void:
	if (
		registration == null
		or registration.tombstone
		or registration.suspended
	):
		return
	var enemy := registration.enemy
	if enemy == null or not is_instance_valid(enemy):
		return
	# Only trusted families can omit the synthetic per-tick admission/ack write.
	# Checked compatibility families stay in the ready list even if they advertise
	# a sleep predicate, preserving their follow-up token semantics.
	if (
		registration.uses_trusted_layered_phase_entrypoints
		and enemy.layered_area_event_phase_sleeping
	):
		var sleep_deadline := enemy.layered_area_event_sleep_until_physics_frame
		if sleep_deadline >= 0 and sleep_deadline <= physics_frame:
			enemy.layered_area_event_phase_sleeping = false
			enemy.layered_area_event_sleep_until_physics_frame = -1
			_enqueue_event_ready_registration(registration)
			return
		_set_event_sleep_counted(registration, true)
		registration.event_ready_enqueued = false
		if sleep_deadline >= 0:
			_schedule_event_deadline(registration, sleep_deadline)
		return
	_enqueue_event_ready_registration(registration)


func _recover_sparse_event_deadlines_after_frame_gap(
	physics_frame: int
) -> void:
	# Deadline buckets are exact-frame stamps. If a paused SceneTree skips one,
	# wake only registrations held by stale buckets and let the resumed tick
	# recompute their family certificate; future buckets remain untouched.
	var stale_frames: Array[int] = []
	for due_frame_variant in _event_due_by_physics_frame.keys():
		var due_frame := int(due_frame_variant)
		if due_frame < physics_frame:
			stale_frames.append(due_frame)
	stale_frames.sort()
	for due_frame in stale_frames:
		var due_registrations: Array = _event_due_by_physics_frame[due_frame]
		_event_due_by_physics_frame.erase(due_frame)
		for due_variant in due_registrations:
			var registration := due_variant as Registration
			if (
				registration == null
				or registration.tombstone
				or registration.suspended
				or registration.scheduled_event_physics_frame != due_frame
			):
				continue
			var enemy := registration.enemy
			if (
				enemy != null
				and is_instance_valid(enemy)
				and enemy.get_touch_damage_cooldown_deadline_physics_frame()
					== due_frame
			):
				_metric_touch_cooldown_deadline_wake_count += 1
			_wake_event_registration(registration)
		due_registrations.clear()
		if _event_due_bucket_pool.size() < DECISION_DUE_BUCKET_POOL_LIMIT:
			_event_due_bucket_pool.append(due_registrations)


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


func _configure_registration_decision_schedule(
	registration: Registration,
	enemy: Enemy
) -> void:
	registration.uses_physics_phase_decisions = (
		enemy.uses_layered_area_physics_phase_decisions()
	)
	registration.decision_interval_frames = maxi(
		enemy.get_layered_area_decision_interval_frames(),
		1
	)
	registration.decision_phase_offset = (
		enemy.get_layered_area_decision_phase_offset()
	)
	registration.uses_trusted_layered_phase_entrypoints = (
		enemy.uses_trusted_layered_phase_entrypoints()
	)


func _get_next_physics_decision_frame(
	after_physics_frame: int,
	interval: int,
	phase_offset: int
) -> int:
	var safe_interval := maxi(interval, 1)
	var next_frame := after_physics_frame + 1
	if safe_interval <= 1:
		return next_frame
	var remainder := posmod(next_frame + phase_offset, safe_interval)
	if remainder != 0:
		next_frame += safe_interval - remainder
	return next_frame


func _schedule_next_physics_decision(
	registration: Registration,
	after_physics_frame: int
) -> void:
	if (
		registration == null
		or registration.tombstone
		or registration.suspended
		or not registration.uses_physics_phase_decisions
	):
		return
	var enemy := registration.enemy
	if enemy != null and is_instance_valid(enemy):
		# Policy values are sampled only when a real decision is (re)scheduled,
		# keeping runtime tuning coherent without restoring a 60 Hz virtual call.
		registration.decision_interval_frames = maxi(
			enemy.get_layered_area_decision_interval_frames(),
			1
		)
		registration.decision_phase_offset = (
			enemy.get_layered_area_decision_phase_offset()
		)
	var due_frame := (
		enemy.get_next_layered_area_decision_physics_frame(
			after_physics_frame
		)
		if enemy != null and is_instance_valid(enemy)
		else _get_next_physics_decision_frame(
			after_physics_frame,
			registration.decision_interval_frames,
			registration.decision_phase_offset
		)
	)
	due_frame = maxi(due_frame, after_physics_frame + 1)
	if registration.scheduled_decision_physics_frame == due_frame:
		return
	registration.scheduled_decision_physics_frame = due_frame
	if not _decision_due_by_physics_frame.has(due_frame):
		var recycled_bucket: Array = (
			_decision_due_bucket_pool.pop_back()
			if not _decision_due_bucket_pool.is_empty()
			else []
		)
		_decision_due_by_physics_frame[due_frame] = recycled_bucket
	var due_registrations: Array = _decision_due_by_physics_frame[due_frame]
	due_registrations.append(registration)


func _recover_sparse_decision_cadence_after_frame_gap(
	physics_frame: int
) -> void:
	# A paused SceneTree/debugger can skip the exact Dictionary key that owned a
	# periodic decision. Rebuild only the sparse cadence table; urgent work and
	# fixed modulo phase remain intact, and no missed decisions are replayed.
	for due_variant in _decision_due_by_physics_frame.values():
		var due_registrations := due_variant as Array
		if due_registrations == null:
			continue
		due_registrations.clear()
		if _decision_due_bucket_pool.size() < DECISION_DUE_BUCKET_POOL_LIMIT:
			_decision_due_bucket_pool.append(due_registrations)
	_decision_due_by_physics_frame.clear()
	for registration in _registrations:
		if (
			registration == null
			or registration.tombstone
			or registration.suspended
			or registration.uses_anchored_compat_simulation
			or not registration.uses_physics_phase_decisions
		):
			continue
		registration.scheduled_decision_physics_frame = -1
		_schedule_next_physics_decision(registration, physics_frame - 1)


func _enqueue_urgent_decision_registration(
	registration: Registration
) -> bool:
	if (
		registration == null
		or registration.tombstone
		or registration.suspended
		or registration.uses_anchored_compat_simulation
		or not registration.uses_physics_phase_decisions
	):
		return false
	if registration.urgent_decision_enqueued:
		return true
	registration.urgent_decision_enqueued = true
	_urgent_decision_registrations.append(registration)
	return true


func _insert_decision_work_registration(
	registration: Registration,
	physics_frame: int,
	_urgent: bool,
	minimum_index: int = 0
) -> void:
	if registration == null or registration.tombstone:
		return
	if registration.decision_work_physics_frame == physics_frame:
		return
	registration.decision_work_physics_frame = physics_frame
	var low := clampi(minimum_index, 0, _decision_work_registrations.size())
	var high := _decision_work_registrations.size()
	while low < high:
		var middle := (low + high) >> 1
		if (
			_decision_work_registrations[middle].simulation_id
			< registration.simulation_id
		):
			low = middle + 1
		else:
			high = middle
	_decision_work_registrations.insert(low, registration)


func _register_compat_decision_registration(
	registration: Registration
) -> void:
	if (
		registration == null
		or registration.tombstone
		or registration.uses_anchored_compat_simulation
		or registration.uses_physics_phase_decisions
		or registration.compat_decision_listed
	):
		return
	registration.compat_decision_listed = true
	# Simulation IDs are monotonic and mode preparation walks the already sorted
	# master registrations, so ordinary admission is an ordered append.
	_compat_decision_registrations.append(registration)


func _collect_sparse_physics_decision_work(physics_frame: int) -> void:
	_decision_work_registrations.clear()
	if _decision_due_by_physics_frame.has(physics_frame):
		var due_registrations: Array = (
			_decision_due_by_physics_frame[physics_frame]
		)
		_decision_due_by_physics_frame.erase(physics_frame)
		for due_variant in due_registrations:
			var registration := due_variant as Registration
			if (
				registration == null
				or registration.tombstone
				or registration.scheduled_decision_physics_frame
					!= physics_frame
			):
				continue
			registration.scheduled_decision_physics_frame = -1
			if (
				_registration_has_event_admission_for_decision(
					registration,
					physics_frame
				)
				and _ensure_registration_active_for_tick(
					registration,
					physics_frame
				)
			):
				_insert_decision_work_registration(
					registration,
					physics_frame,
					false
				)
			else:
				_schedule_next_physics_decision(registration, physics_frame)
		due_registrations.clear()
		if _decision_due_bucket_pool.size() < DECISION_DUE_BUCKET_POOL_LIMIT:
			_decision_due_bucket_pool.append(due_registrations)

	var retained_urgent_count := 0
	for registration in _urgent_decision_registrations:
		if registration == null or registration.tombstone:
			continue
		var enemy := registration.enemy
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or not enemy.layered_area_decision_urgent
		):
			registration.urgent_decision_enqueued = false
			continue
		if registration.suspended:
			registration.urgent_decision_enqueued = false
			continue
		if not _registration_has_event_admission_for_decision(
			registration,
			physics_frame
		):
			_urgent_decision_registrations[retained_urgent_count] = registration
			retained_urgent_count += 1
			continue
		if not _ensure_registration_active_for_tick(registration, physics_frame):
			_urgent_decision_registrations[retained_urgent_count] = registration
			retained_urgent_count += 1
			continue
		registration.urgent_decision_enqueued = false
		_insert_decision_work_registration(
			registration,
			physics_frame,
			true
		)
	_urgent_decision_registrations.resize(retained_urgent_count)


func _collect_compat_decision_work(physics_frame: int) -> void:
	var write_index := 0
	var compat_count := _compat_decision_registrations.size()
	for read_index in range(compat_count):
		var registration := _compat_decision_registrations[read_index]
		if (
			registration == null
			or registration.tombstone
			or not registration.compat_decision_listed
		):
			continue
		_compat_decision_registrations[write_index] = registration
		write_index += 1
		if registration.suspended:
			continue
		var enemy := registration.enemy
		if enemy == null or not is_instance_valid(enemy):
			_ensure_registration_active_for_tick(registration, physics_frame)
			continue
		var urgent := enemy.is_layered_area_decision_urgent()
		if not urgent and _simulation_tick < registration.next_decision_tick:
			continue
		if not _registration_has_event_admission_for_decision(
			registration,
			physics_frame
		):
			continue
		if not _ensure_registration_active_for_tick(registration, physics_frame):
			continue
		_insert_decision_work_registration(
			registration,
			physics_frame,
			urgent
		)
	_compat_decision_registrations.resize(write_index)


func _is_registration_motion_due(
	registration: Registration,
	enemy: Enemy
) -> bool:
	if registration == null or enemy == null or not is_instance_valid(enemy):
		return false
	return (
		enemy.layered_area_motion_phase_due
		if registration.uses_trusted_layered_phase_entrypoints
		else enemy.should_execute_layered_area_motion_phase()
	)


func _reconcile_motion_registration(registration: Registration) -> void:
	if (
		registration == null
		or registration.tombstone
		or registration.suspended
		or registration.motion_listed
	):
		return
	var enemy := registration.enemy
	if not _is_registration_motion_due(registration, enemy):
		return
	registration.motion_listed = true
	var low := 0
	var high := _motion_active_registrations.size()
	while low < high:
		var middle := (low + high) >> 1
		if (
			_motion_active_registrations[middle].simulation_id
			< registration.simulation_id
		):
			low = middle + 1
		else:
			high = middle
	_motion_active_registrations.insert(low, registration)


func _advance_persistent_motion(
	delta: float,
	physics_frame: int
) -> void:
	var write_index := 0
	var active_count := _motion_active_registrations.size()
	for read_index in range(active_count):
		var registration := _motion_active_registrations[read_index]
		if (
			registration == null
			or registration.tombstone
			or not registration.motion_listed
		):
			continue
		if registration.suspended:
			registration.motion_listed = false
			continue
		if not _ensure_registration_active_for_tick(registration, physics_frame):
			if registration.tombstone or registration.suspended:
				registration.motion_listed = false
				continue
			_motion_active_registrations[write_index] = registration
			write_index += 1
			continue
		var enemy := registration.enemy
		if not _is_registration_motion_due(registration, enemy):
			registration.motion_listed = false
			continue
		var motion_completed := (
			enemy.simulate_trusted_layered_area_motion_phase(
				delta,
				_simulation_tick
			)
			if registration.uses_trusted_layered_phase_entrypoints
			else enemy.simulate_layered_area_motion_phase(
				delta,
				_simulation_tick,
				registration.token
			)
		)
		if motion_completed:
			_metric_motion_phase_count += 1
		if (
			not registration.tombstone
			and not registration.suspended
			and _is_registration_motion_due(registration, registration.enemy)
		):
			_motion_active_registrations[write_index] = registration
			write_index += 1
		else:
			registration.motion_listed = false
	_motion_active_registrations.resize(write_index)


func _reset_layered_scheduler_state() -> void:
	for due_variant in _event_due_by_physics_frame.values():
		var due_registrations := due_variant as Array
		if due_registrations == null:
			continue
		due_registrations.clear()
		if _event_due_bucket_pool.size() < DECISION_DUE_BUCKET_POOL_LIMIT:
			_event_due_bucket_pool.append(due_registrations)
	_event_due_by_physics_frame.clear()
	for due_variant in _decision_due_by_physics_frame.values():
		var due_registrations := due_variant as Array
		if due_registrations == null:
			continue
		due_registrations.clear()
		if _decision_due_bucket_pool.size() < DECISION_DUE_BUCKET_POOL_LIMIT:
			_decision_due_bucket_pool.append(due_registrations)
	_decision_due_by_physics_frame.clear()
	_urgent_decision_registrations.clear()
	_decision_work_registrations.clear()
	_event_ready_registrations.clear()
	_event_work_registrations.clear()
	_motion_active_registrations.clear()
	_compat_decision_registrations.clear()
	_sleeping_event_registration_count = 0
	_event_phase_active = false
	_event_phase_physics_frame = -1
	_event_phase_cursor = -1
	_event_phase_current_simulation_id = INVALID_SIMULATION_ID
	_event_phase_completed_physics_frame = -1
	_event_sleep_ack_metric_physics_frame = -1
	_decision_phase_active = false
	_decision_phase_physics_frame = -1
	_decision_phase_cursor = -1
	_decision_phase_current_simulation_id = INVALID_SIMULATION_ID
	for registration in _registrations:
		if registration == null:
			continue
		registration.scheduled_decision_physics_frame = -1
		registration.urgent_decision_enqueued = false
		registration.decision_work_physics_frame = -1
		registration.event_ready_enqueued = false
		registration.event_work_physics_frame = -1
		registration.scheduled_event_physics_frame = -1
		registration.event_sleep_counted = false
		registration.event_admission_physics_frame = -1
		registration.trusted_sleep_wake_after_event_physics_frame = -1
		registration.motion_listed = false
		registration.compat_decision_listed = false
		registration.activation_check_physics_frame = -1
		registration.active_this_tick = false


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
	var enemy := registration.enemy
	if enemy != null and is_instance_valid(enemy):
		# Every ownership-release path restores the authored Player/Plant contact
		# sensor before this registration drops its enemy reference.
		enemy.set_indexed_touch_authority(false)
		var faction_callback := Callable(
			self,
			&"_on_registered_enemy_combat_faction_changed"
		)
		if enemy.combat_faction_changed.is_connected(faction_callback):
			enemy.combat_faction_changed.disconnect(faction_callback)
	_unregister_contact_proxy(registration)
	if (
		_registration_by_instance_id.get(registration.instance_id)
		== registration
	):
		_registration_by_instance_id.erase(registration.instance_id)
	if registration.suspended:
		_suspended_count = maxi(_suspended_count - 1, 0)
	_set_event_sleep_counted(registration, false)
	registration.suspended = false
	registration.active_this_tick = false
	registration.scheduled_decision_physics_frame = -1
	registration.urgent_decision_enqueued = false
	registration.event_ready_enqueued = false
	registration.scheduled_event_physics_frame = -1
	registration.motion_listed = false
	registration.compat_decision_listed = false
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
		_apply_mode(next_mode, false, false)


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
	if _registered_count <= 0:
		_reset_layered_scheduler_state()
	_metric_compaction_count += 1
	_metric_compacted_tombstone_count += previous_tombstone_count


func _clear_slot_storage() -> void:
	_registrations.clear()
	_registration_by_instance_id.clear()
	_pending_contact_admissions.clear()
	_dirty_contact_geometries.clear()
	_clear_indexed_touch_invalidation_queues()
	_indexed_touch_nonempty_player_registrations.clear()
	_tombstone_count = 0
	_registered_count = 0
	_suspended_count = 0
	_maximum_indexed_touch_enemy_extent = 0.0
	_maximum_indexed_touch_enemy_extent_dirty = false
	_reset_layered_scheduler_state()
	_deferred_claim_mode = -1
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
	var combat_services := get_combat_services()
	_damageable_spatial_index = (
		combat_services.get_enemy_damageable_spatial_index()
		if combat_services != null
		else null
	)
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
	if _uses_shared_contact_mode(simulation_mode):
		_contact_service.request_mode(
			EnemyContactService.Mode.HYBRID_ENEMY_CONTACT
		)
		_queue_all_contact_admissions()
		return
	_unregister_all_contact_proxies()
	_pending_contact_admissions.clear()
	_disable_and_clear_contact_service_at_boundary()


func _refresh_indexed_touch_player_candidates() -> void:
	_indexed_touch_previous_player_instance_ids.assign(
		_indexed_touch_player_instance_ids
	)
	_indexed_touch_previous_player_shapes.assign(
		_indexed_touch_player_shapes
	)
	_indexed_touch_previous_player_transforms.assign(
		_indexed_touch_player_transforms
	)
	_indexed_touch_previous_player_positions.assign(
		_indexed_touch_player_positions
	)
	_indexed_touch_previous_player_extents.assign(
		_indexed_touch_player_extents
	)
	_indexed_touch_previous_player_shape_rects.assign(
		_indexed_touch_player_shape_rects
	)
	_indexed_touch_previous_player_world_aabbs.assign(
		_indexed_touch_player_world_aabbs
	)
	_indexed_touch_living_players.clear()
	var runtime := get_parent() as CombatRuntimeBase
	if runtime != null:
		runtime.query_living_players_into(_indexed_touch_living_players)
	_indexed_touch_living_players.sort_custom(
		func(left: Player, right: Player) -> bool:
			return left.get_instance_id() < right.get_instance_id()
	)
	var player_count := _indexed_touch_living_players.size()
	_indexed_touch_player_instance_ids.resize(player_count)
	_indexed_touch_player_shapes.resize(player_count)
	_indexed_touch_player_transforms.resize(player_count)
	_indexed_touch_player_positions.resize(player_count)
	_indexed_touch_player_extents.resize(player_count)
	_indexed_touch_player_shape_rects.resize(player_count)
	_indexed_touch_player_world_aabbs.resize(player_count)
	_indexed_touch_player_swept_world_aabbs.resize(player_count)
	_indexed_touch_player_state_changed_flags.resize(player_count)
	_indexed_touch_any_player_state_changed_this_tick = false
	for player_index in range(player_count):
		_indexed_touch_player_state_changed_flags[player_index] = false
		var player := _indexed_touch_living_players[player_index]
		_indexed_touch_player_instance_ids[player_index] = (
			player.get_instance_id()
		)
		var shape_node := player.collision_shape
		var player_shape: Shape2D = null
		var player_transform := Transform2D()
		if (
			shape_node != null
			and is_instance_valid(shape_node)
			and not shape_node.disabled
			and shape_node.shape != null
		):
			player_shape = shape_node.shape
			player_transform = shape_node.global_transform
		var player_position := (
			player_transform.origin
			if player_shape != null
			else player.global_position
		)
		var player_world_aabb := (
			_get_indexed_touch_shape_world_aabb(
				player_shape,
				player_transform
			)
			if player_shape != null
			else Rect2()
		)
		var player_extent := (
			_get_indexed_touch_player_extent_radius(
				player_position,
				shape_node,
				player_shape
			)
			if player_shape != null
			else 0.0
		)
		_indexed_touch_player_shapes[player_index] = player_shape
		_indexed_touch_player_transforms[player_index] = player_transform
		_indexed_touch_player_positions[player_index] = player_position
		_indexed_touch_player_extents[player_index] = player_extent
		_indexed_touch_player_shape_rects[player_index] = (
			player_shape.get_rect() if player_shape != null else Rect2()
		)
		_indexed_touch_player_world_aabbs[player_index] = player_world_aabb
		_indexed_touch_player_swept_world_aabbs[player_index] = player_world_aabb
	if _maximum_indexed_touch_enemy_extent_dirty:
		_recompute_maximum_indexed_touch_enemy_extent()
	_invalidate_indexed_touch_for_changed_players()
	_invalidate_indexed_touch_for_moved_enemies()
	_indexed_touch_has_registered_plants_this_tick = (
		_damageable_spatial_index != null
		and is_instance_valid(_damageable_spatial_index)
		and _damageable_spatial_index.has_registered_damageables()
	)
	var next_plant_geometry_revision := (
		_damageable_spatial_index.get_geometry_revision()
		if _damageable_spatial_index != null
		and is_instance_valid(_damageable_spatial_index)
		else -1
	)
	if (
		next_plant_geometry_revision
		!= _indexed_touch_plant_geometry_revision_this_tick
	):
		_indexed_touch_plant_geometry_revision_this_tick = (
			next_plant_geometry_revision
		)
		_enqueue_all_indexed_touch_authority(
			INDEXED_TOUCH_DIRTY_PLANT_GEOMETRY
		)
		_metric_indexed_touch_global_invalidation_count += 1


## Relation edits are rare, but a sleeping native-Area enemy would otherwise keep
## an obsolete contact/target decision until its cooldown deadline. Poll the
## monotonic revision once per layered tick and fan out only when it changes.
## Indexed contact receives the same invalidation before its snapshot is drained.
func _refresh_layered_relation_revision(uses_shared_contact: bool) -> void:
	var next_relation_revision := (
		_combat_relation_service.get_revision()
		if _combat_relation_service != null
		else -1
	)
	if next_relation_revision == _indexed_touch_relation_revision_this_tick:
		return
	var previous_relation_revision := _indexed_touch_relation_revision_this_tick
	_indexed_touch_relation_revision_this_tick = next_relation_revision
	if uses_shared_contact:
		_enqueue_all_indexed_touch_authority(INDEXED_TOUCH_DIRTY_RELATION)
		_metric_indexed_touch_global_invalidation_count += 1
	if previous_relation_revision < 0:
		return
	for registration in _registrations:
		if (
			registration == null
			or registration.tombstone
			or registration.suspended
			or registration.uses_anchored_compat_simulation
		):
			continue
		var enemy := registration.enemy
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		_wake_event_registration(registration)
		enemy.request_layered_area_urgent_decision()


func _get_indexed_touch_player_extent_radius(
	player_position: Vector2,
	shape_node: CollisionShape2D,
	shape: Shape2D
) -> float:
	if shape_node == null or shape == null:
		return 0.0
	var shape_rect := shape.get_rect()
	var maximum_radius := 0.0
	var local_corners: Array[Vector2] = [
		shape_rect.position,
		Vector2(shape_rect.end.x, shape_rect.position.y),
		shape_rect.end,
		Vector2(shape_rect.position.x, shape_rect.end.y),
	]
	for local_corner in local_corners:
		maximum_radius = maxf(
			maximum_radius,
			player_position.distance_to(
				shape_node.global_transform * local_corner
			)
		)
	return maximum_radius


func _get_indexed_touch_shape_world_aabb(
	shape: Shape2D,
	world_transform: Transform2D
) -> Rect2:
	if shape == null or not world_transform.origin.is_finite():
		return Rect2()
	var local_rect := shape.get_rect()
	var first := world_transform * local_rect.position
	var second := world_transform * Vector2(
		local_rect.end.x,
		local_rect.position.y
	)
	var third := world_transform * local_rect.end
	var fourth := world_transform * Vector2(
		local_rect.position.x,
		local_rect.end.y
	)
	var minimum := Vector2(
		minf(minf(first.x, second.x), minf(third.x, fourth.x)),
		minf(minf(first.y, second.y), minf(third.y, fourth.y))
	)
	var maximum := Vector2(
		maxf(maxf(first.x, second.x), maxf(third.x, fourth.x)),
		maxf(maxf(first.y, second.y), maxf(third.y, fourth.y))
	)
	return Rect2(minimum, maximum - minimum)


func _invalidate_indexed_touch_for_changed_players() -> void:
	var previous_index := 0
	var current_index := 0
	var previous_count := _indexed_touch_previous_player_instance_ids.size()
	var current_count := _indexed_touch_living_players.size()
	var player_state_changed := false
	while previous_index < previous_count or current_index < current_count:
		var previous_id := (
			_indexed_touch_previous_player_instance_ids[previous_index]
			if previous_index < previous_count
			else 9223372036854775807
		)
		var current_id := (
			_indexed_touch_player_instance_ids[current_index]
			if current_index < current_count
			else 9223372036854775807
		)
		if previous_id == current_id:
			var previous_shape := (
				_indexed_touch_previous_player_shapes[previous_index]
			)
			var current_shape := _indexed_touch_player_shapes[current_index]
			var previous_aabb := (
				_indexed_touch_previous_player_world_aabbs[previous_index]
			)
			var current_aabb := (
				_indexed_touch_player_world_aabbs[current_index]
			)
			_indexed_touch_player_swept_world_aabbs[current_index] = (
				_merge_indexed_touch_player_world_aabbs(
					previous_aabb,
					previous_shape,
					current_aabb,
					current_shape
				)
			)
			if _indexed_touch_player_state_changed(
				previous_index,
				current_index
			):
				player_state_changed = true
				_indexed_touch_player_state_changed_flags[current_index] = true
			previous_index += 1
			current_index += 1
		elif previous_id < current_id:
			player_state_changed = true
			previous_index += 1
		else:
			player_state_changed = true
			_indexed_touch_player_state_changed_flags[current_index] = true
			current_index += 1
	if not player_state_changed:
		return
	_indexed_touch_any_player_state_changed_this_tick = true
	_enqueue_indexed_touch_nonempty_player_snapshots()
	_metric_indexed_touch_player_invalidation_count += 1


func _indexed_touch_player_state_changed(
	previous_index: int,
	current_index: int
) -> bool:
	return (
		_indexed_touch_previous_player_shapes[previous_index]
			!= _indexed_touch_player_shapes[current_index]
		or _indexed_touch_previous_player_transforms[previous_index]
			!= _indexed_touch_player_transforms[current_index]
		or not is_equal_approx(
			_indexed_touch_previous_player_extents[previous_index],
			_indexed_touch_player_extents[current_index]
		)
		or _indexed_touch_previous_player_shape_rects[previous_index]
			!= _indexed_touch_player_shape_rects[current_index]
	)


func _merge_indexed_touch_player_world_aabbs(
	previous_aabb: Rect2,
	previous_shape: Shape2D,
	current_aabb: Rect2,
	current_shape: Shape2D
) -> Rect2:
	if previous_shape == null:
		return current_aabb
	if current_shape == null:
		return previous_aabb
	return previous_aabb.merge(current_aabb)


func _invalidate_indexed_touch_for_moved_enemies() -> void:
	if (
		_indexed_touch_moved_registrations.is_empty()
		and not _indexed_touch_any_player_state_changed_this_tick
	):
		return
	# Swap the producer and reusable consumer buffers. Transform notifications
	# raised while this drain is running append to the now-empty producer and are
	# retained for the next contact setup without copying/filtering this batch.
	var recycled_queue := _indexed_touch_moved_work_registrations
	_indexed_touch_moved_work_registrations = (
		_indexed_touch_moved_registrations
	)
	_indexed_touch_moved_registrations = recycled_queue
	_indexed_touch_moved_registrations.clear()
	var queue_was_ordered := _indexed_touch_moved_queue_ordered
	_indexed_touch_moved_queue_ordered = true
	_indexed_touch_moved_queue_last_simulation_id = INVALID_SIMULATION_ID
	if queue_was_ordered and not _indexed_touch_moved_work_registrations.is_empty():
		_metric_indexed_touch_moved_ordered_drain_count += 1
	elif not _indexed_touch_moved_work_registrations.is_empty():
		_indexed_touch_moved_work_registrations.sort_custom(
			func(left: Registration, right: Registration) -> bool:
				return left.simulation_id < right.simulation_id
		)
		_metric_indexed_touch_moved_sort_count += 1
	var movement_generation := Engine.get_physics_frames()
	var maximum_normal_motion := 0.0
	var normal_mover_count := 0
	var can_use_player_index := (
		_combat_target_index != null
		and is_instance_valid(_combat_target_index)
	)
	_indexed_touch_slow_path_registrations.clear()
	if _indexed_touch_any_player_state_changed_this_tick and not can_use_player_index:
		_enqueue_all_indexed_touch_authority(INDEXED_TOUCH_DIRTY_PLAYER)
	for registration in _indexed_touch_moved_work_registrations:
		if registration == null or not registration.indexed_touch_motion_pending:
			continue
		registration.indexed_touch_motion_pending = false
		registration.indexed_touch_moved_generation = -1
		if (
			registration.tombstone
			or registration.suspended
			or not registration.contact_proxy_registered
			or not registration.indexed_touch_authority_capable
		):
			continue
		if registration.indexed_touch_dirty:
			continue
		if (
			not registration.indexed_touch_complete_snapshot_valid
			or not registration.indexed_touch_player_snapshot_empty_cache
		):
			_enqueue_indexed_touch_dirty(
				registration,
				INDEXED_TOUCH_DIRTY_PLAYER
			)
			continue
		var enemy_sweep := registration.indexed_touch_motion_world_aabb
		var enemy := registration.enemy
		var motion_distance := registration.indexed_touch_motion_from_position.distance_to(
			registration.indexed_touch_motion_to_position
		)
		if (
			not enemy_sweep.position.is_finite()
			or not enemy_sweep.size.is_finite()
			or enemy_sweep.size.x <= 0.0
			or enemy_sweep.size.y <= 0.0
			or not registration.indexed_touch_motion_from_position.is_finite()
			or not registration.indexed_touch_motion_to_position.is_finite()
			or not is_finite(motion_distance)
		):
			_enqueue_indexed_touch_dirty(
				registration,
				INDEXED_TOUCH_DIRTY_PLAYER
			)
			continue
		if (
			not can_use_player_index
			or enemy == null
			or not is_instance_valid(enemy)
			or enemy.combat_target_index_binding != _combat_target_index
			or enemy.combat_target_index_net_id <= 0
			or motion_distance > INDEXED_TOUCH_MAX_NORMAL_MOTION_PER_TICK
		):
			_indexed_touch_slow_path_registrations.append(registration)
			continue
		registration.indexed_touch_moved_generation = movement_generation
		normal_mover_count += 1
		maximum_normal_motion = maxf(maximum_normal_motion, motion_distance)

	if can_use_player_index:
		for player_index in range(_indexed_touch_living_players.size()):
			var player_state_changed := (
				_indexed_touch_player_state_changed_flags[player_index]
			)
			if not player_state_changed and normal_mover_count <= 0:
				continue
			if _indexed_touch_player_shapes[player_index] == null:
				continue
			var player_sweep := (
				_indexed_touch_player_swept_world_aabbs[player_index]
			)
			if (
				not player_sweep.position.is_finite()
				or not player_sweep.size.is_finite()
				or player_sweep.size.x <= 0.0
				or player_sweep.size.y <= 0.0
			):
				if player_state_changed:
					_enqueue_all_indexed_touch_authority(
						INDEXED_TOUCH_DIRTY_PLAYER
					)
				_enqueue_all_normal_movers_for_indexed_touch_slow_path(
					movement_generation
				)
				break
			var query_aabb := player_sweep.grow(
				maxf(_maximum_indexed_touch_enemy_extent, 0.0)
					+ maximum_normal_motion
					+ INDEXED_TOUCH_STATIC_ENVELOPE_EPSILON
			)
			_combat_target_index.query_world_aabb_into(
				query_aabb,
				_indexed_touch_player_enemy_candidates
			)
			_metric_indexed_touch_player_index_query_count += 1
			_metric_indexed_touch_player_index_candidate_count += (
				_indexed_touch_player_enemy_candidates.size()
			)
			for candidate in _indexed_touch_player_enemy_candidates:
				if candidate == null or not is_instance_valid(candidate):
					continue
				var registration := _registration_by_instance_id.get(
					candidate.get_instance_id()
				) as Registration
				if player_state_changed:
					_enqueue_indexed_touch_dirty(
						registration,
						INDEXED_TOUCH_DIRTY_PLAYER
					)
					continue
				if (
					registration == null
					or registration.indexed_touch_moved_generation
						!= movement_generation
					or registration.indexed_touch_dirty
				):
					continue
				_metric_indexed_touch_player_aabb_pair_check_count += 1
				if not registration.indexed_touch_motion_world_aabb.intersects(
					player_sweep,
					true
				):
					continue
				_metric_indexed_touch_player_aabb_pair_hit_count += 1
				_enqueue_indexed_touch_dirty(
					registration,
					INDEXED_TOUCH_DIRTY_PLAYER
				)

	for registration in _indexed_touch_slow_path_registrations:
		_invalidate_indexed_touch_slow_path_mover(registration)
	_indexed_touch_any_player_state_changed_this_tick = false
	_indexed_touch_moved_work_registrations.clear()
	_indexed_touch_slow_path_registrations.clear()


func _enqueue_all_normal_movers_for_indexed_touch_slow_path(
	movement_generation: int
) -> void:
	for registration in _indexed_touch_moved_work_registrations:
		if (
			registration == null
			or registration.indexed_touch_moved_generation != movement_generation
		):
			continue
		registration.indexed_touch_moved_generation = -1
		_indexed_touch_slow_path_registrations.append(registration)


func _invalidate_indexed_touch_slow_path_mover(
	registration: Registration
) -> void:
	if registration == null or registration.indexed_touch_dirty:
		return
	_metric_indexed_touch_player_slow_path_mover_count += 1
	var enemy_sweep := registration.indexed_touch_motion_world_aabb
	for player_index in range(_indexed_touch_living_players.size()):
		if _indexed_touch_player_shapes[player_index] == null:
			continue
		var player_sweep := _indexed_touch_player_swept_world_aabbs[player_index]
		_metric_indexed_touch_player_aabb_pair_check_count += 1
		if enemy_sweep.intersects(player_sweep, true):
			_metric_indexed_touch_player_aabb_pair_hit_count += 1
			_enqueue_indexed_touch_dirty(
				registration,
				INDEXED_TOUCH_DIRTY_PLAYER
			)
			return


func _enqueue_indexed_touch_nonempty_player_snapshots() -> void:
	for registration in _indexed_touch_nonempty_player_registrations:
		if (
			registration == null
			or registration.tombstone
			or registration.indexed_touch_player_snapshot_nonempty_slot < 0
		):
			continue
		_enqueue_indexed_touch_dirty(
			registration,
			INDEXED_TOUCH_DIRTY_PLAYER
		)


func _set_indexed_touch_nonempty_player_membership(
	registration: Registration,
	nonempty: bool
) -> void:
	if registration == null:
		return
	var slot := registration.indexed_touch_player_snapshot_nonempty_slot
	if nonempty:
		if slot >= 0:
			return
		registration.indexed_touch_player_snapshot_nonempty_slot = (
			_indexed_touch_nonempty_player_registrations.size()
		)
		_indexed_touch_nonempty_player_registrations.append(registration)
		return
	if slot < 0:
		return
	var last_slot := _indexed_touch_nonempty_player_registrations.size() - 1
	if slot < last_slot:
		var moved_registration := (
			_indexed_touch_nonempty_player_registrations[last_slot]
		)
		_indexed_touch_nonempty_player_registrations[slot] = moved_registration
		moved_registration.indexed_touch_player_snapshot_nonempty_slot = slot
	_indexed_touch_nonempty_player_registrations.resize(maxi(last_slot, 0))
	registration.indexed_touch_player_snapshot_nonempty_slot = -1


func _enqueue_all_indexed_touch_authority(reason: int) -> void:
	for registration in _registrations:
		if (
			registration == null
			or registration.tombstone
			or registration.suspended
			or not registration.contact_proxy_registered
			or not registration.indexed_touch_authority_capable
		):
			continue
		_enqueue_indexed_touch_dirty(registration, reason)


func _enqueue_indexed_touch_dirty(
	registration: Registration,
	reason: int
) -> void:
	if (
		registration == null
		or registration.tombstone
		or registration.suspended
		or not registration.contact_proxy_registered
		or not registration.indexed_touch_authority_capable
	):
		return
	registration.indexed_touch_dirty_reasons |= reason
	if registration.indexed_touch_dirty:
		return
	registration.indexed_touch_dirty = true
	var simulation_id := registration.simulation_id
	if (
		not _dirty_indexed_touch_registrations.is_empty()
		and simulation_id
			< _dirty_indexed_touch_queue_last_simulation_id
	):
		_dirty_indexed_touch_queue_ordered = false
	_dirty_indexed_touch_registrations.append(registration)
	_dirty_indexed_touch_queue_last_simulation_id = simulation_id
	_metric_indexed_touch_dirty_enqueue_count += 1


func _drain_indexed_touch_dirty_queue() -> void:
	if _dirty_indexed_touch_registrations.is_empty():
		return
	# Work and producer buffers alternate ownership. A sync callback may dirty the
	# same Registration again after its flag is cleared below; that second request
	# lands in the empty producer and survives this drain for the next stable tick.
	var recycled_queue := _dirty_indexed_touch_work_registrations
	_dirty_indexed_touch_work_registrations = (
		_dirty_indexed_touch_registrations
	)
	_dirty_indexed_touch_registrations = recycled_queue
	_dirty_indexed_touch_registrations.clear()
	var queue_was_ordered := _dirty_indexed_touch_queue_ordered
	_dirty_indexed_touch_queue_ordered = true
	_dirty_indexed_touch_queue_last_simulation_id = INVALID_SIMULATION_ID
	if queue_was_ordered:
		_metric_indexed_touch_dirty_ordered_drain_count += 1
	else:
		_dirty_indexed_touch_work_registrations.sort_custom(
			func(left: Registration, right: Registration) -> bool:
				return left.simulation_id < right.simulation_id
		)
		_metric_indexed_touch_dirty_sort_count += 1
	for registration in _dirty_indexed_touch_work_registrations:
		if registration == null or not registration.indexed_touch_dirty:
			continue
		registration.indexed_touch_dirty = false
		registration.indexed_touch_dirty_reasons = 0
		if (
			registration.tombstone
			or registration.suspended
			or not registration.contact_proxy_registered
			or not registration.indexed_touch_authority_capable
		):
			continue
		var enemy := registration.enemy
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or enemy.is_queued_for_deletion()
			or enemy.is_dead
		):
			continue
		_sync_indexed_touch_contacts(registration, enemy)
		_metric_indexed_touch_dirty_drain_count += 1
	_dirty_indexed_touch_work_registrations.clear()


func _sync_indexed_touch_contacts(
	registration: Registration,
	enemy: Enemy
) -> bool:
	if (
		registration == null
		or enemy == null
		or not is_instance_valid(enemy)
		or not enemy.supports_layered_contact_authoritative_simulation()
		or not enemy.supports_indexed_touch_authority()
		or registration.contact_attacker_shape == null
		or registration.contact_attacker_proxy == null
		or _damageable_spatial_index == null
		or not is_instance_valid(_damageable_spatial_index)
		or not _damageable_spatial_index.is_bound()
	):
		if enemy != null and is_instance_valid(enemy):
			_set_indexed_touch_nonempty_player_membership(registration, false)
			enemy.set_indexed_touch_authority(false)
		return false

	var touch_shape := registration.contact_attacker_shape
	var touch_transform := (
		enemy.global_transform
			* registration.contact_attacker_local_transform
	)
	var plant_geometry_revision := (
		_indexed_touch_plant_geometry_revision_this_tick
	)
	var relation_revision := _indexed_touch_relation_revision_this_tick
	var faction_id := enemy.get_combat_faction_id()
	_indexed_touch_players.clear()
	var player_count := _indexed_touch_living_players.size()
	for player_index in range(player_count):
		var player := _indexed_touch_living_players[player_index]
		var player_shape := _indexed_touch_player_shapes[player_index]
		if (
			player == null
			or not is_instance_valid(player)
			or player.is_dead
			or player.is_queued_for_deletion()
			or player_shape == null
		):
			continue
		var combined_extent := (
			registration.contact_attacker_bounding_radius
			+ _indexed_touch_player_extents[player_index]
		)
		if (
			combined_extent > 0.0
			and touch_transform.origin.distance_squared_to(
				_indexed_touch_player_positions[player_index]
			) > combined_extent * combined_extent
		):
			continue
		_metric_indexed_touch_player_exact_shape_check_count += 1
		if touch_shape.collide(
			touch_transform,
			player_shape,
			_indexed_touch_player_transforms[player_index]
		):
			_metric_indexed_touch_player_exact_shape_hit_count += 1
			_indexed_touch_players.append(player)
	if not enemy.is_indexed_touch_authority_enabled():
		enemy.set_indexed_touch_authority(true)
		_metric_indexed_touch_authority_count += 1
	if (
		registration.indexed_touch_complete_snapshot_valid
		and touch_transform == registration.indexed_touch_complete_transform
		and plant_geometry_revision
			== registration.indexed_touch_complete_plant_geometry_revision
		and relation_revision
			== registration.indexed_touch_complete_relation_revision
		and faction_id == registration.indexed_touch_complete_faction_id
		and enemy.get_contact_shape_revision()
			== registration.indexed_touch_complete_contact_shape_revision
		and enemy.indexed_touch_player_snapshot_matches(_indexed_touch_players)
	):
		_metric_indexed_touch_complete_snapshot_skip_count += 1
		return true
	_indexed_touch_plants.clear()
	if _indexed_touch_has_registered_plants_this_tick:
		_sync_indexed_touch_plant_candidates(
			registration,
			enemy,
			touch_shape,
			touch_transform,
			plant_geometry_revision
		)
	else:
		registration.indexed_touch_plant_geometry_revision = (
			plant_geometry_revision
		)
		registration.indexed_touch_plant_candidates.clear()
		registration.indexed_touch_plant_candidate_aabbs.clear()
		registration.indexed_touch_exact_geometry_revision = (
			plant_geometry_revision
		)
		registration.indexed_touch_exact_transform = touch_transform
		registration.indexed_touch_exact_transform_valid = true
		registration.indexed_touch_exact_plants.clear()
	if (
		_indexed_touch_players.is_empty()
		and _indexed_touch_plants.is_empty()
		and enemy.indexed_touch_contact_snapshot_is_empty()
	):
		# Most enemies are not touching a Player or Plant on most ticks. Once the
		# indexed snapshot and the owned gameplay snapshot are both empty, running
		# the full dictionary reconciliation cannot change gameplay state.
		_metric_indexed_touch_empty_snapshot_skip_count += 1
		_record_indexed_touch_complete_snapshot(
			registration,
			enemy,
			touch_transform,
			plant_geometry_revision,
			relation_revision,
			faction_id
		)
		return true
	if enemy.indexed_touch_contact_snapshot_matches(
		_indexed_touch_players,
		_indexed_touch_plants
	):
		# Membership did not change. Selection may still change as the enemy moves
		# between two overlapping targets, so refresh only that deterministic tail.
		enemy.refresh_indexed_touch_contact_selection()
		_metric_indexed_touch_unchanged_snapshot_skip_count += 1
		_record_indexed_touch_complete_snapshot(
			registration,
			enemy,
			touch_transform,
			plant_geometry_revision,
			relation_revision,
			faction_id
		)
		return true
	var contact_membership_changes := _count_indexed_touch_membership_changes(
		enemy,
		_indexed_touch_players,
		_indexed_touch_plants
	)
	if not enemy.synchronize_indexed_touch_contacts(
		_indexed_touch_players,
		_indexed_touch_plants
	):
		_set_indexed_touch_nonempty_player_membership(registration, false)
		enemy.set_indexed_touch_authority(false)
		return false
	_metric_indexed_touch_sync_count += 1
	_metric_indexed_touch_contact_enter_count += contact_membership_changes.x
	_metric_indexed_touch_contact_exit_count += contact_membership_changes.y
	_record_indexed_touch_complete_snapshot(
		registration,
		enemy,
		touch_transform,
		plant_geometry_revision,
		relation_revision,
		faction_id
	)
	return true


func _count_indexed_touch_membership_changes(
	enemy: Enemy,
	players: Array[Player],
	plants: Array
) -> Vector2i:
	var shared_player_count := 0
	for player in players:
		if (
			player != null
			and is_instance_valid(player)
			and enemy.touching_players.get(player.get_instance_id()) == player
		):
			shared_player_count += 1
	var shared_plant_count := 0
	for plant_variant in plants:
		if plant_variant == null or not is_instance_valid(plant_variant):
			continue
		var plant := plant_variant as PlantDefense
		if (
			plant != null
			and enemy.touching_plants.get(plant.get_instance_id()) == plant
		):
			shared_plant_count += 1
	return Vector2i(
		maxi(players.size() - shared_player_count, 0)
			+ maxi(plants.size() - shared_plant_count, 0),
		maxi(enemy.touching_players.size() - shared_player_count, 0)
			+ maxi(enemy.touching_plants.size() - shared_plant_count, 0)
	)


func _can_reuse_indexed_touch_safe_corridor(
	registration: Registration,
	enemy: Enemy
) -> bool:
	if (
		registration == null
		or registration.indexed_touch_dirty
		or not registration.indexed_touch_empty_corridor_fast
		or not registration.indexed_touch_complete_snapshot_valid
		or not registration.indexed_touch_player_snapshot_empty_cache
		or not registration.indexed_touch_snapshot_empty_cache
		or registration.contact_attacker_shape == null
		or registration.contact_attacker_proxy == null
		or registration.indexed_touch_complete_plant_geometry_revision
			!= _indexed_touch_plant_geometry_revision_this_tick
		or registration.indexed_touch_complete_relation_revision
			!= _indexed_touch_relation_revision_this_tick
		or registration.indexed_touch_complete_faction_id
			!= enemy.get_combat_faction_id()
		or registration.indexed_touch_complete_contact_shape_revision
			!= enemy.get_contact_shape_revision()
	):
		return false
	var touch_transform := (
		enemy.global_transform
			* registration.contact_attacker_local_transform
	)
	if (
		touch_transform.x != registration.indexed_touch_complete_transform.x
		or touch_transform.y != registration.indexed_touch_complete_transform.y
	):
		return false
	var root_position := enemy.global_position
	var can_reuse := (
		root_position.x >= registration.indexed_touch_safe_position_minimum.x
		and root_position.y >= registration.indexed_touch_safe_position_minimum.y
		and root_position.x <= registration.indexed_touch_safe_position_maximum.x
		and root_position.y <= registration.indexed_touch_safe_position_maximum.y
	)
	if (
		can_reuse
		and not registration.indexed_touch_plant_candidates.is_empty()
	):
		_metric_indexed_touch_nonempty_plant_certificate_reuse_count += 1
	return can_reuse


func _record_indexed_touch_complete_snapshot(
	registration: Registration,
	enemy: Enemy,
	touch_transform: Transform2D,
	plant_geometry_revision: int,
	relation_revision: int,
	faction_id: int
) -> void:
	registration.indexed_touch_complete_snapshot_valid = true
	registration.indexed_touch_complete_transform = touch_transform
	registration.indexed_touch_last_observed_transform = touch_transform
	registration.indexed_touch_last_observed_transform_valid = true
	registration.indexed_touch_complete_plant_geometry_revision = (
		plant_geometry_revision
	)
	registration.indexed_touch_complete_relation_revision = relation_revision
	registration.indexed_touch_complete_faction_id = faction_id
	registration.indexed_touch_complete_contact_shape_revision = (
		enemy.get_contact_shape_revision()
	)
	registration.indexed_touch_player_snapshot_empty_cache = (
		enemy.indexed_touch_player_snapshot_is_empty()
	)
	var player_snapshot_nonempty := (
		not registration.indexed_touch_player_snapshot_empty_cache
	)
	_set_indexed_touch_nonempty_player_membership(
		registration,
		player_snapshot_nonempty
	)
	registration.indexed_touch_snapshot_empty_cache = (
		enemy.indexed_touch_contact_snapshot_is_empty()
	)
	registration.indexed_touch_empty_corridor_fast = (
		registration.indexed_touch_player_snapshot_empty_cache
		and registration.indexed_touch_snapshot_empty_cache
		and registration.contact_attacker_shape != null
		and registration.contact_attacker_proxy != null
	)
	_rebuild_indexed_touch_safe_position_bounds(registration, enemy)


func _rebuild_indexed_touch_safe_position_bounds(
	registration: Registration,
	enemy: Enemy
) -> void:
	if not registration.indexed_touch_empty_corridor_fast:
		registration.indexed_touch_safe_position_minimum = enemy.global_position
		registration.indexed_touch_safe_position_maximum = enemy.global_position
		return
	var safe_minimum := Vector2(-INF, -INF)
	var safe_maximum := Vector2(INF, INF)
	if _indexed_touch_has_registered_plants_this_tick:
		if (
			registration.indexed_touch_plant_geometry_revision
				!= _indexed_touch_plant_geometry_revision_this_tick
		):
			_reject_indexed_touch_plant_corridor_certificate(
				registration,
				enemy
			)
			return
		var plant_bounds := registration.indexed_touch_plant_safe_position_bounds
		if not _is_valid_indexed_touch_world_aabb(plant_bounds):
			_reject_indexed_touch_plant_corridor_certificate(
				registration,
				enemy
			)
			return
		safe_minimum = plant_bounds.position
		safe_maximum = plant_bounds.end
		if not registration.indexed_touch_plant_candidates.is_empty():
			if not _build_indexed_touch_nonempty_plant_certificate(
				registration,
				enemy,
				safe_minimum,
				safe_maximum
			):
				_reject_indexed_touch_plant_corridor_certificate(
					registration,
					enemy
				)
				return
			safe_minimum = (
				registration.indexed_touch_safe_position_minimum
			)
			safe_maximum = (
				registration.indexed_touch_safe_position_maximum
			)
			_metric_indexed_touch_nonempty_plant_certificate_build_count += 1

	registration.indexed_touch_safe_position_minimum = safe_minimum
	registration.indexed_touch_safe_position_maximum = safe_maximum
	var root_position := enemy.global_position
	if (
		root_position.x < safe_minimum.x
		or root_position.y < safe_minimum.y
		or root_position.x > safe_maximum.x
		or root_position.y > safe_maximum.y
	):
		registration.indexed_touch_empty_corridor_fast = false


func _build_indexed_touch_nonempty_plant_certificate(
	registration: Registration,
	enemy: Enemy,
	initial_safe_minimum: Vector2,
	initial_safe_maximum: Vector2
) -> bool:
	var candidate_count := registration.indexed_touch_plant_candidates.size()
	if (
		candidate_count <= 0
		or candidate_count
			!= registration.indexed_touch_plant_candidate_aabbs.size()
		or _damageable_spatial_index == null
		or not is_instance_valid(_damageable_spatial_index)
		or registration.contact_attacker_proxy == null
		or not initial_safe_minimum.is_finite()
		or not initial_safe_maximum.is_finite()
		or initial_safe_minimum.x > initial_safe_maximum.x
		or initial_safe_minimum.y > initial_safe_maximum.y
	):
		return false
	var root_position := enemy.global_position
	if (
		not root_position.is_finite()
		or root_position.x < initial_safe_minimum.x
		or root_position.y < initial_safe_minimum.y
		or root_position.x > initial_safe_maximum.x
		or root_position.y > initial_safe_maximum.y
	):
		return false
	var touch_transform := (
		enemy.global_transform
			* registration.contact_attacker_local_transform
	)
	if (
		not touch_transform.origin.is_finite()
		or not registration.contact_attacker_proxy
			.is_translation_transform_supported(touch_transform)
	):
		return false
	var attacker_aabb := (
		registration.contact_attacker_proxy.get_world_aabb_at(
			touch_transform.origin
		)
	)
	if not _is_valid_indexed_touch_world_aabb(attacker_aabb):
		return false

	var safe_minimum := initial_safe_minimum
	var safe_maximum := initial_safe_maximum
	for candidate_index in range(candidate_count):
		var damageable := (
			registration.indexed_touch_plant_candidates[candidate_index]
		)
		var candidate_aabb := (
			registration.indexed_touch_plant_candidate_aabbs[candidate_index]
		)
		if (
			damageable == null
			or not is_instance_valid(damageable)
			or damageable.is_queued_for_deletion()
			or not _damageable_spatial_index.contains_damageable(damageable)
			or not _is_valid_indexed_touch_world_aabb(candidate_aabb)
			or attacker_aabb.intersects(candidate_aabb, true)
		):
			return false
		var plant := damageable as PlantDefense
		if plant == null or plant.is_dead or plant.is_removing:
			return false

		var separation := INDEXED_TOUCH_SEPARATION_NONE
		var separation_margin := -INF
		var margin := candidate_aabb.position.x - attacker_aabb.end.x
		if margin > 0.0 and margin > separation_margin:
			separation = INDEXED_TOUCH_SEPARATION_LEFT
			separation_margin = margin
		margin = attacker_aabb.position.x - candidate_aabb.end.x
		if margin > 0.0 and margin > separation_margin:
			separation = INDEXED_TOUCH_SEPARATION_RIGHT
			separation_margin = margin
		margin = candidate_aabb.position.y - attacker_aabb.end.y
		if margin > 0.0 and margin > separation_margin:
			separation = INDEXED_TOUCH_SEPARATION_ABOVE
			separation_margin = margin
		margin = attacker_aabb.position.y - candidate_aabb.end.y
		if margin > 0.0 and margin > separation_margin:
			separation = INDEXED_TOUCH_SEPARATION_BELOW
			separation_margin = margin
		if (
			separation == INDEXED_TOUCH_SEPARATION_NONE
			or separation_margin
				<= INDEXED_TOUCH_STATIC_ENVELOPE_EPSILON
		):
			return false
		var safe_displacement := (
			separation_margin
			- INDEXED_TOUCH_STATIC_ENVELOPE_EPSILON
		)
		match separation:
			INDEXED_TOUCH_SEPARATION_LEFT:
				safe_maximum.x = minf(
					safe_maximum.x,
					root_position.x + safe_displacement
				)
			INDEXED_TOUCH_SEPARATION_RIGHT:
				safe_minimum.x = maxf(
					safe_minimum.x,
					root_position.x - safe_displacement
				)
			INDEXED_TOUCH_SEPARATION_ABOVE:
				safe_maximum.y = minf(
					safe_maximum.y,
					root_position.y + safe_displacement
				)
			INDEXED_TOUCH_SEPARATION_BELOW:
				safe_minimum.y = maxf(
					safe_minimum.y,
					root_position.y - safe_displacement
				)
		if (
			not safe_minimum.is_finite()
			or not safe_maximum.is_finite()
			or safe_minimum.x > safe_maximum.x
			or safe_minimum.y > safe_maximum.y
			or root_position.x < safe_minimum.x
			or root_position.y < safe_minimum.y
			or root_position.x > safe_maximum.x
			or root_position.y > safe_maximum.y
		):
			return false

	registration.indexed_touch_safe_position_minimum = safe_minimum
	registration.indexed_touch_safe_position_maximum = safe_maximum
	return true


func _reject_indexed_touch_plant_corridor_certificate(
	registration: Registration,
	enemy: Enemy
) -> void:
	if not registration.indexed_touch_plant_candidates.is_empty():
		_metric_indexed_touch_nonempty_plant_certificate_reject_count += 1
	registration.indexed_touch_empty_corridor_fast = false
	registration.indexed_touch_safe_position_minimum = enemy.global_position
	registration.indexed_touch_safe_position_maximum = enemy.global_position


static func _is_valid_indexed_touch_world_aabb(world_aabb: Rect2) -> bool:
	return (
		world_aabb.position.is_finite()
		and world_aabb.size.is_finite()
		and world_aabb.size.x >= 0.0
		and world_aabb.size.y >= 0.0
		and (world_aabb.position + world_aabb.size).is_finite()
	)


func _sync_indexed_touch_plant_candidates(
	registration: Registration,
	enemy: Enemy,
	touch_shape: Shape2D,
	touch_transform: Transform2D,
	geometry_revision: int
) -> void:
	_indexed_touch_plants.clear()
	var current_envelope := (
		registration.contact_attacker_proxy.get_world_aabb_at(
			touch_transform.origin
		)
	)
	if (
		registration.indexed_touch_exact_transform_valid
		and geometry_revision
			== registration.indexed_touch_exact_geometry_revision
		and touch_transform == registration.indexed_touch_exact_transform
	):
		for cached_plant in registration.indexed_touch_exact_plants:
			if (
				cached_plant != null
				and is_instance_valid(cached_plant)
				and not cached_plant.is_dead
				and not cached_plant.is_removing
				and enemy.can_attack_plant_target(cached_plant)
			):
				_indexed_touch_plants.append(cached_plant)
		_metric_indexed_touch_plant_exact_cache_hit_count += 1
		return
	var candidate_cache_is_safe := (
		geometry_revision
			== registration.indexed_touch_plant_geometry_revision
		and registration.indexed_touch_plant_safe_envelope.encloses(
			current_envelope
		)
	)
	if candidate_cache_is_safe:
		_metric_indexed_touch_plant_sleep_skip_count += 1
	else:
		var physics_ticks_per_second := maxi(
			Engine.physics_ticks_per_second,
			1
		)
		var maximum_idle_displacement := (
			enemy.get_effective_move_speed()
			* float(INDEXED_TOUCH_STATIC_IDLE_QUERY_TICKS)
			/ float(physics_ticks_per_second)
		)
		var query_envelope := current_envelope.grow(
			maximum_idle_displacement + INDEXED_TOUCH_STATIC_ENVELOPE_EPSILON
		)
		_damageable_spatial_index.query_world_aabb_into(
			query_envelope,
			registration.indexed_touch_plant_candidates
		)
		var refreshed_candidate_count := (
			registration.indexed_touch_plant_candidates.size()
		)
		registration.indexed_touch_plant_candidate_aabbs.resize(
			refreshed_candidate_count
		)
		for candidate_index in range(refreshed_candidate_count):
			registration.indexed_touch_plant_candidate_aabbs[candidate_index] = (
				_damageable_spatial_index.get_registered_world_aabb(
					registration.indexed_touch_plant_candidates[candidate_index]
				)
			)
		_metric_indexed_touch_plant_broadphase_count += 1
		registration.indexed_touch_plant_geometry_revision = geometry_revision
		registration.indexed_touch_plant_safe_envelope = query_envelope
		var safe_position_radius := Vector2.ONE * (
			maximum_idle_displacement
			+ INDEXED_TOUCH_STATIC_ENVELOPE_EPSILON
		)
		registration.indexed_touch_plant_safe_position_bounds = Rect2(
			enemy.global_position - safe_position_radius,
			safe_position_radius * 2.0
		)

	var candidate_count := registration.indexed_touch_plant_candidates.size()
	_metric_indexed_touch_plant_candidate_check_count += candidate_count
	for read_index in range(candidate_count):
		var damageable := registration.indexed_touch_plant_candidates[read_index]
		var plant := damageable as PlantDefense
		var damageable_world_aabb := (
			registration.indexed_touch_plant_candidate_aabbs[read_index]
		)
		if (
			plant == null
			or not damageable_world_aabb.intersects(current_envelope, true)
			or not enemy.can_attack_plant_target(plant)
		):
			continue
		_metric_indexed_touch_plant_exact_candidate_count += 1
		if not _damageable_spatial_index.damageable_overlaps_shape(
				damageable,
				touch_shape,
				touch_transform
			):
			continue
		_metric_indexed_touch_plant_exact_shape_hit_count += 1
		_indexed_touch_plants.append(plant)
	registration.indexed_touch_exact_geometry_revision = geometry_revision
	registration.indexed_touch_exact_transform = touch_transform
	registration.indexed_touch_exact_transform_valid = true
	registration.indexed_touch_exact_plants.assign(_indexed_touch_plants)


func _disable_all_indexed_touch_authority() -> void:
	for registration in _registrations:
		if registration == null or registration.tombstone:
			continue
		var enemy := registration.enemy
		if enemy != null and is_instance_valid(enemy):
			enemy.set_indexed_touch_authority(false)


func _disable_and_clear_contact_service_at_boundary() -> void:
	if _contact_service == null:
		return
	_contact_service.request_mode(EnemyContactService.Mode.DISABLED)
	# Mode requests are committed only from step(). This call is made either
	# between physics ticks or from _finish_mutation after the current tick has
	# completed, so rollback cannot expose a half-old contact snapshot.
	_contact_service.step(_simulation_tick)
	_contact_service.clear()


func _collect_authored_contact_shape_nodes(
	enemy: Enemy,
	touch_shapes: bool
) -> Array[CollisionShape2D]:
	var shape_nodes: Array[CollisionShape2D] = []
	if enemy == null or not is_instance_valid(enemy):
		return shape_nodes
	var authored_shapes: Array[CollisionShape2D] = (
		enemy.touch_damage_shapes
		if touch_shapes
		else enemy.body_collision_shapes
	)
	for shape_node in authored_shapes:
		if shape_node == null or not is_instance_valid(shape_node):
			# A stale authored member invalidates the entire atomic capture.
			shape_nodes.clear()
			return shape_nodes
		if touch_shapes:
			# Indexed authority disables the live touch nodes, so their authored
			# state is the only stable source across admission and recapture.
			if not enemy.is_touch_damage_shape_authored_enabled(shape_node):
				continue
		elif shape_node.disabled:
			continue
		if shape_node.shape == null:
			# An enabled null/unsupported resource must not be omitted from the union.
			shape_nodes.clear()
			return shape_nodes
		shape_nodes.append(shape_node)
	return shape_nodes


func _create_contact_shape_proxy_set(
	shape_nodes: Array[CollisionShape2D],
	enemy: Enemy
) -> CombatContactShapeProxy:
	if shape_nodes.is_empty() or enemy == null or not is_instance_valid(enemy):
		return null
	if shape_nodes.size() == 1:
		# Preserve the proven single-shape path for Cardboard/Stone and indexed
		# Player/Plant authority. Compound is reserved for a real authored union.
		return CombatContactShapeProxy.from_collision_shape(shape_nodes[0])
	return CombatContactShapeProxy.from_collision_shapes(
		shape_nodes,
		enemy.global_transform
	)


func _get_contact_shape_set_anchor_transform(
	shape_nodes: Array[CollisionShape2D],
	enemy: Enemy
) -> Transform2D:
	if shape_nodes.size() == 1:
		return shape_nodes[0].global_transform
	return enemy.global_transform


func _get_contact_shape_set_local_transform(
	shape_nodes: Array[CollisionShape2D],
	enemy: Enemy
) -> Transform2D:
	return (
		enemy.global_transform.affine_inverse()
			* _get_contact_shape_set_anchor_transform(shape_nodes, enemy)
	)


func _capture_contact_shape_set_resource_ids(
	shape_nodes: Array[CollisionShape2D]
) -> PackedInt64Array:
	var resource_ids := PackedInt64Array()
	resource_ids.resize(shape_nodes.size())
	for shape_index in range(shape_nodes.size()):
		resource_ids[shape_index] = shape_nodes[shape_index].shape.get_instance_id()
	return resource_ids


func _capture_contact_shape_set_local_transforms(
	shape_nodes: Array[CollisionShape2D],
	enemy: Enemy
) -> Array[Transform2D]:
	var local_transforms: Array[Transform2D] = []
	local_transforms.resize(shape_nodes.size())
	var inverse_root := enemy.global_transform.affine_inverse()
	for shape_index in range(shape_nodes.size()):
		local_transforms[shape_index] = (
			inverse_root * shape_nodes[shape_index].global_transform
		)
	return local_transforms


func _contact_shape_set_signature_matches(
	shape_nodes: Array[CollisionShape2D],
	enemy: Enemy,
	resource_ids: PackedInt64Array,
	local_transforms: Array[Transform2D]
) -> bool:
	if (
		shape_nodes.size() != resource_ids.size()
		or shape_nodes.size() != local_transforms.size()
	):
		return false
	var inverse_root := enemy.global_transform.affine_inverse()
	for shape_index in range(shape_nodes.size()):
		var shape_node := shape_nodes[shape_index]
		if (
			shape_node == null
			or not is_instance_valid(shape_node)
			or shape_node.shape == null
			or resource_ids[shape_index]
				!= shape_node.shape.get_instance_id()
			or local_transforms[shape_index]
				!= inverse_root * shape_node.global_transform
		):
			return false
	return true


func _register_contact_proxy(registration: Registration) -> bool:
	if (
		registration == null
		or registration.tombstone
		or registration.suspended
		or registration.uses_anchored_compat_simulation
		or registration.contact_proxy_registered
		or not _uses_shared_contact_mode(_mode)
		or not _registration_supports_shared_contact_authority(registration)
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
	# Capture the complete authored shell atomically. A partial union would
	# silently shrink either attack reach or target volume.
	var attacker_shape_nodes := _collect_authored_contact_shape_nodes(enemy, true)
	var body_shape_nodes := _collect_authored_contact_shape_nodes(enemy, false)
	if attacker_shape_nodes.is_empty() or body_shape_nodes.is_empty():
		_metric_contact_registration_rejection_count += 1
		return false
	var attacker_proxy := _create_contact_shape_proxy_set(
		attacker_shape_nodes,
		enemy
	)
	var body_proxy := _create_contact_shape_proxy_set(body_shape_nodes, enemy)
	if (
		attacker_proxy == null
		or not attacker_proxy.is_supported()
		or body_proxy == null
		or not body_proxy.is_supported()
	):
		_metric_contact_registration_rejection_count += 1
		return false
	var attacker_local_transform := _get_contact_shape_set_local_transform(
		attacker_shape_nodes,
		enemy
	)
	var body_local_transform := _get_contact_shape_set_local_transform(
		body_shape_nodes,
		enemy
	)
	registration.contact_attacker_shape = (
		attacker_shape_nodes[0].shape
		if attacker_shape_nodes.size() == 1
		else null
	)
	registration.contact_attacker_local_transform = (
		attacker_local_transform
	)
	registration.contact_body_local_transform = body_local_transform
	var faction_id := enemy.get_combat_faction_id()
	var registered := _contact_service.register_enemy(
		enemy,
		registration.simulation_id,
		faction_id,
		attacker_proxy,
		body_proxy,
		Callable(
			self,
			&"_get_registered_contact_attacker_world_position"
		).bind(registration),
		Callable(
			self,
			&"_get_registered_contact_body_world_position"
		).bind(registration),
		Callable(
			self,
			&"_get_registered_contact_planned_attacker_world_position"
		).bind(registration),
		Callable(
			self,
			&"_get_registered_contact_planned_body_world_position"
		).bind(registration),
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
		registration.contact_attacker_shape = null
		registration.contact_attacker_local_transform = Transform2D()
		registration.contact_body_local_transform = Transform2D()
		return false
	registration.contact_proxy_registered = true
	registration.indexed_touch_authority_capable = (
		enemy.supports_layered_contact_authoritative_simulation()
		and enemy.supports_indexed_touch_authority()
		and attacker_shape_nodes.size() == 1
		and body_shape_nodes.size() == 1
	)
	registration.contact_geometry_dirty = false
	registration.contact_faction_id = faction_id
	registration.contact_shape_revision = enemy.get_contact_shape_revision()
	registration.contact_attacker_proxy = attacker_proxy
	registration.contact_body_proxy = body_proxy
	registration.contact_attacker_bounding_radius = (
		attacker_proxy.get_bounding_radius()
	)
	registration.indexed_touch_enemy_extent = (
		enemy.touch_damage_extent_radius
		if registration.indexed_touch_authority_capable
		else 0.0
	)
	if registration.indexed_touch_authority_capable:
		_maximum_indexed_touch_enemy_extent = maxf(
			_maximum_indexed_touch_enemy_extent,
			registration.indexed_touch_enemy_extent
		)
	registration.contact_attacker_shape_resource_ids = (
		_capture_contact_shape_set_resource_ids(attacker_shape_nodes)
	)
	registration.contact_body_shape_resource_ids = (
		_capture_contact_shape_set_resource_ids(body_shape_nodes)
	)
	registration.contact_attacker_shape_local_transforms = (
		_capture_contact_shape_set_local_transforms(attacker_shape_nodes, enemy)
	)
	registration.contact_body_shape_local_transforms = (
		_capture_contact_shape_set_local_transforms(body_shape_nodes, enemy)
	)
	registration.reset_indexed_touch_plant_cache()
	registration.indexed_touch_last_observed_transform = (
		enemy.global_transform
			* registration.contact_attacker_local_transform
	)
	registration.indexed_touch_last_observed_transform_valid = true
	registration.indexed_touch_motion_pending = false
	# Transform notifications are the sparse movement invalidation source. The
	# combat-target index already requests them in normal gameplay; standalone
	# contact fixtures receive the same contract without requiring that index.
	enemy.set_indexed_touch_transform_notifications_required(true)
	_enqueue_indexed_touch_dirty(registration, INDEXED_TOUCH_DIRTY_INITIAL)
	_metric_contact_registration_count += 1
	return true


func _unregister_contact_proxy(registration: Registration) -> void:
	if registration == null or not registration.contact_proxy_registered:
		return
	var enemy := registration.enemy
	# Producer/work buffers may currently own this Registration. Clearing its
	# membership flags cancels either copy in O(1); the next sparse drain skips it.
	_set_indexed_touch_nonempty_player_membership(registration, false)
	registration.indexed_touch_motion_pending = false
	if (
		_contact_service != null
		and enemy != null
		and is_instance_valid(enemy)
	):
		_contact_service.unregister_enemy(enemy, registration.simulation_id)
	if (
		is_equal_approx(
			registration.indexed_touch_enemy_extent,
			_maximum_indexed_touch_enemy_extent
		)
	):
		_maximum_indexed_touch_enemy_extent_dirty = true
	registration.contact_proxy_registered = false
	registration.indexed_touch_authority_capable = false
	registration.indexed_touch_dirty = false
	registration.indexed_touch_dirty_reasons = 0
	registration.contact_geometry_dirty = false
	registration.contact_shape_revision = -1
	registration.contact_attacker_proxy = null
	registration.contact_body_proxy = null
	registration.contact_attacker_shape = null
	registration.contact_attacker_local_transform = Transform2D()
	registration.contact_body_local_transform = Transform2D()
	registration.contact_attacker_bounding_radius = 0.0
	registration.indexed_touch_enemy_extent = 0.0
	registration.contact_attacker_shape_resource_ids.clear()
	registration.contact_body_shape_resource_ids.clear()
	registration.contact_attacker_shape_local_transforms.clear()
	registration.contact_body_shape_local_transforms.clear()
	registration.indexed_touch_last_observed_transform = Transform2D()
	registration.indexed_touch_last_observed_transform_valid = false
	registration.indexed_touch_motion_from_position = Vector2.ZERO
	registration.indexed_touch_motion_to_position = Vector2.ZERO
	registration.indexed_touch_motion_world_aabb = Rect2()
	registration.reset_indexed_touch_plant_cache()
	if enemy != null and is_instance_valid(enemy):
		enemy.set_indexed_touch_transform_notifications_required(false)


func _recompute_maximum_indexed_touch_enemy_extent() -> void:
	_maximum_indexed_touch_enemy_extent = 0.0
	for registration in _registrations:
		if (
			registration == null
			or registration.tombstone
			or registration.suspended
			or not registration.contact_proxy_registered
			or not registration.indexed_touch_authority_capable
		):
			continue
		var enemy := registration.enemy
		if enemy == null or not is_instance_valid(enemy):
			continue
		_maximum_indexed_touch_enemy_extent = maxf(
			_maximum_indexed_touch_enemy_extent,
			registration.indexed_touch_enemy_extent
		)
	_maximum_indexed_touch_enemy_extent_dirty = false


func _unregister_all_contact_proxies() -> void:
	for registration in _registrations:
		_unregister_contact_proxy(registration)
	_maximum_indexed_touch_enemy_extent = 0.0
	_maximum_indexed_touch_enemy_extent_dirty = false
	_pending_contact_admissions.clear()
	_dirty_contact_geometries.clear()
	_clear_indexed_touch_invalidation_queues()


func _clear_indexed_touch_invalidation_queues() -> void:
	_dirty_indexed_touch_registrations.clear()
	_dirty_indexed_touch_work_registrations.clear()
	_dirty_indexed_touch_queue_ordered = true
	_dirty_indexed_touch_queue_last_simulation_id = INVALID_SIMULATION_ID
	_indexed_touch_moved_registrations.clear()
	_indexed_touch_moved_work_registrations.clear()
	_indexed_touch_slow_path_registrations.clear()
	_indexed_touch_moved_queue_ordered = true
	_indexed_touch_moved_queue_last_simulation_id = INVALID_SIMULATION_ID
	_indexed_touch_any_player_state_changed_this_tick = false


func _get_registered_contact_attacker_world_position(
	registration: Registration
) -> Vector2:
	if (
		registration == null
		or registration.tombstone
		or registration.enemy == null
		or not is_instance_valid(registration.enemy)
	):
		return Vector2(INF, INF)
	return (
		registration.enemy.global_transform
			* registration.contact_attacker_local_transform
	).origin


func _get_registered_contact_planned_attacker_world_position(
	delta: float,
	registration: Registration
) -> Vector2:
	var current_position := (
		_get_registered_contact_attacker_world_position(registration)
	)
	if not current_position.is_finite():
		return current_position
	return (
		current_position
		+ registration.enemy.get_layered_area_planned_displacement(delta)
	)


func _get_registered_contact_body_world_position(
	registration: Registration
) -> Vector2:
	if (
		registration == null
		or registration.tombstone
		or registration.enemy == null
		or not is_instance_valid(registration.enemy)
	):
		return Vector2(INF, INF)
	return (
		registration.enemy.global_transform
			* registration.contact_body_local_transform
	).origin


func _get_registered_contact_planned_body_world_position(
	delta: float,
	registration: Registration
) -> Vector2:
	var current_position := _get_registered_contact_body_world_position(
		registration
	)
	if not current_position.is_finite():
		return current_position
	return (
		current_position
		+ registration.enemy.get_layered_area_planned_displacement(delta)
	)


func _step_layered_current_contact_service() -> void:
	if _contact_service == null:
		_bind_runtime_services()
	if _contact_service == null:
		return
	_contact_service.step(_simulation_tick)
	_metric_contact_phase_count += 1


func _step_layered_planned_contact_service(delta: float) -> void:
	if _contact_service == null:
		return
	# Preflight captures existing geometry; the sparse late-decision recapture in
	# _advance_layered_area commits any facing/attack-state shape transition before
	# this future-sweep prediction.
	_contact_service.step_planned(delta, _simulation_tick)


func _request_layered_contact_atomic_fallback() -> void:
	if not _contact_geometry_sync_failed_this_tick:
		_metric_contact_atomic_rollback_count += 1
	_contact_geometry_sync_failed_this_tick = true
	_pending_mode = EnemySimulationPolicy.Mode.COMPAT_60


func _sync_layered_contact_proxy_geometry() -> void:
	var dirty_count := _dirty_contact_geometries.size()
	for dirty_index in range(dirty_count):
		var registration := _dirty_contact_geometries[dirty_index]
		if (
			registration == null
			or registration.tombstone
			or registration.suspended
			or not registration.contact_proxy_registered
		):
			continue
		registration.contact_geometry_dirty = false
		var enemy := registration.enemy
		if enemy == null or not is_instance_valid(enemy):
			continue
		if not enemy.supports_layered_contact_authoritative_simulation():
			enemy.set_indexed_touch_authority(false)
			_unregister_contact_proxy(registration)
			continue
		var attacker_shape_nodes := _collect_authored_contact_shape_nodes(
			enemy,
			true
		)
		var body_shape_nodes := _collect_authored_contact_shape_nodes(enemy, false)
		if attacker_shape_nodes.is_empty() or body_shape_nodes.is_empty():
			# Keep the last coherent proxy/Area ownership intact until the physics
			# boundary. The preflight caller aborts before any contact or gameplay
			# phase, then COMPAT_60 restores all authored state in one transition.
			_request_layered_contact_atomic_fallback()
			break
		var attacker_anchor_transform := _get_contact_shape_set_anchor_transform(
			attacker_shape_nodes,
			enemy
		)
		var body_anchor_transform := _get_contact_shape_set_anchor_transform(
			body_shape_nodes,
			enemy
		)
		var attacker_local_transform := _get_contact_shape_set_local_transform(
			attacker_shape_nodes,
			enemy
		)
		var body_local_transform := _get_contact_shape_set_local_transform(
			body_shape_nodes,
			enemy
		)
		if registration.indexed_touch_authority_capable:
			_record_indexed_touch_enemy_translation(
				registration,
				attacker_anchor_transform
			)
		var geometry_changed := (
			registration.contact_shape_revision
				!= enemy.get_contact_shape_revision()
			or registration.contact_attacker_proxy == null
			or registration.contact_body_proxy == null
			or not _contact_shape_set_signature_matches(
				attacker_shape_nodes,
				enemy,
				registration.contact_attacker_shape_resource_ids,
				registration.contact_attacker_shape_local_transforms
			)
			or not _contact_shape_set_signature_matches(
				body_shape_nodes,
				enemy,
				registration.contact_body_shape_resource_ids,
				registration.contact_body_shape_local_transforms
			)
			or not registration.contact_attacker_proxy
				.is_translation_transform_supported(
					attacker_anchor_transform
				)
			or not registration.contact_body_proxy
				.is_translation_transform_supported(
					body_anchor_transform
				)
		)
		if not geometry_changed:
			registration.contact_attacker_shape = (
				attacker_shape_nodes[0].shape
				if attacker_shape_nodes.size() == 1
				else null
			)
			registration.contact_attacker_local_transform = (
				attacker_local_transform
			)
			registration.contact_body_local_transform = body_local_transform
			continue
		var attacker_proxy := _create_contact_shape_proxy_set(
			attacker_shape_nodes,
			enemy
		)
		var body_proxy := _create_contact_shape_proxy_set(body_shape_nodes, enemy)
		if (
			attacker_proxy == null
			or not attacker_proxy.is_supported()
			or body_proxy == null
			or not body_proxy.is_supported()
		):
			# Unsupported runtime geometry cannot retain LAYERED contact authority,
			# but tearing down only this registration would expose a mixed cohort.
			_request_layered_contact_atomic_fallback()
			break
		# EnemyContactService samples both anchors through Registration-bound
		# providers inside update_shape_proxies(). Publish the recaptured anchors
		# together so no phase can pair a new union with an old child origin.
		var previous_attacker_shape := registration.contact_attacker_shape
		var previous_attacker_local_transform := (
			registration.contact_attacker_local_transform
		)
		var previous_body_local_transform := (
			registration.contact_body_local_transform
		)
		registration.contact_attacker_shape = (
			attacker_shape_nodes[0].shape
			if attacker_shape_nodes.size() == 1
			else null
		)
		registration.contact_attacker_local_transform = (
			attacker_local_transform
		)
		registration.contact_body_local_transform = body_local_transform
		if not _contact_service.update_shape_proxies(
			enemy,
			attacker_proxy,
			body_proxy
		):
			# update_shape_proxies() is fail-before-mutation. Restore the provider
			# anchors it sampled so the old Registration/service pair remains a
			# coherent snapshot until the boundary clears the complete cohort.
			registration.contact_attacker_shape = previous_attacker_shape
			registration.contact_attacker_local_transform = (
				previous_attacker_local_transform
			)
			registration.contact_body_local_transform = (
				previous_body_local_transform
			)
			_request_layered_contact_atomic_fallback()
			break
		registration.contact_attacker_proxy = attacker_proxy
		registration.contact_body_proxy = body_proxy
		registration.contact_attacker_bounding_radius = (
			attacker_proxy.get_bounding_radius()
		)
		var previous_indexed_touch_extent := registration.indexed_touch_enemy_extent
		registration.indexed_touch_authority_capable = (
			enemy.supports_indexed_touch_authority()
			and attacker_shape_nodes.size() == 1
			and body_shape_nodes.size() == 1
		)
		registration.indexed_touch_enemy_extent = (
			enemy.touch_damage_extent_radius
			if registration.indexed_touch_authority_capable
			else 0.0
		)
		if (
			is_equal_approx(
				previous_indexed_touch_extent,
				_maximum_indexed_touch_enemy_extent
			)
			and registration.indexed_touch_enemy_extent
				< previous_indexed_touch_extent
		):
			_maximum_indexed_touch_enemy_extent_dirty = true
		else:
			_maximum_indexed_touch_enemy_extent = maxf(
				_maximum_indexed_touch_enemy_extent,
				registration.indexed_touch_enemy_extent
			)
		registration.contact_shape_revision = enemy.get_contact_shape_revision()
		registration.contact_attacker_shape_resource_ids = (
			_capture_contact_shape_set_resource_ids(attacker_shape_nodes)
		)
		registration.contact_body_shape_resource_ids = (
			_capture_contact_shape_set_resource_ids(body_shape_nodes)
		)
		registration.contact_attacker_shape_local_transforms = (
			_capture_contact_shape_set_local_transforms(attacker_shape_nodes, enemy)
		)
		registration.contact_body_shape_local_transforms = (
			_capture_contact_shape_set_local_transforms(body_shape_nodes, enemy)
		)
		if not registration.indexed_touch_authority_capable:
			enemy.set_indexed_touch_authority(false)
		registration.reset_indexed_touch_plant_cache()
		registration.indexed_touch_last_observed_transform = (
			attacker_anchor_transform
		)
		registration.indexed_touch_last_observed_transform_valid = true
	_dirty_contact_geometries.clear()


func _admit_layered_contact_proxies_for_tick(
	physics_frame: int,
	_initial_slot_count: int
) -> void:
	var write_index := 0
	var pending_count := _pending_contact_admissions.size()
	for read_index in range(pending_count):
		var registration := _pending_contact_admissions[read_index]
		if (
			registration == null
			or registration.tombstone
			or registration.suspended
			or registration.uses_anchored_compat_simulation
		):
			continue
		if registration.contact_proxy_registered:
			continue
		if physics_frame <= registration.activation_physics_frame:
			_pending_contact_admissions[write_index] = registration
			write_index += 1
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
		if not _registration_supports_shared_contact_authority(registration):
			# A fail-closed family remains on the same layered event/decision/motion
			# runner. It simply keeps its authored Area and publishes no shared proxy.
			enemy.set_indexed_touch_authority(false)
			continue
		if not _register_contact_proxy(registration):
			# Partial shared-contact admission is never authoritative. The caller
			# aborts this tick before current-contact/event work and the boundary mode
			# transition removes every proxy, including earlier successful entries.
			_request_layered_contact_atomic_fallback()
			break
	_pending_contact_admissions.resize(write_index)


func _queue_all_contact_admissions() -> void:
	_pending_contact_admissions.clear()
	for registration in _registrations:
		if (
			registration == null
			or registration.tombstone
			or registration.suspended
			or registration.uses_anchored_compat_simulation
			or registration.contact_proxy_registered
			or not _registration_supports_shared_contact_authority(registration)
		):
			continue
		_pending_contact_admissions.append(registration)


func _on_registered_enemy_combat_faction_changed(
	enemy: Enemy,
	previous_faction_id: int,
	next_faction_id: int,
	_revision: int
) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	var registration := (
		_registration_by_instance_id.get(enemy.get_instance_id()) as Registration
	)
	if (
		registration == null
		or registration.tombstone
		or registration.enemy != enemy
	):
		return
	if not registration.contact_proxy_registered or _contact_service == null:
		registration.contact_faction_id = next_faction_id
		return
	_enqueue_indexed_touch_dirty(registration, INDEXED_TOUCH_DIRTY_FACTION)
	if _contact_service.update_faction(
		enemy,
		previous_faction_id,
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
		or value == EnemySimulationPolicy.Mode.LAYERED_CONTACT
	)


func _is_layered_mode(value: int) -> bool:
	return (
		value == EnemySimulationPolicy.Mode.LAYERED_AREA
		or value == EnemySimulationPolicy.Mode.LAYERED_CONTACT
	)


func _uses_shared_contact_mode(value: int) -> bool:
	return value == EnemySimulationPolicy.Mode.LAYERED_CONTACT


func _registration_supports_shared_contact_authority(
	registration: Registration
) -> bool:
	if (
		registration == null
		or registration.tombstone
		or registration.uses_anchored_compat_simulation
	):
		return false
	var enemy := registration.enemy
	return (
		enemy != null
		and is_instance_valid(enemy)
		and enemy.supports_layered_contact_authoritative_simulation()
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
		_is_layered_mode(_mode)
		and (
			enemy.uses_anchored_compat_simulation()
			or enemy.supports_layered_area_authoritative_simulation()
		)
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
	_reset_layered_scheduler_state()
	for registration in _registrations:
		if registration == null or registration.tombstone:
			continue
		registration.next_decision_tick = 0
		registration.active_this_tick = false
		var enemy := registration.enemy
		if enemy == null or not is_instance_valid(enemy):
			continue
		if registration.uses_anchored_compat_simulation:
			enemy.set_indexed_touch_authority(false)
			_unregister_contact_proxy(registration)
			continue
		if (
			_uses_shared_contact_mode(_mode)
			and not _registration_supports_shared_contact_authority(registration)
		):
			# LAYERED_CONTACT is a per-registration contact capability, not a
			# scheduler admission mode. Unsupported families keep LAYERED_AREA
			# ownership and their complete authored TouchDamageArea.
			enemy.set_indexed_touch_authority(false)
			_unregister_contact_proxy(registration)
		enemy.prepare_layered_area_authoritative_simulation()
		_configure_registration_decision_schedule(registration, enemy)
		_enqueue_event_ready_registration(registration)
		_register_compat_decision_registration(registration)
		_schedule_next_physics_decision(
			registration,
			Engine.get_physics_frames()
		)
		_enqueue_urgent_decision_registration(registration)


func _normalize_supported_mode(value: int) -> EnemySimulationPolicy.Mode:
	if (
		value == EnemySimulationPolicy.Mode.COMPAT_60
		or value == EnemySimulationPolicy.Mode.LAYERED_AREA
		or value == EnemySimulationPolicy.Mode.LAYERED_CONTACT
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
	_metric_event_sleep_ack_count = 0
	_metric_touch_cooldown_deadline_wake_count = 0
	_metric_decision_phase_count = 0
	_metric_urgent_decision_count = 0
	_metric_motion_phase_count = 0
	_metric_contact_phase_count = 0
	_metric_contact_registration_count = 0
	_metric_contact_registration_rejection_count = 0
	_metric_contact_atomic_rollback_count = 0
	_metric_indexed_touch_sync_count = 0
	_metric_indexed_touch_authority_count = 0
	_metric_indexed_touch_plant_broadphase_count = 0
	_metric_indexed_touch_plant_exact_candidate_count = 0
	_metric_indexed_touch_plant_exact_shape_hit_count = 0
	_metric_indexed_touch_plant_candidate_check_count = 0
	_metric_indexed_touch_plant_sleep_skip_count = 0
	_metric_indexed_touch_plant_exact_cache_hit_count = 0
	_metric_indexed_touch_empty_snapshot_skip_count = 0
	_metric_indexed_touch_unchanged_snapshot_skip_count = 0
	_metric_indexed_touch_complete_snapshot_skip_count = 0
	_metric_indexed_touch_empty_corridor_skip_count = 0
	_metric_indexed_touch_nonempty_plant_certificate_build_count = 0
	_metric_indexed_touch_nonempty_plant_certificate_reuse_count = 0
	_metric_indexed_touch_nonempty_plant_certificate_reject_count = 0
	_metric_indexed_touch_dirty_enqueue_count = 0
	_metric_indexed_touch_dirty_drain_count = 0
	_metric_indexed_touch_dirty_ordered_drain_count = 0
	_metric_indexed_touch_dirty_sort_count = 0
	_metric_indexed_touch_moved_ordered_drain_count = 0
	_metric_indexed_touch_moved_sort_count = 0
	_metric_indexed_touch_player_invalidation_count = 0
	_metric_indexed_touch_global_invalidation_count = 0
	_metric_indexed_touch_player_index_query_count = 0
	_metric_indexed_touch_player_index_candidate_count = 0
	_metric_indexed_touch_player_aabb_pair_check_count = 0
	_metric_indexed_touch_player_aabb_pair_hit_count = 0
	_metric_indexed_touch_player_exact_shape_check_count = 0
	_metric_indexed_touch_player_exact_shape_hit_count = 0
	_metric_indexed_touch_player_slow_path_mover_count = 0
	_metric_indexed_touch_contact_enter_count = 0
	_metric_indexed_touch_contact_exit_count = 0
	_metric_touch_damage_attempt_count = 0
	_metric_touch_damage_accepted_count = 0
	_metric_touch_damage_rejected_count = 0
	_metric_activation_skip_count = 0
	_metric_suspended_skip_count = 0
	_metric_invalid_enemy_release_count = 0
	_metric_compaction_count = 0
	_metric_compacted_tombstone_count = 0
	_metric_clear_count = 0
	_metric_cleared_registration_count = 0
	_metric_profile_contact_setup_usec = 0
	_metric_profile_contact_admission_usec = 0
	_metric_profile_contact_geometry_usec = 0
	_metric_profile_contact_service_usec = 0
	_metric_profile_indexed_player_refresh_usec = 0
	_metric_profile_indexed_dirty_drain_usec = 0
	_metric_profile_event_phase_usec = 0
	_metric_profile_decision_phase_usec = 0
	_metric_profile_planned_contact_usec = 0
	_metric_profile_motion_phase_usec = 0


func _exit_tree() -> void:
	prepare_combat_services_for_runtime_teardown()
	clear(false)
