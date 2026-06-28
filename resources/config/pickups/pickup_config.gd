extends Resource
class_name PickupConfig

enum PickupType {
	SPEED,
	RAPID,
	SPIRAL,
	TENPURA,
	HEALTH,
	COLLECTIBLE,
	
}

enum PlayerFormMode {
	NORMAL,
	ARMED,
	
}

enum ShotPattern {
	NORMAL,
	SPIRAL,
	
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

const PERIODIC_EFFECT_THUNDER := "thunder"
const PERIODIC_EFFECT_FROST := "frost"
const PERIODIC_EFFECT_HEAL := "heal"
const PERIODIC_EFFECT_ARCHER := "archer"

const SKILL_EFFECT_MOON_SHIELD := "moon_shield"
const SKILL_EFFECT_SWIFT := "swift"

@export_group("基础信息")
@export var pickup_type:PickupType = PickupType.SPEED
@export var display_name : String = "移速道具"
@export_range(0.0 , 1000.0 , 0.1, "or_greater") var drop_weight:float = 1.0
@export_multiline var description: String = ""
@export var can_store_in_inventory: bool = false
@export var stackable: bool = false

@export_group("显示资源")
@export var icon_texture : Texture2D
@export var icon_scale: Vector2 = Vector2.ONE


@export_group("Buff 效果")
# 拾取后回复的生命值，0 表示该道具不回复生命。
@export_range(0, 99, 1, "or_greater") var heal_amount: int = 0
# 道具效果持续时间，单位为秒。
@export_range(0.0, 120.0, 0.1, "or_greater") var duration: float = 5.0
# 玩家移速倍率，1.0 表示不改变，1.2 表示提升 20%。
@export_range(0.1, 5.0, 0.05, "or_greater") var move_speed_multiplier: float = 1.0
# 玩家射速倍率，1.0 表示不改变，1.5 表示射速提升 50%。
@export_range(0.1, 5.0, 0.05, "or_greater") var fire_rate_multiplier: float = 1.0


@export_group("形态与弹幕")
# 玩家拾取后切换到的形态模式。
@export var player_form_mode: PlayerFormMode = PlayerFormMode.NORMAL
# 玩家拾取后使用的弹幕模式。
@export var shot_pattern: ShotPattern = ShotPattern.NORMAL

@export_group("收藏品效果")
# 同名唯一生效的收藏品使用该 ID 去重；宝石和戒指可打开 stacks_by_copy 让每件都生效。
@export var collectible_effect_id: String = ""
@export var collectible_stacks_by_copy: bool = false
# 玩家持有时，普通子弹变为穿透弹的概率。
@export_range(0.0, 1.0, 0.01) var bullet_pierce_chance: float = 0.0
@export_range(0, 999, 1, "or_greater") var collectible_attack_bonus: int = 0
@export_range(0, 999, 1, "or_greater") var collectible_max_health_bonus: int = 0
@export_range(0.0, 999.0, 1.0, "or_greater") var collectible_move_speed_bonus: float = 0.0
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
