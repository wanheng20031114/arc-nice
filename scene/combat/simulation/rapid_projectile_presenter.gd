extends Node2D
class_name RapidProjectilePresenter

const RapidFireSimulationServiceScript := preload(
	"res://scene/combat/simulation/rapid_fire_simulation_service.gd"
)

const FIXED_INSTANCE_CAPACITY := 4096
const GUNNER_FIXED_INSTANCE_CAPACITY := 4096
const GUNNER_ELITE_FIXED_INSTANCE_CAPACITY := 4096
const HIT_INSTANCE_CAPACITY := 256
const AK_FRAME_COUNT := 3
const AK_ANIMATION_FPS := 16.0
const GUNNER_FRAME_COUNT := 3
const GUNNER_ANIMATION_FPS := 25.0
const VIEW_CULL_MARGIN := 8.0
const HIT_LIFETIME_SECONDS := 0.18

@onready var projectile_multimesh: MultiMeshInstance2D = $ProjectileMultiMesh
@onready var gunner_projectile_multimesh: MultiMeshInstance2D = (
	$GunnerProjectileMultiMesh
)
@onready var gunner_elite_projectile_multimesh: MultiMeshInstance2D = (
	$GunnerEliteProjectileMultiMesh
)
@onready var hit_multimesh: MultiMeshInstance2D = $HitMultiMesh

var _rapid_fire_service: RapidFireSimulationServiceScript = null
var _headless_disabled := false
var _teardown_prepared := false
var _teardown_count := 0
var _sync_executions := 0
var _render_sync_executions := 0
var _invalid_view_clear_count := 0
var _last_scanned_count := 0
var _last_visible_count := 0
var _last_culled_count := 0
var _last_capacity_truncated_count := 0
var _last_ak_visible_count := 0
var _last_gunner_visible_count := 0
var _last_gunner_elite_visible_count := 0
var _last_ak_capacity_truncated_count := 0
var _last_gunner_capacity_truncated_count := 0
var _last_gunner_elite_capacity_truncated_count := 0
var _hit_positions := PackedVector2Array()
var _hit_directions := PackedVector2Array()
var _hit_ages := PackedFloat32Array()
var _hit_active_states := PackedByteArray()
var _next_hit_slot := 0
var _active_hit_count := 0
var _last_hit_scanned_count := 0
var _last_visible_hit_count := 0
var _metric_queued_hits := 0
var _metric_rejected_hits := 0
var _metric_hit_capacity_drops := 0


func _init() -> void:
	_hit_positions.resize(HIT_INSTANCE_CAPACITY)
	_hit_directions.resize(HIT_INSTANCE_CAPACITY)
	_hit_ages.resize(HIT_INSTANCE_CAPACITY)
	_hit_active_states.resize(HIT_INSTANCE_CAPACITY)
	set_process(false)


func _ready() -> void:
	_headless_disabled = _is_headless_display()
	if _headless_disabled or _teardown_prepared:
		_disable_multimesh_for_headless()
		set_process(false)
		return
	var ak_multimesh := _get_projectile_multimesh()
	var gunner_multimesh := _get_gunner_projectile_multimesh()
	var gunner_elite_multimesh := _get_gunner_elite_projectile_multimesh()
	var authored_hit_multimesh := _get_hit_multimesh()
	if (
		not _is_valid_authored_multimesh(ak_multimesh)
		or not _is_valid_authored_multimesh(gunner_multimesh)
		or not _is_valid_authored_multimesh(gunner_elite_multimesh)
		or authored_hit_multimesh == null
		or authored_hit_multimesh.transform_format != MultiMesh.TRANSFORM_2D
		or not authored_hit_multimesh.use_custom_data
	):
		push_error("RapidProjectilePresenter authored MultiMesh contracts are invalid.")
		_clear_projectile_multimesh_prefixes()
		if authored_hit_multimesh != null:
			authored_hit_multimesh.visible_instance_count = 0
		return
	ak_multimesh.instance_count = FIXED_INSTANCE_CAPACITY
	ak_multimesh.visible_instance_count = 0
	gunner_multimesh.instance_count = GUNNER_FIXED_INSTANCE_CAPACITY
	gunner_multimesh.visible_instance_count = 0
	gunner_elite_multimesh.instance_count = GUNNER_ELITE_FIXED_INSTANCE_CAPACITY
	gunner_elite_multimesh.visible_instance_count = 0
	authored_hit_multimesh.instance_count = HIT_INSTANCE_CAPACITY
	authored_hit_multimesh.visible_instance_count = 0
	visibility_changed.connect(_on_visibility_changed)
	set_process(_rapid_fire_service != null)


