extends Node2D
class_name LightningSorcererLightningVfx

## Purely visual, pooled chain-lightning trace. Damage is resolved immediately
## by the enemy before this effect is requested; this node owns no collision.

const WORLD_EFFECT_VISIBILITY := preload("res://scene/world_effect_visibility.gd")
const NIGHT_VFX_FLASH_POOL := preload("res://scene/lighting/night_vfx_flash_pool.gd")

const EFFECT_SCENE_PATH := "res://scene/enemy/lightning_sorcerer_lightning_vfx.tscn"
const MAX_PATH_POINTS := 6
const SEGMENT_TRACE_SECONDS := 0.025
const TOTAL_LIFETIME_SECONDS := 0.17
const MIN_FADE_START_SECONDS := 0.085
const JAGGED_STEP_PIXELS := 16.0
const MAX_JAGGED_SUBDIVISIONS := 12
const JITTER_AMPLITUDE_PIXELS := 4.25
const OUTER_WIDTH_PIXELS := 5.5
const CORE_WIDTH_PIXELS := 1.6
const OUTER_COLOR := Color(1.12, 0.72, 0.06, 0.20)
const CORE_COLOR := Color(1.35, 1.18, 0.62, 0.95)
const VISIBILITY_STROKE_MARGIN := 20.0

const FLASH_COLOR := Color(1.0, 0.76, 0.22, 1.0)
const FLASH_PEAK_ENERGY := 0.62
const FLASH_TEXTURE_SCALE := 0.30
const FLASH_ATTACK_SECONDS := 0.015
const FLASH_HOLD_SECONDS := 0.025
const FLASH_DECAY_SECONDS := 0.10
const FLASH_PRIORITY := 1

static var _effect_scene: PackedScene = null

var pool_active := true
var _running := false
var _elapsed_seconds := 0.0
var _fade_alpha := 1.0
var _world_path := PackedVector2Array()
var _segment_polylines: Array[PackedVector2Array] = []
var _full_segment_count := 0
var _partial_segment_index := -1
var _partial_segment_points := PackedVector2Array()
var _random := RandomNumberGenerator.new()


func _ready() -> void:
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)
	_reset_playback()


func on_pool_acquired(generation: int) -> void:
	pool_active = true
	_random.seed = (
		int(Time.get_ticks_usec())
		^ get_instance_id()
		^ (generation * 0x45d9f3b)
	)
	_reset_playback()


func on_pool_released(_generation: int) -> void:
	pool_active = false
	_reset_playback()


## Leases and starts one complete chain. The path is world-space and contains
## the staff origin followed by one to five hit positions. Returns false when
## the visual is invalid, outside the view budget, or the strict pool is full.
static func try_spawn(
	source: Node,
	world_path: PackedVector2Array,
	elapsed_seconds: float = 0.0
) -> bool:
	if source == null or not _is_valid_world_path(world_path):
		return false
	if not _is_path_near_viewport(source, world_path):
		return false

	var pool_host := _find_pool_host(source)
	if pool_host == null:
		return false
	var effect_scene := _get_effect_scene()
	if (
		effect_scene == null
		or not bool(pool_host.call("has_session_object_pool_scene", effect_scene))
	):
		return false
	var effect := pool_host.call(
		"acquire_session_object",
		effect_scene,
		true
	) as LightningSorcererLightningVfx
	if effect == null:
		return false
	if effect.play(world_path, elapsed_seconds):
		return true
	SessionObjectPool.release_to_owner(effect)
	return false


