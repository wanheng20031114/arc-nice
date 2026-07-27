extends SceneTree

const GRID_SIZE := 4
const FRAME_SIZE := 32
const GENERATED_CELL_SCALE_SIZE := 60
const CONNECTION_UP := 1
const CONNECTION_RIGHT := 2
const CONNECTION_DOWN := 4
const CONNECTION_LEFT := 8
const DEFAULT_SOURCE_PATH := (
	"res://dev_assets/source_images/plant_defense/simple_fence/"
	+ "simple_fence_imagegen_rgba.png"
)
const DEFAULT_OUTPUT_PATH := (
	"res://resources/texture/plant_defense/simple_fence/"
	+ "simple_fence_atlas.png"
)
# One shared, non-dithered palette keeps all sixteen connected frames visually
# identical at their seams instead of independently quantizing each mask.
const SHARED_WOOD_PALETTE: Array[Color] = [
	Color8(252, 213, 144),
	Color8(247, 189, 107),
	Color8(240, 161, 71),
	Color8(228, 154, 67),
	Color8(223, 141, 53),
	Color8(218, 133, 47),
	Color8(211, 133, 49),
	Color8(208, 126, 44),
	Color8(204, 120, 41),
	Color8(193, 116, 40),
	Color8(187, 108, 35),
	Color8(182, 101, 31),
	Color8(172, 99, 32),
	Color8(166, 92, 28),
	Color8(161, 86, 25),
	Color8(150, 83, 25),
	Color8(145, 75, 21),
	Color8(132, 70, 20),
	Color8(139, 54, 46),
	Color8(117, 57, 17),
	Color8(106, 54, 13),
	Color8(98, 48, 11),
	Color8(91, 43, 9),
	Color8(86, 31, 25),
	Color8(68, 33, 7),
	Color8(44, 18, 4),
	Color8(33, 11, 4),
	Color8(21, 10, 5),
	Color8(28, 5, 10),
	Color8(18, 4, 5),
	Color8(13, 3, 4),
	Color8(6, 2, 2),
]


func _init() -> void:
	var arguments := _parse_arguments(OS.get_cmdline_user_args())
	var source_path := arguments.get("source", DEFAULT_SOURCE_PATH) as String
	var output_path := arguments.get("output", DEFAULT_OUTPUT_PATH) as String

	var source := Image.load_from_file(source_path)
	if source == null or source.is_empty():
		push_error("Unable to load simple fence source image: %s" % source_path)
		quit(3)
		return

	var atlas := Image.create(
		GRID_SIZE * FRAME_SIZE,
		GRID_SIZE * FRAME_SIZE,
		false,
		Image.FORMAT_RGBA8
	)
	atlas.fill(Color(0.0, 0.0, 0.0, 0.0))
	for frame_index in range(GRID_SIZE * GRID_SIZE):
		var column := frame_index % GRID_SIZE
		var row := frame_index / GRID_SIZE
		var left := roundi(float(source.get_width()) * float(column) / float(GRID_SIZE))
		var top := roundi(float(source.get_height()) * float(row) / float(GRID_SIZE))
		var right := roundi(
			float(source.get_width()) * float(column + 1) / float(GRID_SIZE)
		)
		var bottom := roundi(
			float(source.get_height()) * float(row + 1) / float(GRID_SIZE)
		)
		var frame := source.get_region(Rect2i(left, top, right - left, bottom - top))
		frame.resize(
			GENERATED_CELL_SCALE_SIZE,
			GENERATED_CELL_SCALE_SIZE,
			Image.INTERPOLATE_NEAREST
		)
		var crop_offset := (GENERATED_CELL_SCALE_SIZE - FRAME_SIZE) / 2
		frame = frame.get_region(
			Rect2i(crop_offset, crop_offset, FRAME_SIZE, FRAME_SIZE)
		)
		_enforce_cardinal_edge_contract(frame, frame_index)
		atlas.blit_rect(
			frame,
			Rect2i(Vector2i.ZERO, frame.get_size()),
			Vector2i(column, row) * FRAME_SIZE
		)
	_apply_shared_wood_palette(atlas)
	var validation_error := _validate_atlas(atlas)
	if not validation_error.is_empty():
		push_error(validation_error)
		quit(6)
		return

	var output_directory := output_path.get_base_dir()
	if not output_directory.is_empty():
		var make_directory_error := DirAccess.make_dir_recursive_absolute(output_directory)
		if make_directory_error != OK:
			push_error("Unable to create atlas output directory: %s" % output_directory)
			quit(4)
			return
	var save_error := atlas.save_png(output_path)
	if save_error != OK:
		push_error("Unable to save simple fence atlas: %s" % output_path)
		quit(5)
		return

	print(
		"SIMPLE_FENCE_ATLAS_OK path=%s size=%s colors=%d"
		% [output_path, atlas.get_size(), _count_visible_colors(atlas)]
	)
	quit(0)


