extends PanelContainer
class_name SimpleCraftingItemSlot

@onready var icon: TextureRect = $Content/Icon
@onready var amount_label: Label = $Content/Amount
@onready var detail_label: Label = $Content/Detail


func configure(
	item: PickupConfig,
	amount: int,
	owned_count: int,
	is_input: bool
) -> void:
	visible = item != null and amount > 0
	if not visible:
		icon.texture = null
		return
	icon.texture = item.icon_texture
	amount_label.text = "×%d" % amount
	detail_label.text = (
		"背包 %d" % owned_count
		if is_input
		else "产出 %d" % amount
	)
	var has_enough := not is_input or owned_count >= amount
	self_modulate = Color.WHITE if has_enough else Color(0.58, 0.58, 0.58, 1)
	tooltip_text = (
		"%s\n需要 %d，背包现有 %d" % [
			item.display_name,
			amount,
			owned_count,
		]
		if is_input
		else "%s\n制造后获得 %d" % [item.display_name, amount]
	)
