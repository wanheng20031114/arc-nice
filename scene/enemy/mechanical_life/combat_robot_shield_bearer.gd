extends Enemy
class_name CombatRobotShieldBearer

const ShieldBearerConfig := preload(
	"res://resources/config/enemies/combat_robot_shield_bearer_config.gd"
)
const ACTION_SHIELD_BLOCK: StringName = &"combat_robot_shield_block"
const ACTION_SHIELD_BREAK: StringName = &"combat_robot_shield_break"
const SHIELD_STAGE_VISUAL_STATUS_SHIFT := 5
const SHIELD_STAGE_VISUAL_STATUS_MASK := 0x60
const BASE_VISUAL_STATUS_MASK := 0x1f

enum ShieldStage {
	INTACT,
	CRACKED,
	CRITICAL,
	BROKEN,
}

@export var path_refresh_interval: float = 0.25
@export var waypoint_arrival_distance: float = 4.0
@export_group("盾牌视觉阶段")
@export var intact_sprite_frames: SpriteFrames
@export var cracked_sprite_frames: SpriteFrames
@export var critical_sprite_frames: SpriteFrames
@export var broken_sprite_frames: SpriteFrames

@onready var shield_facing_root: Node2D = $ShieldFacingRoot
@onready var projectile_shield_area: ProjectileShieldArea = (
	$ShieldFacingRoot/ProjectileShieldArea
)
@onready var shield_fx_sprite: AnimatedSprite2D = (
	$ShieldFacingRoot/ShieldFxSprite
)

var shield_config_cache: ShieldBearerConfig = null
var shield_remaining_durability: int = 0
var shield_stage: ShieldStage = ShieldStage.BROKEN
var action_sequence: int = 0
var latest_proxy_action_id: int = 0
var proxy_snapshot_min_action_id: int = 0


func _ready() -> void:
	super._ready()
	_sync_shield_facing()
	_stop_shield_fx()


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(maxf(delta, 0.0))
	if not is_instance_valid(objective_target):
		velocity = Vector2.ZERO
		_move_until_player_contact()
		return
	if _has_player_contact():
		velocity = Vector2.ZERO
		return

	var move_direction := _get_safe_navigation_move_direction(
		objective_target,
		pathfinder,
		waypoint_arrival_distance
	)
	_update_facing(move_direction)
	velocity = move_direction * get_effective_move_speed()
	_move_until_player_contact()


func _apply_config() -> void:
	super._apply_config()
	shield_config_cache = config as ShieldBearerConfig
	var maximum_durability := (
		maxi(shield_config_cache.shield_max_blocks, 1)
		if shield_config_cache != null
		else 0
	)
	shield_remaining_durability = maximum_durability
	action_sequence = 0
	latest_proxy_action_id = 0
	proxy_snapshot_min_action_id = 0
	_apply_shield_stage_from_remaining(true)
	if projectile_shield_area != null:
		projectile_shield_area.setup(self, maximum_durability)
		projectile_shield_area.set_facing_direction(_get_facing_direction())
		projectile_shield_area.set_shield_active(
			maximum_durability > 0 and not is_dead
		)
	_stop_shield_fx()


func configure_multiplayer_proxy() -> void:
	super.configure_multiplayer_proxy()
	if projectile_shield_area != null:
		projectile_shield_area.set_visual_proxy_mode(true)
	_set_shield_interception_active(shield_remaining_durability > 0)


func _die() -> void:
	if is_dead:
		return
	latest_proxy_action_id += 1
	_set_shield_interception_active(false)
	_stop_shield_fx()
	super._die()


func play_multiplayer_death_sequence() -> void:
	if is_dead:
		return
	latest_proxy_action_id += 1
	_set_shield_interception_active(false)
	_stop_shield_fx()
	super.play_multiplayer_death_sequence()


func remove_for_home_escape() -> bool:
	if is_dead:
		return false
	latest_proxy_action_id += 1
	_set_shield_interception_active(false)
	_stop_shield_fx()
	return super.remove_for_home_escape()


func _exit_tree() -> void:
	_set_shield_interception_active(false)
	_stop_shield_fx()
	super._exit_tree()


func set_multiplayer_proxy_visual_active(active: bool) -> void:
	super.set_multiplayer_proxy_visual_active(active)
	if not active and is_multiplayer_proxy:
		_stop_shield_fx()


func get_shield_remaining_durability() -> int:
	return shield_remaining_durability


func get_shield_max_blocks() -> int:
	if shield_config_cache == null:
		return 0
	return maxi(shield_config_cache.shield_max_blocks, 1)


