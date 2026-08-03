@tool
extends FlowStepConfig
class_name WaveConfig

enum SpawnOrder {
	SHUFFLED,
	ENTRY_ROUND_ROBIN,
}

const SPAWN_POINT_1_MASK := 1 << 0
const SPAWN_POINT_2_MASK := 1 << 1
const SPAWN_POINT_3_MASK := 1 << 2
const SPAWN_POINT_4_MASK := 1 << 3
const SPAWN_POINT_5_MASK := 1 << 4
const SPAWN_POINT_6_MASK := 1 << 5
const STANDARD_SPAWN_POINT_MASK := (
	SPAWN_POINT_1_MASK
	| SPAWN_POINT_2_MASK
	| SPAWN_POINT_3_MASK
	| SPAWN_POINT_4_MASK
	| SPAWN_POINT_5_MASK
)
const ALL_SPAWN_POINT_MASK := STANDARD_SPAWN_POINT_MASK | SPAWN_POINT_6_MASK
const SPAWN_POINT_NAMES: Array[StringName] = [
	&"Spawn1",
	&"Spawn2",
	&"Spawn3",
	&"Spawn4",
	&"Spawn5",
	&"Spawn6",
]

@export_group("波次内容")
@export var wave_name: String = "波次"
@export var enemy_entries: Array[WaveEnemyEntry] = []

@export_group("出生点")
@export_flags("Spawn1", "Spawn2", "Spawn3", "Spawn4", "Spawn5", "Spawn6")
var spawn_point_mask: int = STANDARD_SPAWN_POINT_MASK

@export_group("生成节奏")
@export var spawn_order: SpawnOrder = SpawnOrder.SHUFFLED
@export_range(0.025, 60.0, 0.025) var spawn_interval: float = 1.0
@export_range(1, 10, 1, "or_greater") var spawn_count_per_tick: int = 1
@export_range(1, 300, 1, "or_greater") var max_alive_enemies: int = 10

@export_group("音乐")
@export var music: AudioStream
@export var post_wave_music: AudioStream


func get_total_enemy_count() -> int:
	var total := 0
	for entry in enemy_entries:
		if entry != null and entry.enemy_config != null:
			total += maxi(entry.count, 0)
	return total


func get_enabled_spawn_point_names() -> Array[StringName]:
	var result: Array[StringName] = []
	for index in range(SPAWN_POINT_NAMES.size()):
		if spawn_point_mask & (1 << index):
			result.append(SPAWN_POINT_NAMES[index])
	return result


func get_flow_display_name() -> String:
	if not display_name.strip_edges().is_empty():
		return display_name
	if not wave_name.strip_edges().is_empty():
		return wave_name
	return super.get_flow_display_name()
