extends SceneTree

const TRANSITION_SCENE := preload(
	"res://scene/game_modes/rogue/shop/ui/rogue_underground_shop_transition.tscn"
)
const SHADER_PATH := (
	"res://resources/shader/rogue_underground_shop_diamond_transition.gdshader"
)
const VIEWPORT_SIZE := Vector2(1280, 720)
const CELL_SIZE := 40.0
const EDGE_WIDTH := 1.5

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.content_scale_size = Vector2i(VIEWPORT_SIZE)
	root.size = Vector2i(VIEWPORT_SIZE)
	_audit_shader_source()
	_audit_aspect_grid_contract()
	_audit_phase_math()

	var transition := TRANSITION_SCENE.instantiate() as RogueUndergroundShopTransition
	_expect(transition != null, "地下商店菱形转场场景必须能够实例化。")
	if transition == null:
		_finish()
		return
	root.add_child(transition)
	for _frame in range(3):
		await process_frame
	_expect(transition.layer == 120, "商店转场必须位于最高 CanvasLayer。")
	_expect(
		transition.cover_rect.material is ShaderMaterial,
		"菱形转场必须使用可实例化的 ShaderMaterial。"
	)
	transition.visible = true
	transition.call("_set_reveal_phase", false)
	transition.call("_set_progress", 0.5)
	_expect(
		is_equal_approx(
			float(transition.cover_rect.get_instance_shader_parameter(&"cover_progress")),
			0.5
		),
		"中帧进度必须通过实例参数传入，避免跨玩家共享材质状态。"
	)
	transition.call("_set_reveal_phase", true)
	_expect(
		is_equal_approx(
			float(transition.cover_rect.get_instance_shader_parameter(&"reveal_phase")),
			1.0
		),
		"揭示阶段必须明确切换相位。"
	)
	for _frame in range(2):
		await process_frame
	transition.hide_immediately()
	root.remove_child(transition)
	transition.free()
	call_deferred("_finish")


func _audit_shader_source() -> void:
	var source := FileAccess.get_file_as_string(SHADER_PATH)
	_expect(not source.is_empty(), "必须能读取地下商店菱形着色器。")
	for forbidden in ["TIME", "noise", "random", "texture("]:
		_expect(
			not source.contains(forbidden),
			"菱形转场不得依赖时间、噪声、随机数或采样纹理：%s" % forbidden
		)
	for required in [
		"SCREEN_UV",
		"SCREEN_PIXEL_SIZE",
		"target_rows",
		"floor(viewport_pixels.y / max(target_rows, 1.0))",
		"phase_progress = mix(progress, 1.0 - progress, reveal_phase)",
	]:
		_expect(source.contains(required), "菱形转场缺少稳定屏幕网格约束：%s" % required)
	_expect(
		not source.contains("viewport_pixels.x /"),
		"菱形格距不得随宽高比缩小，只能由视口高度决定。"
	)
	_expect(
		source.contains("vec4(1.28, 0.58, 0.16, 0.72)"),
		"转场前沿必须保留超过1.0的克制暖金HDR值。"
	)


func _audit_aspect_grid_contract() -> void:
	var widescreen := _grid_metrics(Vector2i(1280, 720))
	var high_definition := _grid_metrics(Vector2i(1920, 1080))
	var four_three := _grid_metrics(Vector2i(960, 720))
	var ultrawide := _grid_metrics(Vector2i(2560, 1080))
	_expect(
		widescreen == Vector3i(40, 32, 18),
		"1280×720 必须形成40px格距、约32×18个正菱形。"
	)
	_expect(
		high_definition == Vector3i(60, 32, 18),
		"1920×1080 必须形成60px格距、约32×18个正菱形。"
	)
	_expect(
		four_three == Vector3i(40, 24, 18),
		"4:3 必须保持40px菱形，仅减少外围列为24×18。"
	)
	_expect(
		ultrawide == Vector3i(60, 43, 18),
		"超宽屏必须保持60px菱形，仅增加外围列。"
	)


func _grid_metrics(viewport_size: Vector2i) -> Vector3i:
	var cell_size := maxi(
		int(floor(float(viewport_size.y) / 18.0)),
		4
	)
	return Vector3i(
		cell_size,
		ceili(float(viewport_size.x) / float(cell_size)),
		ceili(float(viewport_size.y) / float(cell_size))
	)


func _audit_phase_math() -> void:
	_expect(
		_coverage_at(0.0, false, 0.0) == 0.0
		and _coverage_at(0.0, false, CELL_SIZE) == 0.0,
		"cover起点必须全透明。"
	)
	_expect(
		_coverage_at(1.0, false, 0.0) == 1.0
		and _coverage_at(1.0, false, CELL_SIZE) == 1.0,
		"cover终点必须覆盖菱形单元中心与角落，不得留缝。"
	)
	_expect(
		_coverage_at(0.5, false, 0.0) == 1.0
		and _coverage_at(0.5, false, CELL_SIZE) == 0.0,
		"cover中帧必须由每个菱形中心同步向外扩张。"
	)
	_expect(
		_coverage_at(1.0, true, 0.0) == 1.0
		and _coverage_at(1.0, true, CELL_SIZE) == 1.0,
		"reveal起点必须保持全遮盖。"
	)
	_expect(
		_coverage_at(0.5, true, 0.0) == 0.0
		and _coverage_at(0.5, true, CELL_SIZE) == 1.0,
		"reveal中帧必须从各中心扩大透明菱形。"
	)
	_expect(
		_coverage_at(0.0, true, 0.0) == 0.0
		and _coverage_at(0.0, true, CELL_SIZE) == 0.0,
		"reveal终点必须完全透明。"
	)


func _coverage_at(raw_progress: float, reveal: bool, distance: float) -> float:
	var phase_progress := 1.0 - raw_progress if reveal else raw_progress
	var threshold := lerpf(
		-EDGE_WIDTH * 2.0,
		CELL_SIZE + EDGE_WIDTH * 2.0,
		phase_progress
	)
	var fill := 1.0 if distance <= threshold else 0.0
	return 1.0 - fill if reveal else fill


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_UNDERGROUND_SHOP_TRANSITION_SMOKE_TEST_OK grid=32x18")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
