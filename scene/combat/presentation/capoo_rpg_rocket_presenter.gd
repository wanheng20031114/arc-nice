extends Node2D
class_name CapooRPGRocketPresenter

const WORLD_EFFECT_VISIBILITY := preload(
	"res://scene/combat/feedback/world_effect_visibility.gd"
)
const SimulationServiceScript := preload(
	"res://scene/combat/simulation/capoo_rpg_rocket_simulation_service.gd"
)

const VISUAL_CAPACITY := 512
const FRAME_COUNT := 4
const ANIMATION_FPS := 14.0
const VISIBILITY_MARGIN := 48.0
const HALO_LOCAL_OFFSET := -7.0
const HALO_SCALE := Vector2(1.35, 0.62)

@onready var base_instances: MultiMeshInstance2D = $RocketBase
@onready var emission_instances: MultiMeshInstance2D = $RocketEmission
@onready var halo_instances: MultiMeshInstance2D = $RocketHalo

var _simulation_service: SimulationServiceScript = null
var _headless_disabled := false
var _teardown_prepared := false
var _teardown_count := 0
var _last_visible_count := 0
var _last_offscreen_omissions := 0
var _last_capacity_drops := 0
var _metric_flushes := 0
var _metric_dense_records_seen := 0
var _metric_visual_writes := 0
var _metric_headless_flush_skips := 0


func _init() -> void:
	_headless_disabled = DisplayServer.get_name() == "headless"
	set_process(false)
	set_physics_process(false)


func _ready() -> void:
	if _headless_disabled or _teardown_prepared:
		_disable_visual_storage()
		return
	for multimesh in _get_multimeshes():
		if not _is_valid_authored_multimesh(multimesh):
			push_error("CapooRPGRocketPresenter authored MultiMesh contract is invalid.")
			_disable_visual_storage()
			return
		multimesh.instance_count = VISUAL_CAPACITY
		multimesh.visible_instance_count = 0


func bind_simulation_service(
	simulation_service: SimulationServiceScript
) -> bool:
	if (
		_teardown_prepared
		or simulation_service == null
		or not is_instance_valid(simulation_service)
	):
		return false
	if _simulation_service != null and _simulation_service != simulation_service:
		return false
	_simulation_service = simulation_service
	return true


func is_bound() -> bool:
	return (
		_simulation_service != null
		and is_instance_valid(_simulation_service)
	)


func flush_presenter() -> int:
	if _headless_disabled:
		_metric_headless_flush_skips += 1
		return 0
	if _teardown_prepared or not is_bound() or not is_inside_tree():
		_clear_visible_prefixes()
		return 0
	var multimeshes := _get_multimeshes()
	for multimesh in multimeshes:
		if multimesh == null or multimesh.instance_count != VISUAL_CAPACITY:
			_clear_visible_prefixes()
			return 0
	_metric_flushes += 1
	_last_visible_count = 0
	_last_offscreen_omissions = 0
	_last_capacity_drops = 0
	var dense_count := _simulation_service.get_dense_record_count()
	_metric_dense_records_seen += dense_count
	for stable_index in range(dense_count):
		var handle := _simulation_service.get_handle_at_stable_index(stable_index)
		if handle <= 0:
			continue
		var world_position := (
			_simulation_service.get_position_at_stable_index(stable_index)
		)
		if not WORLD_EFFECT_VISIBILITY.is_position_near_viewport(
			self,
			world_position,
			VISIBILITY_MARGIN
		):
			_last_offscreen_omissions += 1
			continue
		if _last_visible_count >= VISUAL_CAPACITY:
			_last_capacity_drops += 1
			continue
		var direction := (
			_simulation_service.get_direction_at_stable_index(stable_index)
		)
		if not direction.is_finite() or direction.length_squared() <= 0.001:
			continue
		var visual_age := maxf(
			_simulation_service.get_visual_age_at_stable_index(stable_index),
			0.0
		)
		_write_instance(
			_last_visible_count,
			world_position,
			direction.normalized(),
			visual_age,
			multimeshes
		)
		_last_visible_count += 1
	for multimesh in multimeshes:
		multimesh.visible_instance_count = _last_visible_count
	_metric_visual_writes += _last_visible_count * multimeshes.size()
	return _last_visible_count


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_teardown_count += 1
	_simulation_service = null
	_disable_visual_storage()


