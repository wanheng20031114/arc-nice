extends PlantDefense
class_name CardinalConnectedPlant

const MIN_CONNECTION_MASK := 0
const MAX_CONNECTION_MASK := 15
const CONNECTION_UP := 1
const CONNECTION_RIGHT := 2
const CONNECTION_DOWN := 4
const CONNECTION_LEFT := 8

@onready var cardinal_sprite: Sprite2D = $Sprite2D
@onready var connector_right: Sprite2D = $ConnectorRight
@onready var connector_down: Sprite2D = $ConnectorDown

var _cardinal_connection_mask := MIN_CONNECTION_MASK


func set_cardinal_connection_mask(mask: int) -> void:
	if mask < MIN_CONNECTION_MASK or mask > MAX_CONNECTION_MASK:
		push_error("CardinalConnectedPlant connection mask must be in [0, 15].")
		return
	if cardinal_sprite == null:
		push_error("CardinalConnectedPlant requires a Sprite2D child named Sprite2D.")
		return
	if connector_right == null or connector_down == null:
		push_error(
			"CardinalConnectedPlant requires ConnectorRight and ConnectorDown sprites."
		)
		return
	if _cardinal_connection_mask == mask:
		return
	_cardinal_connection_mask = mask
	# Each undirected edge is drawn exactly once: the left fence owns RIGHT and
	# the upper fence owns DOWN. LEFT/UP remain in the mask for topology logic,
	# while their visible pieces are owned by the corresponding neighbor.
	connector_right.visible = (mask & CONNECTION_RIGHT) != 0
	connector_down.visible = (mask & CONNECTION_DOWN) != 0


func get_cardinal_connection_mask() -> int:
	return _cardinal_connection_mask


func _on_removal_started(_mode: RemovalMode) -> void:
	_cardinal_connection_mask = MIN_CONNECTION_MASK
	if connector_right != null:
		connector_right.hide()
	if connector_down != null:
		connector_down.hide()
