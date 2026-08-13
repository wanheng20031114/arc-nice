extends SceneTree

const GENERATION_CONFIG_PATH := "res://resources/config/rogue_route/p3_generation_config.tres"
const OUTPUT_PATH := "res://dev_tools/output/rogue_route_template_preview.png"
const CANVAS_SIZE := Vector2i(1200, 620)
const CARD_SIZE := Vector2i(220, 130)
const CARD_GAP := Vector2i(15, 15)
const GRID_ORIGIN := Vector2(24.0, 24.0)
const GRID_STEP := 19.0
const NODE_RADIUS := 4.5
const BACKGROUND := Color("202327")
const CARD_BACKGROUND := Color("141618")
const EDGE_COLOR := Color("8f959a")
const NODE_FILL := Color("17191b")
const NODE_STROKE := Color("aeb4b9")
const LABEL_COLOR := Color("d9e0e5")
const TEMPLATE_IDS := [
	"4a", "4b", "4c", "4d", "4e", "4f", "4g", "4h", "4i", "4j",
	"5a", "5b", "5c", "5d", "5e", "5f", "5g", "5h", "5i", "5j",
]
const LABEL_GLYPHS := {
	"4": ["101", "101", "111", "001", "001"],
	"5": ["111", "100", "110", "001", "110"],
	"a": ["000", "110", "011", "101", "111"],
	"b": ["100", "100", "110", "101", "110"],
	"c": ["000", "011", "100", "100", "011"],
	"d": ["001", "001", "011", "101", "011"],
	"e": ["000", "010", "101", "110", "011"],
	"f": ["011", "010", "111", "010", "010"],
	"g": ["000", "011", "101", "011", "110"],
	"h": ["100", "100", "110", "101", "101"],
	"i": ["010", "000", "010", "010", "010"],
	"j": ["001", "000", "001", "101", "010"],
}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var generation_config: Resource = load(GENERATION_CONFIG_PATH)
	if generation_config == null:
		push_error("无法加载正式路线生成配置：%s" % GENERATION_CONFIG_PATH)
		quit(1)
		return
	var templates_value: Variant = generation_config.get("templates")
	if templates_value == null or not templates_value is Array:
		push_error("正式路线生成配置尚未声明 templates 数组。")
		quit(1)
		return
	var registered_templates: Array = templates_value
	if registered_templates.size() != TEMPLATE_IDS.size():
		push_error("正式路线生成配置必须正好注册 20 个模板。")
		quit(1)
		return
	var templates_by_id: Dictionary = {}
	for template_value in registered_templates:
		var template: Resource = template_value
		if template == null:
			push_error("正式路线生成配置包含空模板。")
			quit(1)
			return
		var template_id := String(template.get("template_id"))
		if not TEMPLATE_IDS.has(template_id):
			push_error("正式路线生成配置包含未知模板：%s" % template_id)
			quit(1)
			return
		if templates_by_id.has(template_id):
			push_error("正式路线生成配置重复注册模板：%s" % template_id)
			quit(1)
			return
		templates_by_id[template_id] = template
	var templates: Array[Resource] = []
	for template_id in TEMPLATE_IDS:
		if not templates_by_id.has(template_id):
			push_error("正式路线生成配置缺少模板：%s" % template_id)
			quit(1)
			return
		templates.append(templates_by_id[template_id])

	var image := Image.create(CANVAS_SIZE.x, CANVAS_SIZE.y, false, Image.FORMAT_RGBA8)
	image.fill(BACKGROUND)
	for template_index in range(templates.size()):
		var template := templates[template_index]
		var column := template_index % 5
		var row := template_index / 5
		var card_origin := Vector2i(
			10 + column * (CARD_SIZE.x + CARD_GAP.x),
			10 + row * (CARD_SIZE.y + CARD_GAP.y)
		)
		image.fill_rect(Rect2i(card_origin, CARD_SIZE), CARD_BACKGROUND)
		_draw_template(image, template, Vector2(card_origin) + GRID_ORIGIN)
		_draw_label(
			image,
			String(template.get("template_id")),
			card_origin + Vector2i(185, 108)
		)

	var absolute_output_path := ProjectSettings.globalize_path(OUTPUT_PATH)
	var error := image.save_png(absolute_output_path)
	if error != OK:
		push_error("保存路线模板预览失败：%s" % error_string(error))
		quit(1)
		return
	print("ROGUE_ROUTE_TEMPLATE_PREVIEW_OK: %s" % absolute_output_path)
	quit()