func bind_service(service: RapidFireSimulationServiceScript) -> bool:
	if (
		_teardown_prepared
		or service == null
		or not is_instance_valid(service)
	):
		return false
	if _rapid_fire_service != null and _rapid_fire_service != service:
		return false
	_rapid_fire_service = service
	if is_inside_tree() and not _headless_disabled:
		set_process(true)
	return true


func is_bound_to(service: RapidFireSimulationServiceScript) -> bool:
	return (
		_rapid_fire_service == service
		and service != null
		and is_instance_valid(service)
	)


func _process(delta: float) -> void:
	if _is_headless_display():
		_headless_disabled = true
		_disable_multimesh_for_headless()
		set_process(false)
		return
	if (
		_teardown_prepared
		or _rapid_fire_service == null
		or not is_instance_valid(_rapid_fire_service)
		or not is_inside_tree()
		or not is_visible_in_tree()
	):
		clear()
		return
	var world_view_rect := calculate_viewport_world_aabb(get_viewport())
	if not world_view_rect.has_area():
		_invalid_view_clear_count += 1
		clear()
		return
	_render_sync_executions += 1
	sync_from_service(_rapid_fire_service, world_view_rect)
	_sync_hits(delta, world_view_rect)


func sync_from_service(
	service: RapidFireSimulationServiceScript,
	world_view_rect: Rect2
) -> int:
	if _is_headless_display():
		_headless_disabled = true
		_disable_multimesh_for_headless()
		return 0
	if _teardown_prepared or service == null or not is_instance_valid(service):
		clear()
		return 0
	if not is_inside_tree() or not is_visible_in_tree():
		clear()
		return 0
	var ak_multimesh := _get_projectile_multimesh()
	var gunner_multimesh := _get_gunner_projectile_multimesh()
	var gunner_elite_multimesh := _get_gunner_elite_projectile_multimesh()
	if (
		ak_multimesh == null
		or ak_multimesh.instance_count != FIXED_INSTANCE_CAPACITY
		or gunner_multimesh == null
		or gunner_multimesh.instance_count != GUNNER_FIXED_INSTANCE_CAPACITY
		or gunner_elite_multimesh == null
		or gunner_elite_multimesh.instance_count
		!= GUNNER_ELITE_FIXED_INSTANCE_CAPACITY
		or not world_view_rect.has_area()
	):
		clear()
		return 0

	_sync_executions += 1
	_last_scanned_count = 0
	_last_visible_count = 0
	_last_culled_count = 0
	_last_capacity_truncated_count = 0
	_last_ak_visible_count = 0
	_last_gunner_visible_count = 0
	_last_gunner_elite_visible_count = 0
	_last_ak_capacity_truncated_count = 0
	_last_gunner_capacity_truncated_count = 0
	_last_gunner_elite_capacity_truncated_count = 0
	var expanded_view_rect := world_view_rect.grow(VIEW_CULL_MARGIN)
	var stable_record_count := service.get_dense_record_count()
	var physics_frame := Engine.get_physics_frames()
	var physics_ticks_per_second := maxf(
		float(Engine.physics_ticks_per_second),
		1.0
	)
	for stable_index in range(stable_record_count):
		var handle := service.get_handle_at_stable_index(stable_index)
		if handle <= RapidFireSimulationServiceScript.INVALID_HANDLE:
			continue
		_last_scanned_count += 1
		var mode := service.get_slot_mode(handle)
		if (
			not _is_presentable_mode(mode)
			or service.get_slot_state(handle)
			!= RapidFireSimulationServiceScript.SlotState.ACTIVE
		):
			_last_culled_count += 1
			continue
		var profile := service.get_slot_profile(handle)
		if not _is_supported_profile(profile):
			_last_culled_count += 1
			continue
		var world_position := service.get_position(handle)
		if not is_world_position_visible(world_position, expanded_view_rect):
			_last_culled_count += 1
			continue
		var direction := service.get_direction(handle)
		if not direction.is_finite() or direction.length_squared() <= 0.0:
			_last_culled_count += 1
			continue
		var local_position := to_local(world_position)
		var local_direction := direction.rotated(-global_rotation).normalized()
		var target_multimesh: MultiMesh = null
		var write_index := 0
		match profile:
			RapidFireSimulationServiceScript.Profile.AK:
				if _last_ak_visible_count >= FIXED_INSTANCE_CAPACITY:
					_last_ak_capacity_truncated_count += 1
					_last_capacity_truncated_count += 1
					continue
				target_multimesh = ak_multimesh
				write_index = _last_ak_visible_count
				_last_ak_visible_count += 1
			RapidFireSimulationServiceScript.Profile.GUNNER:
				if (
					_last_gunner_visible_count
					>= GUNNER_FIXED_INSTANCE_CAPACITY
				):
					_last_gunner_capacity_truncated_count += 1
					_last_capacity_truncated_count += 1
					continue
				target_multimesh = gunner_multimesh
				write_index = _last_gunner_visible_count
				_last_gunner_visible_count += 1
			RapidFireSimulationServiceScript.Profile.GUNNER_ELITE:
				if (
					_last_gunner_elite_visible_count
					>= GUNNER_ELITE_FIXED_INSTANCE_CAPACITY
				):
					_last_gunner_elite_capacity_truncated_count += 1
					_last_capacity_truncated_count += 1
					continue
				target_multimesh = gunner_elite_multimesh
				write_index = _last_gunner_elite_visible_count
				_last_gunner_elite_visible_count += 1
			_:
				continue
		target_multimesh.set_instance_transform_2d(
			write_index,
			build_instance_transform(local_position, local_direction)
		)
		var age_seconds := (
			service.get_replica_active_age_seconds(handle)
			if mode == RapidFireSimulationServiceScript.Mode.REPLICA
			else float(maxi(
				physics_frame - service.get_spawn_physics_frame(handle),
				0
			)) / physics_ticks_per_second
		)
		target_multimesh.set_instance_custom_data(
			write_index,
			Color(
				age_seconds,
				0.0,
				0.0,
				1.0
			)
		)
		_last_visible_count += 1
	ak_multimesh.visible_instance_count = _last_ak_visible_count
	gunner_multimesh.visible_instance_count = _last_gunner_visible_count
	gunner_elite_multimesh.visible_instance_count = (
		_last_gunner_elite_visible_count
	)
	return _last_visible_count


