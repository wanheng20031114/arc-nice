extends SceneTree

const PLAYER_SCENE := preload(
	"res://scene/player/hoe_cat/player_hoe_cat.tscn"
)
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const LINGLAN_BOSS_SCENE := preload(
	"res://scene/boss/linglan/linglan_boss.tscn"
)

const CASES := [
	{
		"label": "科研中心",
		"plant_id": &"research_center",
		"scene_path": "res://scene/plant_defense/research_center.tscn",
		"master_path": (
			"res://resources/texture/plant_defense/research_center/"
			+ "research_center.png"
		),
		"lower_path": (
			"res://resources/texture/plant_defense/research_center/layers/"
			+ "lower_body.png"
		),
		"upper_path": (
			"res://resources/texture/plant_defense/research_center/layers/"
			+ "upper_foreground.png"
		),
		"shader_path": (
			"res://resources/shader/"
			+ "research_center_lifecycle_glow.gdshader"
		),
		"upper_visible_pixels": 371,
	},
	{
		"label": "植物培育中心",
		"plant_id": &"plant_cultivation_center",
		"scene_path": (
			"res://scene/plant_defense/plant_cultivation_center.tscn"
		),
		"master_path": (
			"res://resources/texture/plant_defense/plant_cultivation_center/"
			+ "plant_cultivation_center.png"
		),
		"lower_path": (
			"res://resources/texture/plant_defense/"
			+ "plant_cultivation_center/layers/lower_body.png"
		),
		"upper_path": (
			"res://resources/texture/plant_defense/"
			+ "plant_cultivation_center/layers/upper_foreground.png"
		),
		"shader_path": (
			"res://resources/shader/"
			+ "plant_cultivation_center_lifecycle_glow.gdshader"
		),
		"upper_visible_pixels": 880,
	},
]

const TEST_CONSTRUCTION_PROGRESS := 0.375
const TEST_REMOVAL_PROGRESS := 0.625

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test_root := Node2D.new()
	test_root.name = "BuildingForegroundLayerSmokeTest"
	root.add_child(test_root)

	for case_data: Dictionary in CASES:
		await _verify_scene_contract(test_root, case_data)
		_verify_asset_contract(case_data)

	test_root.free()
	if failures.is_empty():
		print("BUILDING_FOREGROUND_LAYER_SMOKE_TEST_PASSED")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_scene_contract(test_root: Node, case_data: Dictionary) -> void:
	var label := String(case_data["label"])
	var packed_scene := load(String(case_data["scene_path"])) as PackedScene
	_expect(packed_scene != null, "%s场景必须可加载。" % label)
	if packed_scene == null:
		return
	var building := packed_scene.instantiate() as PlantDefense
	_expect(building != null, "%s场景根节点必须继承PlantDefense。" % label)
	if building == null:
		return
	test_root.add_child(building)
	await process_frame

	var config := PlantDefenseRegistry.get_config(
		case_data["plant_id"] as StringName
	)
	_expect(config != null, "%s配置必须存在。" % label)
	if config == null:
		building.free()
		return
	building.setup(
		config,
		null,
		[
			Vector2i.ZERO,
			Vector2i.RIGHT,
			Vector2i.DOWN,
			Vector2i.ONE,
		]
	)

	var visual_root := building.get_node_or_null("VisualRoot") as Node2D
	var lower := building.get_node_or_null(
		"VisualRoot/LowerBody"
	) as Sprite2D
	var upper := building.get_node_or_null(
		"VisualRoot/UpperForeground"
	) as Sprite2D
	var lower_material := (
		lower.material as ShaderMaterial if lower != null else null
	)
	var upper_material := (
		upper.material as ShaderMaterial if upper != null else null
	)
	_expect(
		visual_root != null
		and visual_root.scale == Vector2(0.5, 0.5)
		and lower != null
		and upper != null
		and lower.texture != null
		and upper.texture != null
		and lower.texture.get_size() == Vector2(64, 64)
		and upper.texture.get_size() == Vector2(64, 64)
		and lower.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and upper.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"%s上下两层必须同为64×64、0.5整数缩放并使用nearest采样。" % label
	)
	_expect(
		lower != null
		and upper != null
		and lower.z_index == 0
		and upper.z_index == 4
		and building.lifecycle_visual_paths
		== [
			NodePath("VisualRoot/LowerBody"),
			NodePath("VisualRoot/UpperForeground"),
		],
		"%s必须由z=0下层和z=4前景层组成，且两层都加入生命周期视觉。" % label
	)
	_verify_entity_z_contract(label, lower, upper)
	_expect(
		lower_material != null
		and upper_material != null
		and lower_material != upper_material
		and lower_material.shader == upper_material.shader
		and lower_material.shader != null
		and lower_material.shader.resource_path
		== String(case_data["shader_path"])
		and is_equal_approx(
			float(
				lower_material.get_shader_parameter(
					&"transparent_halo_weight"
				)
			),
			1.0
		)
		and is_zero_approx(
			float(
				upper_material.get_shader_parameter(
					&"transparent_halo_weight"
				)
			)
		),
		"%s上下层必须共享专用Shader；透明晕光只能由下层绘制一次。" % label
	)

	building.call(
		"_set_construction_progress",
		TEST_CONSTRUCTION_PROGRESS
	)
	building.call("_set_removal_progress", TEST_REMOVAL_PROGRESS)
	building.call("_set_lifecycle_parameter", &"removal_enabled", true)
	_verify_synced_instance_parameter(
		label,
		lower,
		upper,
		&"construction_progress",
		TEST_CONSTRUCTION_PROGRESS
	)
	_verify_synced_instance_parameter(
		label,
		lower,
		upper,
		&"removal_progress",
		TEST_REMOVAL_PROGRESS
	)
	_verify_synced_instance_parameter(
		label,
		lower,
		upper,
		&"removal_enabled",
		true
	)
	for parameter_name in [&"effect_top_y", &"effect_bottom_y", &"noise_offset"]:
		_expect(
			lower != null
			and upper != null
			and lower.get_instance_shader_parameter(parameter_name)
			== upper.get_instance_shader_parameter(parameter_name),
			"%s上下层的%s生命周期实例参数必须保持同步。" % [
				label,
				String(parameter_name),
			]
		)

	building.free()