func get_shield_visual_stage() -> ShieldStage:
	return shield_stage


func is_projectile_shield_active() -> bool:
	return (
		projectile_shield_area != null
		and projectile_shield_area.is_active()
	)


func get_collectible_visual_status_mask() -> int:
	return (
		super.get_collectible_visual_status_mask()
		| (
			(int(shield_stage) << SHIELD_STAGE_VISUAL_STATUS_SHIFT)
			& SHIELD_STAGE_VISUAL_STATUS_MASK
		)
	)


func apply_multiplayer_visual_status_mask(status_mask: int) -> void:
	if not is_multiplayer_proxy or is_dead:
		return
	var remote_stage := clampi(
		(status_mask & SHIELD_STAGE_VISUAL_STATUS_MASK)
		>> SHIELD_STAGE_VISUAL_STATUS_SHIFT,
		int(ShieldStage.INTACT),
		int(ShieldStage.BROKEN)
	) as ShieldStage
	_apply_remote_shield_stage(remote_stage)
	super.apply_multiplayer_visual_status_mask(status_mask & BASE_VISUAL_STATUS_MASK)


## Optional exact-durability snapshots only advance the proxy's monotonic state
## floor. Ordinary block/break actions still own their transient FX timeline.
func apply_remote_shield_remaining_durability(remaining: int) -> void:
	if not is_multiplayer_proxy or is_dead:
		return
	shield_remaining_durability = mini(
		shield_remaining_durability,
		clampi(
			remaining,
			0,
			get_shield_max_blocks()
		)
	)
	proxy_snapshot_min_action_id = maxi(
		proxy_snapshot_min_action_id,
		get_shield_max_blocks() - shield_remaining_durability
	)
	_apply_shield_stage_from_remaining()
	if projectile_shield_area != null:
		projectile_shield_area.apply_proxy_durability_snapshot(
			shield_remaining_durability
		)
	_set_shield_interception_active(shield_remaining_durability > 0)


func _on_projectile_shield_area_durability_changed(
	remaining: int,
	maximum: int
) -> void:
	if is_dead or is_multiplayer_proxy:
		return
	var previous_remaining := shield_remaining_durability
	shield_remaining_durability = clampi(remaining, 0, maxi(maximum, 0))
	_apply_shield_stage_from_remaining()
	if shield_remaining_durability >= previous_remaining:
		return
	if shield_remaining_durability > 0:
		_play_shield_fx(_get_block_animation_name())
		action_sequence = maxi(
			action_sequence,
			get_shield_max_blocks() - shield_remaining_durability
		)
		_broadcast_enemy_action(ACTION_SHIELD_BLOCK)


func _on_projectile_shield_area_shield_broken() -> void:
	if is_dead or is_multiplayer_proxy:
		return
	shield_remaining_durability = 0
	_apply_shield_stage_from_remaining()
	_set_shield_interception_active(false)
	_play_shield_fx(_get_break_animation_name())
	action_sequence = get_shield_max_blocks()
	_broadcast_enemy_action(ACTION_SHIELD_BREAK)


func _on_shield_fx_sprite_animation_finished() -> void:
	_stop_shield_fx()


func play_multiplayer_enemy_action(
	action_name: StringName,
	direction: Vector2,
	action_id: int
) -> void:
	play_multiplayer_enemy_action_with_context(
		action_name,
		direction,
		global_position,
		action_id,
		0.0
	)


func play_multiplayer_enemy_action_with_context(
	action_name: StringName,
	direction: Vector2,
	_action_position: Vector2,
	action_id: int,
	action_elapsed: float
) -> void:
	if not is_multiplayer_proxy or is_dead:
		return
	var maximum_blocks := get_shield_max_blocks()
	if (
		(action_name == ACTION_SHIELD_BLOCK and action_id >= maximum_blocks)
		or (action_name == ACTION_SHIELD_BREAK and action_id != maximum_blocks)
		or (
			action_name != ACTION_SHIELD_BLOCK
			and action_name != ACTION_SHIELD_BREAK
		)
	):
		return
	if action_id <= latest_proxy_action_id:
		return
	latest_proxy_action_id = action_id
	var action_is_fresh := (
		action_id >= proxy_snapshot_min_action_id
		and _is_proxy_shield_action_fresh(action_name, action_elapsed)
	)
	var fx_allowed := action_is_fresh and multiplayer_proxy_visual_active
	if action_is_fresh and direction != Vector2.ZERO:
		_update_facing(direction)

	match action_name:
		ACTION_SHIELD_BLOCK:
			if shield_remaining_durability <= 0:
				return
			shield_remaining_durability = mini(
				shield_remaining_durability,
				clampi(
					get_shield_max_blocks() - action_id,
					1,
					get_shield_max_blocks()
				)
			)
			_apply_shield_stage_from_remaining()
			_sync_proxy_area_durability()
			if fx_allowed:
				_play_proxy_shield_fx(
					_get_block_animation_name(),
					action_elapsed
				)
		ACTION_SHIELD_BREAK:
			shield_remaining_durability = 0
			_apply_shield_stage_from_remaining()
			_sync_proxy_area_durability()
			_set_shield_interception_active(false)
			if fx_allowed:
				_play_proxy_shield_fx(
					_get_break_animation_name(),
					action_elapsed
				)


