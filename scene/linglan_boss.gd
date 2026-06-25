extends Enemy
class_name LinglanBoss

signal health_changed(current_health: int, maximum_health: int)
signal boss_defeated

@export var starts_active: bool = false
@export var boss_display_name: String = "铃兰"

var is_active: bool = false


func _ready() -> void:
	super._ready()
	set_active(starts_active)
	_emit_health_changed()


func setup(enemy_config: EnemyConfig, player: Player, shared_pathfinder: Node = null) -> void:
	super.setup(enemy_config, player, shared_pathfinder)
	_emit_health_changed()


func activate_boss(player: Player, shared_pathfinder: Node = null) -> void:
	setup(config, player, shared_pathfinder)
	set_active(true)
	if animated_sprite != null and not is_dead:
		animated_sprite.play(&"idle")


func set_active(active: bool) -> void:
	is_active = active
	visible = active
	set_process(active)
	set_physics_process(active)
	if touch_damage_area != null:
		touch_damage_area.set_deferred("monitoring", active)
		touch_damage_area.set_deferred("monitorable", active)
	_set_collision_shapes_disabled(body_collision_shapes, not active)
	_set_collision_shapes_disabled(touch_damage_shapes, not active)


func apply_damage(
	amount: int,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
) -> bool:
	var accepted := super.apply_damage(amount, impact_direction, damage_type)
	if accepted:
		_emit_health_changed()
	return accepted


func _physics_process(delta: float) -> void:
	if not is_active or is_dead:
		velocity = Vector2.ZERO
		return
	_update_touch_damage(delta)
	velocity = Vector2.ZERO


func _die() -> void:
	if is_dead:
		return
	boss_defeated.emit()
	super._die()
	_emit_health_changed()


func get_max_health() -> int:
	return config.max_health if config != null else 0


func _emit_health_changed() -> void:
	health_changed.emit(maxi(current_health, 0), get_max_health())
