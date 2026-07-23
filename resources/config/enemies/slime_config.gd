extends EnemyConfig
class_name SlimeConfig

enum Variant {
	BASIC,
}

@export_group("史莱姆")

@export var variant: Variant = Variant.BASIC
