extends Resource
class_name WaveEnemyEntry

@export var enemy_config: EnemyConfig
@export_range(1, 999, 1, "or_greater") var count: int = 1
