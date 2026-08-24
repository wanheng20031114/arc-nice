extends Node
class_name EnemyContactService

## Shared, deterministic enemy-to-enemy contact predictor.
##
## This stage intentionally owns no gameplay transition or damage. SHADOW mode
## compares predicted enter/stay/exit events with a caller-supplied observation
## provider. AUTHORITATIVE mode exposes the same stable event stream for a later
## production migration. An authoritative rollback always spends one complete
## tick in RESTORING before entering the requested non-authoritative mode.

const RELATIONS := preload(
	"res://scene/combat/faction/combat_relation_service.gd"
)
const MAX_DIFFERENCES := 64
const MAX_SIMULATION_ID := 2147483647
const BROAD_PHASE_CLOSED_BOUNDARY_EPSILON := 0.001

enum Mode {
	DISABLED,
	SHADOW,
	## Enemy-to-enemy prediction is authoritative while legacy Player/Plant
	## Area2D contact remains enabled. Unlike full AUTHORITATIVE, leaving this
	## mode needs no collision-mask restoration tick.
	HYBRID_ENEMY_CONTACT,
	AUTHORITATIVE,
	RESTORING,
}

enum ContactEvent {
	NONE,
	ENTER,
	STAY,
	EXIT,
}

class ContactEntry extends RefCounted:
	var entity: Node2D
	var instance_id := 0
	var simulation_id := 0
	var faction_id := RELATIONS.NEUTRAL
	var attacker_shape_proxy: CombatContactShapeProxy
	var body_shape_proxy: CombatContactShapeProxy
	var body_anchor_extent := 0.0
	var attacker_position_provider: Callable
	var body_position_provider: Callable
	var current_attacker_position := Vector2.ZERO
	var current_body_position := Vector2.ZERO
	var planned_attacker_position_provider: Callable
	var planned_body_position_provider: Callable
	var planned_motion_certification_provider: Callable
	var contact_target_provider: Callable
	var planned_attacker_position := Vector2.ZERO
	var planned_body_position := Vector2.ZERO
	var has_attacker_position := false
	var has_body_position := false
	var has_planned_attacker_position := false
	var has_planned_body_position := false


signal mode_changed(previous_mode: Mode, current_mode: Mode)
signal contact_event_predicted(event: Dictionary)

@export var initial_mode: Mode = Mode.DISABLED
@export var automatic_physics_step := true
## Semantic event dictionaries are intentionally optional in the production
## HYBRID path. SHADOW comparison, authoritative consumers, explicit listeners,
## and standalone tests still force capture.
@export var capture_event_streams := true
## Stable candidate order is evidence/debug data, not required by contact math.
@export var capture_candidate_order := true

var mode: Mode = Mode.DISABLED

var _pending_mode := -1
var _restoration_target_mode: Mode = Mode.DISABLED
var _hostile_aabb_query: Callable
var _observed_contacts_provider: Callable
var _relation_service := RELATIONS.new()

var _entries: Array[ContactEntry] = []
var _entry_by_instance_id: Dictionary[int, ContactEntry] = {}
var _entry_by_simulation_id: Dictionary[int, ContactEntry] = {}
var _faction_counts := PackedInt32Array()
var _present_faction_mask := 0
var _faction_membership_revision := 0
var _hostile_pair_cache_valid := false
var _hostile_pair_cache_present_faction_mask := 0
var _hostile_pair_cache_membership_revision := -1
var _hostile_pair_cache_relation_revision := -1
var _hostile_pair_cache_value := false
var _hostile_pair_cache_stale_prune_validated := false
var _order_dirty := false
var _maximum_target_extent := 0.0
var _maximum_extent_dirty := false
var _maximum_planned_target_displacement := 0.0
## `last_tick` records API entry even when a no-hostile fast path performs no
## position work. Planned contact needs a stronger certificate so a relation
## change later in the same tick cannot reuse a stale current snapshot.
var _last_current_position_refresh_tick := -1

# Current contacts are the only state exposed by has_directed_contact(). Planned
# swept contacts are kept separately so a future prediction can clip this tick's
# motion without being mistaken for contact that has already happened.
var _predicted_contacts: Dictionary[int, bool] = {}
var _planned_contacts: Dictionary[int, bool] = {}
var _directed_safe_motion_fractions: Dictionary[int, float] = {}
var _observed_contacts: Dictionary[int, bool] = {}
var _last_predicted_events: Array[Dictionary] = []
var _last_observed_events: Array[Dictionary] = []
var _last_candidate_order: Array[Vector2i] = []
var _differences: Array[Dictionary] = []
var _candidate_buffer: Array[Node2D] = []
var _observed_buffer: Array[Node2D] = []
var _canonical_candidate_buffer: Array[ContactEntry] = []
var _canonical_seen_simulation_ids: Dictionary[int, bool] = {}
var _stale_entry_buffer: Array[ContactEntry] = []
## Read-only empty set reused by the no-hostile transition path. Keeping this
## separate from the live dictionaries lets the first friendly-only tick emit
## deterministic EXIT events, then clear and retain the existing allocations.
var _empty_contact_set: Dictionary[int, bool] = {}
var _metrics: Dictionary = {}


func _init() -> void:
	_faction_counts.resize(RELATIONS.MAX_FACTION_COUNT)
	_faction_counts.fill(0)
	_reset_metrics()


func _ready() -> void:
	mode = _normalize_mode(initial_mode)
	set_physics_process(automatic_physics_step)


func _physics_process(_delta: float) -> void:
	step(Engine.get_physics_frames())


## Contract: query(world_aabb, source_faction_id, excluded_entity, result).
## The query must clear and fill result with a conservative enemy candidate set.
## Point-based spatial indexes are supported because the service grows the AABB
## by the largest registered target extent before invoking this callable.
func set_hostile_aabb_query(query: Callable) -> void:
	_hostile_aabb_query = query


## Contract: provider(attacker_entity, result). The provider must clear and fill
## result with the contacts currently reported by the legacy Area2D path.
func set_observed_contacts_provider(provider: Callable) -> void:
	_observed_contacts_provider = provider


func set_relation_service(relation_service: CombatRelationService) -> void:
	_relation_service = relation_service if relation_service != null else RELATIONS.new()
	_invalidate_hostile_pair_cache()


func request_mode(next_mode: int) -> void:
	var safe_mode := _normalize_mode(next_mode)
	if safe_mode == Mode.RESTORING:
		return
	if mode == Mode.RESTORING:
		_restoration_target_mode = safe_mode
		return
	_pending_mode = safe_mode


