@tool
extends FlowStepConfig
class_name WaveConfig

@export_group("波次内容")
@export var wave_name: String = "波次"
@export var enemy_entries: Array[WaveEnemyEntry] = []

@export_group("生成节奏")
@export_range(0.1, 60.0, 0.05) var spawn_interval: float = 1.0
@export_range(1, 4, 1) var spawn_count_per_tick: int = 1
@export_range(1, 200, 1, "or_greater") var max_alive_enemies: int = 10

@export_group("音乐")
@export var music: AudioStream
@export var post_wave_music: AudioStream


func get_total_enemy_count() -> int:
	var total := 0
	for entry in enemy_entries:
		if entry != null and entry.enemy_config != null:
			total += maxi(entry.count, 0)
	return total


func get_flow_display_name() -> String:
	if not display_name.strip_edges().is_empty():
		return display_name
	if not wave_name.strip_edges().is_empty():
		return wave_name
	return super.get_flow_display_name()
