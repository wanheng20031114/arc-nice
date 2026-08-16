extends AmmoRangedPlayer
class_name PlayerTiyi

const SNIPER_BULLET_SCENE := preload(
	"res://scene/player/tiyi/tiyi_sniper_bullet.tscn"
)
const SNIPER_HIT_EFFECT_SCENE := preload(
	"res://scene/player/tiyi/tiyi_sniper_hit_effect.tscn"
)
const HIGH_NOON_DURATION := 4.0
const HIGH_NOON_MAX_TARGETS := 25
const HIGH_NOON_IDEAL_FULL_LOCK_TIME := 2.0
const HIGH_NOON_LOCK_INTERVAL := (
	HIGH_NOON_IDEAL_FULL_LOCK_TIME / HIGH_NOON_MAX_TARGETS
)
const HIGH_NOON_LAST_LOCK_TIME := HIGH_NOON_DURATION - HIGH_NOON_LOCK_INTERVAL
const HIGH_NOON_RANGE := 400.0
const HIGH_NOON_RANGE_SQUARED := HIGH_NOON_RANGE * HIGH_NOON_RANGE
const HIGH_NOON_DAMAGE_MULTIPLIER := 3.5
const HIGH_NOON_WORLD_MASK := 1

@onready var high_noon_lock_lines: TiyiHighNoonLockLines = $HighNoonLockLines
@onready var high_noon_cast_effect_sprite: AnimatedSprite2D = $HighNoonCastEffectSprite

var _high_noon_active: bool = false
var _high_noon_authoritative: bool = false
var _high_noon_activation_id: int = 0
var _high_noon_last_seen_activation_id: int = 0
var _high_noon_elapsed: float = 0.0
var _high_noon_next_lock_time: float = HIGH_NOON_LOCK_INTERVAL
var _high_noon_target_refs: Array[WeakRef] = []
var _high_noon_locked_instance_ids: Dictionary = {}
var _high_noon_remote_target_ids := PackedInt32Array()
var _high_noon_remote_resolve_time_left := 0.0
var _high_noon_remote_resolve_attempts := 0

const HIGH_NOON_REMOTE_RESOLVE_INTERVAL := 0.1
const HIGH_NOON_REMOTE_RESOLVE_MAX_ATTEMPTS := 12
var _high_noon_lock_lines_base_position: Vector2 = Vector2.ZERO
var _high_noon_cast_effect_sprite_base_position: Vector2 = Vector2.ZERO


func _init() -> void:
	character_id = &"tiyi"


func is_tiyi() -> bool:
	return true


func _get_primary_projectile_scene() -> PackedScene:
	return SNIPER_BULLET_SCENE


func _get_primary_projectile_type() -> StringName:
	return &"tiyi_sniper_bullet"


func _get_muzzle_distance() -> float:
	return bullet_spawn_distance


func _get_primary_attack_damage_type() -> EnemyConfig.DamageType:
	return EnemyConfig.DamageType.MAGIC


func plays_multiplayer_death_animation() -> bool:
	return true


func _update_character_resources(delta: float) -> void:
	super._update_character_resources(delta)
	_update_high_noon(delta)


func _reset_character_resources_on_revive() -> void:
	super._reset_character_resources_on_revive()
	_clear_high_noon_state()
	_clear_owned_sniper_bullets()


func _cleanup_character_combat_on_death() -> void:
	super._cleanup_character_combat_on_death()
	_cancel_high_noon(true)
	_clear_owned_sniper_bullets()


func _clear_character_scene_transients() -> void:
	super._clear_character_scene_transients()
	_cancel_high_noon(true)
	_clear_owned_sniper_bullets()


func _on_controls_lock_changed(locked: bool) -> void:
	super._on_controls_lock_changed(locked)
	if locked:
		_cancel_high_noon(true)


func _on_combat_actions_lock_changed(locked: bool) -> void:
	if locked:
		_cancel_high_noon(true)


func _exit_tree() -> void:
	_cancel_high_noon(true)
	_clear_owned_sniper_bullets()
	super._exit_tree()