func register_enemy(
	entity: Node2D,
	simulation_id: int,
	faction_id: int,
	attacker_shape_proxy: CombatContactShapeProxy,
	body_shape_proxy: CombatContactShapeProxy = null,
	attacker_position_provider: Callable = Callable(),
	body_position_provider: Callable = Callable(),
	planned_attacker_position_provider: Callable = Callable(),
	planned_body_position_provider: Callable = Callable(),
	planned_motion_certification_provider: Callable = Callable(),
	contact_target_provider: Callable = Callable()
) -> bool:
	if (
		entity == null
		or not is_instance_valid(entity)
		or simulation_id <= 0
		or simulation_id > MAX_SIMULATION_ID
		or not RELATIONS.is_valid_faction_id(faction_id)
	):
		return false
	if (
		attacker_shape_proxy == null
		or not attacker_shape_proxy.is_supported()
	):
		_metrics["unsupported_shape_registrations"] = int(
			_metrics.get("unsupported_shape_registrations", 0)
		) + 1
		return false
	var safe_body_shape_proxy: CombatContactShapeProxy = (
		body_shape_proxy
		if body_shape_proxy != null
		else attacker_shape_proxy
	)
	if not safe_body_shape_proxy.is_supported():
		_metrics["unsupported_shape_registrations"] = int(
			_metrics.get("unsupported_shape_registrations", 0)
		) + 1
		return false
	var instance_id := entity.get_instance_id()
	if (
		_entry_by_instance_id.has(instance_id)
		or _entry_by_simulation_id.has(simulation_id)
	):
		return false
	var first_attacker_position: Vector2 = _read_position(
		entity,
		attacker_position_provider
	)
	var first_body_position: Vector2 = _read_position(entity, body_position_provider)
	if (
		not first_attacker_position.is_finite()
		or not first_body_position.is_finite()
	):
		return false
	var entry := ContactEntry.new()
	entry.entity = entity
	entry.instance_id = instance_id
	entry.simulation_id = simulation_id
	entry.faction_id = faction_id
	entry.attacker_shape_proxy = attacker_shape_proxy
	entry.body_shape_proxy = safe_body_shape_proxy
	entry.body_anchor_extent = (
		safe_body_shape_proxy.get_bounding_radius()
		+
		entity.global_position.distance_to(first_body_position)
	)
	entry.attacker_position_provider = attacker_position_provider
	entry.body_position_provider = body_position_provider
	entry.current_attacker_position = first_attacker_position
	entry.current_body_position = first_body_position
	entry.planned_attacker_position_provider = planned_attacker_position_provider
	entry.planned_body_position_provider = planned_body_position_provider
	entry.planned_motion_certification_provider = (
		planned_motion_certification_provider
	)
	entry.contact_target_provider = contact_target_provider
	entry.planned_attacker_position = first_attacker_position
	entry.planned_body_position = first_body_position
	entry.has_attacker_position = true
	entry.has_body_position = true
	entry.has_planned_attacker_position = true
	entry.has_planned_body_position = true
	_entries.append(entry)
	_entry_by_instance_id[instance_id] = entry
	_entry_by_simulation_id[simulation_id] = entry
	_increment_faction_count(faction_id)
	_mark_faction_membership_changed()
	_order_dirty = true
	_maximum_target_extent = maxf(
		_maximum_target_extent,
		entry.body_anchor_extent
	)
	_metrics["registrations_total"] = int(_metrics["registrations_total"]) + 1
	_metrics["registered_count"] = _entries.size()
	_metrics["max_registered_count"] = maxi(
		int(_metrics["max_registered_count"]),
		_entries.size()
	)
	return true


func unregister_enemy(entity: Node2D, simulation_id: int = 0) -> bool:
	if entity == null or not is_instance_valid(entity):
		return false
	var instance_id := entity.get_instance_id()
	var entry := _entry_by_instance_id.get(instance_id) as ContactEntry
	if entry == null or (simulation_id > 0 and entry.simulation_id != simulation_id):
		return false
	_remove_entry(entry)
	return true


func update_faction(
	entity: Node2D,
	old_faction_id: int,
	new_faction_id: int
) -> bool:
	if (
		entity == null
		or not is_instance_valid(entity)
		or not RELATIONS.is_valid_faction_id(new_faction_id)
	):
		return false
	var entry := _entry_by_instance_id.get(entity.get_instance_id()) as ContactEntry
	if entry == null:
		return false
	if RELATIONS.is_valid_faction_id(old_faction_id) and entry.faction_id != old_faction_id:
		old_faction_id = entry.faction_id
	if entry.faction_id == new_faction_id:
		return true
	_decrement_faction_count(entry.faction_id)
	entry.faction_id = new_faction_id
	_increment_faction_count(entry.faction_id)
	_mark_faction_membership_changed()
	_metrics["faction_updates_total"] = int(_metrics["faction_updates_total"]) + 1
	return true


func update_shape_proxies(
	entity: Node2D,
	attacker_shape_proxy: CombatContactShapeProxy,
	body_shape_proxy: CombatContactShapeProxy
) -> bool:
	if (
		entity == null
		or not is_instance_valid(entity)
		or attacker_shape_proxy == null
		or not attacker_shape_proxy.is_supported()
		or body_shape_proxy == null
		or not body_shape_proxy.is_supported()
	):
		return false
	var entry := _entry_by_instance_id.get(entity.get_instance_id()) as ContactEntry
	if entry == null:
		return false
	var attacker_position := _read_position(
		entity,
		entry.attacker_position_provider
	)
	var body_position := _read_position(entity, entry.body_position_provider)
	if not attacker_position.is_finite() or not body_position.is_finite():
		return false
	# Both proxies and their root-anchor extent publish as one service mutation;
	# no phase can observe a new touch shell paired with an old body shape.
	entry.attacker_shape_proxy = attacker_shape_proxy
	entry.body_shape_proxy = body_shape_proxy
	entry.body_anchor_extent = (
		body_shape_proxy.get_bounding_radius()
		+ entity.global_position.distance_to(body_position)
	)
	entry.current_attacker_position = attacker_position
	entry.current_body_position = body_position
	entry.planned_attacker_position = attacker_position
	entry.planned_body_position = body_position
	_maximum_extent_dirty = true
	_metrics["shape_proxy_updates_total"] = int(
		_metrics["shape_proxy_updates_total"]
	) + 1
	return true


func owns_enemy(entity: Node2D, simulation_id: int = 0) -> bool:
	if entity == null or not is_instance_valid(entity):
		return false
	var entry := _entry_by_instance_id.get(entity.get_instance_id()) as ContactEntry
	return entry != null and (simulation_id <= 0 or entry.simulation_id == simulation_id)


func has_registered_hostile_pair() -> bool:
	return _get_cached_hostile_pair_state()


