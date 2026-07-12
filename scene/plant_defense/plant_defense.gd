extends StaticBody2D
class_name PlantDefense

signal health_changed(current_health: int, maximum_health: int)
signal authoritative_health_changed(current_health: int, maximum_health: int, revision: int)
signal died
signal modal_ui_visibility_changed(is_open: bool)

var config: PlantDefenseConfig = null
var owner_player: Player = null
var footprint_cells: Array[Vector2i] = []
var current_health: int = 0
var max_health: int = 0
var physical_defense: int = 0
var magic_defense: int = 0
var is_dead: bool = false
var is_multiplayer_proxy: bool = false
var health_revision: int = 0


func _ready() -> void:
	add_to_group(&"plant_defense")


func setup(
	new_config: PlantDefenseConfig,
	new_owner_player: Player,
	new_footprint_cells: Array[Vector2i],
	as_multiplayer_proxy: bool = false,
	initial_health: int = -1,
	initial_health_revision: int = 0,
	initial_maximum_health: int = -1
) -> void:
	if new_config == null or not new_config.is_valid():
		push_error("PlantDefense setup requires a valid config.")
		return

	config = new_config
	owner_player = new_owner_player
	footprint_cells.assign(new_footprint_cells)
	max_health = initial_maximum_health if initial_maximum_health > 0 else config.max_health
	current_health = clampi(initial_health, 0, max_health) if initial_health >= 0 else max_health
	physical_defense = maxi(config.physical_defense, 0)
	magic_defense = clampi(config.magic_defense, 0, 100)
	# Keep the node alive through subclass setup so a zero-health replica can
	# complete its visual initialization and then follow the normal death path.
	is_dead = false
	is_multiplayer_proxy = as_multiplayer_proxy
	health_revision = maxi(initial_health_revision, 0)
	health_changed.emit(current_health, max_health)
	if not is_multiplayer_proxy:
		_bump_health_revision()
	_on_setup_completed()
	if current_health <= 0:
		_begin_death()


func receive_damage(
	amount: int,
	source: Node = null,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
) -> bool:
	if is_multiplayer_proxy or is_dead or amount <= 0:
		return false

	var mitigated_damage := _calculate_incoming_damage(amount, damage_type)
	var applied_damage := mini(mitigated_damage, current_health)
	current_health -= applied_damage
	health_changed.emit(current_health, max_health)
	_bump_health_revision()
	_on_damage_received(applied_damage, source, impact_direction, damage_type)
	if current_health <= 0:
		_begin_death()
	return true


func receive_healing(amount: int, source: Node = null) -> bool:
	if is_multiplayer_proxy or is_dead or amount <= 0 or current_health >= max_health:
		return false

	var previous_health := current_health
	current_health = mini(current_health + amount, max_health)
	health_changed.emit(current_health, max_health)
	_bump_health_revision()
	_on_healing_received(current_health - previous_health, source)
	return true


func get_health_ratio() -> float:
	if max_health <= 0:
		return 0.0
	return float(current_health) / float(max_health)


func get_effective_physical_defense() -> int:
	return maxi(physical_defense, 0)


func get_effective_magic_defense() -> int:
	return clampi(magic_defense, 0, 100)


func is_modal_ui_open() -> bool:
	return false


func apply_remote_health(
	new_current_health: int,
	new_maximum_health: int,
	new_revision: int
) -> bool:
	if not is_multiplayer_proxy or new_revision <= health_revision:
		return false
	health_revision = new_revision
	max_health = maxi(new_maximum_health, 1)
	current_health = clampi(new_current_health, 0, max_health)
	health_changed.emit(current_health, max_health)
	if current_health <= 0:
		_begin_death()
	return true


func configure_multiplayer_proxy(
	initial_health: int,
	initial_maximum_health: int,
	initial_revision: int
) -> void:
	is_multiplayer_proxy = true
	max_health = maxi(initial_maximum_health, 1)
	current_health = clampi(initial_health, 0, max_health)
	health_revision = maxi(initial_revision, 0)
	health_changed.emit(current_health, max_health)
	_on_multiplayer_proxy_configured()
	if current_health <= 0:
		_begin_death()


func _bump_health_revision() -> void:
	health_revision += 1
	authoritative_health_changed.emit(current_health, max_health, health_revision)


func _calculate_incoming_damage(amount: int, damage_type: EnemyConfig.DamageType) -> int:
	match damage_type:
		EnemyConfig.DamageType.MAGIC:
			var defense_ratio := float(100 - get_effective_magic_defense()) / 100.0
			return maxi(floori(float(amount) * defense_ratio), 1)
		_:
			return maxi(amount - get_effective_physical_defense(), 1)


func _begin_death() -> void:
	if is_dead:
		return

	is_dead = true
	current_health = 0
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)
	var player_core_body := get_node_or_null("PlayerCoreBody") as StaticBody2D
	if player_core_body != null:
		player_core_body.set_deferred("collision_layer", 0)
		player_core_body.set_deferred("collision_mask", 0)
	died.emit()
	_on_death_started()


func _on_setup_completed() -> void:
	pass


func _on_multiplayer_proxy_configured() -> void:
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
