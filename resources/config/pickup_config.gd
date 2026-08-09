extends Resource
class_name PickupConfig

const INVENTORY_ICON_MAX_SIDE := 32.0

enum PickupType {
	SPEED,
	RAPID,
	SPIRAL,
	TENPURA,
	CONSUMABLE,
	COLLECTIBLE,
	MATERIAL,
	BUILDING,
}

enum PlayerFormMode {
	NORMAL,
	ARMED,
	
}

enum ShotPattern {
	NORMAL,
	SPIRAL,
	
}

enum CollectibleRarity {
	COMMON,
	RARE,
	EPIC,
	LEGENDARY,
	SPECIAL,
	
}

const COLLECTIBLE_EFFECT_APPLE := "apple"
const COLLECTIBLE_EFFECT_GOLD_WINE_CUP := "gold_wine_cup"
const COLLECTIBLE_EFFECT_TIANSHI_STAKE := "tianshi_stake"
const COLLECTIBLE_EFFECT_RUBY := "ruby"
const COLLECTIBLE_EFFECT_EMERALD := "emerald"
const COLLECTIBLE_EFFECT_TOPAZ := "topaz"
const COLLECTIBLE_EFFECT_GRAY_GEM := "gray_gem"
const COLLECTIBLE_EFFECT_AMETHYST := "amethyst"
const COLLECTIBLE_EFFECT_POWER_RING := "power_ring"
const COLLECTIBLE_EFFECT_LIFE_RING := "life_ring"
const COLLECTIBLE_EFFECT_SPEED_RING := "speed_ring"
const COLLECTIBLE_EFFECT_PHYSICAL_RING := "physical_ring"
const COLLECTIBLE_EFFECT_MAGIC_RING := "magic_ring"
const COLLECTIBLE_EFFECT_MOON_AMULET := "moon_amulet"
const COLLECTIBLE_EFFECT_THUNDER_CRYSTAL := "thunder_crystal"
const COLLECTIBLE_EFFECT_FROST_CRYSTAL := "frost_crystal"
const COLLECTIBLE_EFFECT_LIFE_CRYSTAL := "life_crystal"
const COLLECTIBLE_EFFECT_SWIFT_CRYSTAL := "swift_crystal"
const COLLECTIBLE_EFFECT_ADMIN_DOLL := "admin_doll"
const COLLECTIBLE_EFFECT_ARCHER := "archer"
const COLLECTIBLE_EFFECT_NINE_ELEVEN := "nine_eleven"
const COLLECTIBLE_EFFECT_CHARGED_JADE_PENDANT := "charged_jade_pendant"
const COLLECTIBLE_EFFECT_LUCKY_GEM := "lucky_gem"
const COLLECTIBLE_EFFECT_MEDIEVAL_SHIELD := "medieval_shield"
const COLLECTIBLE_EFFECT_SAKURA := "sakura"
const COLLECTIBLE_EFFECT_BASKETBALL := "basketball"

const PERIODIC_EFFECT_THUNDER := "thunder"
const PERIODIC_EFFECT_FROST := "frost"
const PERIODIC_EFFECT_HEAL := "heal"
const PERIODIC_EFFECT_ARCHER := "archer"
const PERIODIC_EFFECT_SAKURA_ROCKET := "sakura_rocket"

const SKILL_EFFECT_MOON_SHIELD := "moon_shield"
const SKILL_EFFECT_SWIFT := "swift"

const CONDITION_HEALTH_BELOW := "health_below"
const CONDITION_HEALTH_ABOVE := "health_above"
const CONDITION_XIRANG_AT_LEAST := "xirang_at_least"
const CONDITION_XIRANG_BELOW := "xirang_below"
const CONDITION_SKILL_UNLOCKED := "skill_unlocked"
const CONDITION_SKILL_LOCKED := "skill_locked"

const TRIGGER_SHOT_HEAL := "shot_heal"
const TRIGGER_SHOT_XIRANG := "shot_xirang"
const TRIGGER_SHOT_CHARGE := "shot_charge"
const TRIGGER_SHOT_THUNDER := "shot_thunder"
const TRIGGER_SHOT_FROST := "shot_frost"
const TRIGGER_HURT_HEAL := "hurt_heal"
const TRIGGER_HURT_XIRANG := "hurt_xirang"
const TRIGGER_HURT_THUNDER := "hurt_thunder"
const TRIGGER_HURT_FROST := "hurt_frost"
const TRIGGER_SKILL_HEAL := "skill_heal"
const TRIGGER_SKILL_XIRANG := "skill_xirang"
const TRIGGER_SKILL_CHARGE := "skill_charge"
const TRIGGER_SKILL_THUNDER := "skill_thunder"
const TRIGGER_SKILL_FROST := "skill_frost"