## Allocation-free directed current-contact lookup for scheduled enemy logic.
## Future swept predictions never enter this dictionary: an enemy cannot begin
## attacking merely because its planned movement may touch later in the tick.
func has_directed_contact(attacker: Node2D, target: Node2D) -> bool:
	if (
		attacker == null
		or target == null
		or not is_instance_valid(attacker)
		or not is_instance_valid(target)
	):
		return false
	var attacker_entry := (
		_entry_by_instance_id.get(attacker.get_instance_id()) as ContactEntry
	)
	var target_entry := (
		_entry_by_instance_id.get(target.get_instance_id()) as ContactEntry
	)
	if attacker_entry == null or target_entry == null:
		return false
	return _predicted_contacts.has(_contact_key(
		attacker_entry.simulation_id,
		target_entry.simulation_id
	))


## Allocation-free lookup of this tick's directed continuous-motion limit.
## 1.0 means the complete planned displacement is safe; 0.0 means the directed
## attack shell already overlaps the target body at the current position.
func get_directed_safe_motion_fraction(
	attacker: Node2D,
	target: Node2D
) -> float:
	if (
		attacker == null
		or target == null
		or not is_instance_valid(attacker)
		or not is_instance_valid(target)
	):
		return 1.0
	var attacker_entry := (
		_entry_by_instance_id.get(attacker.get_instance_id()) as ContactEntry
	)
	var target_entry := (
		_entry_by_instance_id.get(target.get_instance_id()) as ContactEntry
	)
	if attacker_entry == null or target_entry == null:
		return 1.0
	return clampf(float(_directed_safe_motion_fractions.get(
		_contact_key(attacker_entry.simulation_id, target_entry.simulation_id),
		1.0
	)), 0.0, 1.0)


func has_planned_directed_contact(attacker: Node2D, target: Node2D) -> bool:
	if (
		attacker == null
		or target == null
		or not is_instance_valid(attacker)
		or not is_instance_valid(target)
	):
		return false
	var attacker_entry := (
		_entry_by_instance_id.get(attacker.get_instance_id()) as ContactEntry
	)
	var target_entry := (
		_entry_by_instance_id.get(target.get_instance_id()) as ContactEntry
	)
	if attacker_entry == null or target_entry == null:
		return false
	return _planned_contacts.has(_contact_key(
		attacker_entry.simulation_id,
		target_entry.simulation_id
	))


func clear() -> void:
	_entries.clear()
	_entry_by_instance_id.clear()
	_entry_by_simulation_id.clear()
	_faction_counts.fill(0)
	_present_faction_mask = 0
	_predicted_contacts.clear()
	_planned_contacts.clear()
	_directed_safe_motion_fractions.clear()
	_observed_contacts.clear()
	_last_predicted_events.clear()
	_last_observed_events.clear()
	_last_candidate_order.clear()
	_differences.clear()
	_candidate_buffer.clear()
	_observed_buffer.clear()
	_canonical_candidate_buffer.clear()
	_canonical_seen_simulation_ids.clear()
	_stale_entry_buffer.clear()
	_empty_contact_set.clear()
	_mark_faction_membership_changed()
	_order_dirty = false
	_maximum_target_extent = 0.0
	_maximum_extent_dirty = false
	_maximum_planned_target_displacement = 0.0
	_last_current_position_refresh_tick = -1
	_metrics["registered_count"] = 0
	_metrics["difference_buffer_size"] = 0
	_metrics["last_predicted_contact_count"] = 0
	_metrics["last_planned_contact_count"] = 0
	_metrics["last_observed_contact_count"] = 0


func step(physics_tick: int = -1) -> void:
	_apply_pending_mode_at_tick_boundary()
	_metrics["ticks_total"] = int(_metrics["ticks_total"]) + 1
	_metrics["last_tick"] = physics_tick
	match mode:
		Mode.DISABLED:
			_metrics["disabled_ticks"] = int(_metrics["disabled_ticks"]) + 1
			return
		Mode.RESTORING:
			_metrics["restoring_ticks"] = int(_metrics["restoring_ticks"]) + 1
			return
		Mode.SHADOW:
			_metrics["shadow_ticks"] = int(_metrics["shadow_ticks"]) + 1
		Mode.HYBRID_ENEMY_CONTACT:
			_metrics["hybrid_enemy_contact_ticks"] = int(
				_metrics["hybrid_enemy_contact_ticks"]
			) + 1
		Mode.AUTHORITATIVE:
			_metrics["authoritative_ticks"] = int(_metrics["authoritative_ticks"]) + 1

	if not _prepare_entries_for_contact_step():
		_complete_current_step_without_hostile_pairs(physics_tick)
		return
	_sort_entries_if_needed()
	_refresh_maximum_extent_if_needed()
	_refresh_current_positions()
	_last_current_position_refresh_tick = physics_tick
	# A new current snapshot invalidates the previous frame's motion plan. The
	# coordinator rebuilds planned contact only after every due decision ran.
	_planned_contacts.clear()
	_directed_safe_motion_fractions.clear()
	var next_predicted: Dictionary[int, bool] = {}
	_predict_current_contacts(next_predicted)
	if _should_capture_predicted_event_stream():
		_last_predicted_events = _build_event_stream(
			_predicted_contacts,
			next_predicted,
			physics_tick,
			true
		)
		_accumulate_event_metrics(_last_predicted_events, true)
		for event in _last_predicted_events:
			contact_event_predicted.emit(event)
	else:
		_last_predicted_events.clear()
		_metrics["predicted_event_stream_skips_total"] = int(
			_metrics["predicted_event_stream_skips_total"]
		) + 1

	if mode == Mode.SHADOW and _observed_contacts_provider.is_valid():
		var next_observed: Dictionary[int, bool] = {}
		_collect_observed_contacts(next_observed)
		_last_observed_events = _build_event_stream(
			_observed_contacts,
			next_observed,
			physics_tick,
			false
		)
		_accumulate_event_metrics(_last_observed_events, false)
		_compare_event_streams(
			_last_predicted_events,
			_last_observed_events,
			physics_tick
		)
		_observed_contacts = next_observed
	else:
		_last_observed_events.clear()
		if mode == Mode.SHADOW:
			_metrics["shadow_ticks_without_observation"] = int(
				_metrics["shadow_ticks_without_observation"]
			) + 1

	_predicted_contacts = next_predicted
	_metrics["last_predicted_contact_count"] = _predicted_contacts.size()
	_metrics["last_observed_contact_count"] = _observed_contacts.size()
	_metrics["last_planned_contact_count"] = 0


