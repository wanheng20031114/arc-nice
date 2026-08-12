extends PlantDefense
class_name LifeTower

@onready var health_bar: PlantHealthBar = $HealthBar
@onready var heart_motes: GPUParticles2D = $VisualRoot/HeartBobRoot/HeartMotes

var life_tower_config: LifeTowerConfig = null


func _on_setup_completed() -> void:
	life_tower_config = config as LifeTowerConfig
	if life_tower_config == null:
		push_error("LifeTower requires LifeTowerConfig.")
		return
	health_bar.setup(max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)
	heart_motes.process_mode = Node.PROCESS_MODE_INHERIT
	heart_motes.show()
	heart_motes.emitting = true


func _on_removal_started(_mode: RemovalMode) -> void:
	_stop_heart_motes()
	health_bar.hide()


func _on_construction_started() -> void:
	_stop_heart_motes()


func _on_construction_finished(_was_animated: bool) -> void:
	_start_heart_motes()


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.set_health(new_health, new_max_health)


func _start_heart_motes() -> void:
	if not is_operational or is_dead or is_removing or heart_motes.emitting:
		return
	heart_motes.show()
	heart_motes.restart()
	heart_motes.emitting = true


func _stop_heart_motes() -> void:
	heart_motes.emitting = false
	heart_motes.hide()


func get_player_max_health_bonus_ratio() -> float:
	return (
		life_tower_config.max_health_bonus_ratio
		if life_tower_config != null
		else 0.0
	)
