extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_coordinator.tscn"
)
const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const PANEL_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_building_panel.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const WHITE_CRYSTAL := preload(
	"res://resources/config/materials/material_white_crystal.tres"
)
const CAPOO_BLUE_CRYSTAL := preload(
	"res://resources/config/materials/material_capoo_blue_crystal.tres"
)
const WHITE_CRYSTAL_POWDER := preload(
	"res://resources/config/materials/material_white_crystal_powder.tres"
)
const CAPOO_BLUE_CRYSTAL_POWDER := preload(
	"res://resources/config/materials/material_capoo_blue_crystal_powder.tres"
)

const STONE_MILL_TEXTURE_PATH := (
	"res://resources/texture/plant_defense/stone_mill/stone_mill.png"
)
const WHITE_POWDER_TEXTURE_PATH := (
	"res://resources/texture/materials/white_crystal_powder.png"
)
const BLUE_POWDER_TEXTURE_PATH := (
	"res://resources/texture/materials/capoo_blue_crystal_powder.png"
)

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test_root := Node.new()
	test_root.name = "StoneMillSmokeTest"
	root.add_child(test_root)
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)

	var coordinator := COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	var first_warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var second_warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var panel := PANEL_SCENE.instantiate() as ProductionBuildingPanel
	var player := PLAYER_SCENE.instantiate() as Player
	var config := PlantDefenseRegistry.get_config(&"stone_mill")
	var mill := (
		config.plant_scene.instantiate() as ProductionBuilding
		if config != null
		else null
	)
	test_root.add_child(coordinator)
	test_root.add_child(first_warehouse)
	test_root.add_child(second_warehouse)
	if mill != null:
		test_root.add_child(mill)
	test_root.add_child(panel)
	test_root.add_child(player)
	await process_frame
	coordinator.production_tick_timer.stop()

	_expect(config != null and config.is_valid(), "石磨台配置必须有效。")
	_expect(
		config != null
		and config.plant_scene != null
		and config.plant_scene.resource_path
		== "res://scene/plant_defense/stone_mill.tscn"
		and config.supports_multiplayer,
		"石磨台必须注册独立场景并允许进入多人建造与生产网络。"
	)
	_expect(
		config != null
		and config.max_health == 2000
		and config.physical_defense == 5
		and config.magic_defense == 0
		and config.footprint_size == Vector2i.ONE,
		"石磨台必须为2000生命、5物防、0法防且只占一格。"
	)
	_expect(
		mill != null
		and mill.get_script() != null
		and mill.get_script().resource_path
		== "res://scene/plant_defense/stone_mill.gd",
		"石磨台场景根节点必须使用独立脚本并继承公共生产建筑。"
	)
	if mill == null or config == null:
		_finish(test_root)
		return

	var warehouse_config := PlantDefenseRegistry.get_config(&"oak_warehouse")
	first_warehouse.setup(warehouse_config, null, [Vector2i.ZERO])
	second_warehouse.setup(warehouse_config, null, [Vector2i(2, 0)])
	mill.setup(config, null, [Vector2i.ONE])
	coordinator.register_plant(first_warehouse)
	coordinator.register_plant(second_warehouse)
	coordinator.register_plant(mill)
	mill.set_shared_production_panel(panel)

	_test_native_scene_contract(mill)
	_test_recipe_contract(mill)
	await _test_panel_and_interaction(mill, panel, player)
	_test_pixel_assets(mill)

	_test_shared_storage_transaction(
		mill,
		coordinator,
		first_warehouse,
		second_warehouse,
		&"white_crystal_to_powder",
		WHITE_CRYSTAL,
		WHITE_CRYSTAL_POWDER,
		"白晶研磨"
	)
	_test_shared_storage_transaction(
		mill,
		coordinator,
		first_warehouse,
		second_warehouse,
		&"capoo_blue_crystal_to_powder",
		CAPOO_BLUE_CRYSTAL,
		CAPOO_BLUE_CRYSTAL_POWDER,
		"蓝晶研磨"
	)
	_test_multiplayer_recipe_authority(mill)

	_finish(test_root)


