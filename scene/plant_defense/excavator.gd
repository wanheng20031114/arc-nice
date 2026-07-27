extends ProductionProgressBorderBuilding
class_name Excavator

const DIRT_BLOCK: PickupConfig = preload(
	"res://resources/config/materials/material_dirt_block.tres"
)
const PLANK: PickupConfig = preload(
	"res://resources/config/materials/material_plank.tres"
)
const HEALTH_POTION: PickupConfig = preload(
	"res://resources/config/pickups/pickup_health.tres"
)

const OUTPUT_DIRT := &"dirt"
const OUTPUT_PLANK := &"plank"
const OUTPUT_HEALTH_POTION := &"health_potion"
const OUTPUT_COMMON_COLLECTIBLE := &"common_collectible"
const OUTPUT_NON_COMMON_COLLECTIBLE := &"non_common_collectible"

var loot_rng := RandomNumberGenerator.new()


func _on_setup_completed() -> void:
	super._on_setup_completed()
	if not is_multiplayer_proxy:
		var identity := int(get_meta(&"net_id", get_instance_id()))
		loot_rng.seed = int(Time.get_ticks_usec()) ^ (identity * 0x45D9F3B)


static func get_output_category_for_roll(roll: int) -> StringName:
	if roll < 0 or roll > 99:
		return &""
	if roll < 50:
		return OUTPUT_DIRT
	if roll < 75:
		return OUTPUT_PLANK
	if roll < 95:
		return OUTPUT_HEALTH_POTION
	if roll < 99:
		return OUTPUT_COMMON_COLLECTIBLE
	return OUTPUT_NON_COMMON_COLLECTIBLE


func _select_local_output(_recipe: ProductionRecipe) -> Dictionary:
	var category := get_output_category_for_roll(loot_rng.randi_range(0, 99))
	var item: PickupConfig = null
	match category:
		OUTPUT_DIRT:
			item = DIRT_BLOCK
		OUTPUT_PLANK:
			item = PLANK
		OUTPUT_HEALTH_POTION:
			item = HEALTH_POTION
		OUTPUT_COMMON_COLLECTIBLE:
			item = _pick_collectible(
				CollectibleRegistry.get_by_rarity(
					PickupConfig.CollectibleRarity.COMMON
				)
			)
		OUTPUT_NON_COMMON_COLLECTIBLE:
			item = _pick_collectible(
				CollectibleRegistry.get_excluding_rarity(
					PickupConfig.CollectibleRarity.COMMON
				)
			)
	if item == null:
		push_error("Excavator could not resolve its authoritative output roll.")
		return {}
	return {"item": item, "count": 1}


func _pick_collectible(pool: Array[PickupConfig]) -> PickupConfig:
	if pool.is_empty():
		return null
	return pool[loot_rng.randi_range(0, pool.size() - 1)]