func _cache_character_visual_base_positions() -> void:
	super._cache_character_visual_base_positions()
	_high_noon_lock_lines_base_position = high_noon_lock_lines.position
	_high_noon_cast_effect_sprite_base_position = high_noon_cast_effect_sprite.position


func _set_character_visual_offset(offset: Vector2) -> void:
	super._set_character_visual_offset(offset)
	high_noon_lock_lines.position = _high_noon_lock_lines_base_position + offset
	high_noon_cast_effect_sprite.position = (
		_high_noon_cast_effect_sprite_base_position + offset
	)


func _try_use_skill1() -> bool:
	if (
		not skill1_unlocked
		or is_dead
		or are_combat_actions_locked()
		or _high_noon_active
	):
		return false
	_sync_skill1_charge_duration_to_upgrade_level()
	if not has_void_battery_charge() and skill1_charge < skill1_charge_duration:
		return false

	if _requires_multiplayer_gameplay_gateway():
		return gameplay_gateway != null and gameplay_gateway.request_tiyi_high_noon()
	if not _is_explicit_singleplayer_authority():
		return false

	if not try_begin_skill1_activation(_uses_authoritative_skill_preserve_roll()):
		return false
	var activation_id := _high_noon_last_seen_activation_id + 1
	_begin_high_noon(activation_id, true)
	_acquire_next_high_noon_target()
	_activate_collectible_skill_effects()
	_play_reload_audio()
	return true


func try_start_authoritative_high_noon(activation_id: int) -> bool:
	if activation_id <= _high_noon_last_seen_activation_id or _high_noon_active:
		return false
	if not try_begin_skill1_activation(true):
		return false
	_begin_high_noon(activation_id, true)
	# The first lock belongs to t=0. MpGame publishes the start event after this
	# method succeeds, then asks us to resend the complete list in RPC order.
	_acquire_next_high_noon_target()
	_activate_collectible_skill_effects()
	_play_reload_audio()
	return true


func sync_authoritative_high_noon_targets() -> void:
	if _high_noon_active and _high_noon_authoritative:
		_notify_high_noon_targets_changed()


func play_remote_high_noon_started(activation_id: int) -> void:
	if _high_noon_active or activation_id <= _high_noon_last_seen_activation_id:
		return
	_begin_high_noon(activation_id, false)


func apply_remote_high_noon_targets(
	activation_id: int,
	target_ids: PackedInt32Array
) -> void:
	if not _high_noon_active or activation_id != _high_noon_activation_id:
		return
	_high_noon_remote_target_ids = target_ids.duplicate()
	_high_noon_remote_resolve_time_left = 0.0
	_high_noon_remote_resolve_attempts = 0
	_resolve_remote_high_noon_targets()


func _resolve_remote_high_noon_targets() -> void:
	var resolved_targets: Array[Enemy] = []
	var resolved_instance_ids: Dictionary = {}
	var unresolved_count := 0
	for enemy_net_id in _high_noon_remote_target_ids:
		var enemy: Enemy = null
		if _has_valid_combat_runtime():
			enemy = combat_runtime.get_enemy_for_net_id(int(enemy_net_id))
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			unresolved_count += 1
			continue
		resolved_targets.append(enemy)
		resolved_instance_ids[enemy.get_instance_id()] = true
	if (
		unresolved_count > 0
		and _high_noon_remote_resolve_attempts < HIGH_NOON_REMOTE_RESOLVE_MAX_ATTEMPTS
	):
		_high_noon_remote_resolve_time_left = HIGH_NOON_REMOTE_RESOLVE_INTERVAL
	elif unresolved_count == 0:
		_high_noon_remote_resolve_attempts = HIGH_NOON_REMOTE_RESOLVE_MAX_ATTEMPTS
	if resolved_instance_ids == _high_noon_locked_instance_ids:
		return
	_high_noon_target_refs.clear()
	_high_noon_locked_instance_ids.clear()
	for enemy in resolved_targets:
		_high_noon_target_refs.append(weakref(enemy))
		_high_noon_locked_instance_ids[enemy.get_instance_id()] = true
	_refresh_high_noon_lock_lines()


