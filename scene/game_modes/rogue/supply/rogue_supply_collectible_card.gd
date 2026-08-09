extends PanelContainer
class_name RogueSupplyCollectibleCard

signal selected(offer_index: int)

@onready var button: Button = $Button
@onready var icon_rect: TextureRect = $Content/Margin/Rows/IconCenter/Icon
@onready var title_label: Label = $Content/Margin/Rows/Title
@onready var rarity_label: Label = $Content/Margin/Rows/Rarity
@onready var description_label: Label = $Content/Margin/Rows/Description

var offer_index := -1
var config_path := ""


func _ready() -> void:
	button.pressed.connect(_on_button_pressed)


func configure(new_offer_index: int, new_config_path: String, enabled: bool) -> void:
	offer_index = new_offer_index
	config_path = new_config_path
	icon_rect.texture = null
	title_label.text = "无效收藏品"
	rarity_label.text = ""
	description_label.text = "该候选已失效，请等待主机同步。"
	button.disabled = true
	button.focus_mode = Control.FOCUS_NONE
	if config_path.is_empty():
		return
	var item := CollectibleRegistry.get_for_path(config_path)
	if item == null:
		return
	icon_rect.texture = item.icon_texture
	title_label.text = item.display_name
	var rarity := int(item.collectible_rarity)
	rarity_label.text = PickupConfig.get_collectible_rarity_label(rarity)
	rarity_label.add_theme_color_override(
		&"font_color",
		Color.from_string(
			PickupConfig.get_collectible_rarity_bbcode_color(rarity),
			Color.WHITE
		)
	)
	description_label.text = item.description
	button.disabled = not enabled
	button.focus_mode = (
		Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
	)


func set_interaction_enabled(enabled: bool) -> void:
	var accepts_input := enabled and not button.disabled
	button.mouse_filter = (
		Control.MOUSE_FILTER_STOP
		if accepts_input
		else Control.MOUSE_FILTER_IGNORE
	)
	button.focus_mode = (
		Control.FOCUS_ALL if accepts_input else Control.FOCUS_NONE
	)
	if not accepts_input and button.has_focus():
		button.release_focus()


func _on_button_pressed() -> void:
	if offer_index >= 0 and not button.disabled:
		selected.emit(offer_index)
