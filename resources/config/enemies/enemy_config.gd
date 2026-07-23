extends Resource
class_name EnemyConfig

const CATEGORY_YUANSHI_INSECT: StringName = &"yuanshi_insect"
const CATEGORY_CAPOO: StringName = &"capoo"
const CATEGORY_SORCERER: StringName = &"sorcerer"
const CATEGORY_ARTIFICIAL_CREATION: StringName = &"artificial_creation"
const CATEGORY_SLIME: StringName = &"slime"

enum DamageType {
	PHYSICAL,
	MAGIC,
}

@export_group("基础信息")

@export var display_name: String = "敌人"
# 稳定的敌人类别标签，供掉落、全局增益和收藏品等系统统一筛选。
@export var category_tags: PackedStringArray = PackedStringArray()
# 当前敌人的完整场景，包含碰撞体积、接触伤害体积和本体动画。
@export var enemy_scene: PackedScene

@export_group("基础数值")
# 最大生命值，敌人生成时可用它初始化当前生命值。
@export_range(1, 999, 1, "or_greater") var max_health: int = 3
# 常规攻击伤害，供身体接触、光环和远程弹丸等攻击方式统一读取。
@export_range(0, 999, 1, "or_greater") var attack_damage: int = 1
# 物理防御直接抵消物理伤害，最终伤害最低为 1。
@export_range(0, 999, 1, "or_greater") var physical_defense: int = 0
# 魔法防御按百分比降低魔法伤害，最终伤害最低为 1。
@export_range(0, 100, 1) var magic_defense: int = 0
# 移动速度，单位通常为像素/秒。
@export_range(0.0, 1000.0, 1.0, "or_greater") var move_speed: float = 60.0
# 在塔防模式进入 Home 时对基地造成的伤害。
@export_range(1, 999, 1, "or_greater") var home_damage: int = 1

@export_group("地形移动")
# 角色可以通过的地形类型。默认仅陆地；两栖单位使用 Land | Water。
@export_flags("Land", "Water") var terrain_traversal_types: int = DualGridTilemap.TraversalType.LAND


@export_group("动画名称")
# 敌人正常移动时默认播放的动画名。
@export var move_animation_name: StringName = &"move"
# 敌人死亡时默认播放的动画名。
@export var death_animation_name: StringName = &"death"
# 爆炸特效默认播放的动画名。
@export var explosion_animation_name: StringName = &"explode"


@export_group("死亡效果")
# 是否在死亡时触发自爆。
@export var explode_on_death: bool = false
# 自爆伤害，只有 explode_on_death 为 true 时才有意义。
@export_range(0, 999, 1, "or_greater") var explosion_damage: int = 0
# 自爆半径，只有 explode_on_death 为 true 时才有意义。
@export_range(0.0, 512.0, 1.0, "or_greater") var explosion_radius: float = 0
# 爆炸动画相对原始帧的显示缩放，用于让视觉范围贴合实际伤害半径。
@export_range(0.1, 10.0, 0.01, "or_greater") var explosion_animation_scale: float = 1.0


@export_group("奖励与掉落")
# 敌人被击杀时直接发给每位当前玩家的息壤奖金；0 表示没有奖金。
@export_range(0, 999, 1, "or_greater") var xirang_kill_reward: int = 1
# 敌人死亡时使用的数据驱动掉落表；表内每条规则都会独立判定。
@export var drop_table: EnemyDropTable = preload("res://resources/config/enemies/default_enemy_drop_table.tres")


func has_category_tag(category: StringName) -> bool:
	return String(category) in category_tags