func get_metrics() -> Dictionary:
	return {
		"bound": is_bound(),
		"headless_disabled": _headless_disabled,
		"teardown_prepared": _teardown_prepared,
		"teardown_count": _teardown_count,
		"visual_capacity": VISUAL_CAPACITY,
		"draw_family_count": 3,
		"visible_rockets": _last_visible_count,
		"last_offscreen_omissions": _last_offscreen_omissions,
		"last_capacity_drops": _last_capacity_drops,
		"flushes": _metric_flushes,
		"dense_records_seen": _metric_dense_records_seen,
		"visual_writes": _metric_visual_writes,
		"headless_flush_skips": _metric_headless_flush_skips,
		"allocated_base_instances": _instance_count(_get_base_multimesh()),
		"allocated_emission_instances": _instance_count(_get_emission_multimesh()),
		"allocated_halo_instances": _instance_count(_get_halo_multimesh()),
	}


func _write_instance(
	draw_slot: int,
	world_position: Vector2,
	direction: Vector2,
	visual_age: float,
	multimeshes: Array[MultiMesh]
) -> void:
	var local_position := to_local(world_position)
	var rotation := direction.angle()
	var transform := Transform2D(rotation, local_position)
	var halo_transform := Transform2D(
		rotation,
		local_position + direction * HALO_LOCAL_OFFSET
	).scaled_local(HALO_SCALE)
	var frame_index: int = floori(visual_age * ANIMATION_FPS) % FRAME_COUNT
	var phase := fmod(visual_age * ANIMATION_FPS / float(FRAME_COUNT), 1.0)
	var custom_data := Color(
		(float(frame_index) + 0.5) / float(FRAME_COUNT),
		phase,
		0.0,
		1.0
	)
	multimeshes[0].set_instance_transform_2d(draw_slot, transform)
	multimeshes[1].set_instance_transform_2d(draw_slot, transform)
	multimeshes[2].set_instance_transform_2d(draw_slot, halo_transform)
	for multimesh in multimeshes:
		multimesh.set_instance_custom_data(draw_slot, custom_data)


func _clear_visible_prefixes() -> void:
	for multimesh in _get_multimeshes():
		if multimesh != null:
			multimesh.visible_instance_count = 0
	_last_visible_count = 0
	_last_offscreen_omissions = 0
	_last_capacity_drops = 0


func _disable_visual_storage() -> void:
	for multimesh in _get_multimeshes():
		if multimesh != null:
			multimesh.visible_instance_count = 0
			multimesh.instance_count = 0
	_last_visible_count = 0


func _get_multimeshes() -> Array[MultiMesh]:
	return [
		_get_base_multimesh(),
		_get_emission_multimesh(),
		_get_halo_multimesh(),
	]


func _get_base_multimesh() -> MultiMesh:
	var node := get_node_or_null("RocketBase") as MultiMeshInstance2D
	return node.multimesh if node != null else null


func _get_emission_multimesh() -> MultiMesh:
	var node := get_node_or_null("RocketEmission") as MultiMeshInstance2D
	return node.multimesh if node != null else null


func _get_halo_multimesh() -> MultiMesh:
	var node := get_node_or_null("RocketHalo") as MultiMeshInstance2D
	return node.multimesh if node != null else null


static func _is_valid_authored_multimesh(multimesh: MultiMesh) -> bool:
	return (
		multimesh != null
		and multimesh.transform_format == MultiMesh.TRANSFORM_2D
		and multimesh.use_custom_data
		and multimesh.mesh != null
	)


static func _instance_count(multimesh: MultiMesh) -> int:
	return multimesh.instance_count if multimesh != null else 0


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
