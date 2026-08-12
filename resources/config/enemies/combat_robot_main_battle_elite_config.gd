extends EnemyConfig
class_name CombatRobotMainBattleEliteConfig

@export_group("普通双剑斩")
@export var attack_animation_name: StringName = &"attack"
@export_range(0.0, 256.0, 0.5, "or_greater") var attack_range := 32.0
@export_range(1.0, 360.0, 1.0) var attack_angle_degrees := 90.0
@export_range(0.0, 5.0, 0.01, "or_greater") var attack_windup := 0.35
@export_range(0.0, 5.0, 0.001, "or_greater") var attack_damage_delay := (1.0 / 15.0)
@export_range(0.01, 5.0, 0.001, "or_greater") var attack_slash_duration := (5.0 / 15.0)
@export_range(0.0, 60.0, 0.01, "or_greater") var attack_cooldown := 1.33

@export_group("技能1：冲锋圆斩")
@export var skill1_windup_animation_name: StringName = &"skill1_windup"
@export var skill1_dash_animation_name: StringName = &"skill1_dash"
@export var skill1_circle_animation_name: StringName = &"skill1_circle_slash"
@export_range(0.0, 30.0, 0.01, "or_greater") var skill1_initial_delay := 1.5
@export_range(0.0, 2048.0, 1.0, "or_greater") var skill1_trigger_range := 160.0
@export_range(0.0, 5.0, 0.01, "or_greater") var skill1_windup := 0.5
@export_range(0.0, 1000.0, 1.0, "or_greater") var skill1_dash_speed := 240.0
@export_range(0.01, 5.0, 0.01, "or_greater") var skill1_dash_duration := 0.75
@export_range(0.0, 256.0, 0.5, "or_greater") var skill1_circle_radius := 36.0
@export_range(0.0, 10.0, 0.05, "or_greater") var skill1_damage_multiplier := 1.2
@export_range(0.0, 5.0, 0.01, "or_greater") var skill1_recovery := 0.4
@export_range(0.0, 60.0, 0.01, "or_greater") var skill1_cooldown := 10.0

@export_group("技能2：升空追踪落砸")
@export var skill2_takeoff_animation_name: StringName = &"skill2_takeoff"
@export var skill2_drop_animation_name: StringName = &"skill2_drop_slash"
@export_range(0.0, 30.0, 0.01, "or_greater") var skill2_initial_delay := 4.0
@export_range(0.0, 2048.0, 1.0, "or_greater") var skill2_trigger_range := 220.0
@export_range(0.01, 5.0, 0.01, "or_greater") var skill2_takeoff_duration := 0.15
@export_range(0.01, 10.0, 0.01, "or_greater") var skill2_tracking_duration := 3.0
@export_range(0.0, 1000.0, 1.0, "or_greater") var skill2_cross_speed := 50.0
@export_range(0.01, 5.0, 0.01, "or_greater") var skill2_drop_duration := 0.18
@export_range(0.0, 256.0, 0.5, "or_greater") var skill2_fan_range := 48.0
@export_range(1.0, 360.0, 1.0) var skill2_fan_angle_degrees := 120.0
@export_range(0.0, 10.0, 0.05, "or_greater") var skill2_damage_multiplier := 1.5
@export_range(0.0, 5.0, 0.01, "or_greater") var skill2_recovery := (5.0 / 15.0)
@export_range(0.0, 60.0, 0.01, "or_greater") var skill2_cooldown := 8.0

@export_group("命中状态与查询")
@export_range(0.05, 30.0, 0.05, "or_greater") var burn_duration := 5.0
@export_range(1, 1000, 1, "or_greater") var burn_level := 5
@export_range(0.05, 30.0, 0.05, "or_greater") var skill2_slow_duration := 1.0
@export_range(0.0, 1.0, 0.01) var skill2_slow_multiplier := 0.75
@export_range(1, 256, 1, "or_greater") var shape_query_batch_size := 64