const HIT_EFFECT_BURN := "burn"
const HIT_EFFECT_BLEED := "bleed"
const HIT_EFFECT_CHILL := "chill"
const HIT_EFFECT_SHOCK := "shock"
const HIT_EFFECT_MARK := "mark"
const HIT_EFFECT_CRACK := "crack"
const HIT_EFFECT_LEECH := "leech"
const HIT_EFFECT_SIPHON := "siphon"
const HIT_EFFECT_EXECUTE := "execute"
const HIT_EFFECT_BLOOM := "bloom"
const HIT_EFFECT_XIRANG := "xirang"

const KILL_EFFECT_HEAL := "heal"
const KILL_EFFECT_XIRANG := "xirang"
const KILL_EFFECT_CHARGE := "charge"
const KILL_EFFECT_THUNDER := "thunder"
const KILL_EFFECT_FROST := "frost"
const KILL_EFFECT_HASTE := "haste"
const KILL_EFFECT_BLOOM := "bloom"
const KILL_EFFECT_BURST := "burst"
const MAX_DASH_COOLDOWN_REDUCTION_PER_COLLECTIBLE := 0.5

@export_group("基础信息")
@export var pickup_type:PickupType = PickupType.SPEED
@export var display_name : String = "移速道具"
# 兼容旧资源的权重元数据；敌人掉落现由 EnemyDropTable 的独立 chance 规则决定。
@export_range(0.0 , 1000.0 , 0.1, "or_greater") var drop_weight:float = 1.0
@export_multiline var description: String = ""
@export var can_store_in_inventory: bool = false
@export var stackable: bool = false
## Locked fate items remain visible in the normal backpack but cannot be used,
## consumed, discarded, moved, or selected as crafting input.
@export var inventory_locked: bool = false
# 可叠加物品在单个背包槽位中的数量上限；不可叠加物品固定视为 1。
@export_range(1, 999, 1) var inventory_stack_limit: int = 1


static func inventory_identity_matches(
	existing_item: PickupConfig,
	expected_item: PickupConfig
) -> bool:
	if existing_item == null or expected_item == null:
		return false
	if existing_item == expected_item:
		return true
	return (
		not existing_item.resource_path.is_empty()
		and existing_item.resource_path == expected_item.resource_path
	)


static func inventory_items_can_stack(
	existing_item: PickupConfig,
	incoming_item: PickupConfig
) -> bool:
	if (
		existing_item == null
		or incoming_item == null
		or not existing_item.stackable
		or not incoming_item.stackable
	):
		return false
	if existing_item == incoming_item:
		return true
	return (
		not existing_item.resource_path.is_empty()
		and existing_item.resource_path == incoming_item.resource_path
	)


static func get_inventory_stack_limit(item: PickupConfig) -> int:
	if item == null or not item.stackable:
		return 1
	return clampi(item.inventory_stack_limit, 1, 999)


func is_pickup_triggered_item() -> bool:
	return pickup_type in [
		PickupType.SPEED,
		PickupType.RAPID,
		PickupType.SPIRAL,
		PickupType.TENPURA,
	]


func is_consumable_item() -> bool:
	return pickup_type == PickupType.CONSUMABLE

@export_group("显示资源")
@export var icon_texture : Texture2D
# 仅控制物品作为世界掉落物时的显示尺寸；背包图标按源纹理尺寸独立适配。
@export var icon_scale: Vector2 = Vector2.ONE
@export_range(0.0, 300.0, 1.0, "or_greater") var world_lifetime: float = 12.0


func get_inventory_icon_scale() -> Vector2:
	if icon_texture == null:
		return Vector2.ONE
	var texture_size := icon_texture.get_size()
	var max_side := maxf(texture_size.x, texture_size.y)
	if max_side <= INVENTORY_ICON_MAX_SIDE:
		return Vector2.ONE
	var fit_scale := INVENTORY_ICON_MAX_SIDE / max_side
	return Vector2(fit_scale, fit_scale)

