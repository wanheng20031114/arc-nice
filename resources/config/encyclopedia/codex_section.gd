extends RefCounted
class_name CodexSection

enum {
	ENEMY,
	COLLECTIBLE,
	BUILDING,
}

const ALL: Array[int] = [ENEMY, COLLECTIBLE, BUILDING]


static func is_valid(section: int) -> bool:
	return section in ALL


static func get_label(section: int) -> String:
	match section:
		ENEMY:
			return "敌人"
		COLLECTIBLE:
			return "收藏品"
		BUILDING:
			return "建筑物"
		_:
			return "未知"


static func get_key(section: int) -> StringName:
	match section:
		ENEMY:
			return &"enemy"
		COLLECTIBLE:
			return &"collectible"
		BUILDING:
			return &"building"
		_:
			return &""
