extends EnemyConfig
class_name CombatRobotDroneOperatorConfig

@export_group("爆炸无人机操作员部署")

@export var deploy_animation_name: StringName = &"deploy"
@export_range(0.0, 1024.0, 0.1, "or_greater") var attack_range: float = 80.0
@export_range(0.0, 1024.0, 0.1, "or_greater") var stop_distance: float = 40.0
@export_range(0.0, 10.0, 0.01, "or_greater") var deploy_delay: float = 0.10
@export_range(0.0, 60.0, 0.01, "or_greater") var attack_cooldown: float = 3.0
@export_range(1, 32, 1, "or_greater") var visible_target_check_limit: int = 4
@export_range(0.01, 10.0, 0.01, "or_greater") var blocked_retry_interval: float = 0.35
@export_range(0.0, 2000.0, 0.1, "or_greater") var drone_speed: float = 60.0
@export var projectile_type: StringName = &"combat_robot_suicide_drone"
@export var drone_scene: PackedScene
