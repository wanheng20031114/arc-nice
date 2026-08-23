extends CapooKnight
class_name StoneGolem

const SLAM_PLAYER_COLLISION_MASK := 1 << 1
const SLAM_ENEMY_COLLISION_MASK := 1 << 2
const SLAM_PLANT_COLLISION_MASK := 1 << 9
const SLAM_COLLISION_MASK := (
	SLAM_PLAYER_COLLISION_MASK
	| SLAM_ENEMY_COLLISION_MASK
	| SLAM_PLANT_COLLISION_MASK
)
const WARNING_BASE_RADIUS := 44.0
const COMPLETE_SHAPE_QUERY_2D := preload("res://scene/combat/physics/complete_shape_query_2d.gd")
const StoneGolemConfigScript := preload(
	"res://resources/config/enemies/stone_golem_config.gd"
)
const SLAM_WORLD_EFFECT_VISIBILITY := preload(
	"res://scene/combat/feedback/world_effect_visibility.gd"
)

@onready var slam_impact_ring: Line2D = $SlamImpactRing

static var slam_performance_metrics_enabled := false
static var _slam_performance_metrics := {
	"slam_query_calls": 0,
	"slam_query_usec": 0,
	"slam_total_usec": 0,
	"slam_query_results": 0,
	"slam_unique_targets": 0,
	"slam_damage_dispatches": 0,
	"slam_physics_queries": 0,
}

var slam_query := PhysicsShapeQueryParameters2D.new()
var slam_hit_target_ids: Dictionary = {}
var slam_query_page_metrics: Dictionary = {}
var slam_impact_time_left := 0.0
var slam_impact_visual_token := 0
var initial_attack_stagger_applied := false
var authored_slam_warning_polygon := PackedVector2Array()
var authored_slam_warning_color := Color(0.78, 0.67, 0.5, 0.08)


static func set_slam_performance_metrics_enabled(enabled: bool) -> void:
	slam_performance_metrics_enabled = enabled
	reset_slam_performance_metrics()


static func reset_slam_performance_metrics() -> void:
	_slam_performance_metrics["slam_query_calls"] = 0
	_slam_performance_metrics["slam_query_usec"] = 0
	_slam_performance_metrics["slam_total_usec"] = 0
	_slam_performance_metrics["slam_query_results"] = 0
	_slam_performance_metrics["slam_unique_targets"] = 0
	_slam_performance_metrics["slam_damage_dispatches"] = 0
	_slam_performance_metrics["slam_physics_queries"] = 0


static func get_slam_performance_metrics(reset_after_read := false) -> Dictionary:
	var snapshot := _slam_performance_metrics.duplicate()
	if reset_after_read:
		reset_slam_performance_metrics()
	return snapshot


func _ready() -> void:
	authored_slam_warning_polygon = windup_warning.polygon.duplicate()
	authored_slam_warning_color = windup_warning.color
	super._ready()


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if slam_impact_time_left > 0.0:
		_update_slam_impact_visual(delta)


func _uses_inherited_touch_damage() -> bool:
	return false


func _apply_config() -> void:
	super._apply_config()
	if not authored_slam_warning_polygon.is_empty():
		windup_warning.polygon = authored_slam_warning_polygon
	_hide_slam_impact_visual()

	var golem_config := config as StoneGolemConfigScript
	if golem_config == null:
		return

	slash_query_shape.radius = golem_config.slam_radius
	slam_query.shape = slash_query_shape
	slam_query.collision_mask = SLAM_COLLISION_MASK
	slam_query.collide_with_bodies = true
	slam_query.collide_with_areas = false
	slam_query.exclude = []
	if not initial_attack_stagger_applied:
		attack_cooldown_left = maxf(
			attack_cooldown_left,
			_get_initial_attack_stagger(golem_config.initial_attack_stagger)
		)
		initial_attack_stagger_applied = true


