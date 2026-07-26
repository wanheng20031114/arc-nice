extends EnemyConfig
class_name SlimeConfig

enum Variant {
	BASIC,
	GOLDEN,
	FIRE,
	FROST,
	GREEN,
}

@export_group("史莱姆")

@export var variant: Variant = Variant.BASIC