func _test_native_scene_contract(mill: ProductionBuilding) -> void:
	_expect(
		mill.max_health == 2000
		and mill.current_health == 2000
		and mill.physical_defense == 5
		and mill.magic_defense == 0
		and mill.is_operational,
		"石磨台setup后必须落实2000生命、5物防、0法防并立即进入可用状态。"
	)
	_expect(
		mill.has_node("MainSprite")
		and mill.get_node("MainSprite") is Sprite2D
		and mill.has_node("ProductionBorder")
		and mill.get_node("ProductionBorder") is DayNightProgressBorder
		and mill.has_node("CollisionShape2D")
		and mill.get_node("CollisionShape2D") is CollisionShape2D
		and mill.has_node("PlayerCoreBody/CollisionShape2D")
		and mill.get_node("PlayerCoreBody") is StaticBody2D
		and mill.has_node("InteractionArea/CollisionShape2D")
		and mill.get_node("InteractionArea") is Area2D
		and mill.has_node(
			"InteractionPrompt/PromptMargin/PromptRow/Keycap/KeyLabel"
		)
		and mill.has_node(
			"InteractionPrompt/PromptMargin/PromptRow/ActionLabel"
		)
		and mill.has_node("HealthBar")
		and mill.has_node("MultiplayerProductionRequestTimer"),
		"石磨台必须在场景中原生预建主体、边框、碰撞、交互提示、血条与多人请求Timer。"
	)

	var direct_timers := mill.find_children("*", "Timer", false, false)
	var request_timer := mill.get_node_or_null(
		"MultiplayerProductionRequestTimer"
	) as Timer
	_expect(
		direct_timers.size() == 1
		and request_timer != null
		and request_timer.one_shot
		and is_equal_approx(request_timer.wait_time, 4.0),
		"石磨台直属节点只能预置4秒多人生产请求Timer，生产刻度由全场协调器推进。"
	)

	var health_bar := mill.get_node_or_null("HealthBar") as PlantHealthBar
	var health_idle_timer := (
		health_bar.get_node_or_null("IdleFadeTimer") as Timer
		if health_bar != null
		else null
	)
	_expect(
		health_bar != null
		and health_bar.size == Vector2(12, 3)
		and health_bar.position == Vector2(-6, -9)
		and health_bar.scale == Vector2.ONE
		and health_idle_timer != null
		and health_idle_timer.one_shot
		and health_idle_timer.is_stopped()
		and not health_bar.is_processing()
		and not health_bar.is_physics_processing(),
		"石磨台必须沿用木头加工站的12×3公共血条位置，满血时不得常驻逐帧处理。"
	)

	var prompt := mill.get_node_or_null("InteractionPrompt") as Control
	var key_label := mill.get_node_or_null(
		"InteractionPrompt/PromptMargin/PromptRow/Keycap/KeyLabel"
	) as Label
	var action_label := mill.get_node_or_null(
		"InteractionPrompt/PromptMargin/PromptRow/ActionLabel"
	) as Label
	_expect(
		prompt != null
		and not prompt.visible
		and key_label != null
		and key_label.text == "F"
		and action_label != null
		and action_label.text == "打开石磨台",
		"石磨台必须沿用建筑F键帽提示并明确显示“打开石磨台”。"
	)

	var border := mill.get_node_or_null(
		"ProductionBorder"
	) as DayNightProgressBorder
	var border_mesh := border.mesh as QuadMesh if border != null else null
	var border_material := (
		border.material as ShaderMaterial if border != null else null
	)
	var border_shader := (
		border_material.shader if border_material != null else null
	)
	var shader_code := border_shader.code if border_shader != null else ""
	_expect(
		border != null
		and border_mesh != null
		and border_mesh.size == Vector2(16, 16)
		and border_material != null
		and border_shader != null
		and border_shader.resource_path
		== "res://resources/shader/stone_mill_border.gdshader",
		"石磨台必须使用16×16网格与独立stone_mill_border Shader。"
	)
	_expect(
		shader_code.contains("pixel.x < 2.0")
		and shader_code.contains("pixel.y < 2.0")
		and shader_code.contains("pixel.x >= 14.0")
		and shader_code.contains("pixel.y >= 14.0"),
		"石磨台Shader必须在16×16逻辑网格的四边严格绘制2像素外框。"
	)
	if border_material != null:
		var idle_gray: Color = border_material.get_shader_parameter(&"idle_gray")
		var idle_shadow: Color = border_material.get_shader_parameter(
			&"idle_shadow"
		)
		var progress_light_gray: Color = border_material.get_shader_parameter(
			&"progress_light_gray"
		)
		_expect(
			_is_neutral_gray(idle_gray)
			and _is_neutral_gray(idle_shadow)
			and _is_neutral_gray(progress_light_gray)
			and progress_light_gray.get_luminance()
			- idle_gray.get_luminance() >= 0.4,
			"石磨台未完成外框必须为灰色，已完成进度必须使用明显更亮的淡灰色。"
		)
		_expect(
			not bool(border.get_instance_shader_parameter(&"working_active"))
			and is_zero_approx(
				float(border.get_instance_shader_parameter(&"progress_value"))
			),
			"未选择配方时石磨台外框必须保持灰色待机状态且进度为零。"
		)


