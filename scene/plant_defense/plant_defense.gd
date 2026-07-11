extends StaticBody2D
class_name PlantDefense

signal health_changed(current_health: int, maximum_health: int)
signal died

var config: PlantDefenseConfig = null
var owner_player: Player = null
var footprint_cells: Array[Vector2i] = []
var current_health: int = 0
var max_health: int = 0
var is_dead: bool = false


func _ready() -> void:
	add_to_group(&"plant_defense")


func setup(
	new_config: PlantDefenseConfig,
	new_owner_player: Player,
	new_footprint_cells: Array[Vector2i]
) -> void:
	if new_config == null or not new_config.is_valid():
		push_error("PlantDefense setup requires a valid config.")
		return

	config = new_config
	owner_player = new_owner_player
	footprint_cells.assign(new_footprint_cells)
	max_health = config.max_health
	current_health = max_health
	is_dead = false
	health_changed.emit(current_health, max_health)
	_on_setup_completed()


func receive_damage(
	amount: int,
	source: Node = null,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
) -> bool:
	if is_dead or amount <= 0:
		return false

	var applied_damage := mini(amount, current_health)
	current_health -= applied_damage
	health_changed.emit(current_health, max_health)
	_on_damage_received(applied_damage, source, impact_direction, damage_type)
	if current_health <= 0:
		_begin_death()
	return true


func receive_healing(amount: int, source: Node = null) -> bool:
	if is_dead or amount <= 0 or current_health >= max_health:
		return false

	var previous_health := current_health
	current_health = mini(current_health + amount, max_health)
	health_changed.emit(current_health, max_health)
	_on_healing_received(current_health - previous_health, source)
	return true


func get_health_ratio() -> float:
	if max_health <= 0:
		return 0.0
	return float(current_health) / float(max_health)


func _begin_death() -> void:
	if is_dead:
		return

	is_dead = true
	current_health = 0
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)
	died.emit()
	_on_death_started()


func _on_setup_completed() -> void:
	pass


func _on_damage_received(
	_applied_damage: int,
	_source: Node,
	_impact_direction: Vector2,
	_damage_type: EnemyConfig.DamageType
) -> void:
	pass


func _on_healing_received(_applied_healing: int, _source: Node) -> void:
	pass


func _on_death_started() -> void:
	queue_free()