## Builds the continuous contact plan for the current physics tick. This must be
## called after movement decisions and before any CharacterBody2D transform is
## submitted. It does not advance modes or contact events a second time.
func step_planned(delta: float, physics_tick: int = -1) -> void:
	_planned_contacts.clear()
	_directed_safe_motion_fractions.clear()
	_metrics["planned_steps_total"] = int(
		_metrics["planned_steps_total"]
	) + 1
	_metrics["last_planned_tick"] = physics_tick
	if (
		mode == Mode.DISABLED
		or mode == Mode.RESTORING
		or not is_finite(delta)
		or delta < 0.0
	):
		_metrics["last_planned_contact_count"] = 0
		return
	if not _prepare_entries_for_contact_step():
		_last_candidate_order.clear()
		_metrics["planned_broad_phase_source_skips_total"] = int(
			_metrics.get("planned_broad_phase_source_skips_total", 0)
		) + _entries.size()
		_metrics["planned_no_hostile_pair_steps_total"] = int(
			_metrics.get("planned_no_hostile_pair_steps_total", 0)
		) + 1
		_metrics["last_maximum_target_displacement"] = 0.0
		_metrics["last_planned_contact_count"] = 0
		return
	_sort_entries_if_needed()
	_refresh_maximum_extent_if_needed()
	# No transform is permitted between step() and step_planned(), but refreshing
	# here makes the API fail safe for standalone diagnostics and explicit users.
	if (
		physics_tick < 0
		or _last_current_position_refresh_tick != physics_tick
	):
		_refresh_current_positions()
		_last_current_position_refresh_tick = physics_tick
	else:
		_metrics["planned_current_refresh_skips_total"] = int(
			_metrics.get("planned_current_refresh_skips_total", 0)
		) + 1
	_refresh_planned_positions(delta)
	_predict_planned_contacts(
		_planned_contacts,
		_directed_safe_motion_fractions,
		delta
	)
	_metrics["last_planned_contact_count"] = _planned_contacts.size()


func get_last_predicted_events() -> Array[Dictionary]:
	return _last_predicted_events.duplicate(true)


func get_last_observed_events() -> Array[Dictionary]:
	return _last_observed_events.duplicate(true)


func get_last_candidate_order() -> Array[Vector2i]:
	return _last_candidate_order.duplicate()


func get_differences() -> Array[Dictionary]:
	return _differences.duplicate(true)


func get_metrics() -> Dictionary:
	var result := _metrics.duplicate(true)
	result["mode"] = mode
	result["mode_name"] = mode_to_name(mode)
	result["pending_mode"] = _pending_mode
	result["registered_count"] = _entries.size()
	result["last_current_position_refresh_tick"] = (
		_last_current_position_refresh_tick
	)
	result["difference_buffer_size"] = _differences.size()
	result["predicted_contact_count"] = _predicted_contacts.size()
	result["planned_contact_count"] = _planned_contacts.size()
	result["observed_contact_count"] = _observed_contacts.size()
	result["authoritative_scope"] = (
		&"ENEMY_TO_ENEMY_ONLY"
		if mode == Mode.HYBRID_ENEMY_CONTACT
		else &"NONE"
	)
	return result


func reset_metrics() -> void:
	var registered_count := _entries.size()
	_reset_metrics()
	_metrics["registered_count"] = registered_count
	_metrics["max_registered_count"] = registered_count


static func mode_to_name(value: int) -> StringName:
	match value:
		Mode.DISABLED:
			return &"DISABLED"
		Mode.SHADOW:
			return &"SHADOW"
		Mode.HYBRID_ENEMY_CONTACT:
			return &"HYBRID_ENEMY_CONTACT"
		Mode.AUTHORITATIVE:
			return &"AUTHORITATIVE"
		Mode.RESTORING:
			return &"RESTORING"
	return &"DISABLED"


static func event_to_name(value: int) -> StringName:
	match value:
		ContactEvent.ENTER:
			return &"ENTER"
		ContactEvent.STAY:
			return &"STAY"
		ContactEvent.EXIT:
			return &"EXIT"
	return &"NONE"


func _apply_pending_mode_at_tick_boundary() -> void:
	if mode == Mode.RESTORING:
		var previous_mode := mode
		mode = _restoration_target_mode
		_restoration_target_mode = Mode.DISABLED
		_metrics["restorations_completed"] = int(
			_metrics["restorations_completed"]
		) + 1
		mode_changed.emit(previous_mode, mode)
		return
	if _pending_mode < 0 or _pending_mode == mode:
		_pending_mode = -1
		return
	var requested_mode := _normalize_mode(_pending_mode)
	_pending_mode = -1
	var previous_mode := mode
	if mode == Mode.AUTHORITATIVE and requested_mode != Mode.AUTHORITATIVE:
		mode = Mode.RESTORING
		_restoration_target_mode = requested_mode
		_metrics["restorations_started"] = int(
			_metrics["restorations_started"]
		) + 1
	else:
		mode = requested_mode
	mode_changed.emit(previous_mode, mode)


func _predict_current_contacts(next_contacts: Dictionary[int, bool]) -> void:
	_last_candidate_order.clear()
	if not _hostile_aabb_query.is_valid():
		_metrics["ticks_without_broad_phase_query"] = int(
			_metrics["ticks_without_broad_phase_query"]
		) + 1
		return
	for source in _entries:
		if not source.has_attacker_position:
			continue
		if not _has_registered_hostile_target(source.faction_id):
			_metrics["broad_phase_source_skips_total"] = int(
				_metrics.get("broad_phase_source_skips_total", 0)
			) + 1
			continue
		var query_aabb: Rect2 = source.attacker_shape_proxy.get_world_aabb_at(
			source.current_attacker_position
		).grow(
			_maximum_target_extent + BROAD_PHASE_CLOSED_BOUNDARY_EPSILON
		)
		_candidate_buffer.clear()
		_hostile_aabb_query.call(
			query_aabb,
			source.faction_id,
			source.entity,
			_candidate_buffer
		)
		_metrics["broad_phase_queries_total"] = int(
			_metrics["broad_phase_queries_total"]
		) + 1
		_metrics["broad_phase_candidates_total"] = int(
			_metrics["broad_phase_candidates_total"]
		) + _candidate_buffer.size()
		var candidates := _canonicalize_candidates(source, _candidate_buffer)
		for target in candidates:
			if capture_candidate_order:
				_last_candidate_order.append(Vector2i(
					source.simulation_id,
					target.simulation_id
				))
			_metrics["narrow_phase_tests_total"] = int(
				_metrics["narrow_phase_tests_total"]
			) + 1
			var current_overlap: bool = source.attacker_shape_proxy.overlaps_at(
				source.current_attacker_position,
				target.body_shape_proxy,
				target.current_body_position
			)
			if current_overlap:
				_metrics["current_overlap_hits_total"] = int(
					_metrics["current_overlap_hits_total"]
				) + 1
				next_contacts[_contact_key(
					source.simulation_id,
					target.simulation_id
				)] = true


