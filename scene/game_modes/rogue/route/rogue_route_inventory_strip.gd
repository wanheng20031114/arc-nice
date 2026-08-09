extends Control
class_name RogueRouteInventoryStrip

signal bag_requested

const VISIBLE_SLOT_COUNT := 11
const EMPTY_SLOT_TEXTURE: Texture2D = preload(
	"res://resources/texture/rogue_route/inventory/inventory_slot_empty_ref_v3.png"
)
const SELECTED_SLOT_TEXTURE: Texture2D = preload(
	"res://resources/texture/rogue_route/inventory/inventory_slot_selected_ref_v3.png"
)

@onready var bag_button: Button = $BagButton
@onready var previous_button: Button = $PreviousButton
@onready var next_button: Button = $NextButton
@onready var slot_buttons: Array[Button] = [
	$Slot0,
	$Slot1,
	$Slot2,
	$Slot3,
	$Slot4,
	$Slot5,
	$Slot6,
	$Slot7,
	$Slot8,
	$Slot9,
	$Slot10,
]
@onready var slot_frames: Array[TextureRect] = [
	$Slot0/Frame,
	$Slot1/Frame,
	$Slot2/Frame,
	$Slot3/Frame,
	$Slot4/Frame,
	$Slot5/Frame,
	$Slot6/Frame,
	$Slot7/Frame,
	$Slot8/Frame,
	$Slot9/Frame,
	$Slot10/Frame,
]
@onready var item_icons: Array[TextureRect] = [
	$Slot0/ItemIcon,
	$Slot1/ItemIcon,
	$Slot2/ItemIcon,
	$Slot3/ItemIcon,
	$Slot4/ItemIcon,
	$Slot5/ItemIcon,
	$Slot6/ItemIcon,
	$Slot7/ItemIcon,
	$Slot8/ItemIcon,
	$Slot9/ItemIcon,
	$Slot10/ItemIcon,
]
@onready var quick_use_badges: Array[TextureRect] = [
	$Slot0/QuickUseBadge,
	$Slot1/QuickUseBadge,
	$Slot2/QuickUseBadge,
	$Slot3/QuickUseBadge,
	$Slot4/QuickUseBadge,
	$Slot5/QuickUseBadge,
	$Slot6/QuickUseBadge,
	$Slot7/QuickUseBadge,
	$Slot8/QuickUseBadge,
	$Slot9/QuickUseBadge,
	$Slot10/QuickUseBadge,
]
@onready var stack_labels: Array[Label] = [
	$Slot0/StackCount,
	$Slot1/StackCount,
	$Slot2/StackCount,
	$Slot3/StackCount,
	$Slot4/StackCount,
	$Slot5/StackCount,
	$Slot6/StackCount,
	$Slot7/StackCount,
	$Slot8/StackCount,
	$Slot9/StackCount,
	$Slot10/StackCount,
]

var run_state: RunStateStore = null
## 0 是单人背包；联机时显式记录本地玩家的背包 owner，不能依赖全局活动 peer。
var inventory_owner_peer_id := 0
var first_slot_index := 0
var selected_slot_index := -1


func _ready() -> void:
	bag_button.pressed.connect(_on_bag_button_pressed)
	previous_button.pressed.connect(_on_previous_button_pressed)
	next_button.pressed.connect(_on_next_button_pressed)
	for visual_slot_index in range(slot_buttons.size()):
		slot_buttons[visual_slot_index].pressed.connect(
			_on_slot_button_pressed.bind(visual_slot_index)
		)
	_refresh()


func bind_run_state(
	new_run_state: RunStateStore,
	owner_peer_id: int = 0
) -> void:
	var normalized_owner_peer_id := maxi(owner_peer_id, 0)
	if (
		run_state == new_run_state
		and inventory_owner_peer_id == normalized_owner_peer_id
	):
		_refresh()
		return
	if run_state != null and run_state.inventory_changed.is_connected(
		_on_inventory_changed
	):
		run_state.inventory_changed.disconnect(_on_inventory_changed)
	if run_state != null and run_state.quick_use_binding_changed.is_connected(
		_on_quick_use_binding_changed
	):
		run_state.quick_use_binding_changed.disconnect(
			_on_quick_use_binding_changed
		)
	run_state = new_run_state
	inventory_owner_peer_id = normalized_owner_peer_id
	if run_state != null and not run_state.inventory_changed.is_connected(
		_on_inventory_changed
	):
		run_state.inventory_changed.connect(_on_inventory_changed)
	if run_state != null and not run_state.quick_use_binding_changed.is_connected(
		_on_quick_use_binding_changed
	):
		run_state.quick_use_binding_changed.connect(
			_on_quick_use_binding_changed
		)
	_refresh()


