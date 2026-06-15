extends YuanshiInsectConfig
class_name YuanshiInsectGreenShellConfig

@export_group("翠壳毒性光环")
# 是否启用持续伤害光环。
@export var aura_enabled: bool = true
# 光环的实际伤害半径，同时控制范围提示的大小。
@export_range(1.0, 256.0, 0.5, "or_greater") var aura_radius: float = 30.0
# 光环连续命中玩家之间的最短间隔（秒）。
@export_range(0.1, 10.0, 0.01, "or_greater") var aura_damage_interval: float = 1.0

@export_group("翠壳粒子表现")
# 单颗粒子使用的像素纹理。
@export var aura_particle_texture: Texture2D = preload(
	"res://resources/texture/yuanshi_insect_green_aura_particle.tres"
)
# 每颗粒子出生时随机抽取的绿色系色泽。
@export var aura_particle_color_ramp: Texture2D = preload(
	"res://resources/texture/yuanshi_insect_green_aura_colors.tres"
)
# 同时存在的粒子数量；数量越高，喷射越密集。
@export_range(1, 512, 1, "or_greater") var aura_particle_amount: int = 72
# 单颗粒子持续时间，配合速度决定粒子可到达的距离。
@export_range(0.05, 10.0, 0.05, "or_greater") var aura_particle_lifetime: float = 0.9
# 粒子生成圆环的外半径，通常略大于敌人的实体碰撞半径。
@export_range(0.0, 64.0, 0.5, "or_greater") var aura_particle_emission_radius: float = 8.0
# 粒子生成圆环的厚度。
@export_range(0.0, 64.0, 0.5, "or_greater") var aura_particle_emission_thickness: float = 1.5
# 粒子向四周喷出的最小速度。
@export_range(0.0, 1000.0, 0.5, "or_greater") var aura_particle_speed_min: float = 16.0
# 粒子向四周喷出的最大速度。
@export_range(0.0, 1000.0, 0.5, "or_greater") var aura_particle_speed_max: float = 25.0
# 粒子的最小尺寸倍率。
@export_range(0.05, 10.0, 0.05, "or_greater") var aura_particle_scale_min: float = 0.65
# 粒子的最大尺寸倍率。
@export_range(0.05, 10.0, 0.05, "or_greater") var aura_particle_scale_max: float = 1.1
# 粒子的整体颜色和透明度。
@export var aura_particle_color: Color = Color.WHITE

@export_group("翠壳范围提示")
# 伤害范围内部的半透明填充颜色。
@export var aura_fill_color: Color = Color(0.12, 0.72, 0.08, 0.01)
# 伤害范围边缘轮廓的颜色。
@export var aura_outline_color: Color = Color(0.55, 1.0, 0.35, 0.12)
# 伤害范围边缘轮廓的宽度。
@export_range(0.25, 8.0, 0.25, "or_greater") var aura_outline_width: float = 4.0
