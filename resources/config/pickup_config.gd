extends Resource
class_name PickupConfig

enum PickupType {
	SPEED,
	RAPID,
	SPIRAL,
	TENPURA,
	HEALTH,
	
}

enum PlayerFormMode {
	NORMAL,
	ARMED,
	
}

enum ShotPattern {
	NORMAL,
	SPIRAL,
	
}

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
