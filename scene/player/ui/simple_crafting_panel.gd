extends Control
class_name SimpleCraftingPanel

signal craft_requested(recipe_id: StringName)

@onready var recipe_name: Label = $Background/CraftArea/Margin/Content/RecipeName
@onready var recipe_summary: RichTextLabel = $Background/CraftArea/Margin/Content/RecipeSummary
@onready var input_slots: Array[SimpleCraftingItemSlot] = [
	$Background/CraftArea/Margin/Content/InputSlots/InputSlot0,
	$Background/CraftArea/Margin/Content/InputSlots/InputSlot1,
	$Background/CraftArea/Margin/Content/InputSlots/InputSlot2,
]
@onready var output_slots: Array[SimpleCraftingItemSlot] = [
	$Background/CraftArea/Margin/Content/OutputSlots/OutputSlot0,
	$Background/CraftArea/Margin/Content/OutputSlots/OutputSlot1,
	$Background/CraftArea/Margin/Content/OutputSlots/OutputSlot2,
]
@onready var craft_button: Button = $Background/CraftArea/Margin/Content/CraftButton
@onready var status_label: Label = $Background/CraftArea/Margin/Content/Status
@onready var recipe_buttons: Array[Button] = [
	$Background/RecipeArea/Margin/Content/Recipe0,
	$Background/RecipeArea/Margin/Content/Recipe1,
	$Background/RecipeArea/Margin/Content/Recipe2,
	$Background/RecipeArea/Margin/Content/Recipe3,
	$Background/RecipeArea/Margin/Content/Recipe4,
	$Background/RecipeArea/Margin/Content/Recipe5,
]
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore

var recipes: Array[ProductionRecipe] = []
var selected_recipe_id: StringName = &""
var request_pending := false


func _ready() -> void:
	for button_index in recipe_buttons.size():
		recipe_buttons[button_index].pressed.connect(
			_on_recipe_pressed.bind(button_index)
		)
	craft_button.pressed.connect(_on_craft_pressed)
	_reload_recipes()
	refresh()


func set_panel_active(active: bool) -> void:
	visible = active
	if active:
		refresh()


func refresh() -> void:
	if recipes.is_empty():
		_reload_recipes()
	_refresh_recipe_buttons()
	var recipe := get_selected_recipe()
	_refresh_recipe_detail(recipe)
	_refresh_crafting_state(recipe)


func show_result(recipe_id: StringName, result: StringName) -> void:
	request_pending = false
	if SimpleCraftingRegistry.get_recipe(recipe_id) != null:
		selected_recipe_id = recipe_id
	_refresh_recipe_buttons()
	match result:
		RunStateStore.CRAFT_RESULT_SUCCESS:
			status_label.text = "制造完成，产物已放入背包"
		RunStateStore.CRAFT_RESULT_MISSING_INPUT:
			status_label.text = "背包材料不足"
		RunStateStore.CRAFT_RESULT_INVENTORY_FULL:
			status_label.text = "背包剩余空间不足"
		RunStateStore.CRAFT_RESULT_STALE_REVISION:
			status_label.text = "背包内容已变化，请重试"
		&"rate_limited":
			status_label.text = "操作过快，请稍后再试"
		&"invalid_player":
			status_label.text = "当前玩家状态无法制造"
		&"stale_request":
			status_label.text = "该制造请求已经处理"
		_:
			status_label.text = "配方无效，无法制造"
	_refresh_recipe_detail(get_selected_recipe())
	_refresh_button_enabled_state(get_selected_recipe())


func get_selected_recipe() -> ProductionRecipe:
	return SimpleCraftingRegistry.get_recipe(selected_recipe_id)


func _reload_recipes() -> void:
	recipes = SimpleCraftingRegistry.get_all_recipes()
	if recipes.is_empty():
		selected_recipe_id = &""
		return
	if SimpleCraftingRegistry.get_recipe(selected_recipe_id) == null:
		selected_recipe_id = recipes[0].recipe_id


func _refresh_recipe_buttons() -> void:
	for button_index in recipe_buttons.size():
		var button := recipe_buttons[button_index]
		var has_recipe := button_index < recipes.size()
		button.visible = has_recipe
		if not has_recipe:
			continue
		var recipe := recipes[button_index]
		button.text = recipe.display_name
		button.icon = (
			recipe.output_items[0].icon_texture
			if not recipe.output_items.is_empty()
			else null
		)
		button.button_pressed = recipe.recipe_id == selected_recipe_id
		button.disabled = request_pending


func _refresh_recipe_detail(recipe: ProductionRecipe) -> void:
	for slot in input_slots:
		slot.hide()
	for slot in output_slots:
		slot.hide()
	if recipe == null:
		recipe_name.text = "暂无简易配方"
		recipe_summary.text = "简易制造只使用背包材料，产物也会直接返回背包。"
		return
	recipe_name.text = recipe.display_name
	recipe_summary.text = "消耗 %s\n获得 %s" % [
		recipe.get_input_summary(),
		recipe.get_output_summary(),
	]
	for input_index in mini(recipe.input_items.size(), input_slots.size()):
		var item := recipe.input_items[input_index]
		input_slots[input_index].configure(
			item,
			recipe.input_amounts[input_index],
			run_state.get_inventory_item_total(item),
			true
		)
	for output_index in mini(recipe.output_items.size(), output_slots.size()):
		var item := recipe.output_items[output_index]
		output_slots[output_index].configure(
			item,
			recipe.output_amounts[output_index],
			run_state.get_inventory_item_total(item),
			false
		)


func _refresh_crafting_state(recipe: ProductionRecipe) -> void:
	if request_pending:
		status_label.text = "等待主机确认制造结果…"
		craft_button.disabled = true
		return
	var result := run_state.get_simple_crafting_result(recipe)
	match result:
		RunStateStore.CRAFT_RESULT_SUCCESS:
			status_label.text = "材料充足，可立即制造"
		RunStateStore.CRAFT_RESULT_MISSING_INPUT:
			status_label.text = "背包材料不足"
		RunStateStore.CRAFT_RESULT_INVENTORY_FULL:
			status_label.text = "背包剩余空间不足"
		_:
			status_label.text = "暂无可用配方"
	_refresh_button_enabled_state(recipe)


func _refresh_button_enabled_state(recipe: ProductionRecipe) -> void:
	craft_button.disabled = (
		request_pending
		or recipe == null
		or run_state.get_simple_crafting_result(recipe)
		!= RunStateStore.CRAFT_RESULT_SUCCESS
	)


func _on_recipe_pressed(button_index: int) -> void:
	if button_index < 0 or button_index >= recipes.size():
		return
	selected_recipe_id = recipes[button_index].recipe_id
	request_pending = false
	refresh()


func _on_craft_pressed() -> void:
	var recipe := get_selected_recipe()
	if (
		recipe == null
		or request_pending
		or run_state.get_simple_crafting_result(recipe)
		!= RunStateStore.CRAFT_RESULT_SUCCESS
	):
		_refresh_crafting_state(recipe)
		return
	request_pending = true
	_refresh_recipe_buttons()
	status_label.text = "正在制造…"
	craft_button.disabled = true
	craft_requested.emit(recipe.recipe_id)
