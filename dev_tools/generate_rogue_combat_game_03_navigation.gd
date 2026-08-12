extends SceneTree

const GAME_SCENE_PATH := (
	"res://scene/game_modes/rogue/combat/rogue_combat_game_03.tscn"
)
const NAVIGATION_SCENE_PATH := (
	"res://scene/game_modes/rogue/combat/rogue_combat_game_03_navigation.tscn"
)
const WORLD_RECT := Rect2i(0, -2, 20, 20)
const CELL_SIZE := Vector2i(16, 16)
const TILE_SOURCE_ID := 0
const OPEN_TILE_COORDS := Vector2i(0, 0)
const BLOCKED_TILE_COORDS := Vector2i(1, 0)
const TILE_TEXTURE := preload("res://resources/texture/瓦片.png")


func _initialize() -> void:
	quit(0 if _generate_navigation() else 1)


func _generate_navigation() -> bool:
	var packed_game := load(GAME_SCENE_PATH) as PackedScene
	if packed_game == null:
		push_error("无法加载废弃矿场场景：%s" % GAME_SCENE_PATH)
		return false
	var game := packed_game.instantiate()
	var wall := game.get_node_or_null(^"WorldBounds/Wall") as StaticBody2D
	if wall == null:
		push_error("废弃矿场缺少 WorldBounds/Wall。")
		game.free()
		return false
	var authored_shape_count := _validate_wall_shapes(wall)
	if authored_shape_count <= 0:
		push_error("WorldBounds/Wall 下没有可采样的 CollisionShape2D。")
		game.free()
		return false

	var navigation_layer := TileMapLayer.new()
	navigation_layer.name = &"GroundTileMapLayer"
	navigation_layer.visible = false
	navigation_layer.collision_enabled = false
	navigation_layer.navigation_enabled = false
	navigation_layer.occlusion_enabled = false
	navigation_layer.tile_set = _build_semantic_tile_set()

	var point_probe := CircleShape2D.new()
	point_probe.radius = 0.01
	var blocked_count := 0
	for y in range(WORLD_RECT.position.y, WORLD_RECT.end.y):
		for x in range(WORLD_RECT.position.x, WORLD_RECT.end.x):
			var cell := Vector2i(x, y)
			var center := navigation_layer.map_to_local(cell)
			var blocked := _shape_hits_wall(center, point_probe, wall)
			navigation_layer.set_cell(
				cell,
				TILE_SOURCE_ID,
				BLOCKED_TILE_COORDS if blocked else OPEN_TILE_COORDS
			)
			if blocked:
				blocked_count += 1

	navigation_layer.update_internals()
	var used_rect := navigation_layer.get_used_rect()
	var used_cell_count := navigation_layer.get_used_cells().size()
	if used_rect != WORLD_RECT or used_cell_count != 400:
		push_error(
			"生成的导航区域无效：rect=%s cells=%d。"
			% [used_rect, used_cell_count]
		)
		navigation_layer.free()
		game.free()
		return false
	if blocked_count <= 0 or blocked_count >= used_cell_count:
		push_error(
			"导航层必须同时包含开放格与阻挡格，当前阻挡=%d。" % blocked_count
		)
		navigation_layer.free()
		game.free()
		return false

	var packed_navigation := PackedScene.new()
	var pack_error := packed_navigation.pack(navigation_layer)
	if pack_error != OK:
		push_error("无法打包废弃矿场导航场景：%s" % error_string(pack_error))
		navigation_layer.free()
		game.free()
		return false
	# GAME_SCENE_PATH may already reference the previous navigation PackedScene.
	# Take over its cache path before saving so repeated generation is warning-free.
	packed_navigation.take_over_path(NAVIGATION_SCENE_PATH)
	var save_error := ResourceSaver.save(
		packed_navigation,
		NAVIGATION_SCENE_PATH,
		ResourceSaver.FLAG_REPLACE_SUBRESOURCE_PATHS
	)
	navigation_layer.free()
	game.free()
	if save_error != OK:
		push_error("无法保存废弃矿场导航场景：%s" % error_string(save_error))
		return false
	print(
		"ROGUE_COMBAT_GAME_03_NAVIGATION_GENERATED shapes=%d blocked=%d open=%d"
		% [authored_shape_count, blocked_count, used_cell_count - blocked_count]
	)
	return true


func _validate_wall_shapes(wall: StaticBody2D) -> int:
	var valid_shape_count := 0
	for child in wall.get_children():
		var collision_shape := child as CollisionShape2D
		if collision_shape == null:
			push_error("Wall 只能直接包含 CollisionShape2D：%s。" % child.name)
			return -1
		if collision_shape.disabled or collision_shape.shape == null:
			push_error("Wall 碰撞 %s 必须启用并绑定 Shape2D。" % child.name)
			return -1
		valid_shape_count += 1
	return valid_shape_count


func _build_semantic_tile_set() -> TileSet:
	var atlas_source := TileSetAtlasSource.new()
	atlas_source.texture = TILE_TEXTURE
	atlas_source.texture_region_size = CELL_SIZE
	atlas_source.create_tile(OPEN_TILE_COORDS)
	atlas_source.create_tile(BLOCKED_TILE_COORDS)

	var tile_set := TileSet.new()
	tile_set.tile_size = CELL_SIZE
	tile_set.add_physics_layer(0)
	tile_set.set_physics_layer_collision_layer(0, 0)
	tile_set.set_physics_layer_collision_mask(0, 0)
	tile_set.add_source(atlas_source, TILE_SOURCE_ID)
	var blocked_tile_data := atlas_source.get_tile_data(
		BLOCKED_TILE_COORDS,
		0
	)
	blocked_tile_data.add_collision_polygon(0)
	blocked_tile_data.set_collision_polygon_points(
		0,
		0,
		PackedVector2Array([
			Vector2(-8, -8),
			Vector2(8, -8),
			Vector2(8, 8),
			Vector2(-8, 8),
		])
	)
	return tile_set


func _shape_hits_wall(
	center: Vector2,
	probe: Shape2D,
	wall: StaticBody2D
) -> bool:
	var probe_transform := Transform2D(0.0, center)
	for child in wall.get_children():
		var collision_shape := child as CollisionShape2D
		if collision_shape.shape.collide(
			collision_shape.transform,
			probe,
			probe_transform
		):
			return true
	return false
