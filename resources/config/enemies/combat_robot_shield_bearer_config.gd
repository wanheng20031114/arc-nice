extends EnemyConfig
class_name CombatRobotShieldBearerConfig

@export_group("举盾战斗机器人盾牌")

@export_range(1, 999, 1, "or_greater") var shield_max_blocks: int = 20
@export_range(0, 999, 1, "or_greater") var shield_cracked_remaining: int = 13
@export_range(0, 999, 1, "or_greater") var shield_critical_remaining: int = 6
@export var shield_block_animation_name: StringName = &"shield_block"
@export var shield_break_animation_name: StringName = &"shield_break"
