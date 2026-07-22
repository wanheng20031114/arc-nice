extends EnemyConfig
class_name LightningSorcererConfig

@export_group("链式闪电")
@export var windup_animation_name: StringName = &"windup"
@export var attack_animation_name: StringName = &"attack"
# 项目逻辑格为 16 像素；默认攻击半径为 7 格。
@export_range(0.0, 2048.0, 1.0, "or_greater") var attack_range: float = 112.0
# 首次命中后，每次从上一命中点的 3 格内选取最近的未命中目标。
@export_range(0.0, 512.0, 1.0, "or_greater") var chain_range: float = 48.0
# 不含首次命中；4 次折射代表单次攻击最多命中 5 个不同目标。
@export_range(0, 4, 1) var max_chain_bounces: int = 4
@export_range(0.01, 30.0, 0.01, "or_greater") var windup_duration: float = 0.6
# 冷却从即时闪电完成结算时开始计算。
@export_range(0.01, 60.0, 0.01, "or_greater") var attack_interval: float = 3.0
# 大群敌人初次进入射程时使用确定性错峰，避免同帧集中施法。
@export_range(0.0, 2.0, 0.01, "or_greater") var initial_attack_stagger_window: float = 0.9
