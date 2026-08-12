extends PlantDefense
class_name AttackSpeedTower

@onready var health_bar: PlantHealthBar = $HealthBar
@onready var speed_motes: GPUParticles2D = $VisualRoot/SpeedBobRoot/SpeedMotes

var attack_speed_tower_config: AttackSpeedTowerConfig = null


func _on_setup_completed() -> void:
	attack_speed_tower_config = config as AttackSpeedTowerConfig
	if attack_speed_tower_config == null:
		push_error("AttackSpeedTower requires AttackSpeedTowerConfig.")
		return
	health_bar.setup(max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)
	speed_motes.process_mode = Node.PROCESS_MODE_INHERIT
	speed_motes.show()
	speed_motes.emitting = true


func _on_removal_started(_mode: RemovalMode) -> void:
	_stop_speed_motes()
	health_bar.hide()


func _on_construction_started() -> void:
	_stop_speed_motes()


func _on_construction_finished(_was_animated: bool) -> void:
	_start_speed_motes()


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.set_health(new_health, new_max_health)


func _start_speed_motes() -> void:
	if not is_operational or is_dead or is_removing or speed_motes.emitting:
		return
	speed_motes.show()
	speed_motes.restart()
	speed_motes.emitting = true


func _stop_speed_motes() -> void:
	speed_motes.emitting = false
	speed_motes.hide()


func get_player_attack_speed_bonus_ratio() -> float:
	return (
		attack_speed_tower_config.attack_speed_bonus_ratio
		if attack_speed_tower_config != null
		else 0.0
	)
