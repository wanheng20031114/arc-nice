extends EnemyConfig
class_name FireSorcererConfig

@export_group("三重火球")
# 法杖蓄力期间播放的角色动画。
@export var windup_animation_name: StringName = &"windup"
# 三枚火球完成生成时播放的挥杖动画。
@export var attack_animation_name: StringName = &"attack"
# 比法师 Capoo 的 640 px 多两个逻辑格，但仍低于狙击手。
@export_range(0.0, 2048.0, 1.0, "or_greater") var attack_range: float = 672.0
# 三枚预览火球从零缩放到完整大小的持续时间。
@export_range(0.01, 30.0, 0.01, "or_greater") var summon_duration: float = 0.6
# 从三枚真实火球完成生成后开始计算的攻击冷却。
@export_range(0.01, 60.0, 0.01, "or_greater") var attack_interval: float = 3.0
# 只用于刚进入场景且已经站在射程内的大群敌人。确定性错峰会在移动中
# 自然耗尽；0.9 秒在 60 Hz 下提供 54 个桶，不改变任意两次“生成完成”
# 之间的 3 秒攻击间隔。
@export_range(0.0, 2.0, 0.01, "or_greater") var initial_attack_stagger_window: float = 0.9
# 独立的三火球齐射场景。
@export var volley_scene: PackedScene
# 固定比玩家 120 的默认移动速度高 5。
@export_range(0.0, 2000.0, 0.1, "or_greater") var projectile_speed: float = 125.0
@export_range(0.01, 30.0, 0.01, "or_greater") var projectile_lifetime: float = 7.0
# 每秒最大转向弧度。6 rad/s 明显强于法师 Capoo 的 0.65 rad/s。
@export_range(0.0, 16.0, 0.05, "or_greater") var homing_turn_rate: float = 6.0
@export_group("燃烧")
# 等级等同于每秒一次、经过目标法抗结算的基础法术伤害。
@export_range(0.05, 30.0, 0.05, "or_greater") var burn_duration: float = 5.0
@export_range(1, 1000, 1, "or_greater") var burn_level: int = 5
@export var attack_audio_stream: AudioStream
