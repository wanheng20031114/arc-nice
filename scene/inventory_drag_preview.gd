extends Control


func configure(item: PickupConfig, stack_count: int) -> void:
	var icon := $Icon as TextureRect
	var count_label := $StackCount as Label
	icon.texture = item.icon_texture if item != null else null
	count_label.visible = item != null and stack_count > 1
	count_label.text = str(maxi(stack_count, 0))
