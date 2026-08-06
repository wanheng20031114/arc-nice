extends SceneTree

const INVENTORY_SLOT_SCENE := preload("res://scene/ui/shared/inventory/inventory_slot.tscn")
const INVENTORY_DRAG_PREVIEW_SCENE := preload(
	"res://scene/ui/shared/inventory/inventory_drag_preview.tscn"
)
const WOOD := preload("res://resources/config/materials/material_wood.tres")
const WATER_COLLECTOR := preload(
	"res://resources/config/buildings/building_water_collector.tres"
)
const HYDRANGEA_RAIN_TOWER := preload(
	"res://resources/config/buildings/building_hydrangea_rain_tower.tres"
)

const CASES: Array[Dictionary] = [
	{
		"item": WOOD,
		"source_size": Vector2(32.0, 32.0),
		"inventory_scale": Vector2.ONE,
	},
	{
		"item": WATER_COLLECTOR,
		"source_size": Vector2(64.0, 64.0),
		"inventory_scale": Vector2(0.5, 0.5),
	},
	{
		"item": HYDRANGEA_RAIN_TOWER,
		"source_size": Vector2(128.0, 128.0),
		"inventory_scale": Vector2(0.25, 0.25),
	},
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := Control.new()
	fixture.name = "InventoryIconScaleSmokeTest"
	root.add_child(fixture)
	current_scene = fixture

	var slot := INVENTORY_SLOT_SCENE.instantiate() as InventorySlot
	var drag_preview := INVENTORY_DRAG_PREVIEW_SCENE.instantiate() as Control
	fixture.add_child(slot)
	fixture.add_child(drag_preview)
	await process_frame

	var drag_icon := drag_preview.get_node("Icon") as Sprite2D
	for test_case in CASES:
		var item := test_case["item"] as PickupConfig
		var expected_source_size := test_case["source_size"] as Vector2
		var expected_scale := test_case["inventory_scale"] as Vector2
		var expected_display_size := Vector2(32.0, 32.0)
		slot.set_item(item)
		drag_preview.call("configure", item, 2)
		_expect(
			item.icon_texture.get_size() == expected_source_size,
			"%s源图必须保持%s。" % [item.display_name, expected_source_size]
		)
		_expect(
			item.get_inventory_icon_scale() == expected_scale,
			"%s背包缩放必须为%s。" % [item.display_name, expected_scale]
		)
		_expect(
			slot.item_icon.scale == expected_scale
			and drag_icon.scale == expected_scale,
			"%s在背包槽与拖拽预览中必须使用相同的独立缩放。" % item.display_name
		)
		_expect(
			item.icon_texture.get_size() * slot.item_icon.scale
			== expected_display_size,
			"%s在背包内必须显示为32×32。" % item.display_name
		)

	_expect(
		WOOD.icon_scale == Vector2(0.625, 0.625),
		"木头的世界掉落缩放必须保持0.625，不能被背包显示规则覆盖。"
	)
	slot.set_item(null)
	drag_preview.call("configure", null, 0)
	_expect(
		slot.item_icon.scale == Vector2.ONE and drag_icon.scale == Vector2.ONE,
		"清空背包槽或拖拽预览时必须重置图标缩放。"
	)

	fixture.queue_free()
	await process_frame
	if failures.is_empty():
		print("Inventory icon scale smoke test passed.")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
