extends SceneTree

const METRICS := preload(
	"res://resources/config/rogue_route/p3_world_metrics.tres"
)
const CELL_SCENE := preload("res://scene/game_modes/rogue/route/rogue_route_cell.tscn")
const CONNECTIONS_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_route_connections.tscn"
)

const CAMERA_ZOOM := 2.0
const VIEWPORT_WORLD_WIDTH := 1280.0 / CAMERA_ZOOM
const HUD_SAFE_WORLD_HEIGHT := (580.0 - 78.0) / CAMERA_ZOOM
const EXPECTED_NODE_SIZE := Vector2(32.0, 32.0)
const EXPECTED_NODE_OFFSET := Vector2(16.0, 16.0)
const EXPECTED_GLOW_SIZE := Vector2(44.0, 44.0)
const EXPECTED_GLOW_OFFSET := Vector2(10.0, 10.0)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var cell := CELL_SCENE.instantiate() as RogueRouteCell
	var connections := CONNECTIONS_SCENE.instantiate() as RogueRouteConnections
	root.add_child(cell)
	root.add_child(connections)
	await process_frame

	var node_art := cell.get_node_or_null("NodeButton/NodeArt") as TextureRect
	var empty_ring := cell.get_node_or_null("NodeButton/EmptyRing") as TextureRect
	var active_ring := cell.get_node_or_null("ActiveRing") as TextureRect
	var node_button := cell.get_node_or_null("NodeButton") as Button
	var current_glow := cell.get_node_or_null("CurrentGlow") as ColorRect
	var legacy_name_label := cell.get_node_or_null("NameLabel")
	var visible_columns := _visible_axis_count(
		VIEWPORT_WORLD_WIDTH,
		METRICS.cell_spacing.x
	)
	var visible_rows := _visible_axis_count(
		HUD_SAFE_WORLD_HEIGHT,
		METRICS.cell_spacing.y
	)

	_expect(
		METRICS.cell_spacing.is_equal_approx(Vector2(112.0, 80.0))
		and METRICS.board_margin.is_equal_approx(Vector2(128.0, 112.0)),
		"路线必须使用紧凑且整轨道分块对齐的 112×80 正交网格和 128×112 世界边距。"
	)
	_expect(
		visible_columns >= 5 and visible_rows >= 3,
		"1280×720 活动视野必须至少保留 5 列×3 行方正路线节点。"
	)
	_expect(
		node_art != null
		and empty_ring != null
		and active_ring != null
		and node_button != null
		and current_glow != null
		and node_art.size.is_equal_approx(EXPECTED_NODE_SIZE)
		and empty_ring.size.is_equal_approx(EXPECTED_NODE_SIZE)
		and active_ring.position.is_equal_approx(EXPECTED_NODE_OFFSET)
		and active_ring.size.is_equal_approx(EXPECTED_NODE_SIZE)
		and node_button.position.is_equal_approx(EXPECTED_NODE_OFFSET)
		and node_button.size.is_equal_approx(EXPECTED_NODE_SIZE)
		and current_glow.position.is_equal_approx(EXPECTED_GLOW_OFFSET)
		and current_glow.size.is_equal_approx(EXPECTED_GLOW_SIZE),
		"路线节点必须保持居中的 32×32 像素图标，并使用紧凑的 44×44 HDR 外缘信标。"
	)
	_expect(
		legacy_name_label == null,
		"路线节点不应再渲染下方文字标签。"
	)
	_expect(
		cell.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and connections.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and connections.material is ShaderMaterial,
		"节点和金属轨道必须使用最近邻采样，连接轨道必须绑定原生着色器材质。"
	)
	# 远处未探索节点只是不可点击，不应因此被错误压暗。
	cell.set_click_enabled(false)
	cell.set_visited(false)
	var unexplored_modulate := node_art.modulate
	cell.set_visited(true)
	var visited_modulate := node_art.modulate
	cell.set_current(true)
	_expect(
		unexplored_modulate.r > visited_modulate.r
		and unexplored_modulate.g > visited_modulate.g
		and current_glow.visible
		and current_glow.material is ShaderMaterial
		and float((current_glow.material as ShaderMaterial).get_shader_parameter(
			&"hdr_energy"
		)) > 1.0,
		"未探索节点必须保持原亮度，已走过节点必须暗淡，当前节点必须显示 HDR 像素外缘信标。"
	)

	root.remove_child(cell)
	root.remove_child(connections)
	cell.free()
	connections.free()
	if failures.is_empty():
		print(
			"ROGUE_ROUTE_LAYOUT_AB_TEST_OK columns=%d rows=%d node=%s"
			% [visible_columns, visible_rows, EXPECTED_NODE_SIZE]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _visible_axis_count(view_size: float, spacing: float) -> int:
	return floori(view_size / spacing) + 1


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