func _verify_entity_z_contract(
	label: String,
	lower: Sprite2D,
	upper: Sprite2D
) -> void:
	var player := PLAYER_SCENE.instantiate()
	var enemy := ENEMY_SCENE.instantiate()
	var boss := LINGLAN_BOSS_SCENE.instantiate()
	var player_sprite := player.get_node_or_null("BodySprite") as CanvasItem
	var enemy_sprite := enemy.get_node_or_null("AnimatedSprite2D") as CanvasItem
	var boss_sprite := boss.get_node_or_null("AnimatedSprite2D") as CanvasItem
	_expect(
		lower != null
		and _effective_z_index(lower) == 0
		and player_sprite != null
		and _effective_z_index(player_sprite) == 1
		and enemy_sprite != null
		and _effective_z_index(enemy_sprite) == 2
		and boss_sprite != null
		and _effective_z_index(boss_sprite) == 3
		and upper != null
		and _effective_z_index(upper) == 4,
		"%s必须严格保持下层0 < 玩家1 < 敌人2 < 首领3 < 前景4。" % label
	)
	player.free()
	enemy.free()
	boss.free()


func _verify_synced_instance_parameter(
	label: String,
	lower: Sprite2D,
	upper: Sprite2D,
	parameter_name: StringName,
	expected: Variant
) -> void:
	if lower == null or upper == null:
		return
	var lower_value: Variant = lower.get_instance_shader_parameter(
		parameter_name
	)
	var upper_value: Variant = upper.get_instance_shader_parameter(
		parameter_name
	)
	_expect(
		lower_value == expected
		and upper_value == expected
		and lower_value == upper_value,
		"%s上下两层必须同步接收%s=%s。" % [
			label,
			String(parameter_name),
			str(expected),
		]
	)


func _verify_asset_contract(case_data: Dictionary) -> void:
	var label := String(case_data["label"])
	var master := _load_rgba8_image(String(case_data["master_path"]))
	var lower := _load_rgba8_image(String(case_data["lower_path"]))
	var upper := _load_rgba8_image(String(case_data["upper_path"]))
	_expect(
		not master.is_empty()
		and not lower.is_empty()
		and not upper.is_empty(),
		"%s主图和上下分层贴图必须都能读取。" % label
	)
	if master.is_empty() or lower.is_empty() or upper.is_empty():
		return
	_expect(
		master.get_size() == Vector2i(64, 64)
		and lower.get_size() == master.get_size()
		and upper.get_size() == master.get_size(),
		"%s主图与互补层必须严格保持64×64同尺寸。" % label
	)

	var recomposed := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	var overlap_count := 0
	var non_binary_alpha_count := 0
	var upper_visible_count := 0
	for y in range(64):
		for x in range(64):
			var pixel := Vector2i(x, y)
			var lower_color := lower.get_pixelv(pixel)
			var upper_color := upper.get_pixelv(pixel)
			var lower_alpha := roundi(lower_color.a * 255.0)
			var upper_alpha := roundi(upper_color.a * 255.0)
			if lower_alpha != 0 and lower_alpha != 255:
				non_binary_alpha_count += 1
			if upper_alpha != 0 and upper_alpha != 255:
				non_binary_alpha_count += 1
			if lower_alpha > 0 and upper_alpha > 0:
				overlap_count += 1
			if upper_alpha > 0:
				upper_visible_count += 1
				recomposed.set_pixelv(pixel, upper_color)
			elif lower_alpha > 0:
				recomposed.set_pixelv(pixel, lower_color)

	_expect(
		non_binary_alpha_count == 0,
		"%s分层贴图必须保持像素画二值Alpha，当前发现%d个半透明像素。" % [
			label,
			non_binary_alpha_count,
		]
	)
	_expect(
		overlap_count == 0,
		"%s上下层Alpha必须互补且不能重复绘制，当前重叠%d像素。" % [
			label,
			overlap_count,
		]
	)
	_expect(
		upper_visible_count == int(case_data["upper_visible_pixels"]),
		"%s前景遮挡区域必须保持%d个可见像素，当前为%d。" % [
			label,
			int(case_data["upper_visible_pixels"]),
			upper_visible_count,
		]
	)
	_expect(
		recomposed.get_data() == master.get_data(),
		"%s上下层必须逐字节无损重组为原始64×64主图。" % label
	)


func _load_rgba8_image(resource_path: String) -> Image:
	var image := Image.load_from_file(ProjectSettings.globalize_path(resource_path))
	if image.is_empty():
		return image
	image.convert(Image.FORMAT_RGBA8)
	return image


func _effective_z_index(item: CanvasItem) -> int:
	var effective_z := 0
	var current: CanvasItem = item
	while current != null:
		effective_z += current.z_index
		if not current.z_as_relative:
			break
		current = current.get_parent() as CanvasItem
	return effective_z


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