func clear() -> void:
	_clear_projectile_multimesh_prefixes()
	var authored_hit_multimesh := _get_hit_multimesh()
	if authored_hit_multimesh != null:
		authored_hit_multimesh.visible_instance_count = 0
	_last_scanned_count = 0
	_last_visible_count = 0
	_last_culled_count = 0
	_last_capacity_truncated_count = 0
	_last_ak_visible_count = 0
	_last_gunner_visible_count = 0
	_last_gunner_elite_visible_count = 0
	_last_ak_capacity_truncated_count = 0
	_last_gunner_capacity_truncated_count = 0
	_last_gunner_elite_capacity_truncated_count = 0
	_last_hit_scanned_count = 0
	_last_visible_hit_count = 0
	_active_hit_count = 0
	_next_hit_slot = 0
	_hit_active_states.fill(0)


func queue_completion_hit(
	mode: RapidFireSimulationServiceScript.Mode,
	profile: RapidFireSimulationServiceScript.Profile,
	reason: RapidFireSimulationServiceScript.CompletionReason,
	world_position: Vector2,
	direction: Vector2
) -> bool:
	if (
		_is_headless_display()
		or _teardown_prepared
		or (
			mode != RapidFireSimulationServiceScript.Mode.DATA
			and mode != RapidFireSimulationServiceScript.Mode.REPLICA
		)
		or not _is_supported_profile(profile)
		or (
			reason != RapidFireSimulationServiceScript.CompletionReason.WORLD
			and reason != RapidFireSimulationServiceScript.CompletionReason.TARGET
		)
		or not world_position.is_finite()
		or not direction.is_finite()
		or direction.length_squared() <= 0.0
	):
		_metric_rejected_hits += 1
		return false
	var hit_slot := _find_free_hit_slot()
	if hit_slot < 0:
		_metric_hit_capacity_drops += 1
		return false
	_hit_positions[hit_slot] = world_position
	_hit_directions[hit_slot] = direction.normalized()
	_hit_ages[hit_slot] = 0.0
	_hit_active_states[hit_slot] = 1
	_active_hit_count += 1
	_next_hit_slot = (hit_slot + 1) % HIT_INSTANCE_CAPACITY
	_metric_queued_hits += 1
	return true


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_teardown_count += 1
	clear()
	set_process(false)
	_rapid_fire_service = null
	_release_projectile_multimeshes()
	var authored_hit_multimesh := _get_hit_multimesh()
	if authored_hit_multimesh != null:
		authored_hit_multimesh.instance_count = 0


