extends SceneTree

const METRICS := preload(
	"res://resources/config/rogue_route/p3_world_metrics.tres"
)
const CELL_SCENE := preload("res://scene/rogue_route/rogue_route_cell.tscn")
const CONNECTIONS_SCENE := preload(
	"res://scene/rogue_route/rogue_route_connections.tscn"
)

const CAMERA_ZOOM := 2.0
const PLAYER_DESIGN_HEIGHT := 24.0
const VIEWPORT_WORLD_WIDTH := 1280.0 / CAMERA_ZOOM
const HUD_SAFE_WORLD_HEIGHT := (608.0 - 78.0) / CAMERA_ZOOM

const LEGACY_SPACING := Vector2(144.0, 112.0)
const LEGACY_EVENT_DIAMETER := 48.0
const LEGACY_BASE_LINE_WIDTH := 3.0
const LEGACY_REACHABLE_LINE_WIDTH := 4.0
const LEGACY_LABEL_FONT_SIZE := 12.0

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var cell := CELL_SCENE.instantiate() as RogueRouteCell
	var connections := CONNECTIONS_SCENE.instantiate() as RogueRouteConnections
	root.add_child(cell)
	root.add_child(connections)
	await process_frame

	var content_disc := cell.get_node("NodeButton/ContentDisc") as Control
	var name_label := cell.get_node("NameLabel") as Label
	var legacy_columns := _visible_axis_count(
		VIEWPORT_WORLD_WIDTH,
		LEGACY_SPACING.x
	)
	var current_columns := _visible_axis_count(
		VIEWPORT_WORLD_WIDTH,
		METRICS.cell_spacing.x
	)
	var legacy_rows := _visible_axis_count(
		HUD_SAFE_WORLD_HEIGHT,
		LEGACY_SPACING.y
	)
	var current_rows := _visible_axis_count(
		HUD_SAFE_WORLD_HEIGHT,
		METRICS.cell_spacing.y
	)
	var legacy_node_ratio := LEGACY_EVENT_DIAMETER / PLAYER_DESIGN_HEIGHT
	var current_node_ratio := content_disc.size.x / PLAYER_DESIGN_HEIGHT
	var legacy_base_screen_width := LEGACY_BASE_LINE_WIDTH * CAMERA_ZOOM
	var current_base_screen_width := connections.base_line_width * CAMERA_ZOOM
	var legacy_reachable_screen_width := (
		LEGACY_REACHABLE_LINE_WIDTH * CAMERA_ZOOM
	)
	var current_reachable_screen_width := (
		connections.reachable_line_width * CAMERA_ZOOM
	)
	var legacy_label_screen_size := LEGACY_LABEL_FONT_SIZE * CAMERA_ZOOM
	var current_label_screen_size := (
		float(name_label.get_theme_font_size(&"font_size"))
		* name_label.scale.x
		* CAMERA_ZOOM
	)

	_expect(
		legacy_columns == 5 and current_columns >= 8,
		"横向可见节点预算必须由旧版5列提升至至少8列。"
	)
	_expect(
		legacy_rows == 3 and current_rows >= 6,
		"HUD安全高度内的节点预算必须由旧版3行提升至至少6行。"
	)
	_expect(
		legacy_node_ratio == 2.0
		and current_node_ratio <= 1.10
		and current_node_ratio >= 0.90,
		"事件节点必须由玩家高度2倍收敛到约1倍。"
	)
	_expect(
		legacy_base_screen_width == 6.0
		and current_base_screen_width <= 2.0
		and legacy_reachable_screen_width == 8.0
		and current_reachable_screen_width <= 3.0,
		"普通/高亮线必须由6/8屏幕像素降至不超过2/3。"
	)
	_expect(
		legacy_label_screen_size == 24.0
		and is_equal_approx(current_label_screen_size, 18.0),
		"节点字形必须由12px硬放大到24px改为18px净1:1渲染。"
	)

	root.remove_child(cell)
	root.remove_child(connections)
	cell.free()
	connections.free()
	if failures.is_empty():
		print(
			"ROGUE_ROUTE_LAYOUT_AB_TEST_OK "
			+ "columns=%d->%d rows=%d->%d "
			% [legacy_columns, current_columns, legacy_rows, current_rows]
			+ "node_ratio=%.2f->%.2f lines=%.0f/%.0f->%.0f/%.0f "
			% [
				legacy_node_ratio,
				current_node_ratio,
				legacy_base_screen_width,
				legacy_reachable_screen_width,
				current_base_screen_width,
				current_reachable_screen_width,
			]
			+ "label=%.0f->%.0f"
			% [legacy_label_screen_size, current_label_screen_size]
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
