extends LinglanBoss


# 只保留远端 proxy 身份登记所需的 Boss 语义；不带正式技能、音频与 HUD
# 资源闭包，确保本契约能真实检查索引生命周期且可在同一进程内释放。
func setup(
	enemy_config: EnemyConfig,
	player: Player,
	shared_pathfinder: Node = null,
	runtime_context: CombatRuntimeBase = null,
	runtime_port: LinglanBossRuntimePort = null
) -> void:
	config = enemy_config
	target_player = player
	pathfinder = shared_pathfinder
	combat_runtime = runtime_context
	linglan_runtime_port = runtime_port


func configure_multiplayer_proxy() -> void:
	is_multiplayer_proxy = true
	visible = true
