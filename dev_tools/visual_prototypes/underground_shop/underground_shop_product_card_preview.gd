extends TextureButton

signal offer_selected(card: TextureButton)

@export var item_texture: Texture2D
@export var display_name := "商品"
@export_multiline var description := "视觉拼装用商品说明。"
@export_range(0, 999, 1) var price := 0

@onready var item_icon: TextureRect = %ItemIcon
@onready var price_label: Label = %PriceLabel


func _ready() -> void:
	item_icon.texture = item_texture
	price_label.text = str(price)
	tooltip_text = display_name
	pressed.connect(_on_pressed)


func get_offer_payload() -> Dictionary:
	return {
		"texture": item_texture,
		"display_name": display_name,
		"description": description,
		"price": price,
	}


func _on_pressed() -> void:
	offer_selected.emit(self)
