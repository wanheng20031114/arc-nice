extends Node2D
class_name TiyiHighNoonLockLines

const GLOW_COLOR := Color("3b1c4e")
const CORE_COLOR := Color("e7b6ff")
const GLOW_WIDTH := 1.5
const CORE_WIDTH := 0.6
const SELF_FADE_RADIUS := 10.0
const GRADIENT_SEGMENT_COUNT := 16
const GLOW_NEAR_ALPHA := 0.008
const GLOW_TARGET_ALPHA := 0.14
const CORE_NEAR_ALPHA := 0.015
const CORE_TARGET_ALPHA := 0.42
const MIN_LINE_LENGTH := 0.001

var _target_refs: Array[WeakRef] = []


func _ready() -> void:
	set_process(false)


func set_targets(targets: Array[Enemy]) -> void:
	_target_refs.clear()
	for target in targets:
		if target != null and is_instance_valid(target):
			_target_refs.append(weakref(target))
	set_process(not _target_refs.is_empty())
	queue_redraw()


func clear_targets() -> void:
	_target_refs.clear()
	set_process(false)
	queue_redraw()


func get_visible_target_count() -> int:
	var count := 0
	for target_ref in _target_refs:
		var target := target_ref.get_ref() as Enemy
		if target != null and is_instance_valid(target) and target.is_inside_tree():
			count += 1
	return count


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if _target_refs.is_empty():
		return
	var local_targets := PackedVector2Array()
	for target_ref in _target_refs:
		var target := target_ref.get_ref() as Enemy
		if target == null or not is_instance_valid(target) or not target.is_inside_tree():
			continue
		local_targets.append(to_local(target.global_position))
	var batches := _build_line_batches(local_targets)
	var segments: PackedVector2Array = batches[&"segments"]
	if segments.is_empty():
		return
	var glow_colors: PackedColorArray = batches[&"glow_colors"]
	var core_colors: PackedColorArray = batches[&"core_colors"]
	# 每条锁线拆成有限段来近似透明度渐变；外层和核心仍各只提交一次批量绘制。
	draw_multiline_colors(segments, glow_colors, GLOW_WIDTH, false)
	draw_multiline_colors(segments, core_colors, CORE_WIDTH, false)


func _build_line_batches(local_targets: PackedVector2Array) -> Dictionary:
	var segments := PackedVector2Array()
	var glow_colors := PackedColorArray()
	var core_colors := PackedColorArray()
	for target_position in local_targets:
		var target_distance := target_position.length()
		if target_distance <= MIN_LINE_LENGTH:
			continue
		var line_direction := target_position / target_distance
		var self_fade_end := line_direction * minf(target_distance, SELF_FADE_RADIUS)
		segments.append(Vector2.ZERO)
		segments.append(self_fade_end)
		glow_colors.append(_color_with_alpha(GLOW_COLOR, GLOW_NEAR_ALPHA))
		core_colors.append(_color_with_alpha(CORE_COLOR, CORE_NEAR_ALPHA))
		if target_distance <= SELF_FADE_RADIUS:
			continue

		var gradient_vector := target_position - self_fade_end
		for segment_index in range(GRADIENT_SEGMENT_COUNT):
			var start_ratio := float(segment_index) / float(GRADIENT_SEGMENT_COUNT)
			var end_ratio := float(segment_index + 1) / float(GRADIENT_SEGMENT_COUNT)
			segments.append(self_fade_end + gradient_vector * start_ratio)
			segments.append(self_fade_end + gradient_vector * end_ratio)
			var alpha_ratio := smoothstep(0.0, 1.0, end_ratio)
			glow_colors.append(_color_with_alpha(
				GLOW_COLOR,
				lerpf(GLOW_NEAR_ALPHA, GLOW_TARGET_ALPHA, alpha_ratio)
			))
			core_colors.append(_color_with_alpha(
				CORE_COLOR,
				lerpf(CORE_NEAR_ALPHA, CORE_TARGET_ALPHA, alpha_ratio)
			))
	return {
		&"segments": segments,
		&"glow_colors": glow_colors,
		&"core_colors": core_colors,
	}


func _color_with_alpha(base_color: Color, alpha: float) -> Color:
	return Color(base_color.r, base_color.g, base_color.b, alpha)
