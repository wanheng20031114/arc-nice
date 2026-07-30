extends Resource
class_name WaveEnemyEntry

@export var enemy_config: EnemyConfig
@export_range(1, 999, 1, "or_greater") var count: int = 1
@export_range(-1, 999, 1, "or_greater") var xirang_kill_reward_override: int = -1


## Returns the reward authored for this wave entry. A negative override inherits
## from the resolved config so fate replacements keep their own default reward.
func resolve_xirang_kill_reward(resolved_enemy_config: EnemyConfig = null) -> int:
	if xirang_kill_reward_override >= 0:
		return xirang_kill_reward_override
	var reward_config := (
		resolved_enemy_config if resolved_enemy_config != null else enemy_config
	)
	return reward_config.xirang_kill_reward if reward_config != null else 0