func play_remote_high_noon_finished(
	activation_id: int,
	_target_ids: PackedInt32Array,
	hit_positions: PackedVector2Array
) -> void:
	if activation_id < _high_noon_last_seen_activation_id:
		return
	if _high_noon_active and activation_id != _high_noon_activation_id:
		return
	_high_noon_last_seen_activation_id = activation_id
	_play_high_noon_finish_effects(hit_positions)
	_clear_high_noon_state()


func cancel_remote_high_noon(activation_id: int) -> void:
	if not _high_noon_active or activation_id != _high_noon_activation_id:
		return
	_clear_high_noon_state()


func get_high_noon_damage_against_enemy(enemy: Enemy) -> int:
	var outgoing_damage := get_outgoing_damage(
		floori(float(attack_damage) * HIGH_NOON_DAMAGE_MULTIPLIER),
		EnemyConfig.DamageType.MAGIC
	)
	return resolve_attack_damage_against_enemy(outgoing_damage, enemy)


func is_high_noon_active() -> bool:
	return _high_noon_active


func get_high_noon_activation_id() -> int:
	return _high_noon_activation_id


func get_high_noon_target_count() -> int:
	return _get_locked_high_noon_targets().size()


func _begin_high_noon(activation_id: int, authoritative: bool) -> void:
	_high_noon_active = true
	_high_noon_authoritative = authoritative
	_high_noon_activation_id = activation_id
	_high_noon_last_seen_activation_id = maxi(
		_high_noon_last_seen_activation_id,
		activation_id
	)
	_high_noon_elapsed = 0.0
	_high_noon_next_lock_time = HIGH_NOON_LOCK_INTERVAL
	_high_noon_target_refs.clear()
	_high_noon_locked_instance_ids.clear()
	_high_noon_remote_target_ids.clear()
	_high_noon_remote_resolve_time_left = 0.0
	_high_noon_remote_resolve_attempts = 0
	high_noon_cast_effect_sprite.frame = 0
	high_noon_cast_effect_sprite.frame_progress = 0.0
	high_noon_cast_effect_sprite.show()
	high_noon_cast_effect_sprite.play(&"default")
	_refresh_high_noon_lock_lines()


func _update_high_noon(delta: float) -> void:
	if not _high_noon_active:
		return
	if not _high_noon_authoritative:
		if _high_noon_remote_resolve_attempts >= HIGH_NOON_REMOTE_RESOLVE_MAX_ATTEMPTS:
			return
		_high_noon_remote_resolve_time_left -= maxf(delta, 0.0)
		if _high_noon_remote_resolve_time_left <= 0.0:
			_high_noon_remote_resolve_attempts += 1
			_resolve_remote_high_noon_targets()
		return
	if is_dead or are_combat_actions_locked() or not is_inside_tree():
		_cancel_high_noon(true)
		return

	if _prune_high_noon_targets():
		_notify_high_noon_targets_changed()
	_high_noon_elapsed += maxf(delta, 0.0)
	while (
		_high_noon_next_lock_time <= HIGH_NOON_LAST_LOCK_TIME
		and _high_noon_elapsed + 0.0001 >= _high_noon_next_lock_time
	):
		_acquire_next_high_noon_target()
		_high_noon_next_lock_time += HIGH_NOON_LOCK_INTERVAL
	if _high_noon_elapsed >= HIGH_NOON_DURATION:
		_finish_high_noon()