func _apply_remote_shield_stage(remote_stage: ShieldStage) -> void:
	if shield_config_cache == null or remote_stage <= shield_stage:
		return
	match remote_stage:
		ShieldStage.CRACKED:
			shield_remaining_durability = mini(
				shield_remaining_durability,
				shield_config_cache.shield_cracked_remaining
			)
		ShieldStage.CRITICAL:
			shield_remaining_durability = mini(
				shield_remaining_durability,
				shield_config_cache.shield_critical_remaining
			)
		ShieldStage.BROKEN:
			shield_remaining_durability = 0
		_:
			return
	proxy_snapshot_min_action_id = maxi(
		proxy_snapshot_min_action_id,
		get_shield_max_blocks() - shield_remaining_durability
	)
	_apply_shield_stage_from_remaining()
	_sync_proxy_area_durability()
	_set_shield_interception_active(shield_remaining_durability > 0)


func _apply_shield_stage_from_remaining(force: bool = false) -> void:
	var next_stage := _resolve_shield_stage(shield_remaining_durability)
	if not force and next_stage == shield_stage:
		return
	shield_stage = next_stage
	var next_frames := _get_sprite_frames_for_stage(next_stage)
	if animated_sprite == null or next_frames == null:
		return
	var previous_animation := animated_sprite.animation
	var previous_frame := animated_sprite.frame
	var previous_progress := animated_sprite.frame_progress
	var was_playing := animated_sprite.is_playing()
	animated_sprite.sprite_frames = next_frames
	var animation_to_restore := previous_animation
	if not next_frames.has_animation(animation_to_restore):
		animation_to_restore = (
			config.death_animation_name
			if is_dead and config != null
			else (config.move_animation_name if config != null else &"move")
		)
	if not next_frames.has_animation(animation_to_restore):
		return
	animated_sprite.animation = animation_to_restore
	var frame_count := next_frames.get_frame_count(animation_to_restore)
	if frame_count > 0:
		animated_sprite.set_frame_and_progress(
			clampi(previous_frame, 0, frame_count - 1),
			clampf(previous_progress, 0.0, 1.0)
		)
	if was_playing:
		animated_sprite.play(animation_to_restore)
	else:
		animated_sprite.pause()


func _resolve_shield_stage(remaining: int) -> ShieldStage:
	if remaining <= 0 or shield_config_cache == null:
		return ShieldStage.BROKEN
	if remaining <= shield_config_cache.shield_critical_remaining:
		return ShieldStage.CRITICAL
	if remaining <= shield_config_cache.shield_cracked_remaining:
		return ShieldStage.CRACKED
	return ShieldStage.INTACT


func _get_sprite_frames_for_stage(stage: ShieldStage) -> SpriteFrames:
	match stage:
		ShieldStage.INTACT:
			return intact_sprite_frames
		ShieldStage.CRACKED:
			return cracked_sprite_frames
		ShieldStage.CRITICAL:
			return critical_sprite_frames
		_:
			return broken_sprite_frames


func _play_proxy_shield_fx(
	animation_name: StringName,
	action_elapsed: float
) -> void:
	_stop_shield_fx()
	if not multiplayer_proxy_visual_active:
		return
	var safe_elapsed := maxf(action_elapsed, 0.0)
	var duration := _get_shield_fx_duration(animation_name)
	if duration <= 0.0 or safe_elapsed >= duration:
		return
	_play_shield_fx(animation_name)
	_seek_shield_fx(animation_name, safe_elapsed)


