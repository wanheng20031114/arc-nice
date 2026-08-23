extends Node2D
class_name FireSorcererVolleyPresenter

const FireSorcererVolleySimulationServiceScript := preload(
	"res://scene/combat/simulation/fire_sorcerer_volley_simulation_service.gd"
)

const FIXED_INSTANCE_CAPACITY := 4096
const BALL_COUNT := 3
const VIEW_CULL_MARGIN := 20.0

@onready var normal_volley_multimesh: MultiMeshInstance2D = (
	$NormalVolleyMultiMesh
)
@onready var elite_volley_multimesh: MultiMeshInstance2D = (
	$EliteVolleyMultiMesh
)

var _service: FireSorcererVolleySimulationServiceScript = null
var _headless_disabled := false
var _teardown_prepared := false
var _teardown_count := 0
var _sync_executions := 0
var _render_sync_executions := 0
var _invalid_view_clear_count := 0
var _last_scanned_record_count := 0
var _last_scanned_ball_count := 0
var _last_visible_count := 0
var _last_culled_count := 0
var _last_normal_visible_count := 0
var _last_elite_visible_count := 0
var _last_capacity_drop_count := 0
var _last_normal_capacity_drop_count := 0
var _last_elite_capacity_drop_count := 0
var _critical_capacity_drop_count := 0


func _init() -> void:
	set_process(false)


func _ready() -> void:
	_headless_disabled = _is_headless_display()
	if _headless_disabled or _teardown_prepared:
		_disable_multimeshes_for_headless()
		set_process(false)
		return
	var normal_multimesh := _get_normal_multimesh()
	var elite_multimesh := _get_elite_multimesh()
	if (
		not _is_valid_authored_multimesh(normal_multimesh)
		or not _is_valid_authored_multimesh(elite_multimesh)
	):
		push_error("FireSorcererVolleyPresenter authored MultiMesh contracts are invalid.")
		_release_multimeshes()
		return
	normal_multimesh.instance_count = FIXED_INSTANCE_CAPACITY
	normal_multimesh.visible_instance_count = 0
	elite_multimesh.instance_count = FIXED_INSTANCE_CAPACITY
	elite_multimesh.visible_instance_count = 0
	visibility_changed.connect(_on_visibility_changed)
	set_process(_service != null)


func bind_service(
	service: FireSorcererVolleySimulationServiceScript
) -> bool:
	if _teardown_prepared or service == null or not is_instance_valid(service):
		return false
	if _service != null and _service != service:
		return false
	_service = service
	if is_inside_tree() and not _headless_disabled:
		set_process(true)
	return true


func is_bound_to(
	service: FireSorcererVolleySimulationServiceScript
) -> bool:
	return _service == service and service != null and is_instance_valid(service)


