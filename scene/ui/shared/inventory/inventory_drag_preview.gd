extends Control


func configure(item: PickupConfig, stack_count: int) -> void:
	var icon := $Icon as Sprite2D
	var count_label := $StackCount as Label
	icon.texture = item.icon_texture if item != null else null
	icon.scale = item.get_inventory_icon_scale() if item != null else Vector2.ONE
	count_label.visible = item != null and stack_count > 1
	count_label.text = str(maxi(stack_count, 0))