func _test_recipe_contract(mill: ProductionBuilding) -> void:
	_expect(
		mill.recipes.size() == 2
		and _recipe_matches(
			mill.recipes[0],
			&"white_crystal_to_powder",
			WHITE_CRYSTAL,
			WHITE_CRYSTAL_POWDER
		)
		and _recipe_matches(
			mill.recipes[1],
			&"capoo_blue_crystal_to_powder",
			CAPOO_BLUE_CRYSTAL,
			CAPOO_BLUE_CRYSTAL_POWDER
		),
		"石磨台必须恰好提供两条30秒共享仓库配方，并按1:1将两种水晶磨成对应粉末。"
	)
	_expect(
		WHITE_CRYSTAL_POWDER.can_store_in_inventory
		and WHITE_CRYSTAL_POWDER.stackable
		and WHITE_CRYSTAL_POWDER.inventory_stack_limit >= 999
		and CAPOO_BLUE_CRYSTAL_POWDER.can_store_in_inventory
		and CAPOO_BLUE_CRYSTAL_POWDER.stackable
		and CAPOO_BLUE_CRYSTAL_POWDER.inventory_stack_limit >= 999,
		"两种新晶粉必须是可堆叠并可进入仓库/背包的材料。"
	)


func _test_multiplayer_recipe_authority(mill: ProductionBuilding) -> void:
	mill.configure_multiplayer_production(9101, 1, true)
	var starting_revision := mill.production_revision
	var white_recipe_command := (
		ProductionBuildingProtocol.make_select_recipe_command(
			1,
			9101,
			1,
			starting_revision,
			&"white_crystal_to_powder"
		)
	)
	var white_result := (
		mill.apply_authoritative_multiplayer_production_command(
			white_recipe_command
		)
	)
	var committed_revision := mill.production_revision
	var foreign_recipe_command := (
		ProductionBuildingProtocol.make_select_recipe_command(
			2,
			9101,
			1,
			committed_revision,
			&"wood_to_plank"
		)
	)
	_expect(
		white_result == ProductionBuildingProtocol.RESULT_SUCCESS
		and mill.active_recipe_id == &"white_crystal_to_powder"
		and committed_revision == starting_revision + 1
		and mill.apply_authoritative_multiplayer_production_command(
			foreign_recipe_command
		) == ProductionBuildingProtocol.RESULT_INVALID_RECIPE
		and mill.production_revision == committed_revision,
		"多人Host必须接受石磨台自身晶粉配方，并以实例白名单零写入拒绝其他建筑配方。"
	)


func _test_panel_and_interaction(
	mill: ProductionBuilding,
	panel: ProductionBuildingPanel,
	player: Player
) -> void:
	_expect(not panel.visible and not panel.is_open(), "共享生产面板必须默认隐藏。")
	panel.open_for(mill, player)
	await process_frame
	_expect(
		panel.is_open()
		and panel.visible
		and player.controls_locked
		and panel.building_title.text == "石磨台",
		"打开石磨台UI后必须显示正确标题并锁定玩家控制。"
	)
	_expect(
		panel.recipe_rows[0].visible
		and panel.recipe_rows[1].visible
		and not panel.recipe_rows[2].visible
		and not panel.recipe_rows[3].visible
		and not panel.recipe_rows[4].visible
		and not panel.recipe_rows[5].visible
		and panel.recipe_rows[0].icon == WHITE_CRYSTAL_POWDER.icon_texture
		and panel.recipe_rows[1].icon == CAPOO_BLUE_CRYSTAL_POWDER.icon_texture
		and panel.recipe_rows[0].text.contains("白晶研磨")
		and panel.recipe_rows[1].text.contains("蓝晶研磨")
		and panel.recipe_rows[0].tooltip_text.contains("30.0 秒")
		and panel.recipe_rows[1].tooltip_text.contains("30.0 秒"),
		"石磨台UI必须只显示两条对应晶粉配方，并明确标注各需30秒。"
	)
	_expect(
		panel.input_slots[0].visible
		and not panel.input_slots[1].visible
		and not panel.input_slots[2].visible
		and panel.output_slots[0].visible
		and not panel.output_slots[1].visible
		and not panel.output_slots[2].visible
		and panel.input_slots[0].item == WHITE_CRYSTAL
		and panel.input_slots[0].stack_count == 1
		and panel.output_slots[0].item == WHITE_CRYSTAL_POWDER
		and panel.output_slots[0].stack_count == 1,
		"默认白晶配方必须左右各只展示一个居中槽位，并清楚标出1:1投入产出。"
	)
	panel.call("_on_recipe_row_pressed", 1)
	_expect(
		mill.active_recipe_id == &"capoo_blue_crystal_to_powder"
		and panel.input_slots[0].item == CAPOO_BLUE_CRYSTAL
		and panel.input_slots[0].stack_count == 1
		and panel.output_slots[0].item == CAPOO_BLUE_CRYSTAL_POWDER
		and panel.output_slots[0].stack_count == 1,
		"选择蓝晶配方后UI必须同步切换为卡普蓝晶到卡普蓝晶粉的1:1方案。"
	)
	panel.close()
	_expect(
		not panel.is_open() and not player.controls_locked,
		"关闭石磨台UI必须恢复玩家控制。"
	)

	mill.nearby_player = player
	mill.call("_set_interaction_target", true)
	var prompt := mill.get_node("InteractionPrompt") as Control
	_expect(prompt.visible, "石磨台成为最近交互目标时必须显示F提示。")
	var interact_event := InputEventKey.new()
	interact_event.physical_keycode = KEY_F
	interact_event.pressed = true
	_expect(
		interact_event.is_action_pressed(&"interact"),
		"键盘F必须映射到石磨台的统一建筑交互动作。"
	)
	mill._unhandled_input(interact_event)
	_expect(
		panel.is_open() and player.controls_locked,
		"靠近石磨台第一次按F必须打开UI并锁定玩家。"
	)
	panel._input(interact_event)
	_expect(
		not panel.is_open() and not player.controls_locked,
		"石磨台UI打开后第二次按F必须关闭并解除玩家锁定。"
	)


