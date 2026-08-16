@tool
extends FlowStepConfig
class_name WaveConfig

const ContentValidationContextResource := preload(
	"res://resources/config/content_validation_context.gd"
)

enum SpawnOrder {
	SHUFFLED,
	ENTRY_ROUND_ROBIN,
}

enum SpawnPointOrder {
	UNIFORM_RANDOM,
	BALANCED_SHUFFLE_BAG,
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
@export var spawn_point_order: SpawnPointOrder = SpawnPointOrder.UNIFORM_RANDOM

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


## 波次只负责自身节奏与入口顺序，深层资源共用同一校验上下文。
func append_validation_errors(
	context: ContentValidationContextResource,
	path: String
) -> void:
	var visit_state := context.begin_resource(self, path)
	if visit_state != ContentValidationContextResource.VisitState.ENTERED:
		return

	if wave_name.strip_edges().is_empty():
		context.add_error(path, "缺少 wave_name。")
	if enemy_entries.is_empty():
		context.add_error(path, "enemy_entries 不能为空。")
	if spawn_point_mask == 0:
		context.add_error(path, "没有启用出生点。")
	elif spawn_point_mask & ~ALL_SPAWN_POINT_MASK:
		context.add_error(path, "包含未知出生点位。")
	if spawn_order < SpawnOrder.SHUFFLED or spawn_order > SpawnOrder.ENTRY_ROUND_ROBIN:
		context.add_error(path, "spawn_order 超出已定义范围。")
	if (
		spawn_point_order < SpawnPointOrder.UNIFORM_RANDOM
		or spawn_point_order > SpawnPointOrder.BALANCED_SHUFFLE_BAG
	):
		context.add_error(path, "spawn_point_order 超出已定义范围。")
	if not is_finite(spawn_interval) or spawn_interval < 0.025 or spawn_interval > 60.0:
		context.add_error(path, "spawn_interval 必须是 0.025 到 60 之间的有限数。")
	if spawn_count_per_tick < 1:
		context.add_error(path, "spawn_count_per_tick 必须至少为 1。")
	if max_alive_enemies < 1:
		context.add_error(path, "max_alive_enemies 必须至少为 1。")
	if not is_finite(post_clear_rest_duration) or post_clear_rest_duration < 0.0:
		context.add_error(path, "post_clear_rest_duration 必须是非负有限数。")

	for entry_index in range(enemy_entries.size()):
		var entry := enemy_entries[entry_index]
		var entry_path := ContentValidationContextResource.child_path(
			path,
			"enemy_entries[%d]" % entry_index
		)
		if entry == null:
			context.add_error(entry_path, "不能为空。")
			continue
		entry.append_validation_errors(context, entry_path)

	context.complete_resource(self)