func get_metrics() -> Dictionary:
	var ak_multimesh := _get_projectile_multimesh()
	var gunner_multimesh := _get_gunner_projectile_multimesh()
	var gunner_elite_multimesh := _get_gunner_elite_projectile_multimesh()
	var authored_hit_multimesh := _get_hit_multimesh()
	var allocated_ak_instances := (
		ak_multimesh.instance_count if ak_multimesh != null else 0
	)
	var allocated_gunner_instances := (
		gunner_multimesh.instance_count if gunner_multimesh != null else 0
	)
	var allocated_gunner_elite_instances := (
		gunner_elite_multimesh.instance_count
		if gunner_elite_multimesh != null
		else 0
	)
	return {
		"fixed_capacity": FIXED_INSTANCE_CAPACITY,
		"ak_fixed_capacity": FIXED_INSTANCE_CAPACITY,
		"gunner_fixed_capacity": GUNNER_FIXED_INSTANCE_CAPACITY,
		"gunner_elite_fixed_capacity": GUNNER_ELITE_FIXED_INSTANCE_CAPACITY,
		"total_fixed_capacity": (
			FIXED_INSTANCE_CAPACITY
			+ GUNNER_FIXED_INSTANCE_CAPACITY
			+ GUNNER_ELITE_FIXED_INSTANCE_CAPACITY
		),
		"hit_fixed_capacity": HIT_INSTANCE_CAPACITY,
		# These two legacy keys continue to describe the AK batch.
		"allocated_instances": allocated_ak_instances,
		"visible_instances": (
			ak_multimesh.visible_instance_count if ak_multimesh != null else 0
		),
		"allocated_ak_instances": allocated_ak_instances,
		"allocated_gunner_instances": allocated_gunner_instances,
		"allocated_gunner_elite_instances": allocated_gunner_elite_instances,
		"allocated_projectile_instances": (
			allocated_ak_instances
			+ allocated_gunner_instances
			+ allocated_gunner_elite_instances
		),
		"visible_ak_instances": (
			ak_multimesh.visible_instance_count if ak_multimesh != null else 0
		),
		"visible_gunner_instances": (
			gunner_multimesh.visible_instance_count
			if gunner_multimesh != null
			else 0
		),
		"visible_gunner_elite_instances": (
			gunner_elite_multimesh.visible_instance_count
			if gunner_elite_multimesh != null
			else 0
		),
		"visible_projectile_instances": _last_visible_count,
		"allocated_hit_instances": (
			authored_hit_multimesh.instance_count
			if authored_hit_multimesh != null
			else 0
		),
		"visible_hit_instances": (
			authored_hit_multimesh.visible_instance_count
			if authored_hit_multimesh != null
			else 0
		),
		"headless_disabled": _headless_disabled,
		"bound": (
			_rapid_fire_service != null
			and is_instance_valid(_rapid_fire_service)
		),
		"teardown_prepared": _teardown_prepared,
		"teardown_count": _teardown_count,
		"sync_executions": _sync_executions,
		"render_sync_executions": _render_sync_executions,
		"invalid_view_clear_count": _invalid_view_clear_count,
		"last_scanned_count": _last_scanned_count,
		"last_visible_count": _last_visible_count,
		"last_culled_count": _last_culled_count,
		"last_capacity_truncated_count": _last_capacity_truncated_count,
		"last_ak_visible_count": _last_ak_visible_count,
		"last_gunner_visible_count": _last_gunner_visible_count,
		"last_gunner_elite_visible_count": _last_gunner_elite_visible_count,
		"last_ak_capacity_truncated_count": (
			_last_ak_capacity_truncated_count
		),
		"last_gunner_capacity_truncated_count": (
			_last_gunner_capacity_truncated_count
		),
		"last_gunner_elite_capacity_truncated_count": (
			_last_gunner_elite_capacity_truncated_count
		),
		"active_hit_count": _active_hit_count,
		"last_hit_scanned_count": _last_hit_scanned_count,
		"last_visible_hit_count": _last_visible_hit_count,
		"queued_hits": _metric_queued_hits,
		"rejected_hits": _metric_rejected_hits,
		"hit_capacity_drops": _metric_hit_capacity_drops,
	}