## Starts an already leased instance. Supplying elapsed time lets a late remote
## packet enter the short effect at the correct visual phase.
func play(
	world_path: PackedVector2Array,
	elapsed_seconds: float = 0.0
) -> bool:
	if not pool_active or not _is_valid_world_path(world_path):
		return false

	_reset_playback()
	_world_path.resize(mini(world_path.size(), MAX_PATH_POINTS))
	for point_index in range(_world_path.size()):
		_world_path[point_index] = world_path[point_index]

	global_position = _world_path[0]
	_build_segment_polylines()
	if _segment_polylines.is_empty():
		return false

	_running = true
	_elapsed_seconds = clampf(
		maxf(elapsed_seconds, 0.0),
		0.0,
		TOTAL_LIFETIME_SECONDS
	)
	if _elapsed_seconds >= TOTAL_LIFETIME_SECONDS:
		_running = false
		return false
	_update_visual_state()
	set_process(true)
	show()
	NIGHT_VFX_FLASH_POOL.request_from(
		self,
		_world_path[1],
		FLASH_COLOR,
		FLASH_PEAK_ENERGY,
		FLASH_TEXTURE_SCALE,
		FLASH_ATTACK_SECONDS,
		FLASH_HOLD_SECONDS,
		FLASH_DECAY_SECONDS,
		FLASH_PRIORITY,
		_elapsed_seconds
	)
	return true


func _process(delta: float) -> void:
	if not _running:
		set_process(false)
		return
	_elapsed_seconds += maxf(delta, 0.0)
	if _elapsed_seconds >= TOTAL_LIFETIME_SECONDS:
		_finish()
		return
	_update_visual_state()


func _draw() -> void:
	if not _running or _fade_alpha <= 0.0:
		return
	var revealed_segments := _build_revealed_multiline_segments()
	if revealed_segments.is_empty():
		return
	var flicker := 0.91 + 0.09 * absf(sin(_elapsed_seconds * 142.0))
	var outer_color := OUTER_COLOR
	outer_color.a *= _fade_alpha * flicker
	var core_color := CORE_COLOR
	core_color.a *= _fade_alpha

	# The complete chain is flattened into disconnected segment pairs, so even a
	# five-link cast remains exactly two batched CanvasItem draw calls.
	draw_multiline(revealed_segments, outer_color, OUTER_WIDTH_PIXELS, false)
	draw_multiline(revealed_segments, core_color, CORE_WIDTH_PIXELS, false)


func _build_revealed_multiline_segments() -> PackedVector2Array:
	var revealed_segments := PackedVector2Array()
	for segment_index in range(_full_segment_count):
		var polyline := _segment_polylines[segment_index]
		for point_index in range(1, polyline.size()):
			revealed_segments.append(polyline[point_index - 1])
			revealed_segments.append(polyline[point_index])
	if _partial_segment_index >= 0:
		for point_index in range(1, _partial_segment_points.size()):
			revealed_segments.append(_partial_segment_points[point_index - 1])
			revealed_segments.append(_partial_segment_points[point_index])
	return revealed_segments


func _build_segment_polylines() -> void:
	_segment_polylines.clear()
	for segment_index in range(_world_path.size() - 1):
		var start := _world_path[segment_index] - global_position
		var finish := _world_path[segment_index + 1] - global_position
		_segment_polylines.append(_build_jagged_segment(start, finish))


func _build_jagged_segment(start: Vector2, finish: Vector2) -> PackedVector2Array:
	var points := PackedVector2Array()
	var offset := finish - start
	var length := offset.length()
	if length <= 0.001:
		points.append(start)
		points.append(finish)
		return points

	var subdivisions := clampi(
		ceili(length / JAGGED_STEP_PIXELS),
		2,
		MAX_JAGGED_SUBDIVISIONS
	)
	var normal := offset.normalized().orthogonal()
	points.resize(subdivisions + 1)
	points[0] = start
	for step_index in range(1, subdivisions):
		var progress := float(step_index) / float(subdivisions)
		var endpoint_falloff := sin(progress * PI)
		var alternating_sign := -1.0 if step_index % 2 == 0 else 1.0
		var random_scale := _random.randf_range(0.42, 1.0)
		points[step_index] = (
			start.lerp(finish, progress)
			+ normal
			* alternating_sign
			* JITTER_AMPLITUDE_PIXELS
			* random_scale
			* endpoint_falloff
		)
	points[subdivisions] = finish
	return points


