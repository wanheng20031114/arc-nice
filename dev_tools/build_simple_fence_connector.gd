extends SceneTree

const SOURCE_ATLAS_PATH := (
	"res://resources/texture/plant_defense/simple_fence/simple_fence_atlas.png"
)
const OUTPUT_PATH := (
	"res://resources/texture/plant_defense/simple_fence/simple_fence_connector.png"
)
const SOURCE_FRAME_SIZE := 32
const SOURCE_RIGHT_FRAME := 2
const SOURCE_TIP_ORIGIN := Vector2i(27, 17)
const SOURCE_QUADRANT_SIZE := 5
const BASE_CONNECTOR_SIZE := 10
const CONNECTOR_SIZE := Vector2i(18, 10)
const CONNECTOR_CENTER_EXTENSION := 8
const EDGE_INSETS := [2, 1, 0, 0, 0, 0, 0, 0, 1, 2]


func _init() -> void:
	var atlas_texture := load(SOURCE_ATLAS_PATH) as Texture2D
	var atlas := atlas_texture.get_image() if atlas_texture != null else null
	if atlas == null or atlas.is_empty() or atlas.get_size() != Vector2i(128, 128):
		push_error("Simple fence source atlas must import as a valid 128x128 texture.")
		quit(2)
		return

	var connector := _extend_connector_horizontally(
		_extract_symmetric_connector(atlas)
	)
	var validation_error := _validate_connector(connector)
	if not validation_error.is_empty():
		push_error(validation_error)
		quit(3)
		return
	var save_error := connector.save_png(OUTPUT_PATH)
	if save_error != OK:
		push_error("Unable to save simple fence connector: %s" % OUTPUT_PATH)
		quit(4)
		return
	print("SIMPLE_FENCE_CONNECTOR_OK path=%s size=%s" % [OUTPUT_PATH, connector.get_size()])
	quit(0)


## Extract the far tip of the old right-connection frame, then mirror the same
## five-pixel quadrant across both axes. The result retains the established wood
## palette while guaranteeing that the horizontal piece and its 90° rotation
## have identical silhouettes in either direction.
func _extract_symmetric_connector(atlas: Image) -> Image:
	var connector := Image.create(
		BASE_CONNECTOR_SIZE,
		BASE_CONNECTOR_SIZE,
		false,
		Image.FORMAT_RGBA8
	)
	connector.fill(Color(0.0, 0.0, 0.0, 0.0))
	var frame_origin := Vector2i(
		(SOURCE_RIGHT_FRAME % 4) * SOURCE_FRAME_SIZE,
		(SOURCE_RIGHT_FRAME / 4) * SOURCE_FRAME_SIZE
	)
	for y in range(BASE_CONNECTOR_SIZE):
		var inset: int = EDGE_INSETS[y]
		var source_y: int = (
			y
			if y < SOURCE_QUADRANT_SIZE
			else BASE_CONNECTOR_SIZE - 1 - y
		)
		for x in range(inset, BASE_CONNECTOR_SIZE - inset):
			var source_x: int = (
				SOURCE_QUADRANT_SIZE - 1 - x
				if x < SOURCE_QUADRANT_SIZE
				else x - SOURCE_QUADRANT_SIZE
			)
			var color := atlas.get_pixelv(
				frame_origin
				+ SOURCE_TIP_ORIGIN
				+ Vector2i(source_x, source_y)
			)
			color.a = 1.0
			connector.set_pixel(x, y, color)
	return connector


## Extend only the middle grain columns so every output pixel stays on the
## original 1px art grid. The scene keeps the near edge fixed and places the
## added length toward the right/down neighbor, covering its upward tip.
func _extend_connector_horizontally(base: Image) -> Image:
	var connector := Image.create(
		CONNECTOR_SIZE.x,
		CONNECTOR_SIZE.y,
		false,
		Image.FORMAT_RGBA8
	)
	connector.fill(Color(0.0, 0.0, 0.0, 0.0))
	for y in range(CONNECTOR_SIZE.y):
		for x in range(CONNECTOR_SIZE.x):
			var source_x := x
			if x >= SOURCE_QUADRANT_SIZE:
				if x < SOURCE_QUADRANT_SIZE + CONNECTOR_CENTER_EXTENSION:
					source_x = SOURCE_QUADRANT_SIZE - 1 + posmod(
						x - SOURCE_QUADRANT_SIZE,
						2
					)
				else:
					source_x = x - CONNECTOR_CENTER_EXTENSION
			connector.set_pixel(x, y, base.get_pixel(source_x, y))
	return connector


func _validate_connector(connector: Image) -> String:
	if connector == null or connector.get_size() != CONNECTOR_SIZE:
		return "Simple fence connector must be exactly %s." % CONNECTOR_SIZE
	var visible_pixels := 0
	for y in range(CONNECTOR_SIZE.y):
		for x in range(CONNECTOR_SIZE.x):
			var color := connector.get_pixel(x, y)
			if color.a != 0.0 and color.a != 1.0:
				return "Simple fence connector must use binary alpha."
			if color.a > 0.0:
				visible_pixels += 1
			if color != connector.get_pixel(CONNECTOR_SIZE.x - 1 - x, y):
				return "Simple fence connector must be horizontally symmetric."
			if color != connector.get_pixel(x, CONNECTOR_SIZE.y - 1 - y):
				return "Simple fence connector must be vertically symmetric."
	if visible_pixels != 168:
		return "Simple fence connector silhouette changed unexpectedly: %d pixels." % visible_pixels
	return ""