func get_multimesh_instance() -> MultiMeshInstance2D:
	return get_node_or_null("ProjectileMultiMesh") as MultiMeshInstance2D


func get_gunner_multimesh_instance() -> MultiMeshInstance2D:
	return get_node_or_null("GunnerProjectileMultiMesh") as MultiMeshInstance2D


func get_gunner_elite_multimesh_instance() -> MultiMeshInstance2D:
	return (
		get_node_or_null("GunnerEliteProjectileMultiMesh")
		as MultiMeshInstance2D
	)


func get_hit_multimesh_instance() -> MultiMeshInstance2D:
	return get_node_or_null("HitMultiMesh") as MultiMeshInstance2D


static func build_instance_transform(
	position: Vector2,
	direction: Vector2
) -> Transform2D:
	if not direction.is_finite() or direction.length_squared() <= 0.0:
		return Transform2D(0.0, position)
	return Transform2D(direction.angle(), position)


static func is_world_position_visible(
	world_position: Vector2,
	expanded_world_view_rect: Rect2
) -> bool:
	return (
		world_position.is_finite()
		and expanded_world_view_rect.has_area()
		and expanded_world_view_rect.has_point(world_position)
	)


static func calculate_animation_frame(age_seconds: float) -> int:
	return calculate_animation_frame_for_profile(
		age_seconds,
		RapidFireSimulationServiceScript.Profile.AK
	)


static func calculate_animation_frame_for_profile(
	age_seconds: float,
	profile: RapidFireSimulationServiceScript.Profile
) -> int:
	if not is_finite(age_seconds) or age_seconds <= 0.0:
		return 0
	var animation_fps := AK_ANIMATION_FPS
	var frame_count := AK_FRAME_COUNT
	match profile:
		RapidFireSimulationServiceScript.Profile.GUNNER, RapidFireSimulationServiceScript.Profile.GUNNER_ELITE:
			animation_fps = GUNNER_ANIMATION_FPS
			frame_count = GUNNER_FRAME_COUNT
		RapidFireSimulationServiceScript.Profile.AK:
			pass
		_:
			return 0
	return posmod(
		int(floor(age_seconds * animation_fps)),
		frame_count
	)


static func count_presentable_projectiles_for_view(
	service: RapidFireSimulationServiceScript,
	world_view_rect: Rect2,
	presentation_capacity: int = FIXED_INSTANCE_CAPACITY
) -> int:
	return count_presentable_projectiles_for_profile_and_view(
		service,
		RapidFireSimulationServiceScript.Profile.AK,
		world_view_rect,
		presentation_capacity
	)