@export_group("建筑物品")
# 建筑物品被使用时进入指定植物建筑的放置模式；真正落地后才消耗 1 个。
@export var placeable_plant_id: StringName = &""

@export_group("Buff 效果")
# 拾取后回复的生命值，0 表示该道具不回复生命。
@export_range(0, 99, 1, "or_greater") var heal_amount: int = 0
# 消耗药水提供的临时物理防御；与研究、收藏品加成分别维护并在属性重算时相加。
@export_range(0, 999, 1, "or_greater") var potion_physical_defense_bonus: int = 0
# 道具效果持续时间，单位为秒。
@export_range(0.0, 120.0, 0.1, "or_greater") var duration: float = 5.0
# 玩家移速倍率，1.0 表示不改变，1.2 表示提升 20%。
@export_range(0.1, 5.0, 0.05, "or_greater") var move_speed_multiplier: float = 1.0
# 玩家射速倍率，1.0 表示不改变，1.5 表示射速提升 50%。
@export_range(0.1, 5.0, 0.05, "or_greater") var fire_rate_multiplier: float = 1.0
# 玩家攻击力倍率，1.0 表示不改变，1.1 表示攻击力提高 10%。
@export_range(0.1, 5.0, 0.05, "or_greater") var attack_damage_multiplier: float = 1.0


@export_group("形态与弹幕")
# 玩家拾取后切换到的形态模式。
@export var player_form_mode: PlayerFormMode = PlayerFormMode.NORMAL
# 玩家拾取后使用的弹幕模式。
@export var shot_pattern: ShotPattern = ShotPattern.NORMAL

@export_group("收藏品效果")
# 同名唯一生效的收藏品使用该 ID 去重；宝石和戒指可打开 stacks_by_copy 让每件都生效。
@export var collectible_effect_id: String = ""
@export var collectible_rarity: CollectibleRarity = CollectibleRarity.COMMON
@export var collectible_stacks_by_copy: bool = false
# 仅限制参与效果计算的份数，不限制玩家实际携带；0 表示所有携带份数均生效。
@export_range(0, 99, 1, "or_greater") var collectible_max_copies: int = 0

@export_group("收藏品兼容性")
# 需要玩家的普通攻击能够生成投射物；近战角色不应获得此类收藏品。
@export var requires_projectile_primary_attack: bool = false
# 需要玩家拥有弹药与换弹机制；无弹药角色不应获得此类收藏品。
@export var requires_ammunition: bool = false

@export_group("收藏品数值")
# 玩家持有时，普通子弹变为穿透弹的概率。
@export_range(0.0, 1.0, 0.01) var bullet_pierce_chance: float = 0.0
# 玩家持有时，普通子弹获得追踪能力的概率。
@export_range(0.0, 1.0, 0.01) var bullet_homing_chance: float = 0.0
# 玩家持有时，普通射击不消耗弹药的概率。
@export_range(0.0, 1.0, 0.01) var ammo_free_shot_chance: float = 0.0
# 所有加算弹匣逐份累加，随后再参与百分比容量乘算。
@export_range(0, 9999, 1, "or_greater") var collectible_ammo_capacity_additive_bonus: int = 0
# 同类百分比容量只取持有中的最高值；2.0 表示提高 200%。
@export_range(0.0, 10.0, 0.05, "or_greater") var collectible_ammo_capacity_bonus_ratio: float = 0.0
# 同类换弹缩短只取持有中的最高值；0.5 表示缩短 50%。
@export_range(0.0, 0.95, 0.05) var collectible_reload_time_reduction: float = 0.0
# 使用技能时保留全部技力的概率。
@export_range(0.0, 1.0, 0.01) var skill_charge_preserve_chance: float = 0.0
# 攻击处于对应状态的敌人时使用两个相互独立的伤害乘区。
@export_range(1.0, 5.0, 0.05, "or_greater") var damage_against_burning_multiplier: float = 1.0
@export_range(1.0, 5.0, 0.05, "or_greater") var damage_against_bleeding_multiplier: float = 1.0
@export_range(0, 999, 1, "or_greater") var collectible_attack_bonus: int = 0
@export_range(0, 999, 1, "or_greater") var collectible_max_health_bonus: int = 0
@export_range(0.0, 999.0, 1.0, "or_greater") var collectible_move_speed_bonus: float = 0.0
@export_range(0.0, 999.0, 0.1, "or_greater") var collectible_attack_speed_bonus: float = 0.0
@export_range(0.0, 999.0, 1.0, "or_greater") var collectible_dash_distance_bonus: float = 0.0
# 每件收藏品的固定减秒至多 0.5；多件不同收藏品仍可按件累加。
@export_range(0.0, 0.5, 0.1) var collectible_dash_cooldown_reduction: float = 0.0
@export_range(0, 999, 1, "or_greater") var collectible_physical_defense_bonus: int = 0
@export_range(0, 100, 1) var collectible_magic_defense_bonus: int = 0
@export_range(0, 999, 1, "or_greater") var collectible_physical_damage_bonus: int = 0
@export_range(0, 999, 1, "or_greater") var collectible_magic_damage_bonus: int = 0
@export_range(0.0, 999.0, 0.05, "or_greater") var collectible_skill_charge_bonus_per_second: float = 0.0
@export_range(0.0, 1.0, 0.01) var base_upgrade_free_chance: float = 0.0
@export_range(0.0, 5.0, 0.05) var incoming_ranged_front_damage_multiplier: float = 1.0
@export_range(0.0, 5.0, 0.05) var incoming_ranged_back_damage_multiplier: float = 1.0
@export_range(0.0, 1.0, 0.01) var incoming_ranged_dodge_chance: float = 0.0
@export_range(0, 99999, 1, "or_greater") var attack_speed_xirang_step: int = 0
@export_range(0.0, 999.0, 0.1, "or_greater") var attack_speed_bonus_per_xirang_step: float = 0.0
@export_range(0, 99999, 1, "or_greater") var defense_xirang_step: int = 0
@export_range(0, 999, 1, "or_greater") var defense_bonus_per_xirang_step: int = 0