func _acquire_next_high_noon_target() -> bool:
	if _get_locked_high_noon_targets().size() >= HIGH_NOON_MAX_TARGETS:
		return false
	var candidates: Array[Enemy] = []
	if not _has_valid_combat_runtime():
		return false
	var candidate_source := combat_runtime.query_combat_targets(
			global_position,
			HIGH_NOON_RANGE,
			0
		)
	for enemy in candidate_source:
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		if _high_noon_locked_instance_ids.has(enemy.get_instance_id()):
			continue
		if global_position.distance_squared_to(enemy.global_position) > HIGH_NOON_RANGE_SQUARED:
			continue
		if not _has_clear_high_noon_line_of_sight(enemy):
			continue
		candidates.append(enemy)
	if candidates.is_empty():
		return false
	candidates.sort_custom(func(a: Enemy, b: Enemy) -> bool:
		var distance_a := global_position.distance_squared_to(a.global_position)
		var distance_b := global_position.distance_squared_to(b.global_position)
		if not is_equal_approx(distance_a, distance_b):
			return distance_a < distance_b
		return _get_high_noon_stable_enemy_id(a) < _get_high_noon_stable_enemy_id(b)
	)
	var target := candidates[0]
	_high_noon_target_refs.append(weakref(target))
	_high_noon_locked_instance_ids[target.get_instance_id()] = true
	_apply_research_lock_slow(target)
	_refresh_high_noon_lock_lines()
	_notify_high_noon_targets_changed()
	return true


