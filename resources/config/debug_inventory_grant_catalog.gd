extends RefCounted
class_name DebugInventoryGrantCatalog

## F10 调试目录允许授予的背包物品白名单。
## 收藏品继续由 CollectibleRegistry 定义；资源材料从多人运行时内容目录
## 自动发现，只接受可进入背包的 item.materials.* 项。
const MATERIAL_ID_PREFIX := "item.materials."
const COLLECTIBLE_ID_PREFIX := "item.collectibles."


static func get_collectibles() -> Array[PickupConfig]:
	var collectibles: Array[PickupConfig] = []
	for item in CollectibleRegistry.get_all():
		var item_id := RuntimeContentCatalog.get_pickup_id_for_path(
			item.resource_path
		)
		if item_id.begins_with(COLLECTIBLE_ID_PREFIX):
			collectibles.append(item)
	return collectibles


static func get_materials() -> Array[PickupConfig]:
	var material_ids: Array[String] = []
	for item_id_variant in RuntimeContentCatalog.PICKUP_ID_TO_PATH:
		var item_id := String(item_id_variant)
		if item_id.begins_with(MATERIAL_ID_PREFIX):
			material_ids.append(item_id)
	material_ids.sort()

	var materials: Array[PickupConfig] = []
	for item_id in material_ids:
		var config_path := RuntimeContentCatalog.get_pickup_path_for_id(item_id)
		var item := RuntimeContentCatalog.load_pickup_config_from_path(config_path)
		if _is_grantable_material(item):
			materials.append(item)
	return materials


static func get_for_path(config_path: String) -> PickupConfig:
	if config_path.is_empty():
		return null
	var item_id := RuntimeContentCatalog.get_pickup_id_for_path(config_path)
	if item_id.begins_with(COLLECTIBLE_ID_PREFIX):
		return CollectibleRegistry.get_for_path(config_path)
	if not item_id.begins_with(MATERIAL_ID_PREFIX):
		return null
	var item := RuntimeContentCatalog.load_pickup_config_from_path(config_path)
	return item if _is_grantable_material(item) else null


static func _is_grantable_material(item: PickupConfig) -> bool:
	return (
		item != null
		and item.pickup_type == PickupConfig.PickupType.MATERIAL
		and item.can_store_in_inventory
	)