func _predict_planned_contacts(
	next_contacts: Dictionary[int, bool],
	next_safe_fractions: Dictionary[int, float],
	delta: float
) -> void:
	_last_candidate_order.clear()
	if not _hostile_aabb_query.is_valid():
		_metrics["planned_steps_without_broad_phase_query"] = int(
			_metrics["planned_steps_without_broad_phase_query"]
		) + 1
		return
	for source in _entries:
		if (
			not source.has_attacker_position
			or not source.has_planned_attacker_position
		):
			continue
		if not _has_registered_hostile_target(source.faction_id):
			_metrics["planned_broad_phase_source_skips_total"] = int(
				_metrics.get("planned_broad_phase_source_skips_total", 0)
			) + 1
			continue
		var query_aabb := source.attacker_shape_proxy.get_swept_world_aabb(
			source.current_attacker_position,
			source.planned_attacker_position
		).grow(
			_maximum_target_extent
			+ _maximum_planned_target_displacement
			+ BROAD_PHASE_CLOSED_BOUNDARY_EPSILON
		)
		_candidate_buffer.clear()
		_hostile_aabb_query.call(
			query_aabb,
			source.faction_id,
			source.entity,
			_candidate_buffer
		)
		_metrics["planned_broad_phase_queries_total"] = int(
			_metrics["planned_broad_phase_queries_total"]
		) + 1
		_metrics["planned_broad_phase_candidates_total"] = int(
			_metrics["planned_broad_phase_candidates_total"]
		) + _candidate_buffer.size()
		var candidates := _canonicalize_candidates(source, _candidate_buffer)
		for target in candidates:
			if not target.has_planned_body_position:
				continue
			if capture_candidate_order:
				_last_candidate_order.append(Vector2i(
					source.simulation_id,
					target.simulation_id
				))
			_metrics["planned_narrow_phase_tests_total"] = int(
				_metrics["planned_narrow_phase_tests_total"]
			) + 1
			var key := _contact_key(
				source.simulation_id,
				target.simulation_id
			)
			if source.attacker_shape_proxy.overlaps_at(
				source.current_attacker_position,
				target.body_shape_proxy,
				target.current_body_position
			):
				next_contacts[key] = true
				next_safe_fractions[key] = 0.0
				_metrics["planned_current_overlap_hits_total"] = int(
					_metrics["planned_current_overlap_hits_total"]
				) + 1
				continue
			_metrics["swept_tests_total"] = int(
				_metrics["swept_tests_total"]
			) + 1
			var synchronized_hit := source.attacker_shape_proxy.swept_overlaps(
				source.current_attacker_position,
				source.planned_attacker_position,
				target.body_shape_proxy,
				target.current_body_position,
				target.planned_body_position
			)
			if not synchronized_hit:
				continue
			_metrics["swept_hits_total"] = int(
				_metrics["swept_hits_total"]
			) + 1
			next_contacts[key] = true
			if not _can_authoritatively_clip_pair(source, target, delta):
				_metrics["uncommitted_pair_shadow_hits_total"] = int(
					_metrics["uncommitted_pair_shadow_hits_total"]
				) + 1
				continue
			var safe_fraction := (
				source.attacker_shape_proxy
				.get_earliest_swept_overlap_fraction(
					source.current_attacker_position,
					source.planned_attacker_position,
					target.body_shape_proxy,
					target.current_body_position,
					target.planned_body_position
				)
			)
			if (
				_is_mutual_contact_objective_pair(source, target)
				and _has_planned_body_motion(source)
				and _has_planned_body_motion(target)
			):
				# A common normalized TOI is valid only while both members will
				# consume it. Once an asymmetric shell has stopped one member, the
				# other must keep closing against that stationary body with its own
				# directed TOI; feeding the already-overlapping reverse shell back
				# into the minimum would lock the pair at the larger shell forever.
				safe_fraction = _get_mutual_certified_safe_fraction(
					source,
					target
				)
				_store_planned_contact_fraction(
					next_contacts,
					next_safe_fractions,
					_contact_key(
						target.simulation_id,
						source.simulation_id
					),
					safe_fraction
				)
			_store_planned_contact_fraction(
				next_contacts,
				next_safe_fractions,
				key,
				safe_fraction
			)
			_metrics["toi_solves_total"] = int(
				_metrics["toi_solves_total"]
			) + 1


func _can_authoritatively_clip_pair(
	source: ContactEntry,
	target: ContactEntry,
	delta: float
) -> bool:
	if _read_contact_target(source) != target.entity:
		return false
	if not _has_planned_body_motion(source):
		return false
	if (
		not _is_straight_plan_certified(source, target, delta)
		or not _is_straight_plan_certified(target, source, delta)
	):
		return false
	if target.current_body_position.is_equal_approx(target.planned_body_position):
		return true
	# A moving target must consume the same normalized fraction. Even a statically
	# certified target pursuing a Player/Plant would otherwise keep moving for the
	# remainder of the frame and invalidate the source-only synchronized TOI.
	return _is_mutual_contact_objective_pair(source, target)


func _has_planned_body_motion(entry: ContactEntry) -> bool:
	return not entry.current_body_position.is_equal_approx(
		entry.planned_body_position
	)


func _is_mutual_contact_objective_pair(
	first: ContactEntry,
	second: ContactEntry
) -> bool:
	return (
		_read_contact_target(first) == second.entity
		and _read_contact_target(second) == first.entity
		and _relation_service.is_hostile(first.faction_id, second.faction_id)
		and _relation_service.is_hostile(second.faction_id, first.faction_id)
	)


func _get_mutual_certified_safe_fraction(
	first: ContactEntry,
	second: ContactEntry
) -> float:
	var result := 1.0
	if first.attacker_shape_proxy.swept_overlaps(
		first.current_attacker_position,
		first.planned_attacker_position,
		second.body_shape_proxy,
		second.current_body_position,
		second.planned_body_position
	):
		result = minf(
			result,
			first.attacker_shape_proxy.get_earliest_swept_overlap_fraction(
				first.current_attacker_position,
				first.planned_attacker_position,
				second.body_shape_proxy,
				second.current_body_position,
				second.planned_body_position
			)
		)
	if second.attacker_shape_proxy.swept_overlaps(
		second.current_attacker_position,
		second.planned_attacker_position,
		first.body_shape_proxy,
		first.current_body_position,
		first.planned_body_position
	):
		result = minf(
			result,
			second.attacker_shape_proxy.get_earliest_swept_overlap_fraction(
				second.current_attacker_position,
				second.planned_attacker_position,
				first.body_shape_proxy,
				first.current_body_position,
				first.planned_body_position
			)
		)
	return result


func _store_planned_contact_fraction(
	next_contacts: Dictionary[int, bool],
	next_safe_fractions: Dictionary[int, float],
	key: int,
	safe_fraction: float
) -> void:
	next_contacts[key] = true
	next_safe_fractions[key] = minf(
		float(next_safe_fractions.get(key, 1.0)),
		clampf(safe_fraction, 0.0, 1.0)
	)


func _is_straight_plan_certified(
	target: ContactEntry,
	source: ContactEntry,
	delta: float
) -> bool:
	if target.current_body_position.is_equal_approx(target.planned_body_position):
		return true
	if not target.planned_motion_certification_provider.is_valid():
		return false
	var result: Variant = target.planned_motion_certification_provider.call(
		delta,
		source.entity
	)
	return result is bool and bool(result)