func _has_clear_high_noon_line_of_sight(enemy: Enemy) -> bool:
	var space_state := get_world_2d().direct_space_state
	if space_state == null:
		return true
	var query := PhysicsRayQueryParameters2D.create(
		global_position,
		enemy.global_position,
		HIGH_NOON_WORLD_MASK
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.exclude = [get_rid()]
	return space_state.intersect_ray(query).is_empty()


func _get_high_noon_stable_enemy_id(enemy: Enemy) -> int:
	var enemy_net_id := int(enemy.get_meta("net_id", 0))
	if enemy_net_id > 0:
		return enemy_net_id
	return int(enemy.get_instance_id())


func _prune_high_noon_targets() -> bool:
	var previous_count := _high_noon_target_refs.size()
	var valid_refs: Array[WeakRef] = []
	_high_noon_locked_instance_ids.clear()
	for target_ref in _high_noon_target_refs:
		var target := target_ref.get_ref() as Enemy
		if (
			target == null
			or not is_instance_valid(target)
			or not target.is_inside_tree()
			or target.is_dead
		):
			if target != null and is_instance_valid(target):
				target.remove_move_speed_modifier(_get_research_lock_slow_source_id())
			continue
		valid_refs.append(target_ref)
		_high_noon_locked_instance_ids[target.get_instance_id()] = true
	_high_noon_target_refs = valid_refs
	var changed := previous_count != _high_noon_target_refs.size()
	if changed:
		_refresh_high_noon_lock_lines()
	return changed


func _get_locked_high_noon_targets() -> Array[Enemy]:
	var targets: Array[Enemy] = []
	for target_ref in _high_noon_target_refs:
		var target := target_ref.get_ref() as Enemy
		if (
			target != null
			and is_instance_valid(target)
			and target.is_inside_tree()
			and not target.is_dead
		):
			targets.append(target)
	return targets


func _refresh_high_noon_lock_lines() -> void:
	if high_noon_lock_lines != null and is_instance_valid(high_noon_lock_lines):
		high_noon_lock_lines.set_targets(_get_locked_high_noon_targets())


func _notify_high_noon_targets_changed() -> void:
	if not _high_noon_authoritative or not _has_high_noon_scene_bridge():
		return
	var target_ids := PackedInt32Array()
	for target in _get_locked_high_noon_targets():
		var enemy_net_id := int(target.get_meta("net_id", 0))
		if enemy_net_id > 0:
			target_ids.append(enemy_net_id)
	gameplay_gateway.notify_tiyi_high_noon_targets_changed(
		peer_id,
		_high_noon_activation_id,
		target_ids
	)


func _finish_high_noon() -> void:
	if not _high_noon_active or not _high_noon_authoritative:
		return
	_prune_high_noon_targets()
	var targets := _get_locked_high_noon_targets()
	var target_ids := PackedInt32Array()
	var hit_positions := PackedVector2Array()
	for target in targets:
		var enemy_net_id := int(target.get_meta("net_id", 0))
		if _has_high_noon_scene_bridge() and enemy_net_id <= 0:
			continue
		target_ids.append(enemy_net_id)
		hit_positions.append(target.global_position)
	var activation_id := _high_noon_activation_id
	_play_high_noon_finish_effects(hit_positions)
	if _has_high_noon_scene_bridge():
		gameplay_gateway.resolve_tiyi_high_noon(
			peer_id,
			activation_id,
			target_ids,
			hit_positions
		)
	elif _is_explicit_singleplayer_authority():
		for target in targets:
			if target == null or not is_instance_valid(target) or target.is_dead:
				continue
			var impact_direction := -global_position.direction_to(target.global_position)
			target.apply_damage(
				get_high_noon_damage_against_enemy(target),
				impact_direction,
				EnemyConfig.DamageType.MAGIC,
				false
			)
	_clear_high_noon_state()


func _play_high_noon_finish_effects(hit_positions: PackedVector2Array) -> void:
	var spawn_parent := _get_combat_spawn_parent()
	if spawn_parent != null:
		for hit_position in hit_positions:
			var effect := SNIPER_HIT_EFFECT_SCENE.instantiate() as TiyiSniperHitEffect
			if effect == null:
				continue
			effect.top_level = true
			effect.setup(global_position.direction_to(hit_position))
			spawn_parent.add_child(effect)
			effect.global_position = hit_position
	if primary_attack_audio != null and primary_attack_audio.stream != null:
		primary_attack_audio.play()


func _cancel_high_noon(notify_scene: bool) -> void:
	if not _high_noon_active:
		return
	var activation_id := _high_noon_activation_id
	var was_authoritative := _high_noon_authoritative
	_clear_high_noon_state()
	if notify_scene and was_authoritative and _has_high_noon_scene_bridge():
		gameplay_gateway.cancel_tiyi_high_noon(peer_id, activation_id)


func _clear_high_noon_state() -> void:
	_remove_research_lock_slow_from_all_targets()
	_high_noon_active = false
	_high_noon_authoritative = false
	_high_noon_activation_id = 0
	_high_noon_elapsed = 0.0
	_high_noon_next_lock_time = HIGH_NOON_LOCK_INTERVAL
	_high_noon_target_refs.clear()
	_high_noon_locked_instance_ids.clear()
	_high_noon_remote_target_ids.clear()
	_high_noon_remote_resolve_time_left = 0.0
	_high_noon_remote_resolve_attempts = 0
	high_noon_cast_effect_sprite.stop()
	high_noon_cast_effect_sprite.hide()
	if high_noon_lock_lines != null and is_instance_valid(high_noon_lock_lines):
		high_noon_lock_lines.clear_targets()


func _get_research_lock_slow_source_id() -> int:
	return maxi(int(get_instance_id()) + 700000, 1)


func _apply_research_lock_slow(target: Enemy) -> void:
	if (
		target == null
		or not is_instance_valid(target)
		or not _high_noon_authoritative
	):
		return
	var multiplier := get_research_tiyi_slow_multiplier()
	if multiplier < 1.0:
		target.add_move_speed_modifier(
			_get_research_lock_slow_source_id(),
			multiplier
		)


func _remove_research_lock_slow_from_all_targets() -> void:
	var source_id := _get_research_lock_slow_source_id()
	for target_ref in _high_noon_target_refs:
		var target := target_ref.get_ref() as Enemy
		if target != null and is_instance_valid(target):
			target.remove_move_speed_modifier(source_id)


func _has_high_noon_scene_bridge() -> bool:
	return (
		_has_valid_combat_runtime()
		and combat_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		and gameplay_gateway != null
	)


func _clear_owned_sniper_bullets() -> void:
	var scene_root := _get_combat_spawn_parent()
	if scene_root == null:
		return
	_clear_owned_sniper_bullets_recursive(scene_root)


func _clear_owned_sniper_bullets_recursive(node: Node) -> void:
	for child in node.get_children():
		var bullet := child as TiyiSniperBullet
		if bullet != null:
			var is_local_owner := (
				bullet.collectible_owner != null
				and is_instance_valid(bullet.collectible_owner)
				and bullet.collectible_owner == self
			)
			var is_network_owner := peer_id > 0 and bullet.owner_peer_id == peer_id
			if is_local_owner or is_network_owner:
				bullet.retire()
				continue
		_clear_owned_sniper_bullets_recursive(child)
