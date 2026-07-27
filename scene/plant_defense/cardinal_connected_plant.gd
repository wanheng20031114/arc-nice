extends PlantDefense
class_name CardinalConnectedPlant

const MIN_CONNECTION_MASK := 0
const MAX_CONNECTION_MASK := 15
const CONNECTION_UP := 1
const CONNECTION_RIGHT := 2
const CONNECTION_DOWN := 4
const CONNECTION_LEFT := 8

@onready var cardinal_sprite: Sprite2D = $Sprite2D

var _cardinal_connection_mask := MIN_CONNECTION_MASK


func set_cardinal_connection_mask(mask: int) -> void:
	if mask < MIN_CONNECTION_MASK or mask > MAX_CONNECTION_MASK:
		push_error("CardinalConnectedPlant connection mask must be in [0, 15].")
		return
	if cardinal_sprite == null:
		push_error("CardinalConnectedPlant requires a Sprite2D child named Sprite2D.")
		return
	if cardinal_sprite.hframes * cardinal_sprite.vframes <= MAX_CONNECTION_MASK:
		push_error("CardinalConnectedPlant Sprite2D requires at least 16 atlas frames.")
		return
	_cardinal_connection_mask = mask
	cardinal_sprite.frame = mask


func get_cardinal_connection_mask() -> int:
	return _cardinal_connection_mask
