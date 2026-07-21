extends Node2D
class_name NightVfxFlashPool

## Fixed-capacity shared lights for short combat flashes. Every explosion keeps
## its additive hot-core sprite, while only the most important simultaneous
## flashes receive real world illumination.

const WORLD_EFFECT_VISIBILITY := preload("res://scene/world_effect_visibility.gd")

var _slots: Array[NightVfxFlash2D] = []
var _slot_priorities: PackedInt32Array = PackedInt32Array()
var _slot_serials: PackedInt64Array = PackedInt64Array()
var _request_serial := 0


func _ready() -> void:
	for child in get_children():
		var flash := child as NightVfxFlash2D
		if flash == null:
			continue
		flash.stop_flash()
		_slots.append(flash)
		_slot_priorities.append(-1)
		_slot_serials.append(0)


func request_flash(
	world_position: Vector2,
	flash_color: Color,
	peak_energy: float,
	peak_texture_scale: float,
	attack_seconds: float = 0.04,
	hold_seconds: float = 0.06,
	decay_seconds: float = 0.30,
	priority: int = 1,
	elapsed_seconds: float = 0.0
) -> bool:
	# The light may still reach the camera while its center is just off-screen.
	# soft_white_point_light.tres is 256 px wide, so half the scaled width is
	# the world-space radius; the extra 16 px covers glow/bilinear falloff.
	var visibility_margin := maxf(
		96.0,
		maxf(peak_texture_scale, 0.0) * 128.0 + 16.0
	)
	if not WORLD_EFFECT_VISIBILITY.is_position_near_viewport(
		self,
		world_position,
		visibility_margin
	):
		return false
	var slot_index := _select_slot(priority)
	if slot_index < 0:
		return false
	var flash := _slots[slot_index]
	_request_serial += 1
	_slot_priorities[slot_index] = priority
	_slot_serials[slot_index] = _request_serial
	flash.global_position = world_position
	flash.configure_flash(
		flash_color,
		peak_energy,
		peak_texture_scale,
		attack_seconds,
		hold_seconds,
		decay_seconds
	)
	flash.play_flash(elapsed_seconds)
	return flash.is_flash_active()


func get_capacity() -> int:
	return _slots.size()


func get_active_flash_count() -> int:
	var count := 0
	for flash in _slots:
		if flash.is_flash_active():
			count += 1
	return count


static func request_from(
	source: Node,
	world_position: Vector2,
	flash_color: Color,
	peak_energy: float,
	peak_texture_scale: float,
	attack_seconds: float = 0.04,
	hold_seconds: float = 0.06,
	decay_seconds: float = 0.30,
	priority: int = 1,
	elapsed_seconds: float = 0.0
) -> bool:
	var pool := find_for(source)
	if pool == null:
		return false
	return pool.request_flash(
		world_position,
		flash_color,
		peak_energy,
		peak_texture_scale,
		attack_seconds,
		hold_seconds,
		decay_seconds,
		priority,
		elapsed_seconds
	)


static func find_for(source: Node) -> NightVfxFlashPool:
	var branch := source
	while branch != null:
		if branch is NightVfxFlashPool:
			return branch as NightVfxFlashPool
		var candidate := branch.get_node_or_null(
			"NightVfxFlashPool"
		) as NightVfxFlashPool
		if candidate != null:
			return candidate
		branch = branch.get_parent()
	return null


func _select_slot(priority: int) -> int:
	for slot_index in range(_slots.size()):
		if not _slots[slot_index].is_flash_active():
			return slot_index

	var replacement_index := -1
	var replacement_priority := priority
	var replacement_serial := 0x7fffffffffffffff
	for slot_index in range(_slots.size()):
		var slot_priority := _slot_priorities[slot_index]
		var slot_serial := _slot_serials[slot_index]
		if slot_priority > replacement_priority:
			continue
		if (
			replacement_index < 0
			or slot_priority < replacement_priority
			or slot_serial < replacement_serial
		):
			replacement_index = slot_index
			replacement_priority = slot_priority
			replacement_serial = slot_serial
	return replacement_index
