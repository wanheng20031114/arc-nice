extends SceneTree

const DAY_NIGHT_CONTROLLER_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)
const BUILDING_SCENES: Array[Dictionary] = [
	{
		"label": "植物培育中心",
		"plant_id": &"plant_cultivation_center",
		"border_path": NodePath("ProductionBorder"),
	},
	{
		"label": "科研中心",
		"plant_id": &"research_center",
		"border_path": NodePath("ResearchBorder"),
	},
	{
		"label": "木头加工站",
		"plant_id": &"wood_processing_station",
		"border_path": NodePath("ProductionBorder"),
	},
	{
		"label": "石磨台",
		"plant_id": &"stone_mill",
		"border_path": NodePath("ProductionBorder"),
	},
]

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var world := Node2D.new()
	world.name = "ProgressBorderNightSmokeWorld"
	root.add_child(world)
	var controller := (
		DAY_NIGHT_CONTROLLER_SCENE.instantiate() as DayNightController
	)
	world.add_child(controller)

	var borders: Array[DayNightProgressBorder] = []
	for fixture in BUILDING_SCENES:
		var config := PlantDefenseRegistry.get_config(
			fixture["plant_id"] as StringName
		)
		var building_scene := (
			config.plant_scene if config != null else null
		)
		_expect(
			building_scene != null,
			"%s必须能通过建筑注册表加载。" % fixture["label"]
		)
		if building_scene == null:
			continue
		var building := building_scene.instantiate() as Node2D
		world.add_child(building)
		var border := building.get_node_or_null(
			fixture["border_path"] as NodePath
		) as DayNightProgressBorder
		_expect(
			border != null,
			"%s进度外框必须直接使用昼夜绑定脚本。" % fixture["label"]
		)
		if border != null:
			borders.append(border)

	await process_frame
	await process_frame
	_expect(
		borders.size() == BUILDING_SCENES.size(),
		"四种生产/科研建筑必须全部参与夜间底色控制。"
	)

	for border in borders:
		_verify_shader_contract(border)
		_expect(
			_get_environment_tint(border).is_equal_approx(Color.WHITE),
			"白天环境色必须为纯白，确保外框像素输出与优化前完全一致。"
		)
		_expect(
			not border.is_processing()
			and not border.is_physics_processing(),
			"进度外框应只响应昼夜信号，不得新增常驻逐帧处理。"
		)

	controller.set_night_factor_immediate(0.5)
	for border in borders:
		_expect(
			_get_environment_tint(border).is_equal_approx(controller.color),
			"昼夜过渡中的未完成底色必须连续跟随环境颜色。"
		)

	for border in borders:
		border.set_instance_shader_parameter(&"working_active", true)
		border.set_instance_shader_parameter(&"progress_value", 0.42)
	controller.set_night_factor_immediate(1.0)
	for border in borders:
		_expect(
			_get_environment_tint(border).is_equal_approx(
				DayNightController.REFERENCE_NIGHT_COLOR
			)
			and bool(
				border.get_instance_shader_parameter(&"working_active")
			)
			and is_equal_approx(
				float(
					border.get_instance_shader_parameter(&"progress_value")
				),
				0.42
			),
			"夜间压暗未完成底色时不得改写工作状态或已完成进度。"
		)

	controller.set_night_factor_immediate(0.0)
	for border in borders:
		_expect(
			_get_environment_tint(border).is_equal_approx(Color.WHITE),
			"返回白天后外框环境色必须精确恢复纯白。"
		)

	world.queue_free()
	await process_frame
	if failures.is_empty():
		print("PROGRESS_BORDER_NIGHT_SMOKE_TEST_OK")
		quit(0)
		return
	print(
		"PROGRESS_BORDER_NIGHT_SMOKE_TEST_FAILED count=%d"
		% failures.size()
	)
	quit(1)


func _verify_shader_contract(border: DayNightProgressBorder) -> void:
	var shader_material := border.material as ShaderMaterial
	var shader := shader_material.shader if shader_material != null else null
	var shader_code := shader.code if shader != null else ""
	_expect(
		shader_material != null
		and shader != null
		and shader_code.contains(
			"instance uniform vec4 environment_tint"
		)
		and shader_code.contains("* environment_tint.rgb"),
		"外框Shader必须通过独立实例参数只压暗未完成底色。"
	)
	_expect(
		shader_code.contains("vec3 completed_color")
		and not shader_code.contains(
			"completed_color * environment_tint"
		),
		"已完成进度颜色不得乘环境色，夜间应继续保持发光。"
	)


func _get_environment_tint(border: DayNightProgressBorder) -> Color:
	return border.get_instance_shader_parameter(
		&"environment_tint"
	) as Color


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)