func _test_pixel_assets(mill: ProductionBuilding) -> void:
	var sprite := mill.get_node_or_null("MainSprite") as Sprite2D
	var sprite_texture := sprite.texture if sprite != null else null
	_expect(
		sprite != null
		and sprite_texture != null
		and sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and sprite_texture.get_size() == Vector2(64, 64)
		and sprite.scale == Vector2(0.5, 0.5)
		and sprite_texture.get_size() * sprite.scale == Vector2(32, 32),
		"石磨台必须用64×64源画布、0.5静态缩放和邻近过滤落入32×32占格。"
	)
	_audit_pixel_asset(
		STONE_MILL_TEXTURE_PATH,
		Vector2i(64, 64),
		Vector2i(32, 32),
		"石磨台"
	)
	_audit_pixel_asset(
		WHITE_POWDER_TEXTURE_PATH,
		Vector2i(32, 32),
		Vector2i(28, 28),
		"白色水晶粉"
	)
	_audit_pixel_asset(
		BLUE_POWDER_TEXTURE_PATH,
		Vector2i(32, 32),
		Vector2i(28, 28),
		"卡普蓝晶粉"
	)
	if sprite != null and sprite_texture != null:
		var source_image := Image.load_from_file(
			ProjectSettings.globalize_path(STONE_MILL_TEXTURE_PATH)
		)
		if source_image != null and not source_image.is_empty():
			var subject_rect := _get_centered_sprite_subject_rect(
				sprite,
				source_image.get_used_rect(),
				source_image.get_size()
			)
			_expect(
				Rect2(Vector2(-16, -16), Vector2(32, 32)).encloses(
					subject_rect
				),
				"石磨台非透明主体应用场景变换后不得超出一格32×32世界像素。"
			)