func _apply_slash_damage() -> void:
	if is_dead:
		return

	var golem_config := config as StoneGolemConfigScript
	if golem_config == null:
		return
	if slash_damage_source_snapshot == null:
		slash_damage_source_snapshot = create_damage_source_snapshot(
			_get_multiplayer_damage_source_id(action_sequence),
			_get_slash_damage_source_type()
		)

	_start_slam_impact_visual(golem_config)
	slam_query.transform = Transform2D(0.0, global_position)
	slam_hit_target_ids.clear()
	var metrics_enabled := StoneGolem.slam_performance_metrics_enabled
	var total_started_usec := (
		Time.get_ticks_usec()
		if metrics_enabled
		else 0
	)
	var query_metrics: Variant = (
		slam_query_page_metrics
		if metrics_enabled
		else null
	)
	var query_started_usec := Time.get_ticks_usec() if metrics_enabled else 0
	var results := COMPLETE_SHAPE_QUERY_2D.intersect_shape_all(
		get_world_2d().direct_space_state,
		slam_query,
		golem_config.slam_query_batch_size,
		query_metrics
	)
	var query_elapsed_usec := (
		maxi(Time.get_ticks_usec() - query_started_usec, 0)
		if metrics_enabled
		else 0
	)
	var outgoing_damage := get_effective_attack_damage(golem_config.attack_damage)
	var damage_dispatches := 0
	for result in results:
		var hit_target := result.get("collider") as Node2D
		if not _is_ranged_combat_target_valid(hit_target):
			continue
		if (
			not (hit_target is Player)
			and not (hit_target is PlantDefense)
			and not (hit_target is Enemy)
		):
			continue
		var target_id := hit_target.get_instance_id()
		if slam_hit_target_ids.has(target_id):
			continue
		var impact_direction := global_position.direction_to(
			hit_target.global_position
		)
		if impact_direction == Vector2.ZERO:
			impact_direction = slash_direction
		if not _dispatch_slash_damage(
			hit_target,
			outgoing_damage,
			impact_direction,
			golem_config.slam_damage_type
		):
			continue
		slam_hit_target_ids[target_id] = true
		damage_dispatches += 1

	if metrics_enabled:
		StoneGolem._slam_performance_metrics["slam_query_calls"] = (
			int(StoneGolem._slam_performance_metrics["slam_query_calls"]) + 1
		)
		StoneGolem._slam_performance_metrics["slam_query_usec"] = (
			int(StoneGolem._slam_performance_metrics["slam_query_usec"])
			+ query_elapsed_usec
		)
		StoneGolem._slam_performance_metrics["slam_total_usec"] = (
			int(StoneGolem._slam_performance_metrics["slam_total_usec"])
			+ maxi(Time.get_ticks_usec() - total_started_usec, 0)
		)
		StoneGolem._slam_performance_metrics["slam_query_results"] = (
			int(StoneGolem._slam_performance_metrics["slam_query_results"])
			+ results.size()
		)
		StoneGolem._slam_performance_metrics["slam_unique_targets"] = (
			int(StoneGolem._slam_performance_metrics["slam_unique_targets"])
			+ slam_hit_target_ids.size()
		)
		StoneGolem._slam_performance_metrics["slam_damage_dispatches"] = (
			int(StoneGolem._slam_performance_metrics["slam_damage_dispatches"])
			+ damage_dispatches
		)
		StoneGolem._slam_performance_metrics["slam_physics_queries"] = (
			int(StoneGolem._slam_performance_metrics["slam_physics_queries"])
			+ int(slam_query_page_metrics.get("physics_query_count", 0))
		)


# The impact pixels are already authored into the attack row. The reusable
# scene-owned Line2D is triggered at the actual damage frame instead of spawning
# one transient effect node per slam.
func _play_slash_effect(_direction: Vector2) -> void:
	return


func _get_slam_damage_source_type() -> StringName:
	return &"stone_golem_slam"


func _get_slash_damage_source_type() -> StringName:
	return _get_slam_damage_source_type()


func play_multiplayer_enemy_action(
	action_name: StringName,
	direction: Vector2,
	action_id: int
) -> void:
	if action_name == &"cancel":
		if action_id <= latest_proxy_action_id:
			return
		latest_proxy_action_id = action_id
		var safe_direction := (
			direction.normalized()
			if direction != Vector2.ZERO
			else Vector2.RIGHT
		)
		_update_facing(safe_direction)
		_set_windup_warning(0.0, safe_direction)
		_hide_slam_impact_visual()
		proxy_action_restore_token += 1
		proxy_action_animation_name_in_use = &""
		if config != null:
			_play_scene_animation(config.move_animation_name)
		return

	super.play_multiplayer_enemy_action(action_name, direction, action_id)
	if action_name != &"slash" or action_id != latest_proxy_action_id:
		return
	var golem_config := config as StoneGolemConfigScript
	if golem_config == null:
		return
	_queue_proxy_slam_impact(golem_config, action_id)


func _set_windup_warning(progress: float, _direction: Vector2) -> void:
	if windup_warning == null:
		return
	var golem_config := config as StoneGolemConfigScript
	if golem_config == null:
		windup_warning.visible = false
		return
	var clamped_progress := clampf(progress, 0.0, 1.0)
	if clamped_progress <= 0.0:
		windup_warning.visible = false
		return
	windup_warning.visible = true
	windup_warning.rotation = 0.0
	var radius_scale := golem_config.slam_radius / WARNING_BASE_RADIUS
	windup_warning.scale = (
		Vector2.ONE
		* radius_scale
		* lerpf(0.76, 1.0, clamped_progress)
	)
	windup_warning.color = Color(
		authored_slam_warning_color.r,
		authored_slam_warning_color.g,
		authored_slam_warning_color.b,
		lerpf(0.08, 0.3, clamped_progress)
	)


