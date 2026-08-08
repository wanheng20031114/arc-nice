extends Control

signal preview_purchase_requested(offer_index: int)
signal exit_requested

const PRODUCT_COUNT := 10

@onready var top_bar: RogueRouteTopBar = %TopBar
@onready var detail_overlay: Control = %DetailOverlay
@onready var detail_icon: TextureRect = %DetailIcon
@onready var detail_name: Label = %DetailName
@onready var detail_description: Label = %DetailDescription
@onready var detail_price: Label = %DetailPrice
@onready var product_grid: GridContainer = %ProductGrid
@onready var exit_button: TextureButton = %ExitButton
@onready var preview_purchase_button: TextureButton = %PreviewPurchaseButton

@onready var product_cards: Array[TextureButton] = [
	%Product00,
	%Product01,
	%Product02,
	%Product03,
	%Product04,
	%Product05,
	%Product06,
	%Product07,
	%Product08,
	%Product09,
]

var _selected_offer_index := -1


func _ready() -> void:
	assert(product_cards.size() == PRODUCT_COUNT)
	assert(product_grid.get_child_count() == PRODUCT_COUNT)
	top_bar.set_floor_title("浅层矿洞")
	top_bar.set_core_health(100, 100)
	top_bar.set_action_points(12)
	top_bar.set_shared_light_stone(128)
	top_bar.set_personal_xirang(46)
	detail_overlay.hide()
	product_cards[0].grab_focus()


func open_offer(index: int) -> void:
	if index < 0 or index >= product_cards.size():
		return
	_on_offer_selected(product_cards[index])


func close_detail() -> void:
	detail_overlay.hide()
	_set_background_focus_enabled(true)
	if _selected_offer_index >= 0 and _selected_offer_index < product_cards.size():
		product_cards[_selected_offer_index].grab_focus()


func get_product_cards() -> Array[TextureButton]:
	return product_cards


func _on_offer_selected(card: TextureButton) -> void:
	var offer_index := product_cards.find(card)
	if offer_index < 0:
		return
	_selected_offer_index = offer_index
	var payload: Dictionary = card.call("get_offer_payload")
	detail_icon.texture = payload.get("texture") as Texture2D
	detail_name.text = str(payload.get("display_name", "商品"))
	detail_description.text = str(payload.get("description", ""))
	detail_price.text = str(int(payload.get("price", 0)))
	_set_background_focus_enabled(false)
	detail_overlay.show()
	preview_purchase_button.grab_focus()


func _on_preview_purchase_pressed() -> void:
	# 视觉原型只暴露所选单件商品，不执行购买或任何经济写入。
	if _selected_offer_index >= 0:
		preview_purchase_requested.emit(_selected_offer_index)


func _on_detail_cancel_pressed() -> void:
	close_detail()


func _on_exit_pressed() -> void:
	# 视觉原型只提供可测试的退出边界，不接入正式场景切换。
	exit_requested.emit()


func _set_background_focus_enabled(enabled: bool) -> void:
	var focus_mode := Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
	for card in product_cards:
		card.focus_mode = focus_mode
	exit_button.focus_mode = focus_mode
