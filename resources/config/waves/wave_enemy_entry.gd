extends Resource
class_name WaveEnemyEntry

const ContentValidationContextResource := preload(
	"res://resources/config/content_validation_context.gd"
)

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


## 条目保留数量和奖励语义，敌人配置由同一闭包继续校验。
func append_validation_errors(
	context: ContentValidationContextResource,
	path: String
) -> void:
	var visit_state := context.begin_resource(self, path)
	if visit_state != ContentValidationContextResource.VisitState.ENTERED:
		return
	if count < 1:
		context.add_error(path, "count 必须至少为 1。")
	if xirang_kill_reward_override < -1:
		context.add_error(path, "xirang_kill_reward_override 不能小于 -1。")
	var enemy_path := ContentValidationContextResource.child_path(path, "enemy_config")
	if enemy_config == null:
		context.add_error(enemy_path, "不能为空。")
	else:
		enemy_config.append_validation_errors(context, enemy_path)
	context.complete_resource(self)