func _read_contact_target(entry: ContactEntry) -> Node2D:
	if entry == null or not entry.contact_target_provider.is_valid():
		return null
	var result: Variant = entry.contact_target_provider.call()
	if result is Node2D and is_instance_valid(result):
		return result as Node2D
	return null


func _collect_observed_contacts(next_contacts: Dictionary[int, bool]) -> void:
	for source in _entries:
		_observed_buffer.clear()
		_observed_contacts_provider.call(source.entity, _observed_buffer)
		var candidates := _canonicalize_candidates(source, _observed_buffer)
		for target in candidates:
			next_contacts[_contact_key(
				source.simulation_id,
				target.simulation_id
			)] = true


func _canonicalize_candidates(
	source: ContactEntry,
	raw_candidates: Array
) -> Array[ContactEntry]:
	_canonical_candidate_buffer.clear()
	_canonical_seen_simulation_ids.clear()
	for candidate_variant in raw_candidates:
		if not candidate_variant is Node2D:
			continue
		var candidate := candidate_variant as Node2D
		if candidate == null or not is_instance_valid(candidate):
			continue
		var target := _entry_by_instance_id.get(candidate.get_instance_id()) as ContactEntry
		if (
			target == null
			or target == source
			or _canonical_seen_simulation_ids.has(target.simulation_id)
			or not _relation_service.is_hostile(source.faction_id, target.faction_id)
		):
			continue
		if not target.has_body_position:
			continue
		_canonical_seen_simulation_ids[target.simulation_id] = true
		_canonical_candidate_buffer.append(target)
	_canonical_candidate_buffer.sort_custom(_is_contact_entry_before)
	return _canonical_candidate_buffer


func _is_contact_entry_before(left: ContactEntry, right: ContactEntry) -> bool:
	return left.simulation_id < right.simulation_id


func _should_capture_predicted_event_stream() -> bool:
	return (
		capture_event_streams
		or mode == Mode.SHADOW
		or mode == Mode.AUTHORITATIVE
		or not contact_event_predicted.get_connections().is_empty()
	)


func _build_event_stream(
	previous_contacts: Dictionary[int, bool],
	next_contacts: Dictionary[int, bool],
	physics_tick: int,
	predicted: bool
) -> Array[Dictionary]:
	var keys: Array[int] = []
	for key in previous_contacts:
		keys.append(int(key))
	for key in next_contacts:
		var safe_key := int(key)
		if not previous_contacts.has(safe_key):
			keys.append(safe_key)
	keys.sort()
	var events: Array[Dictionary] = []
	for key in keys:
		var existed := previous_contacts.has(key)
		var exists := next_contacts.has(key)
		var event_type: ContactEvent = ContactEvent.NONE
		if exists and existed:
			event_type = ContactEvent.STAY
		elif exists:
			event_type = ContactEvent.ENTER
		elif existed:
			event_type = ContactEvent.EXIT
		if event_type == ContactEvent.NONE:
			continue
		events.append({
			"tick": physics_tick,
			"attacker_simulation_id": _attacker_id_from_key(key),
			"target_simulation_id": _target_id_from_key(key),
			"event": event_type,
			"event_name": event_to_name(event_type),
			"predicted": predicted,
		})
	return events


func _compare_event_streams(
	predicted_events: Array[Dictionary],
	observed_events: Array[Dictionary],
	physics_tick: int
) -> void:
	var predicted_by_key: Dictionary[int, int] = {}
	var observed_by_key: Dictionary[int, int] = {}
	for event in predicted_events:
		predicted_by_key[_contact_key(
			int(event["attacker_simulation_id"]),
			int(event["target_simulation_id"])
		)] = int(event["event"])
	for event in observed_events:
		observed_by_key[_contact_key(
			int(event["attacker_simulation_id"]),
			int(event["target_simulation_id"])
		)] = int(event["event"])
	var keys: Array[int] = []
	for key in predicted_by_key:
		keys.append(int(key))
	for key in observed_by_key:
		var safe_key := int(key)
		if not predicted_by_key.has(safe_key):
			keys.append(safe_key)
	keys.sort()
	for key in keys:
		var predicted_event := int(predicted_by_key.get(key, ContactEvent.NONE))
		var observed_event := int(observed_by_key.get(key, ContactEvent.NONE))
		if predicted_event == observed_event:
			continue
		_append_difference({
			"tick": physics_tick,
			"attacker_simulation_id": _attacker_id_from_key(key),
			"target_simulation_id": _target_id_from_key(key),
			"predicted_event": predicted_event,
			"predicted_event_name": event_to_name(predicted_event),
			"observed_event": observed_event,
			"observed_event_name": event_to_name(observed_event),
		})


func _append_difference(difference: Dictionary) -> void:
	_metrics["differences_total"] = int(_metrics["differences_total"]) + 1
	if _differences.size() >= MAX_DIFFERENCES:
		_differences.pop_front()
		_metrics["difference_overflow_total"] = int(
			_metrics["difference_overflow_total"]
		) + 1
	_differences.append(difference)
	_metrics["difference_buffer_size"] = _differences.size()


func _accumulate_event_metrics(
	events: Array[Dictionary],
	predicted: bool
) -> void:
	var prefix := "predicted_" if predicted else "observed_"
	for event in events:
		var event_name := String(event_to_name(int(event["event"]))).to_lower()
		var metric_name := prefix + event_name + "_total"
		_metrics[metric_name] = int(_metrics[metric_name]) + 1


func _sort_entries_if_needed() -> void:
	if not _order_dirty:
		return
	_entries.sort_custom(func(left: ContactEntry, right: ContactEntry) -> bool:
		return left.simulation_id < right.simulation_id
	)
	_order_dirty = false


func _prune_stale_entries() -> void:
	_stale_entry_buffer.clear()
	_metrics["stale_prune_scans_total"] = int(
		_metrics["stale_prune_scans_total"]
	) + 1
	_metrics["stale_prune_entry_checks_total"] = int(
		_metrics["stale_prune_entry_checks_total"]
	) + _entries.size()
	for entry in _entries:
		if entry.entity == null or not is_instance_valid(entry.entity):
			_stale_entry_buffer.append(entry)
	for entry in _stale_entry_buffer:
		_remove_entry(entry, true)


func _has_registered_hostile_target(source_faction_id: int) -> bool:
	if (
		_relation_service == null
		or not RELATIONS.is_valid_faction_id(source_faction_id)
	):
		return false
	return (
		_relation_service.get_hostile_mask(source_faction_id)
		& _present_faction_mask
	) != 0