func _process(_delta: float) -> void:
	if _is_headless_display():
		_headless_disabled = true
		_disable_multimeshes_for_headless()
		set_process(false)
		return
	if (
		_teardown_prepared
		or _service == null
		or not is_instance_valid(_service)
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
	sync_from_service(_service, world_view_rect)


func sync_from_service(
	service: FireSorcererVolleySimulationServiceScript,
	world_view_rect: Rect2
) -> int:
	if _is_headless_display():
		_headless_disabled = true
		_disable_multimeshes_for_headless()
		return 0
	if (
		_teardown_prepared
		or service == null
		or not is_instance_valid(service)
		or not is_inside_tree()
		or not is_visible_in_tree()
	):
		clear()
		return 0
	var normal_multimesh := _get_normal_multimesh()
	var elite_multimesh := _get_elite_multimesh()
	if (
		normal_multimesh == null
		or normal_multimesh.instance_count != FIXED_INSTANCE_CAPACITY
		or elite_multimesh == null
		or elite_multimesh.instance_count != FIXED_INSTANCE_CAPACITY
		or not world_view_rect.has_area()
	):
		clear()
		return 0

	_reset_last_sync_metrics()
	_sync_executions += 1
	var expanded_view_rect := world_view_rect.grow(VIEW_CULL_MARGIN)
	for stable_index in range(service.get_dense_record_count()):
		var handle := service.get_handle_at_stable_index(stable_index)
		if handle <= FireSorcererVolleySimulationServiceScript.INVALID_HANDLE:
			continue
		_last_scanned_record_count += 1
		var mode := service.get_slot_mode(handle)
		if not _is_presentable_mode(mode):
			continue
		var profile := service.get_slot_profile(handle)
		if not _is_supported_profile(profile):
			continue
		var active_ball_mask := service.get_active_ball_mask(handle)
		var visible_effect_mask := service.get_visible_effect_mask(handle)
		for ball_index in range(BALL_COUNT):
			var ball_bit := 1 << ball_index
			var is_active := (active_ball_mask & ball_bit) != 0
			var is_effect := (visible_effect_mask & ball_bit) != 0
			if not is_active and not is_effect:
				continue
			_last_scanned_ball_count += 1
			var world_position := service.get_ball_position(handle, ball_index)
			if not is_world_position_visible(world_position, expanded_view_rect):
				_last_culled_count += 1
				continue
			var direction := service.get_ball_direction(handle, ball_index)
			if not direction.is_finite() or direction.length_squared() <= 0.0:
				_last_culled_count += 1
				continue
			var target_multimesh := normal_multimesh
			var write_index := _last_normal_visible_count
			if profile == FireSorcererVolleySimulationServiceScript.Profile.ELITE:
				target_multimesh = elite_multimesh
				write_index = _last_elite_visible_count
			if write_index >= FIXED_INSTANCE_CAPACITY:
				_track_capacity_drop(profile)
				continue
			var visual_age := service.get_ball_visual_age_seconds(
				handle,
				ball_index
			)
			var effect_progress := 0.0
			var effect_kind := (
				FireSorcererVolleySimulationServiceScript.EffectKind.NONE
			)
			if is_effect and not is_active:
				effect_progress = service.get_ball_effect_progress(
					handle,
					ball_index
				)
				effect_kind = service.get_ball_effect_kind(handle, ball_index)
			target_multimesh.set_instance_transform_2d(
				write_index,
				build_instance_transform(
					to_local(world_position),
					direction.rotated(-global_rotation).normalized()
				)
			)
			target_multimesh.set_instance_custom_data(
				write_index,
				Color(
					maxf(visual_age, 0.0),
					clampf(effect_progress, 0.0, 1.0),
					float(effect_kind),
					1.0
				)
			)
			if profile == FireSorcererVolleySimulationServiceScript.Profile.NORMAL:
				_last_normal_visible_count += 1
			else:
				_last_elite_visible_count += 1
			_last_visible_count += 1
	normal_multimesh.visible_instance_count = _last_normal_visible_count
	elite_multimesh.visible_instance_count = _last_elite_visible_count
	return _last_visible_count


func clear() -> void:
	var normal_multimesh := _get_normal_multimesh()
	if normal_multimesh != null:
		normal_multimesh.visible_instance_count = 0
	var elite_multimesh := _get_elite_multimesh()
	if elite_multimesh != null:
		elite_multimesh.visible_instance_count = 0
	_reset_last_sync_metrics()


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_teardown_count += 1
	clear()
	set_process(false)
	_service = null
	_release_multimeshes()


func get_metrics() -> Dictionary:
	var normal_multimesh := _get_normal_multimesh()
	var elite_multimesh := _get_elite_multimesh()
	return {
		"fixed_capacity_per_family": FIXED_INSTANCE_CAPACITY,
		"total_fixed_capacity": FIXED_INSTANCE_CAPACITY * 2,
		"allocated_normal_instances": (
			normal_multimesh.instance_count if normal_multimesh != null else 0
		),
		"allocated_elite_instances": (
			elite_multimesh.instance_count if elite_multimesh != null else 0
		),
		"visible_normal_instances": (
			normal_multimesh.visible_instance_count
			if normal_multimesh != null
			else 0
		),
		"visible_elite_instances": (
			elite_multimesh.visible_instance_count
			if elite_multimesh != null
			else 0
		),
		"headless_disabled": _headless_disabled,
		"bound": _service != null and is_instance_valid(_service),
		"teardown_prepared": _teardown_prepared,
		"teardown_count": _teardown_count,
		"sync_executions": _sync_executions,
		"render_sync_executions": _render_sync_executions,
		"invalid_view_clear_count": _invalid_view_clear_count,
		"last_scanned_record_count": _last_scanned_record_count,
		"last_scanned_ball_count": _last_scanned_ball_count,
		"last_visible_count": _last_visible_count,
		"last_culled_count": _last_culled_count,
		"last_normal_visible_count": _last_normal_visible_count,
		"last_elite_visible_count": _last_elite_visible_count,
		"last_capacity_drop_count": _last_capacity_drop_count,
		"last_normal_capacity_drop_count": (
			_last_normal_capacity_drop_count
		),
		"last_elite_capacity_drop_count": _last_elite_capacity_drop_count,
		"critical_capacity_drop_count": _critical_capacity_drop_count,
	}


func get_normal_multimesh_instance() -> MultiMeshInstance2D:
	return get_node_or_null("NormalVolleyMultiMesh") as MultiMeshInstance2D


func get_elite_multimesh_instance() -> MultiMeshInstance2D:
	return get_node_or_null("EliteVolleyMultiMesh") as MultiMeshInstance2D


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


func _get_normal_multimesh() -> MultiMesh:
	var multimesh_instance := get_normal_multimesh_instance()
	return multimesh_instance.multimesh if multimesh_instance != null else null


func _get_elite_multimesh() -> MultiMesh:
	var multimesh_instance := get_elite_multimesh_instance()
	return multimesh_instance.multimesh if multimesh_instance != null else null


func _track_capacity_drop(
	profile: FireSorcererVolleySimulationServiceScript.Profile
) -> void:
	_last_capacity_drop_count += 1
	_critical_capacity_drop_count += 1
	if profile == FireSorcererVolleySimulationServiceScript.Profile.NORMAL:
		_last_normal_capacity_drop_count += 1
	else:
		_last_elite_capacity_drop_count += 1


func _reset_last_sync_metrics() -> void:
	_last_scanned_record_count = 0
	_last_scanned_ball_count = 0
	_last_visible_count = 0
	_last_culled_count = 0
	_last_normal_visible_count = 0
	_last_elite_visible_count = 0
	_last_capacity_drop_count = 0
	_last_normal_capacity_drop_count = 0
	_last_elite_capacity_drop_count = 0


func _disable_multimeshes_for_headless() -> void:
	_release_multimeshes()


func _release_multimeshes() -> void:
	var normal_multimesh := _get_normal_multimesh()
	if normal_multimesh != null:
		normal_multimesh.visible_instance_count = 0
		normal_multimesh.instance_count = 0
	var elite_multimesh := _get_elite_multimesh()
	if elite_multimesh != null:
		elite_multimesh.visible_instance_count = 0
		elite_multimesh.instance_count = 0


static func _is_valid_authored_multimesh(multimesh: MultiMesh) -> bool:
	var quad_mesh := multimesh.mesh as QuadMesh if multimesh != null else null
	return (
		multimesh != null
		and multimesh.transform_format == MultiMesh.TRANSFORM_2D
		and multimesh.use_custom_data
		and quad_mesh != null
		and quad_mesh.size == Vector2(32.0, 32.0)
	)


static func _is_presentable_mode(
	mode: FireSorcererVolleySimulationServiceScript.Mode
) -> bool:
	return (
		mode == FireSorcererVolleySimulationServiceScript.Mode.DATA
		or mode == FireSorcererVolleySimulationServiceScript.Mode.REPLICA
	)


static func _is_supported_profile(
	profile: FireSorcererVolleySimulationServiceScript.Profile
) -> bool:
	return (
		profile == FireSorcererVolleySimulationServiceScript.Profile.NORMAL
		or profile == FireSorcererVolleySimulationServiceScript.Profile.ELITE
	)


func _on_visibility_changed() -> void:
	if not visible:
		clear()


static func _is_headless_display() -> bool:
	return DisplayServer.get_name() == "headless"


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
