extends Node2D
class_name RapidProjectilePresenter

const RapidFireSimulationServiceScript := preload(
	"res://scene/combat/simulation/rapid_fire_simulation_service.gd"
)

const FIXED_INSTANCE_CAPACITY := 4096
const AK_FRAME_COUNT := 3
const AK_ANIMATION_FPS := 16.0
const VIEW_CULL_MARGIN := 8.0

@onready var projectile_multimesh: MultiMeshInstance2D = $ProjectileMultiMesh

var _headless_disabled := false
var _teardown_prepared := false
var _teardown_count := 0
var _sync_executions := 0
var _last_scanned_count := 0
var _last_visible_count := 0
var _last_culled_count := 0
var _last_capacity_truncated_count := 0


func _ready() -> void:
	_headless_disabled = _is_headless_display()
	if _headless_disabled or _teardown_prepared:
		_disable_multimesh_for_headless()
		return
	var multimesh := _get_multimesh()
	if multimesh == null:
		push_error("RapidProjectilePresenter requires its authored MultiMesh.")
		return
	if (
		multimesh.transform_format != MultiMesh.TRANSFORM_2D
		or not multimesh.use_custom_data
	):
		push_error("RapidProjectilePresenter authored MultiMesh contract is invalid.")
		multimesh.visible_instance_count = 0
		return
	multimesh.instance_count = FIXED_INSTANCE_CAPACITY
	multimesh.visible_instance_count = 0


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
	var multimesh := _get_multimesh()
	if (
		multimesh == null
		or multimesh.instance_count != FIXED_INSTANCE_CAPACITY
		or not world_view_rect.has_area()
	):
		clear()
		return 0

	_sync_executions += 1
	_last_scanned_count = 0
	_last_visible_count = 0
	_last_culled_count = 0
	_last_capacity_truncated_count = 0
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
		if (
			service.get_slot_profile(handle)
			!= RapidFireSimulationServiceScript.Profile.AK
			or service.get_slot_mode(handle)
			!= RapidFireSimulationServiceScript.Mode.DATA
		):
			_last_culled_count += 1
			continue
		var world_position := service.get_position(handle)
		if not is_world_position_visible(world_position, expanded_view_rect):
			_last_culled_count += 1
			continue
		if _last_visible_count >= FIXED_INSTANCE_CAPACITY:
			_last_capacity_truncated_count += 1
			continue
		var direction := service.get_direction(handle)
		if not direction.is_finite() or direction.length_squared() <= 0.0:
			_last_culled_count += 1
			continue
		var local_position := to_local(world_position)
		var local_direction := direction.rotated(-global_rotation).normalized()
		multimesh.set_instance_transform_2d(
			_last_visible_count,
			build_instance_transform(local_position, local_direction)
		)
		var age_physics_frames := maxi(
			physics_frame - service.get_spawn_physics_frame(handle),
			0
		)
		multimesh.set_instance_custom_data(
			_last_visible_count,
			Color(
				float(age_physics_frames) / physics_ticks_per_second,
				0.0,
				0.0,
				1.0
			)
		)
		_last_visible_count += 1
	multimesh.visible_instance_count = _last_visible_count
	return _last_visible_count


func clear() -> void:
	var multimesh := _get_multimesh()
	if multimesh != null:
		multimesh.visible_instance_count = 0
	_last_scanned_count = 0
	_last_visible_count = 0
	_last_culled_count = 0
	_last_capacity_truncated_count = 0


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_teardown_count += 1
	clear()
	var multimesh := _get_multimesh()
	if multimesh != null:
		multimesh.instance_count = 0


func get_metrics() -> Dictionary:
	var multimesh := _get_multimesh()
	return {
		"fixed_capacity": FIXED_INSTANCE_CAPACITY,
		"allocated_instances": multimesh.instance_count if multimesh != null else 0,
		"visible_instances": (
			multimesh.visible_instance_count if multimesh != null else 0
		),
		"headless_disabled": _headless_disabled,
		"teardown_prepared": _teardown_prepared,
		"teardown_count": _teardown_count,
		"sync_executions": _sync_executions,
		"last_scanned_count": _last_scanned_count,
		"last_visible_count": _last_visible_count,
		"last_culled_count": _last_culled_count,
		"last_capacity_truncated_count": _last_capacity_truncated_count,
	}


func get_multimesh_instance() -> MultiMeshInstance2D:
	return get_node_or_null("ProjectileMultiMesh") as MultiMeshInstance2D


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
	if not is_finite(age_seconds) or age_seconds <= 0.0:
		return 0
	return posmod(
		int(floor(age_seconds * AK_ANIMATION_FPS)),
		AK_FRAME_COUNT
	)


static func count_presentable_projectiles_for_view(
	service: RapidFireSimulationServiceScript,
	world_view_rect: Rect2,
	presentation_capacity: int = FIXED_INSTANCE_CAPACITY
) -> int:
	if (
		service == null
		or not is_instance_valid(service)
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
			!= RapidFireSimulationServiceScript.Profile.AK
			or service.get_slot_mode(handle)
			!= RapidFireSimulationServiceScript.Mode.DATA
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


func _get_multimesh() -> MultiMesh:
	var multimesh_instance := get_multimesh_instance()
	return multimesh_instance.multimesh if multimesh_instance != null else null


func _disable_multimesh_for_headless() -> void:
	var multimesh := _get_multimesh()
	if multimesh == null:
		return
	multimesh.visible_instance_count = 0
	multimesh.instance_count = 0


static func _is_headless_display() -> bool:
	return DisplayServer.get_name() == "headless"


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
