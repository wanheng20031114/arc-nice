extends Resource
class_name EnemyConfig

const ContentValidationContextResource := preload(
	"res://resources/config/content_validation_context.gd"
)
const CombatRelationServiceResource := preload(
	"res://scene/combat/faction/combat_relation_service.gd"
)

const CATEGORY_YUANSHI_INSECT: StringName = &"yuanshi_insect"
const CATEGORY_CAPOO: StringName = &"capoo"
const CATEGORY_SORCERER: StringName = &"sorcerer"
const CATEGORY_ARTIFICIAL_CREATION: StringName = &"artificial_creation"
const CATEGORY_SLIME: StringName = &"slime"
const CATEGORY_MECHANICAL_LIFE: StringName = &"mechanical_life"
const CATEGORY_STONE_ERODED: StringName = &"stone_eroded"

enum DamageType {
	PHYSICAL,
	MAGIC,
}

@export_group("基础信息")

@export var display_name: String = "敌人"
# Boss 身份是战斗规则的一部分，不复用碰撞层或家族标签。
@export var is_boss: bool = false
# 稳定的敌人类别标签，供掉落、全局增益和收藏品等系统统一筛选。
@export var category_tags: PackedStringArray = PackedStringArray()
# 当前敌人的完整场景，包含碰撞体积、接触伤害体积和本体动画。
@export var enemy_scene: PackedScene

@export_group("阵营")
# Enemy instances own their runtime faction. Config only supplies the spawn
# default so temporary conversion never mutates a shared resource.
@export_range(0, 31, 1) var default_combat_faction_id: int = (
	CombatRelationServiceResource.HOSTILE_WAVE
)
@export var allow_runtime_faction_change := true

@export_group("基础数值")
# 最大生命值，敌人生成时可用它初始化当前生命值。
@export_range(1, 999, 1, "or_greater") var max_health: int = 3
# 常规攻击伤害，供身体接触、光环和远程弹丸等攻击方式统一读取。
@export_range(0, 999, 1, "or_greater") var attack_damage: int = 1
# 物理防御直接抵消物理伤害，最终伤害最低为 1。
@export_range(0, 999, 1, "or_greater") var physical_defense: int = 0
# 法术防御按百分比降低法术伤害，最终伤害最低为 1。
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


func can_change_faction_at_runtime() -> bool:
	# Bosses are valid combat targets but remain faction-locked unless a future
	# dedicated boss mechanic explicitly introduces a separate override path.
	return allow_runtime_faction_change and not is_boss


## 这里校验所有通用敌人运行时会直接消费的基础契约。
func append_validation_errors(
	context: ContentValidationContextResource,
	path: String
) -> void:
	var visit_state := context.begin_resource(self, path)
	if visit_state != ContentValidationContextResource.VisitState.ENTERED:
		return

	if display_name.strip_edges().is_empty():
		context.add_error(path, "缺少 display_name。")
	if enemy_scene == null:
		context.add_error(path, "缺少 enemy_scene。")
	elif not enemy_scene.can_instantiate():
		context.add_error(path, "enemy_scene 无法实例化。")
	if not CombatRelationServiceResource.is_valid_faction_id(default_combat_faction_id):
		context.add_error(path, "default_combat_faction_id 必须位于 0 到 31。")
	if max_health < 1:
		context.add_error(path, "max_health 必须至少为 1。")
	if attack_damage < 0:
		context.add_error(path, "attack_damage 不能为负数。")
	if physical_defense < 0:
		context.add_error(path, "physical_defense 不能为负数。")
	if magic_defense < 0 or magic_defense > 100:
		context.add_error(path, "magic_defense 必须位于 0 到 100 之间。")
	if not is_finite(move_speed) or move_speed < 0.0:
		context.add_error(path, "move_speed 必须是非负有限数。")
	if home_damage < 1:
		context.add_error(path, "home_damage 必须至少为 1。")
	var known_traversal_types := (
		DualGridTilemap.TraversalType.LAND
		| DualGridTilemap.TraversalType.WATER
	)
	if terrain_traversal_types == 0:
		context.add_error(path, "terrain_traversal_types 不能为空。")
	elif terrain_traversal_types & ~known_traversal_types:
		context.add_error(path, "terrain_traversal_types 包含未知地形标志。")
	if move_animation_name == &"":
		context.add_error(path, "缺少 move_animation_name。")
	if death_animation_name == &"":
		context.add_error(path, "缺少 death_animation_name。")
	if explosion_damage < 0:
		context.add_error(path, "explosion_damage 不能为负数。")
	if not is_finite(explosion_radius) or explosion_radius < 0.0:
		context.add_error(path, "explosion_radius 必须是非负有限数。")
	if not is_finite(explosion_animation_scale) or explosion_animation_scale < 0.1:
		context.add_error(path, "explosion_animation_scale 必须是至少 0.1 的有限数。")
	if explode_on_death:
		if explosion_damage <= 0:
			context.add_error(path, "自爆敌人的 explosion_damage 必须大于 0。")
		if not is_finite(explosion_radius) or explosion_radius <= 0.0:
			context.add_error(path, "自爆敌人的 explosion_radius 必须是正有限数。")
		if explosion_animation_name == &"":
			context.add_error(path, "自爆敌人缺少 explosion_animation_name。")
	if xirang_kill_reward < 0:
		context.add_error(path, "xirang_kill_reward 不能为负数。")

	var seen_tags: Dictionary = {}
	for tag_index in range(category_tags.size()):
		var tag := category_tags[tag_index]
		var tag_path := ContentValidationContextResource.child_path(
			path,
			"category_tags[%d]" % tag_index
		)
		if tag.strip_edges().is_empty():
			context.add_error(tag_path, "不能为空。")
		elif seen_tags.has(tag):
			context.add_error(tag_path, "不能重复。")
		else:
			seen_tags[tag] = true

	var drop_table_path := ContentValidationContextResource.child_path(path, "drop_table")
	if drop_table == null:
		context.add_error(drop_table_path, "不能为空。")
	else:
		drop_table.append_validation_errors(context, drop_table_path)
	context.complete_resource(self)
