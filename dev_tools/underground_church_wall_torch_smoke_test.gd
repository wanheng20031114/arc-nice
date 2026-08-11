extends SceneTree

const TORCH_SCENE := preload(
	"res://scene/lighting/underground_church_wall_torch.tscn"
)
const LAYOUT_SCENE := preload(
	"res://scene/lighting/underground_church_wall_torch_layout.tscn"
)
const TORCH_TEXTURE_PATH := (
	"res://resources/texture/lighting/underground_church_wall_torch.png"
)
const LIGHT_TEXTURE_PATH := "res://resources/lighting/soft_white_point_light.tres"
const EXPECTED_LAYOUT: Dictionary[StringName, Array] = {
	&"UpperLeftTorch": [Vector2(104, 52), 1.35],
	&"UpperRightTorch": [Vector2(216, 52), 1.55],
	&"LowerTorch": [Vector2(160, 256), 1.75],
}

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var layout := LAYOUT_SCENE.instantiate() as Node2D
	_expect(layout != null, "地下教会火把布局必须能实例化。")
	if layout == null:
		_finish()
		return
	root.add_child(layout)
	await process_frame

	_expect(
		layout.get_child_count() == EXPECTED_LAYOUT.size(),
		"共享布局必须只包含三盏 authored 壁挂火把。",
	)
	for torch_name in EXPECTED_LAYOUT:
		var torch := layout.get_node_or_null(
			NodePath(String(torch_name))
		) as UndergroundChurchWallTorch
		_expect(torch != null, "布局缺少壁挂火把 %s。" % torch_name)
		if torch == null:
			continue
		var expected: Array = EXPECTED_LAYOUT[torch_name]
		_expect(
			torch.position.is_equal_approx(expected[0] as Vector2)
			and is_equal_approx(torch.half_cycle_seconds, float(expected[1])),
			"%s 的挂点或呼吸半周期与 authored 合同不一致。" % torch_name,
		)
		_test_torch_contract(torch)

	layout.queue_free()
	await process_frame
	_finish()


func _test_torch_contract(torch: UndergroundChurchWallTorch) -> void:
	var sprite := torch.get_node("Sprite") as Sprite2D
	_expect(
		sprite.position.is_equal_approx(Vector2(0, -12))
		and sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"火把 Sprite 必须以挂点底部定位并使用 nearest。",
	)
	_expect(
		sprite.texture != null
		and sprite.texture.resource_path == TORCH_TEXTURE_PATH
		and sprite.texture.get_width() == 16
		and sprite.texture.get_height() == 24,
		"火把必须使用唯一的16×24正式透明像素素材。",
	)
	var light := torch.night_light
	_expect(
		light != null
		and light.position.is_equal_approx(Vector2(0, -18))
		and light.color.is_equal_approx(Color(1.0, 0.58, 0.26, 1.0))
		and is_equal_approx(light.texture_scale, 0.42)
		and is_equal_approx(light.night_energy, 0.36),
		"壁挂火把必须使用微弱暖色 NightPointLight2D。",
	)
	_expect(
		light.texture != null
		and light.texture.resource_path == LIGHT_TEXTURE_PATH
		and light.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR
		and not light.shadow_enabled,
		"火把光必须使用无阴影、线性过滤的平滑径向纹理。",
	)
	_expect(
		torch.breathing_tween != null
		and torch.breathing_tween.is_running()
		and light.get_emission_strength() >= 0.9
		and light.get_emission_strength() <= 1.0,
		"火把必须以0.90–1.00范围持续执行 SINE 呼吸。",
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("UNDERGROUND_CHURCH_WALL_TORCH_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