static func count_presentable_projectiles_for_profile_and_view(
	service: RapidFireSimulationServiceScript,
	profile: RapidFireSimulationServiceScript.Profile,
	world_view_rect: Rect2,
	presentation_capacity: int
) -> int:
	if (
		service == null
		or not is_instance_valid(service)
		or not _is_supported_profile(profile)
		or not world_view_rect.has_area()
		or presentation_capacity <= 0
	):
		return 0
	var expanded_view_rect := world_view_rect.grow(VIEW_CULL_MARGIN)
	var presentable_count := 0
	for stable_index in range(service.get_dense_record_count()):
		var handle := service.get_handle_at_stable_index(stable_index)
		if (
			handle <= RapidFireSimulationServiceScript.INVALID_HANDLE
			or service.get_slot_profile(handle)
			!= profile
			or not _is_presentable_mode(service.get_slot_mode(handle))
			or service.get_slot_state(handle)
			!= RapidFireSimulationServiceScript.SlotState.ACTIVE
			or not is_world_position_visible(
				service.get_position(handle),
				expanded_view_rect
			)
		):
			continue
		presentable_count += 1
		if presentable_count >= presentation_capacity:
			break
	return presentable_count


static func calculate_world_aabb(
	viewport_rect: Rect2,
	canvas_transform: Transform2D
) -> Rect2:
	if not viewport_rect.has_area():
		return Rect2()
	var determinant := canvas_transform.x.cross(canvas_transform.y)
	if not is_finite(determinant) or is_zero_approx(determinant):
		return Rect2()
	var inverse_canvas := canvas_transform.affine_inverse()
	var viewport_end := viewport_rect.end
	var corner_0 := inverse_canvas * viewport_rect.position
	var corner_1 := inverse_canvas * Vector2(
		viewport_end.x,
		viewport_rect.position.y
	)
	var corner_2 := inverse_canvas * viewport_end
	var corner_3 := inverse_canvas * Vector2(
		viewport_rect.position.x,
		viewport_end.y
	)
	if (
		not corner_0.is_finite()
		or not corner_1.is_finite()
		or not corner_2.is_finite()
		or not corner_3.is_finite()
	):
		return Rect2()
	var minimum := corner_0
	var maximum := corner_0
	minimum = minimum.min(corner_1)
	maximum = maximum.max(corner_1)
	minimum = minimum.min(corner_2)
	maximum = maximum.max(corner_2)
	minimum = minimum.min(corner_3)
	maximum = maximum.max(corner_3)
	return Rect2(minimum, maximum - minimum)


static func calculate_viewport_world_aabb(viewport: Viewport) -> Rect2:
	if viewport == null or not is_instance_valid(viewport):
		return Rect2()
	return calculate_world_aabb(
		viewport.get_visible_rect(),
		viewport.get_canvas_transform()
	)


func _sync_hits(delta: float, world_view_rect: Rect2) -> void:
	var authored_hit_multimesh := _get_hit_multimesh()
	if authored_hit_multimesh == null or not world_view_rect.has_area():
		if authored_hit_multimesh != null:
			authored_hit_multimesh.visible_instance_count = 0
		return
	_last_hit_scanned_count = 0
	_last_visible_hit_count = 0
	if _active_hit_count <= 0:
		authored_hit_multimesh.visible_instance_count = 0
		return
	var safe_delta := maxf(delta, 0.0) if is_finite(delta) else 0.0
	var expanded_view_rect := world_view_rect.grow(VIEW_CULL_MARGIN)
	for hit_slot in range(HIT_INSTANCE_CAPACITY):
		if _hit_active_states[hit_slot] == 0:
			continue
		_last_hit_scanned_count += 1
		var age := float(_hit_ages[hit_slot]) + safe_delta
		_hit_ages[hit_slot] = age
		if age >= HIT_LIFETIME_SECONDS:
			_hit_active_states[hit_slot] = 0
			_active_hit_count = maxi(_active_hit_count - 1, 0)
			continue
		var world_position := _hit_positions[hit_slot]
		if not is_world_position_visible(world_position, expanded_view_rect):
			continue
		var local_position := to_local(world_position)
		var local_direction := _hit_directions[hit_slot].rotated(
			-global_rotation
		)
		authored_hit_multimesh.set_instance_transform_2d(
			_last_visible_hit_count,
			build_instance_transform(local_position, local_direction)
		)
		authored_hit_multimesh.set_instance_custom_data(
			_last_visible_hit_count,
			Color(clampf(age / HIT_LIFETIME_SECONDS, 0.0, 1.0), 0.0, 0.0, 1.0)
		)
		_last_visible_hit_count += 1
	authored_hit_multimesh.visible_instance_count = _last_visible_hit_count