func _draw_template(image: Image, template: Resource, origin: Vector2) -> void:
	var node_coords: PackedVector2Array = template.get("node_coords")
	var edges: PackedInt32Array = template.get("edges")
	for edge_offset in range(0, edges.size(), 2):
		var first_coord := node_coords[int(edges[edge_offset])]
		var second_coord := node_coords[int(edges[edge_offset + 1])]
		_draw_line(
			image,
			origin + first_coord * GRID_STEP,
			origin + second_coord * GRID_STEP,
			EDGE_COLOR,
			2.0
		)
	for coord in node_coords:
		var center := origin + coord * GRID_STEP
		_draw_circle(image, center, NODE_RADIUS, NODE_FILL)
		_draw_circle_outline(image, center, NODE_RADIUS, NODE_STROKE)


func _draw_line(
	image: Image,
	start: Vector2,
	finish: Vector2,
	color: Color,
	thickness: float
) -> void:
	var minimum_x := floori(minf(start.x, finish.x) - thickness)
	var maximum_x := ceili(maxf(start.x, finish.x) + thickness)
	var minimum_y := floori(minf(start.y, finish.y) - thickness)
	var maximum_y := ceili(maxf(start.y, finish.y) + thickness)
	var direction := finish - start
	var length_squared := direction.length_squared()
	for y in range(minimum_y, maximum_y + 1):
		for x in range(minimum_x, maximum_x + 1):
			var point := Vector2(x + 0.5, y + 0.5)
			var factor := clampf((point - start).dot(direction) / length_squared, 0.0, 1.0)
			if point.distance_to(start + direction * factor) <= thickness * 0.5:
				image.set_pixel(x, y, color)


func _draw_circle(image: Image, center: Vector2, radius: float, color: Color) -> void:
	var minimum_x := floori(center.x - radius)
	var maximum_x := ceili(center.x + radius)
	var minimum_y := floori(center.y - radius)
	var maximum_y := ceili(center.y + radius)
	for y in range(minimum_y, maximum_y + 1):
		for x in range(minimum_x, maximum_x + 1):
			if Vector2(x + 0.5, y + 0.5).distance_to(center) <= radius:
				image.set_pixel(x, y, color)


func _draw_circle_outline(
	image: Image,
	center: Vector2,
	radius: float,
	color: Color
) -> void:
	var minimum_x := floori(center.x - radius - 1.0)
	var maximum_x := ceili(center.x + radius + 1.0)
	var minimum_y := floori(center.y - radius - 1.0)
	var maximum_y := ceili(center.y + radius + 1.0)
	for y in range(minimum_y, maximum_y + 1):
		for x in range(minimum_x, maximum_x + 1):
			var distance := Vector2(x + 0.5, y + 0.5).distance_to(center)
			if distance >= radius - 1.0 and distance <= radius + 1.0:
				image.set_pixel(x, y, color)


func _draw_label(image: Image, label: String, origin: Vector2i) -> void:
	var cursor_x := origin.x
	for character_index in range(label.length()):
		var character := label.substr(character_index, 1)
		var rows: Array = LABEL_GLYPHS.get(character, [])
		for row in range(rows.size()):
			var pixels: String = rows[row]
			for column in range(pixels.length()):
				if pixels.substr(column, 1) == "1":
					image.fill_rect(
						Rect2i(cursor_x + column * 2, origin.y + row * 2, 2, 2),
						LABEL_COLOR
					)
		cursor_x += 8