func _test_shared_storage_transaction(
	mill: ProductionBuilding,
	coordinator: ProductionCoordinator,
	first_warehouse: OakWarehouse,
	second_warehouse: OakWarehouse,
	recipe_id: StringName,
	input_item: PickupConfig,
	output_item: PickupConfig,
	label: String
) -> void:
	_expect(
		first_warehouse.get_storage_item_total(input_item) == 0
		and second_warehouse.try_add_storage_item_count(input_item, 1)
		and first_warehouse.get_storage_item_total(input_item) == 0
		and second_warehouse.get_storage_item_total(input_item) == 1,
		"%s必须能把测试水晶仅放入第二座仓库，以覆盖跨仓生产网络。" % label
	)
	var output_before := coordinator.get_total_item_count(output_item)
	var transaction_snapshots: Array[Vector2i] = []
	var capture_snapshot := func() -> void:
		transaction_snapshots.append(Vector2i(
			coordinator.get_total_item_count(input_item),
			coordinator.get_total_item_count(output_item)
		))
	first_warehouse.storage_changed.connect(capture_snapshot)
	second_warehouse.storage_changed.connect(capture_snapshot)

	_expect(mill.select_recipe(recipe_id), "石磨台必须能选择%s配方。" % label)
	mill.advance_shared_production_tick(29.0)
	_expect(
		coordinator.get_total_item_count(input_item) == 1
		and coordinator.get_total_item_count(output_item) == output_before
		and transaction_snapshots.is_empty()
		and is_equal_approx(mill.progress_elapsed_seconds, 29.0),
		"%s到29秒时不得访问仓库、扣水晶或提前加入粉末。" % label
	)
	mill.advance_shared_production_tick(1.0)
	var snapshots_are_atomic := not transaction_snapshots.is_empty()
	for snapshot in transaction_snapshots:
		snapshots_are_atomic = (
			snapshot == Vector2i(0, output_before + 1)
			and snapshots_are_atomic
		)
	_expect(
		coordinator.get_total_item_count(input_item) == 0
		and coordinator.get_total_item_count(output_item) == output_before + 1
		and second_warehouse.get_storage_item_total(input_item) == 0
		and snapshots_are_atomic
		and is_zero_approx(mill.progress_elapsed_seconds)
		and mill.completion_wait_reason == &"",
		"%s必须在第30秒跨仓原子扣除1个水晶并向共享仓库加入1份对应粉末。" % label
	)
	first_warehouse.storage_changed.disconnect(capture_snapshot)
	second_warehouse.storage_changed.disconnect(capture_snapshot)


func _recipe_matches(
	recipe: ProductionRecipe,
	expected_recipe_id: StringName,
	expected_input: PickupConfig,
	expected_output: PickupConfig
) -> bool:
	return (
		recipe != null
		and recipe.is_valid()
		and recipe.recipe_id == expected_recipe_id
		and recipe.input_items == [expected_input]
		and recipe.input_amounts == [1]
		and recipe.output_items == [expected_output]
		and recipe.output_amounts == [1]
		and not recipe.inputs_from_player_inventory()
		and not recipe.outputs_to_player_inventory()
		and is_equal_approx(recipe.duration_seconds, 30.0)
	)


func _audit_pixel_asset(
	resource_path: String,
	expected_size: Vector2i,
	maximum_subject_size: Vector2i,
	label: String
) -> void:
	var image := Image.load_from_file(
		ProjectSettings.globalize_path(resource_path)
	)
	_expect(
		image != null
		and not image.is_empty()
		and image.get_size() == expected_size,
		"%s必须保持%d×%d原生像素画布。" % [
			label,
			expected_size.x,
			expected_size.y,
		]
	)
	if image == null or image.is_empty():
		return
	var subject_bounds := image.get_used_rect()
	var alpha_is_binary := true
	var transparent_rgb_is_clean := true
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			if pixel.a > 0.001 and pixel.a < 0.999:
				alpha_is_binary = false
			if pixel.a <= 0.001 and not (
				is_zero_approx(pixel.r)
				and is_zero_approx(pixel.g)
				and is_zero_approx(pixel.b)
			):
				transparent_rgb_is_clean = false
	_expect(
		subject_bounds.has_area()
		and subject_bounds.size.x <= maximum_subject_size.x
		and subject_bounds.size.y <= maximum_subject_size.y,
		"%s非透明主体必须留有安全边距且不得超过%d×%d像素。" % [
			label,
			maximum_subject_size.x,
			maximum_subject_size.y,
		]
	)
	_expect(
		alpha_is_binary and transparent_rgb_is_clean,
		"%s必须保持二值alpha且完全透明像素的RGB必须清零。" % label
	)


func _get_centered_sprite_subject_rect(
	sprite: Sprite2D,
	opaque_bounds: Rect2i,
	texture_size: Vector2i
) -> Rect2:
	var source_origin := Vector2(opaque_bounds.position)
	if sprite.centered:
		source_origin -= Vector2(texture_size) * 0.5
	source_origin += sprite.offset
	return Rect2(
		sprite.position + source_origin * sprite.scale,
		Vector2(opaque_bounds.size) * sprite.scale.abs()
	)


func _is_neutral_gray(color: Color) -> bool:
	var minimum_channel := minf(color.r, minf(color.g, color.b))
	var maximum_channel := maxf(color.r, maxf(color.g, color.b))
	return (
		maximum_channel - minimum_channel <= 0.06
		and is_equal_approx(color.a, 1.0)
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _finish(test_root: Node) -> void:
	test_root.queue_free()
	await process_frame
	if failures.is_empty():
		print("STONE_MILL_SMOKE_TEST_OK")
		quit(0)
		return
	print("STONE_MILL_SMOKE_TEST_FAILED: %d" % failures.size())
	quit(1)
