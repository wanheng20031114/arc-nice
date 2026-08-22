extends PanelContainer
class_name SimpleCraftingItemSlot

@onready var icon: TextureRect = $Content/Icon
@onready var amount_label: Label = $Content/Amount
@onready var detail_label: Label = $Content/Detail


func configure_input(
	item: PickupConfig,
	required_amount: int,
	personal_count: int,
	shared_count: int
) -> void:
	if not _configure_item(item, required_amount):
		return
	var available_count := maxi(personal_count, 0) + maxi(shared_count, 0)
	detail_label.text = "可用 %d" % available_count
	var has_enough := available_count >= required_amount
	self_modulate = Color.WHITE if has_enough else Color(0.58, 0.58, 0.58, 1)
	tooltip_text = "%s\n需要 %d\n背包 %d\n仓库 %d\n合计 %d" % [
		item.display_name,
		required_amount,
		maxi(personal_count, 0),
		maxi(shared_count, 0),
		available_count,
	]


func configure_output(
	item: PickupConfig,
	output_amount: int,
	personal_count: int
) -> void:
	if not _configure_item(item, output_amount):
		return
	detail_label.text = "背包 %d" % maxi(personal_count, 0)
	self_modulate = Color.WHITE
	tooltip_text = "%s\n制造后获得 %d\n背包现有 %d" % [
		item.display_name,
		output_amount,
		maxi(personal_count, 0),
	]


func _configure_item(item: PickupConfig, amount: int) -> bool:
	visible = item != null and amount > 0
	if not visible:
		icon.texture = null
		tooltip_text = ""
		self_modulate = Color.WHITE
		return false
	icon.texture = item.icon_texture
	amount_label.text = "×%d" % amount
	return true
