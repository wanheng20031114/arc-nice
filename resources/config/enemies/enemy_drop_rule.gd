extends Resource
class_name EnemyDropRule


@export var pickup_config: PickupConfig
@export_range(0.0, 1.0, 0.0001) var chance: float = 0.0
@export var required_tags: PackedStringArray = PackedStringArray()


func matches_tags(tags: PackedStringArray) -> bool:
	for required_tag in required_tags:
		if required_tag not in tags:
			return false
	return true