func _enforce_cardinal_edge_contract(frame: Image, connection_mask: int) -> void:
	var transparent := Color(0.0, 0.0, 0.0, 0.0)
	if (connection_mask & CONNECTION_UP) == 0:
		for x in range(FRAME_SIZE):
			frame.set_pixel(x, 0, transparent)
	if (connection_mask & CONNECTION_RIGHT) == 0:
		for y in range(FRAME_SIZE):
			frame.set_pixel(FRAME_SIZE - 1, y, transparent)
	if (connection_mask & CONNECTION_DOWN) == 0:
		for x in range(FRAME_SIZE):
			frame.set_pixel(x, FRAME_SIZE - 1, transparent)
	if (connection_mask & CONNECTION_LEFT) == 0:
		for y in range(FRAME_SIZE):
			frame.set_pixel(0, y, transparent)


func _apply_shared_wood_palette(image: Image) -> void:
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var source_color := image.get_pixel(x, y)
			if source_color.a <= 0.0:
				image.set_pixel(x, y, Color(0.0, 0.0, 0.0, 0.0))
				continue
			var nearest_color := SHARED_WOOD_PALETTE[0]
			var nearest_distance_squared := INF
			for palette_color in SHARED_WOOD_PALETTE:
				var red_delta := source_color.r - palette_color.r
				var green_delta := source_color.g - palette_color.g
				var blue_delta := source_color.b - palette_color.b
				var distance_squared := (
					red_delta * red_delta
					+ green_delta * green_delta
					+ blue_delta * blue_delta
				)
				if distance_squared < nearest_distance_squared:
					nearest_distance_squared = distance_squared
					nearest_color = palette_color
			image.set_pixel(x, y, nearest_color)


func _validate_atlas(atlas: Image) -> String:
	if atlas.get_size() != Vector2i(128, 128):
		return "Simple fence atlas must be exactly 128x128."
	for connection_mask in range(16):
		var origin := Vector2i(
			(connection_mask % GRID_SIZE) * FRAME_SIZE,
			(connection_mask / GRID_SIZE) * FRAME_SIZE
		)
		var minimum := Vector2i(FRAME_SIZE, FRAME_SIZE)
		var maximum := Vector2i(-1, -1)
		var edge_up := false
		var edge_right := false
		var edge_down := false
		var edge_left := false
		for y in range(FRAME_SIZE):
			for x in range(FRAME_SIZE):
				var pixel := atlas.get_pixelv(origin + Vector2i(x, y))
				if pixel.a <= 0.0:
					continue
				if pixel.a < 1.0:
					return "Simple fence atlas must use binary alpha."
				minimum.x = mini(minimum.x, x)
				minimum.y = mini(minimum.y, y)
				maximum.x = maxi(maximum.x, x)
				maximum.y = maxi(maximum.y, y)
				edge_up = edge_up or y == 0
				edge_right = edge_right or x == FRAME_SIZE - 1
				edge_down = edge_down or y == FRAME_SIZE - 1
				edge_left = edge_left or x == 0
		if maximum.x < minimum.x or maximum.y < minimum.y:
			return "Simple fence atlas contains an empty frame: %d" % connection_mask
		var subject_size := maximum - minimum + Vector2i.ONE
		if maxi(subject_size.x, subject_size.y) < 28:
			return (
				"Simple fence frame %d does not nearly fill its 32x32 cell: %s"
				% [connection_mask, subject_size]
			)
		if (
			edge_up != ((connection_mask & CONNECTION_UP) != 0)
			or edge_right != ((connection_mask & CONNECTION_RIGHT) != 0)
			or edge_down != ((connection_mask & CONNECTION_DOWN) != 0)
			or edge_left != ((connection_mask & CONNECTION_LEFT) != 0)
		):
			return "Simple fence frame edge contract mismatch: %d" % connection_mask
	return ""


func _count_visible_colors(image: Image) -> int:
	var colors := {}
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			if pixel.a > 0.0:
				colors[pixel.to_rgba32()] = true
	return colors.size()


func _parse_arguments(raw_arguments: PackedStringArray) -> Dictionary:
	var parsed := {}
	for argument in raw_arguments:
		if not argument.begins_with("--") or not argument.contains("="):
			continue
		var separator := argument.find("=")
		var key := argument.substr(2, separator - 2)
		var value := argument.substr(separator + 1)
		parsed[key] = value
	return parsed