func _exit_tree() -> void:
	if run_state != null and run_state.inventory_changed.is_connected(
		_on_inventory_changed
	):
		run_state.inventory_changed.disconnect(_on_inventory_changed)
	if run_state != null and run_state.quick_use_binding_changed.is_connected(
		_on_quick_use_binding_changed
	):
		run_state.quick_use_binding_changed.disconnect(
			_on_quick_use_binding_changed
		)


func _on_bag_button_pressed() -> void:
	bag_requested.emit()


func _on_previous_button_pressed() -> void:
	first_slot_index = maxi(first_slot_index - 1, 0)
	_refresh()


func _on_next_button_pressed() -> void:
	first_slot_index = mini(first_slot_index + 1, _get_max_first_slot_index())
	_refresh()


func _on_slot_button_pressed(visual_slot_index: int) -> void:
	var inventory_slot_index := first_slot_index + visual_slot_index
	if _get_item(inventory_slot_index) == null:
		selected_slot_index = -1
	else:
		selected_slot_index = inventory_slot_index
	_refresh()


func _on_inventory_changed() -> void:
	_refresh()


func _on_quick_use_binding_changed(
	owner_peer_id: int,
	_config_path: String,
	_preferred_slot_index: int
) -> void:
	if owner_peer_id == inventory_owner_peer_id:
		_refresh()


func _refresh() -> void:
	first_slot_index = clampi(
		first_slot_index,
		0,
		_get_max_first_slot_index()
	)
	if (
		run_state != null
		and selected_slot_index >= 0
		and _get_item(selected_slot_index) == null
	):
		selected_slot_index = -1
	for visual_slot_index in range(VISIBLE_SLOT_COUNT):
		var inventory_slot_index := first_slot_index + visual_slot_index
		var item := _get_item(inventory_slot_index)
		var stack_count := (
			_get_item_count(inventory_slot_index)
			if item != null
			else 0
		)
		slot_frames[visual_slot_index].texture = (
			SELECTED_SLOT_TEXTURE
			if inventory_slot_index == selected_slot_index
			else EMPTY_SLOT_TEXTURE
		)
		item_icons[visual_slot_index].texture = (
			item.icon_texture if item != null else null
		)
		item_icons[visual_slot_index].visible = item != null and item.icon_texture != null
		quick_use_badges[visual_slot_index].visible = (
			item != null
			and run_state != null
			and run_state.is_quick_use_slot(
				inventory_slot_index,
				inventory_owner_peer_id
			)
		)
		stack_labels[visual_slot_index].visible = stack_count > 1
		stack_labels[visual_slot_index].text = str(stack_count) if stack_count > 1 else ""
		slot_buttons[visual_slot_index].tooltip_text = (
			("%s ×%d" % [item.display_name, stack_count])
			if item != null and stack_count > 1
			else item.display_name
			if item != null
			else ""
		)
	previous_button.disabled = first_slot_index <= 0
	next_button.disabled = first_slot_index >= _get_max_first_slot_index()


func _get_item(slot_index: int) -> PickupConfig:
	if run_state == null:
		return null
	if inventory_owner_peer_id > 0:
		return run_state.get_item_for_peer(inventory_owner_peer_id, slot_index)
	return run_state.get_item(slot_index)


func _get_item_count(slot_index: int) -> int:
	if run_state == null:
		return 0
	if inventory_owner_peer_id > 0:
		return run_state.get_item_count_for_peer(
			inventory_owner_peer_id,
			slot_index
		)
	return run_state.get_item_count(slot_index)


func _get_max_first_slot_index() -> int:
	return maxi(RunStateStore.INVENTORY_CAPACITY - VISIBLE_SLOT_COUNT, 0)