func _is_proxy_shield_action_fresh(
	action_name: StringName,
	action_elapsed: float
) -> bool:
	var animation_name := (
		_get_break_animation_name()
		if action_name == ACTION_SHIELD_BREAK
		else _get_block_animation_name()
	)
	var duration := _get_shield_fx_duration(animation_name)
	return duration > 0.0 and maxf(action_elapsed, 0.0) < duration


func _play_shield_fx(animation_name: StringName) -> void:
	if (
		shield_fx_sprite == null
		or shield_fx_sprite.sprite_frames == null
		or not shield_fx_sprite.sprite_frames.has_animation(animation_name)
	):
		return
	# Consecutive bullets can arrive faster than the three-frame block effect.
	# Restart the authored strip explicitly instead of letting AnimatedSprite2D
	# resume the same animation halfway through.
	shield_fx_sprite.stop()
	shield_fx_sprite.animation = animation_name
	shield_fx_sprite.set_frame_and_progress(0, 0.0)
	shield_fx_sprite.visible = true
	shield_fx_sprite.play(animation_name)


func _stop_shield_fx() -> void:
	if shield_fx_sprite == null:
		return
	shield_fx_sprite.stop()
	shield_fx_sprite.visible = false


func _seek_shield_fx(animation_name: StringName, elapsed: float) -> void:
	if shield_fx_sprite == null or shield_fx_sprite.sprite_frames == null:
		return
	var frames := shield_fx_sprite.sprite_frames
	var frame_count := frames.get_frame_count(animation_name)
	var speed := frames.get_animation_speed(animation_name)
	if frame_count <= 0 or speed <= 0.0:
		return
	var remaining_phase := maxf(elapsed, 0.0) * speed
	for frame_index in range(frame_count):
		var frame_duration := maxf(
			frames.get_frame_duration(animation_name, frame_index),
			0.000001
		)
		if remaining_phase < frame_duration:
			shield_fx_sprite.set_frame_and_progress(
				frame_index,
				clampf(remaining_phase / frame_duration, 0.0, 1.0)
			)
			return
		remaining_phase -= frame_duration
	shield_fx_sprite.set_frame_and_progress(frame_count - 1, 1.0)


func _get_shield_fx_duration(animation_name: StringName) -> float:
	if shield_fx_sprite == null or shield_fx_sprite.sprite_frames == null:
		return 0.0
	var frames := shield_fx_sprite.sprite_frames
	if not frames.has_animation(animation_name):
		return 0.0
	var speed := frames.get_animation_speed(animation_name)
	if speed <= 0.0:
		return 0.0
	var duration := 0.0
	for frame_index in range(frames.get_frame_count(animation_name)):
		duration += frames.get_frame_duration(animation_name, frame_index)
	return duration / speed


func _set_shield_interception_active(active: bool) -> void:
	if projectile_shield_area != null:
		projectile_shield_area.set_shield_active(
			active
			and shield_remaining_durability > 0
			and not is_dead
		)


func _sync_proxy_area_durability() -> void:
	if not is_multiplayer_proxy or projectile_shield_area == null:
		return
	projectile_shield_area.apply_proxy_durability_snapshot(
		shield_remaining_durability
	)


func _update_facing(move_direction: Vector2) -> void:
	if is_zero_approx(move_direction.x):
		return
	_set_facing_from_direction(move_direction)


func _set_facing_left(new_facing_left: bool) -> void:
	if facing_left == new_facing_left:
		return
	super._set_facing_left(new_facing_left)
	_sync_shield_facing()


func _sync_shield_facing() -> void:
	var facing_direction := _get_facing_direction()
	if shield_facing_root != null:
		shield_facing_root.position = Vector2(11.0 * facing_direction.x, 1.0)
		shield_facing_root.scale = Vector2(facing_direction.x, 1.0)
	if projectile_shield_area != null:
		projectile_shield_area.set_facing_direction(facing_direction)


func _get_facing_direction() -> Vector2:
	return Vector2.LEFT if facing_left else Vector2.RIGHT


func _get_block_animation_name() -> StringName:
	return (
		shield_config_cache.shield_block_animation_name
		if shield_config_cache != null
		else &"shield_block"
	)


func _get_break_animation_name() -> StringName:
	return (
		shield_config_cache.shield_break_animation_name
		if shield_config_cache != null
		else &"shield_break"
	)


func _broadcast_enemy_action(action_name: StringName) -> void:
	if gameplay_gateway == null or not is_instance_valid(gameplay_gateway):
		return
	gameplay_gateway.broadcast_enemy_action(
		int(get_meta("net_id", 0)),
		action_name,
		_get_facing_direction(),
		global_position,
		action_sequence
	)
