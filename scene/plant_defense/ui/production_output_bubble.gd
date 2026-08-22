extends Node2D
class_name ProductionOutputBubble

const MAX_OUTPUT_SLOTS := ProductionRecipe.MAX_OUTPUT_ITEMS
const OUTPUT_SLOT_SIZE := 32.0
const OUTPUT_SLOT_SEPARATION := 4.0
const PANEL_HORIZONTAL_MARGIN := 12.0
const PANEL_HEIGHT := 44.0

## These two StyleBoxFlat resources are selected as immutable style presets.
## Runtime state never changes their colors or dimensions.
@export var working_panel_style: StyleBoxFlat
@export var stopped_panel_style: StyleBoxFlat

@onready var _bubble_panel: PanelContainer = $BubblePanel
@onready var _tail_border: Polygon2D = $TailBorder
@onready var _tail_fill: Polygon2D = $TailFill
@onready var _output_slots: Array[Control] = [
	$BubblePanel/ContentMargin/OutputRow/OutputSlot1,
	$BubblePanel/ContentMargin/OutputRow/OutputSlot2,
	$BubblePanel/ContentMargin/OutputRow/OutputSlot3,
]
@onready var _output_icons: Array[Sprite2D] = [
	$BubblePanel/ContentMargin/OutputRow/OutputSlot1/ProductIcon,
	$BubblePanel/ContentMargin/OutputRow/OutputSlot2/ProductIcon,
	$BubblePanel/ContentMargin/OutputRow/OutputSlot3/ProductIcon,
]

var _recipe: ProductionRecipe
var _requested_visible := false
var _is_working := false


func _ready() -> void:
	_apply_state()


## Applies the complete local presentation state in one call.
## ProductionBuilding remains the owner of recipe and production state.
func refresh(
	recipe: ProductionRecipe,
	requested_visible: bool,
	is_working: bool
) -> void:
	_recipe = recipe
	_requested_visible = requested_visible
	_is_working = is_working
	_refresh_if_ready()


func set_recipe(recipe: ProductionRecipe) -> void:
	_recipe = recipe
	_refresh_if_ready()


func set_requested_visible(requested_visible: bool) -> void:
	_requested_visible = requested_visible
	_refresh_if_ready()


func set_is_working(is_working: bool) -> void:
	_is_working = is_working
	_refresh_if_ready()


func _refresh_if_ready() -> void:
	if is_node_ready():
		_apply_state()


func _apply_state() -> void:
	_apply_working_style()
	var visible_output_count := _apply_recipe_icons()
	_apply_compact_panel_size(visible_output_count)
	visible = _requested_visible and visible_output_count > 0


func _apply_working_style() -> void:
	var panel_style := working_panel_style if _is_working else stopped_panel_style
	assert(panel_style != null, "ProductionOutputBubble requires both panel styles")
	_bubble_panel.add_theme_stylebox_override(&"panel", panel_style)
	_tail_border.color = panel_style.border_color
	_tail_fill.color = panel_style.bg_color


func _apply_recipe_icons() -> int:
	for slot_index in MAX_OUTPUT_SLOTS:
		_output_slots[slot_index].visible = false
		_output_icons[slot_index].texture = null
		_output_icons[slot_index].scale = Vector2.ONE

	if _recipe == null or not _recipe.is_valid():
		return 0

	var visible_output_count := 0
	var output_count := mini(_recipe.output_items.size(), MAX_OUTPUT_SLOTS)
	for output_index in output_count:
		var output_item: PickupConfig = _recipe.output_items[output_index]
		if output_item == null or output_item.icon_texture == null:
			continue
		_output_slots[output_index].visible = true
		_output_icons[output_index].texture = output_item.icon_texture
		_output_icons[output_index].scale = output_item.get_inventory_icon_scale()
		visible_output_count += 1
	return visible_output_count


func _apply_compact_panel_size(visible_output_count: int) -> void:
	var safe_count := clampi(visible_output_count, 1, MAX_OUTPUT_SLOTS)
	var panel_width := (
		PANEL_HORIZONTAL_MARGIN
		+ OUTPUT_SLOT_SIZE * safe_count
		+ OUTPUT_SLOT_SEPARATION * maxi(safe_count - 1, 0)
	)
	_bubble_panel.custom_minimum_size = Vector2(panel_width, PANEL_HEIGHT)
	_bubble_panel.offset_left = -panel_width * 0.5
	_bubble_panel.offset_right = panel_width * 0.5