func _find_free_hit_slot() -> int:
	if _active_hit_count >= HIT_INSTANCE_CAPACITY:
		return -1
	for offset in range(HIT_INSTANCE_CAPACITY):
		var hit_slot := (_next_hit_slot + offset) % HIT_INSTANCE_CAPACITY
		if _hit_active_states[hit_slot] == 0:
			return hit_slot
	return -1


func _get_projectile_multimesh() -> MultiMesh:
	var multimesh_instance := get_multimesh_instance()
	return multimesh_instance.multimesh if multimesh_instance != null else null


func _get_gunner_projectile_multimesh() -> MultiMesh:
	var multimesh_instance := get_gunner_multimesh_instance()
	return multimesh_instance.multimesh if multimesh_instance != null else null


func _get_gunner_elite_projectile_multimesh() -> MultiMesh:
	var multimesh_instance := get_gunner_elite_multimesh_instance()
	return multimesh_instance.multimesh if multimesh_instance != null else null


func _get_hit_multimesh() -> MultiMesh:
	var multimesh_instance := get_hit_multimesh_instance()
	return multimesh_instance.multimesh if multimesh_instance != null else null


func _disable_multimesh_for_headless() -> void:
	_release_projectile_multimeshes()
	var authored_hit_multimesh := _get_hit_multimesh()
	if authored_hit_multimesh != null:
		authored_hit_multimesh.visible_instance_count = 0
		authored_hit_multimesh.instance_count = 0


func _clear_projectile_multimesh_prefixes() -> void:
	var ak_multimesh := _get_projectile_multimesh()
	if ak_multimesh != null:
		ak_multimesh.visible_instance_count = 0
	var gunner_multimesh := _get_gunner_projectile_multimesh()
	if gunner_multimesh != null:
		gunner_multimesh.visible_instance_count = 0
	var gunner_elite_multimesh := _get_gunner_elite_projectile_multimesh()
	if gunner_elite_multimesh != null:
		gunner_elite_multimesh.visible_instance_count = 0


func _release_projectile_multimeshes() -> void:
	_clear_projectile_multimesh_prefixes()
	var ak_multimesh := _get_projectile_multimesh()
	if ak_multimesh != null:
		ak_multimesh.instance_count = 0
	var gunner_multimesh := _get_gunner_projectile_multimesh()
	if gunner_multimesh != null:
		gunner_multimesh.instance_count = 0
	var gunner_elite_multimesh := _get_gunner_elite_projectile_multimesh()
	if gunner_elite_multimesh != null:
		gunner_elite_multimesh.instance_count = 0


static func _is_valid_authored_multimesh(multimesh: MultiMesh) -> bool:
	return (
		multimesh != null
		and multimesh.transform_format == MultiMesh.TRANSFORM_2D
		and multimesh.use_custom_data
	)


static func _is_supported_profile(
	profile: RapidFireSimulationServiceScript.Profile
) -> bool:
	return (
		profile == RapidFireSimulationServiceScript.Profile.AK
		or profile == RapidFireSimulationServiceScript.Profile.GUNNER
		or profile == RapidFireSimulationServiceScript.Profile.GUNNER_ELITE
	)


static func _is_presentable_mode(
	mode: RapidFireSimulationServiceScript.Mode
) -> bool:
	return (
		mode == RapidFireSimulationServiceScript.Mode.DATA
		or mode == RapidFireSimulationServiceScript.Mode.REPLICA
	)


func _on_visibility_changed() -> void:
	if not visible:
		clear()


static func _is_headless_display() -> bool:
	return DisplayServer.get_name() == "headless"


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