func _compute_has_any_registered_hostile_pair() -> bool:
	if _relation_service == null or _present_faction_mask == 0:
		return false
	for faction_id in range(RELATIONS.MAX_FACTION_COUNT):
		if (_present_faction_mask & (1 << faction_id)) == 0:
			continue
		if (
			_relation_service.get_hostile_mask(faction_id)
			& _present_faction_mask
		) != 0:
			return true
	return false


func _prepare_entries_for_contact_step() -> bool:
	# A stable false cache is stronger than a stale-entry scan: removing an entity
	# cannot create a hostile faction pair, and no position can matter while the
	# relation/membership key is unchanged. Any relation or registry mutation
	# invalidates the key and forces one exact prune before trusting it again.
	if (
		_hostile_pair_cache_matches_current_state()
		and _hostile_pair_cache_stale_prune_validated
		and not _hostile_pair_cache_value
	):
		_metrics["hostile_pair_cache_hits_total"] = int(
			_metrics["hostile_pair_cache_hits_total"]
		) + 1
		_metrics["no_hostile_stale_prune_skips_total"] = int(
			_metrics["no_hostile_stale_prune_skips_total"]
		) + 1
		return false
	_prune_stale_entries()
	var has_hostile_pair := _get_cached_hostile_pair_state()
	_hostile_pair_cache_stale_prune_validated = true
	return has_hostile_pair


func _get_cached_hostile_pair_state() -> bool:
	if _hostile_pair_cache_matches_current_state():
		_metrics["hostile_pair_cache_hits_total"] = int(
			_metrics["hostile_pair_cache_hits_total"]
		) + 1
		return _hostile_pair_cache_value
	_metrics["hostile_pair_cache_misses_total"] = int(
		_metrics["hostile_pair_cache_misses_total"]
	) + 1
	# A public read may populate the cheap faction/relation result between contact
	# phases. It cannot certify entity liveness; only the step preparation scan can.
	_hostile_pair_cache_stale_prune_validated = false
	_hostile_pair_cache_valid = true
	_hostile_pair_cache_present_faction_mask = _present_faction_mask
	_hostile_pair_cache_membership_revision = _faction_membership_revision
	_hostile_pair_cache_relation_revision = _get_relation_revision()
	_hostile_pair_cache_value = _compute_has_any_registered_hostile_pair()
	return _hostile_pair_cache_value


func _hostile_pair_cache_matches_current_state() -> bool:
	return (
		_hostile_pair_cache_valid
		and _hostile_pair_cache_present_faction_mask == _present_faction_mask
		and _hostile_pair_cache_membership_revision == _faction_membership_revision
		and _hostile_pair_cache_relation_revision == _get_relation_revision()
	)


func _get_relation_revision() -> int:
	return _relation_service.get_revision() if _relation_service != null else -1


func _mark_faction_membership_changed() -> void:
	_faction_membership_revision += 1
	_invalidate_hostile_pair_cache()


func _invalidate_hostile_pair_cache() -> void:
	_hostile_pair_cache_valid = false
	_hostile_pair_cache_stale_prune_validated = false
	if not _metrics.is_empty():
		_metrics["hostile_pair_cache_invalidations_total"] = int(
			_metrics.get("hostile_pair_cache_invalidations_total", 0)
		) + 1


func _complete_current_step_without_hostile_pairs(physics_tick: int) -> void:
	_last_candidate_order.clear()
	_planned_contacts.clear()
	_directed_safe_motion_fractions.clear()
	_metrics["broad_phase_source_skips_total"] = int(
		_metrics.get("broad_phase_source_skips_total", 0)
	) + _entries.size()
	_metrics["no_hostile_pair_ticks_total"] = int(
		_metrics.get("no_hostile_pair_ticks_total", 0)
	) + 1
	if _should_capture_predicted_event_stream():
		if _predicted_contacts.is_empty():
			_last_predicted_events.clear()
		else:
			_last_predicted_events = _build_event_stream(
				_predicted_contacts,
				_empty_contact_set,
				physics_tick,
				true
			)
			_accumulate_event_metrics(_last_predicted_events, true)
			for event in _last_predicted_events:
				contact_event_predicted.emit(event)
	else:
		_last_predicted_events.clear()
		_metrics["predicted_event_stream_skips_total"] = int(
			_metrics["predicted_event_stream_skips_total"]
		) + 1

	if mode == Mode.SHADOW and _observed_contacts_provider.is_valid():
		if _observed_contacts.is_empty():
			_last_observed_events.clear()
		else:
			_last_observed_events = _build_event_stream(
				_observed_contacts,
				_empty_contact_set,
				physics_tick,
				false
			)
			_accumulate_event_metrics(_last_observed_events, false)
		_compare_event_streams(
			_last_predicted_events,
			_last_observed_events,
			physics_tick
		)
	else:
		_last_observed_events.clear()
		if mode == Mode.SHADOW:
			_metrics["shadow_ticks_without_observation"] = int(
				_metrics["shadow_ticks_without_observation"]
			) + 1

	_predicted_contacts.clear()
	_observed_contacts.clear()
	_metrics["no_hostile_empty_contact_reuses_total"] = int(
		_metrics["no_hostile_empty_contact_reuses_total"]
	) + 1
	_metrics["last_predicted_contact_count"] = 0
	_metrics["last_observed_contact_count"] = _observed_contacts.size()
	_metrics["last_planned_contact_count"] = 0


func _increment_faction_count(faction_id: int) -> void:
	if not RELATIONS.is_valid_faction_id(faction_id):
		return
	_faction_counts[faction_id] += 1
	_present_faction_mask |= 1 << faction_id


func _decrement_faction_count(faction_id: int) -> void:
	if not RELATIONS.is_valid_faction_id(faction_id):
		return
	_faction_counts[faction_id] = maxi(_faction_counts[faction_id] - 1, 0)
	if _faction_counts[faction_id] == 0:
		_present_faction_mask &= ~(1 << faction_id)


func _remove_entry(entry: ContactEntry, stale: bool = false) -> void:
	_decrement_faction_count(entry.faction_id)
	_entry_by_instance_id.erase(entry.instance_id)
	_entry_by_simulation_id.erase(entry.simulation_id)
	_entries.erase(entry)
	_mark_faction_membership_changed()
	_order_dirty = true
	_maximum_extent_dirty = true
	_metrics["unregistrations_total"] = int(_metrics["unregistrations_total"]) + 1
	if stale:
		_metrics["stale_pruned_total"] = int(_metrics["stale_pruned_total"]) + 1
	_metrics["registered_count"] = _entries.size()


func _refresh_maximum_extent_if_needed() -> void:
	if not _maximum_extent_dirty:
		return
	_maximum_target_extent = 0.0
	for entry in _entries:
		_maximum_target_extent = maxf(
			_maximum_target_extent,
			entry.body_anchor_extent
		)
	_maximum_extent_dirty = false