func _update_visual_state() -> void:
	var segment_count := _segment_polylines.size()
	var trace_phase := _elapsed_seconds / SEGMENT_TRACE_SECONDS
	_full_segment_count = clampi(floori(trace_phase), 0, segment_count)
	_partial_segment_index = -1
	_partial_segment_points = PackedVector2Array()
	if _full_segment_count < segment_count:
		var segment_progress := trace_phase - float(_full_segment_count)
		if segment_progress > 0.0:
			_partial_segment_index = _full_segment_count
			_partial_segment_points = _build_partial_polyline(
				_segment_polylines[_partial_segment_index],
				segment_progress
			)

	var trace_end := float(segment_count) * SEGMENT_TRACE_SECONDS
	var fade_start := maxf(MIN_FADE_START_SECONDS, trace_end)
	_fade_alpha = (
		1.0
		if _elapsed_seconds <= fade_start
		else 1.0 - smoothstep(
			fade_start,
			TOTAL_LIFETIME_SECONDS,
			_elapsed_seconds
		)
	)
	queue_redraw()


func _build_partial_polyline(
	points: PackedVector2Array,
	progress: float
) -> PackedVector2Array:
	if points.size() < 2 or progress <= 0.0:
		return PackedVector2Array()
	if progress >= 1.0:
		return points

	var total_length := 0.0
	for point_index in range(1, points.size()):
		total_length += points[point_index - 1].distance_to(points[point_index])
	if total_length <= 0.001:
		return points

	var target_length := total_length * progress
	var traversed_length := 0.0
	var partial := PackedVector2Array([points[0]])
	for point_index in range(1, points.size()):
		var edge_start := points[point_index - 1]
		var edge_finish := points[point_index]
		var edge_length := edge_start.distance_to(edge_finish)
		if traversed_length + edge_length <= target_length:
			partial.append(edge_finish)
			traversed_length += edge_length
			continue
		if edge_length > 0.001:
			partial.append(edge_start.lerp(
				edge_finish,
				(target_length - traversed_length) / edge_length
			))
		break
	return partial


func _finish() -> void:
	_running = false
	set_process(false)
	queue_redraw()
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()


func _reset_playback() -> void:
	_running = false
	_elapsed_seconds = 0.0
	_fade_alpha = 1.0
	_world_path = PackedVector2Array()
	_segment_polylines.clear()
	_full_segment_count = 0
	_partial_segment_index = -1
	_partial_segment_points = PackedVector2Array()
	set_process(false)
	queue_redraw()


func get_path_point_count() -> int:
	return _world_path.size()


func get_segment_count() -> int:
	return _segment_polylines.size()


func get_started_segment_count() -> int:
	return _full_segment_count + (1 if _partial_segment_index >= 0 else 0)


func get_segment_points(segment_index: int) -> PackedVector2Array:
	if segment_index < 0 or segment_index >= _segment_polylines.size():
		return PackedVector2Array()
	return _segment_polylines[segment_index]


static func _get_effect_scene() -> PackedScene:
	if _effect_scene == null:
		_effect_scene = load(EFFECT_SCENE_PATH) as PackedScene
	return _effect_scene


static func _find_pool_host(source: Node) -> Node:
	var tree := source.get_tree()
	if tree != null:
		var current_scene := tree.current_scene
		if _is_pool_host(current_scene):
			return current_scene
	var branch := source
	while branch != null:
		if _is_pool_host(branch):
			return branch
		branch = branch.get_parent()
	return null


static func _is_pool_host(candidate: Node) -> bool:
	return (
		candidate != null
		and candidate.has_method("has_session_object_pool_scene")
		and candidate.has_method("acquire_session_object")
	)


static func _is_valid_world_path(world_path: PackedVector2Array) -> bool:
	if world_path.size() < 2:
		return false
	for point_index in range(mini(world_path.size(), MAX_PATH_POINTS)):
		if not world_path[point_index].is_finite():
			return false
	return true


static func _is_path_near_viewport(
	source: Node,
	world_path: PackedVector2Array
) -> bool:
	var point_count := mini(world_path.size(), MAX_PATH_POINTS)
	for point_index in range(1, point_count):
		var start := world_path[point_index - 1]
		var finish := world_path[point_index]
		if WORLD_EFFECT_VISIBILITY.is_position_near_viewport(
			source,
			(start + finish) * 0.5,
			start.distance_to(finish) * 0.5 + VISIBILITY_STROKE_MARGIN
		):
			return true
	return false
