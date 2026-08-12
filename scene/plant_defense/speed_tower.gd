extends PlantDefense
class_name SpeedTower

@onready var health_bar: PlantHealthBar = $HealthBar
@onready var boot_motes: GPUParticles2D = $VisualRoot/BootBobRoot/BootMotes

var speed_tower_config: SpeedTowerConfig = null


func _on_setup_completed() -> void:
	speed_tower_config = config as SpeedTowerConfig
	if speed_tower_config == null:
		push_error("SpeedTower requires SpeedTowerConfig.")
		return
	health_bar.setup(max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)
	boot_motes.process_mode = Node.PROCESS_MODE_INHERIT
	boot_motes.show()
	boot_motes.emitting = true


func _on_removal_started(_mode: RemovalMode) -> void:
	_stop_boot_motes()
	health_bar.hide()


func _on_construction_started() -> void:
	_stop_boot_motes()


func _on_construction_finished(_was_animated: bool) -> void:
	_start_boot_motes()


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.set_health(new_health, new_max_health)


func _start_boot_motes() -> void:
	if not is_operational or is_dead or is_removing or boot_motes.emitting:
		return
	boot_motes.show()
	boot_motes.restart()
	boot_motes.emitting = true


func _stop_boot_motes() -> void:
	boot_motes.emitting = false
	boot_motes.hide()


func get_player_move_speed_bonus() -> float:
	return (
		speed_tower_config.move_speed_bonus
		if speed_tower_config != null
		else 0.0
	)
