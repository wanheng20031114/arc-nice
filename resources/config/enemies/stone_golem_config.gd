extends "res://resources/config/enemies/capoo_knight_config.gd"
class_name StoneGolemConfig

@export_group("Ground Slam")

@export_range(0.0, 256.0, 0.5, "or_greater") var slam_radius: float = 44.0
@export var slam_damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
@export_range(1, 256, 1, "or_greater") var slam_query_batch_size: int = 64
@export_range(0.01, 2.0, 0.01, "or_greater") var impact_visual_duration: float = 0.28
@export_range(0.0, 2.0, 0.01, "or_greater") var initial_attack_stagger: float = 0.35
