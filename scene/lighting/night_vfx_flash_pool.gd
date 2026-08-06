extends Node2D
class_name NightVfxFlashPool

## Fixed-capacity shared lights for short combat flashes. Every explosion keeps
## its additive hot-core sprite, while only the most important simultaneous
## flashes receive real world illumination.

const WORLD_EFFECT_VISIBILITY := preload("res://scene/combat/feedback/world_effect_visibility.gd")
const POOL_GROUP := &"night_vfx_flash_pool"

var _slots: Array[NightVfxFlash2D] = []
var _slot_priorities: PackedInt32Array = PackedInt32Array()
var _slot_serials: PackedInt64Array = PackedInt64Array()
var _request_serial := 0


func _ready() -> void:
	add_to_group(POOL_GROUP)
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
	# Replicated combat effects may still be visually alive after their shorter
	# light envelope has ended. Reject those late requests before visibility or
	# slot selection: configuring an expired request would otherwise stop the
	# selected active light and silently reduce the fixed pool capacity.
	if (
		not is_finite(attack_seconds)
		or not is_finite(hold_seconds)
		or not is_finite(decay_seconds)
		or not is_finite(elapsed_seconds)
	):
		return false
	var safe_elapsed_seconds := maxf(elapsed_seconds, 0.0)
	if safe_elapsed_seconds >= NightVfxFlash2D.get_configured_duration_seconds(
		attack_seconds,
		hold_seconds,
		decay_seconds
	):
		return false

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
	flash.play_flash(safe_elapsed_seconds)
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

	# Multiplayer effects are commonly attached to MpGame (the current scene),
	# while the pool belongs to its embedded StandardGame/TowerDefenseGame child. That
	# topology is not reachable by walking only upward from the effect. Pools
	# register once with SceneTree so this fallback remains bounded and avoids a
	# recursive scene scan on every explosion.
	var tree := source.get_tree()
	if tree == null:
		return null
	var current_scene := tree.current_scene
	for candidate_node in tree.get_nodes_in_group(POOL_GROUP):
		var candidate_pool := candidate_node as NightVfxFlashPool
		if candidate_pool == null or not candidate_pool.is_inside_tree():
			continue
		if current_scene == null:
			return candidate_pool
		if (
			candidate_pool == current_scene
			or current_scene.is_ancestor_of(candidate_pool)
		):
			return candidate_pool
	# A pool owned by another viewport, test world or outgoing scene must never
	# receive this world's flash. Only SceneTree-only fixtures without an active
	# current scene may use the first registered pool as a compatibility fallback.
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
