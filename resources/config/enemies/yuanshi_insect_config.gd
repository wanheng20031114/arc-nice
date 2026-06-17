extends EnemyConfig
class_name YuanshiInsectConfig

enum Variant {
	BASIC,
	SHELLED,
	FAST_SMALL,
	BOMBER,
	PURPLE_BOMBER,
	GREEN_SHELLED,
	FIRE_RANGED,
	GUARDIAN,
}

@export_group("原石虫")

@export var variant: Variant = Variant.BASIC
