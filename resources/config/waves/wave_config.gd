extends Resource
class_name WaveConfig

@export_group("波次内容")
@export var wave_name: String = "波次"
@export var enemy_entries: Array[WaveEnemyEntry] = []

@export_group("生成节奏")
@export_range(0.05, 60.0, 0.05, "or_greater") var spawn_interval: float = 1.0
@export_range(1, 20, 1, "or_greater") var spawn_count_per_tick: int = 1
@export_range(1, 200, 1, "or_greater") var max_alive_enemies: int = 10

@export_group("波次衔接")
@export_range(0.0, 600.0, 1.0, "or_greater") var rest_duration_after_wave: float = 30.0
@export var music: AudioStream


func get_total_enemy_count() -> int:
	var total := 0
	for entry in enemy_entries:
		if entry != null and entry.enemy_config != null:
			total += maxi(entry.count, 0)
	return total