@export_group("收藏品周期效果")
@export var periodic_effect_id: String = ""
@export_range(0.0, 999.0, 0.1, "or_greater") var periodic_interval: float = 0.0
@export_range(0.0, 999.0, 1.0, "or_greater") var periodic_radius: float = 0.0
@export_range(0, 9999, 1, "or_greater") var periodic_damage: int = 0
@export_range(0.0, 999.0, 0.05, "or_greater") var periodic_attack_damage_multiplier: float = 0.0
@export_range(1, 16, 1, "or_greater") var periodic_target_count: int = 1
@export_range(0, 9999, 1, "or_greater") var periodic_heal: int = 0
@export_range(0.0, 1.0, 0.05) var periodic_slow_multiplier: float = 1.0
@export_range(0.0, 60.0, 0.1, "or_greater") var periodic_slow_duration: float = 0.0

@export_group("收藏品技能触发")
@export var skill_effect_id: String = ""
@export_range(0.0, 999.0, 1.0, "or_greater") var skill_effect_radius: float = 0.0
@export_range(0.0, 60.0, 0.1, "or_greater") var skill_effect_duration: float = 0.0
@export_range(1.0, 5.0, 0.05, "or_greater") var skill_move_speed_multiplier: float = 1.0

@export_group("收藏品独特设计")
@export var collectible_design_id: String = ""
@export_multiline var collectible_design_note: String = ""
@export var conditional_effect_id: String = ""
@export_range(0.0, 1.0, 0.01) var conditional_health_ratio_threshold: float = 0.0
@export_range(0, 99999, 1, "or_greater") var conditional_xirang_threshold: int = 0
@export_range(0, 999, 1, "or_greater") var conditional_attack_bonus: int = 0
@export_range(0, 999, 1, "or_greater") var conditional_max_health_bonus: int = 0
@export_range(0.0, 999.0, 1.0, "or_greater") var conditional_move_speed_bonus: float = 0.0
@export_range(0, 999, 1, "or_greater") var conditional_physical_defense_bonus: int = 0
@export_range(0, 100, 1) var conditional_magic_defense_bonus: int = 0
@export_range(0, 999, 1, "or_greater") var conditional_physical_damage_bonus: int = 0
@export_range(0, 999, 1, "or_greater") var conditional_magic_damage_bonus: int = 0
@export_range(0.0, 999.0, 0.05, "or_greater") var conditional_skill_charge_bonus_per_second: float = 0.0
@export_range(0.0, 1.0, 0.01) var conditional_bullet_pierce_chance: float = 0.0
@export var trigger_effect_id: String = ""
@export_range(0, 999, 1, "or_greater") var trigger_shot_interval: int = 0
@export_range(0.0, 60.0, 0.1, "or_greater") var trigger_cooldown: float = 0.0
@export_range(0, 9999, 1, "or_greater") var trigger_damage: int = 0
@export_range(0.0, 999.0, 1.0, "or_greater") var trigger_radius: float = 0.0
@export_range(0, 9999, 1, "or_greater") var trigger_heal: int = 0
@export_range(0, 99999, 1, "or_greater") var trigger_xirang: int = 0
@export_range(0.0, 999.0, 0.05, "or_greater") var trigger_skill_charge: float = 0.0
@export_range(0.0, 1.0, 0.05) var trigger_slow_multiplier: float = 1.0
@export_range(0.0, 60.0, 0.1, "or_greater") var trigger_slow_duration: float = 0.0

