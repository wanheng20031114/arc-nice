extends Resource
class_name XirangDropConfig

@export_group("基础信息")
@export var display_name: String = "息壤晶体"

@export_group("显示资源")
@export var icon_texture: Texture2D
# 16x16 原图使用 0.25 倍显示时约为 4x4 像素。
@export var icon_scale: Vector2 = Vector2(0.25, 0.25)
@export_range(0.05, 1.0, 0.05) var spawn_scale_multiplier: float = 0.5

@export_group("吸附参数")
@export_range(1.0, 1024.0, 1.0, "or_greater") var attraction_radius: float = 102.0
@export_range(0.05, 1.0, 0.01) var scatter_duration: float = 0.22
@export_range(0.05, 1.0, 0.01) var attraction_duration: float = 0.38

@export_group("拾取反馈")
@export_range(0.0, 64.0, 1.0, "or_greater") var label_rise_distance: float = 10.0
@export_range(0.05, 1.0, 0.01) var label_fade_duration: float = 0.32