func _refresh_current_positions() -> void:
	_metrics["current_position_refresh_steps_total"] = int(
		_metrics["current_position_refresh_steps_total"]
	) + 1
	_metrics["current_position_refresh_entry_checks_total"] = int(
		_metrics["current_position_refresh_entry_checks_total"]
	) + _entries.size()
	for entry in _entries:
		var next_attacker_position := _read_position(
			entry.entity,
			entry.attacker_position_provider
		)
		var next_body_position := _read_position(
			entry.entity,
			entry.body_position_provider
		)
		entry.has_attacker_position = next_attacker_position.is_finite()
		entry.has_body_position = next_body_position.is_finite()
		if not entry.has_attacker_position or not entry.has_body_position:
			_metrics["invalid_position_entries_total"] = int(
				_metrics["invalid_position_entries_total"]
			) + 1
			continue
		entry.current_attacker_position = next_attacker_position
		entry.current_body_position = next_body_position


func _refresh_planned_positions(delta: float) -> void:
	_metrics["planned_position_refresh_steps_total"] = int(
		_metrics["planned_position_refresh_steps_total"]
	) + 1
	_metrics["planned_position_refresh_entry_checks_total"] = int(
		_metrics["planned_position_refresh_entry_checks_total"]
	) + _entries.size()
	_maximum_planned_target_displacement = 0.0
	for entry in _entries:
		if not entry.has_attacker_position or not entry.has_body_position:
			entry.has_planned_attacker_position = false
			entry.has_planned_body_position = false
			continue
		var next_attacker_position := _read_planned_position(
			entry.entity,
			entry.planned_attacker_position_provider,
			delta,
			entry.current_attacker_position
		)
		var next_body_position := _read_planned_position(
			entry.entity,
			entry.planned_body_position_provider,
			delta,
			entry.current_body_position
		)
		entry.has_planned_attacker_position = next_attacker_position.is_finite()
		entry.has_planned_body_position = next_body_position.is_finite()
		if (
			not entry.has_planned_attacker_position
			or not entry.has_planned_body_position
		):
			_metrics["invalid_planned_position_entries_total"] = int(
				_metrics["invalid_planned_position_entries_total"]
			) + 1
			continue
		entry.planned_attacker_position = next_attacker_position
		entry.planned_body_position = next_body_position
		_maximum_planned_target_displacement = maxf(
			_maximum_planned_target_displacement,
			entry.current_body_position.distance_to(entry.planned_body_position)
		)
	_metrics["last_maximum_target_displacement"] = (
		_maximum_planned_target_displacement
	)
	_metrics["maximum_target_displacement"] = maxf(
		float(_metrics["maximum_target_displacement"]),
		_maximum_planned_target_displacement
	)


func _read_position(entity: Node2D, provider: Callable) -> Vector2:
	if provider.is_valid():
		var provided: Variant = provider.call()
		if provided is Vector2:
			return Vector2(provided)
		return Vector2(INF, INF)
	if entity == null or not is_instance_valid(entity):
		return Vector2(INF, INF)
	return entity.global_position


func _read_planned_position(
	entity: Node2D,
	provider: Callable,
	delta: float,
	fallback_position: Vector2
) -> Vector2:
	if provider.is_valid():
		var provided: Variant = provider.call(delta)
		if provided is Vector2:
			return Vector2(provided)
		return Vector2(INF, INF)
	if entity == null or not is_instance_valid(entity):
		return Vector2(INF, INF)
	return fallback_position


func _reset_metrics() -> void:
	_metrics = {
		"ticks_total": 0,
		"disabled_ticks": 0,
		"shadow_ticks": 0,
		"hybrid_enemy_contact_ticks": 0,
		"authoritative_ticks": 0,
		"restoring_ticks": 0,
		"shadow_ticks_without_observation": 0,
		"ticks_without_broad_phase_query": 0,
		"planned_steps_without_broad_phase_query": 0,
		"planned_steps_total": 0,
		"no_hostile_pair_ticks_total": 0,
		"planned_no_hostile_pair_steps_total": 0,
		"planned_current_refresh_skips_total": 0,
		"hostile_pair_cache_hits_total": 0,
		"hostile_pair_cache_misses_total": 0,
		"hostile_pair_cache_invalidations_total": 0,
		"no_hostile_stale_prune_skips_total": 0,
		"no_hostile_empty_contact_reuses_total": 0,
		"registrations_total": 0,
		"unregistrations_total": 0,
		"unsupported_shape_registrations": 0,
		"stale_pruned_total": 0,
		"stale_prune_scans_total": 0,
		"stale_prune_entry_checks_total": 0,
		"faction_updates_total": 0,
		"shape_proxy_updates_total": 0,
		"registered_count": 0,
		"max_registered_count": 0,
		"broad_phase_queries_total": 0,
		"broad_phase_source_skips_total": 0,
		"broad_phase_candidates_total": 0,
		"narrow_phase_tests_total": 0,
		"current_overlap_hits_total": 0,
		"planned_broad_phase_queries_total": 0,
		"planned_broad_phase_source_skips_total": 0,
		"planned_broad_phase_candidates_total": 0,
		"planned_narrow_phase_tests_total": 0,
		"planned_current_overlap_hits_total": 0,
		"swept_tests_total": 0,
		"swept_hits_total": 0,
		"toi_solves_total": 0,
		"uncommitted_pair_shadow_hits_total": 0,
		"invalid_position_entries_total": 0,
		"invalid_planned_position_entries_total": 0,
		"current_position_refresh_steps_total": 0,
		"current_position_refresh_entry_checks_total": 0,
		"planned_position_refresh_steps_total": 0,
		"planned_position_refresh_entry_checks_total": 0,
		"last_maximum_target_displacement": 0.0,
		"maximum_target_displacement": 0.0,
		"predicted_enter_total": 0,
		"predicted_stay_total": 0,
		"predicted_exit_total": 0,
		"predicted_event_stream_skips_total": 0,
		"observed_enter_total": 0,
		"observed_stay_total": 0,
		"observed_exit_total": 0,
		"differences_total": 0,
		"difference_buffer_size": 0,
		"difference_overflow_total": 0,
		"restorations_started": 0,
		"restorations_completed": 0,
		"last_tick": -1,
		"last_planned_tick": -1,
		"last_predicted_contact_count": 0,
		"last_planned_contact_count": 0,
		"last_observed_contact_count": 0,
	}


func _normalize_mode(value: int) -> Mode:
	if value < Mode.DISABLED or value > Mode.RESTORING:
		return Mode.DISABLED
	return value


func _contact_key(attacker_simulation_id: int, target_simulation_id: int) -> int:
	return (attacker_simulation_id << 32) | (target_simulation_id & 0xffffffff)


func _attacker_id_from_key(key: int) -> int:
	return key >> 32


func _target_id_from_key(key: int) -> int:
	return key & 0xffffffff
