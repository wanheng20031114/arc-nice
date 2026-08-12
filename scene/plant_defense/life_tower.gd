extends PlantDefense
class_name LifeTower

@onready var health_bar: PlantHealthBar = $HealthBar

var life_tower_config: LifeTowerConfig = null


func _on_setup_completed() -> void:
	life_tower_config = config as LifeTowerConfig
	if life_tower_config == null:
		push_error("LifeTower requires LifeTowerConfig.")
		return
	health_bar.setup(max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)


func _on_removal_started(_mode: RemovalMode) -> void:
	health_bar.hide()


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.set_health(new_health, new_max_health)


func get_player_max_health_bonus_ratio() -> float:
	return (
		life_tower_config.max_health_bonus_ratio
		if life_tower_config != null
		else 0.0
	)