@export_group("收藏品命中与击杀效果")
@export var on_hit_effect_id: String = ""
@export_range(0.0, 1.0, 0.01) var on_hit_chance: float = 0.0
@export_range(0.0, 60.0, 0.1, "or_greater") var on_hit_cooldown: float = 0.0
@export_range(0, 9999, 1, "or_greater") var on_hit_damage: int = 0
@export_range(0.0, 30.0, 0.1, "or_greater") var on_hit_duration: float = 0.0
@export_range(0.0, 5.0, 0.05, "or_greater") var on_hit_tick_interval: float = 0.5
@export_range(0.0, 999.0, 1.0, "or_greater") var on_hit_radius: float = 0.0
@export_range(0, 9999, 1, "or_greater") var on_hit_heal: int = 0
@export_range(0, 99999, 1, "or_greater") var on_hit_xirang: int = 0
@export_range(0.0, 999.0, 0.05, "or_greater") var on_hit_skill_charge: float = 0.0
@export_range(0.0, 1.0, 0.05) var on_hit_slow_multiplier: float = 1.0
@export_range(-999, 999, 1) var on_hit_physical_defense_modifier: int = 0
@export_range(0.0, 5.0, 0.05, "or_greater") var on_hit_damage_taken_multiplier: float = 1.0
@export_range(0.0, 1.0, 0.01) var on_hit_execute_health_ratio: float = 0.0

@export var kill_effect_id: String = ""
@export_range(0.0, 60.0, 0.1, "or_greater") var kill_cooldown: float = 0.0
@export_range(0, 9999, 1, "or_greater") var kill_heal: int = 0
@export_range(0, 99999, 1, "or_greater") var kill_xirang: int = 0
@export_range(0.0, 999.0, 0.05, "or_greater") var kill_skill_charge: float = 0.0
@export_range(0, 9999, 1, "or_greater") var kill_damage: int = 0
@export_range(0.0, 999.0, 1.0, "or_greater") var kill_radius: float = 0.0
@export_range(0.0, 30.0, 0.1, "or_greater") var kill_duration: float = 0.0
@export_range(0.0, 1.0, 0.05) var kill_slow_multiplier: float = 1.0
@export_range(1.0, 5.0, 0.05, "or_greater") var kill_move_speed_multiplier: float = 1.0


static func get_collectible_rarity_label(rarity: int) -> String:
	match rarity:
		CollectibleRarity.COMMON:
			return "普通"
		CollectibleRarity.RARE:
			return "稀有"
		CollectibleRarity.EPIC:
			return "史诗"
		CollectibleRarity.LEGENDARY:
			return "传说"
		CollectibleRarity.SPECIAL:
			return "特殊"
		_:
			return "普通"


static func get_collectible_rarity_bbcode_color(rarity: int) -> String:
	match rarity:
		CollectibleRarity.COMMON:
			return "#f0e3c2"
		CollectibleRarity.RARE:
			return "#68d8ff"
		CollectibleRarity.EPIC:
			return "#c987ff"
		CollectibleRarity.LEGENDARY:
			return "#ffae32"
		CollectibleRarity.SPECIAL:
			return "#7EE3C4"
		_:
			return "#f0e3c2"


static func is_special_collectible_category(rarity: int) -> bool:
	return rarity == CollectibleRarity.SPECIAL


static func get_collectible_classification_stat_label(rarity: int) -> String:
	return "分类" if is_special_collectible_category(rarity) else "稀有度"