func _cancel_attack() -> void:
	var had_active_attack := combat_state != CombatState.CHASE
	var committed_slam := (
		combat_state == CombatState.SLASH
		and slash_damage_done
	)
	if committed_slam and current_health > 0:
		# A committed slam no longer depends on its original target. Let the
		# authored action finish so cooldown and host/proxy animation stay aligned.
		return
	super._cancel_attack()
	_hide_slam_impact_visual()
	if had_active_attack and current_health > 0:
		_broadcast_enemy_action(&"cancel", slash_direction)


func _die() -> void:
	_hide_slam_impact_visual()
	super._die()


func play_multiplayer_death_sequence() -> void:
	_hide_slam_impact_visual()
	super.play_multiplayer_death_sequence()


func _start_slam_impact_visual(golem_config: StoneGolemConfigScript) -> void:
	if (
		slam_impact_ring == null
		or not SLAM_WORLD_EFFECT_VISIBILITY.is_position_near_viewport(
			self,
			global_position
		)
	):
		_hide_slam_impact_visual()
		return
	slam_impact_time_left = maxf(golem_config.impact_visual_duration, 0.01)
	slam_impact_visual_token += 1
	var radius_scale := golem_config.slam_radius / WARNING_BASE_RADIUS
	slam_impact_ring.visible = true
	_set_slam_impact_progress(golem_config, 0.0)


func _queue_proxy_slam_impact(
	golem_config: StoneGolemConfigScript,
	action_id: int
) -> void:
	var delay := maxf(golem_config.slash_damage_delay, 0.0)
	if delay <= 0.0:
		_start_proxy_slam_impact_visual(golem_config)
		return
	var tween := create_tween()
	tween.tween_interval(delay)
	tween.tween_callback(
		func() -> void:
			if (
				action_id == latest_proxy_action_id
				and not is_dead
			):
				_start_proxy_slam_impact_visual(golem_config)
	)


func _start_proxy_slam_impact_visual(
	golem_config: StoneGolemConfigScript
) -> void:
	_start_slam_impact_visual(golem_config)
	if slam_impact_ring == null or not slam_impact_ring.visible:
		return
	var visual_token := slam_impact_visual_token
	var duration := maxf(golem_config.impact_visual_duration, 0.01)
	var tween := create_tween()
	tween.tween_method(
		func(progress: float) -> void:
			if visual_token == slam_impact_visual_token:
				_set_slam_impact_progress(golem_config, progress),
		0.0,
		1.0,
		duration
	)
	tween.tween_callback(
		func() -> void:
			if visual_token == slam_impact_visual_token:
				_hide_slam_impact_visual()
	)


func _update_slam_impact_visual(delta: float) -> void:
	if slam_impact_time_left <= 0.0 or slam_impact_ring == null:
		return
	var golem_config := config as StoneGolemConfigScript
	if golem_config == null:
		_hide_slam_impact_visual()
		return
	slam_impact_time_left = maxf(slam_impact_time_left - delta, 0.0)
	var duration := maxf(golem_config.impact_visual_duration, 0.01)
	var progress := 1.0 - slam_impact_time_left / duration
	_set_slam_impact_progress(golem_config, progress)
	if slam_impact_time_left <= 0.0:
		_hide_slam_impact_visual()


func _set_slam_impact_progress(
	golem_config: StoneGolemConfigScript,
	progress: float
) -> void:
	if slam_impact_ring == null:
		return
	var clamped_progress := clampf(progress, 0.0, 1.0)
	var radius_scale := golem_config.slam_radius / WARNING_BASE_RADIUS
	slam_impact_ring.scale = (
		Vector2.ONE
		* radius_scale
		* lerpf(0.5, 1.06, clamped_progress)
	)
	slam_impact_ring.modulate = Color(
		1.0,
		1.0,
		1.0,
		lerpf(0.82, 0.0, clamped_progress)
	)


func _hide_slam_impact_visual() -> void:
	slam_impact_time_left = 0.0
	slam_impact_visual_token += 1
	if slam_impact_ring == null:
		return
	slam_impact_ring.visible = false
	slam_impact_ring.scale = Vector2.ONE
	slam_impact_ring.modulate = Color.WHITE


func _get_initial_attack_stagger(maximum_stagger: float) -> float:
	if maximum_stagger <= 0.0:
		return 0.0
	var phase_index := int(get_instance_id()) % 23
	return maximum_stagger * float(phase_index) / 22.0
