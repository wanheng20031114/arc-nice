extends Node2D
class_name TiyiHighNoonLockLines

const GLOW_COLOR := Color("3b1c4eaa")
const CORE_COLOR := Color("e7b6ffff")
const GLOW_WIDTH := 4.0
const CORE_WIDTH := 1.25

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
	var segments := PackedVector2Array()
	for target_ref in _target_refs:
		var target := target_ref.get_ref() as Enemy
		if target == null or not is_instance_valid(target) or not target.is_inside_tree():
			continue
		segments.append(Vector2.ZERO)
		segments.append(to_local(target.global_position))
	if segments.is_empty():
		return
	# 两次批量绘制固定数量的断开线段，避免为每个目标创建 Line2D。
	draw_multiline(segments, GLOW_COLOR, GLOW_WIDTH, false)
	draw_multiline(segments, CORE_COLOR, CORE_WIDTH, false)
