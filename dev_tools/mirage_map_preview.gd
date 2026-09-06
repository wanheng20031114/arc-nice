extends Node2D
## Finite visual/physics review: captures the authored map and quits.

func _ready() -> void:
	$Camera.zoom = Vector2.ONE * minf(get_viewport_rect().size.x / 1920.0, get_viewport_rect().size.y / 1600.0)
	for frame in range(12):
		await get_tree().process_frame
	var map := $Map as MirageMap
	var ground := $Map/WalkableFloor as TileMapLayer
	assert(ground.get_used_cells().size() == 1001)
	assert(map.get_obstacle_rects().size() == 89)
	for team in ["CT", "T"]:
		for index in range(8):
			var spawn := map.get_spawn_position(team, index)
			assert(map.is_in_buy_zone(spawn, team), "Spawn outside team buy zone: " + team)
			var shape := CircleShape2D.new()
			shape.radius = 9.0
			var query := PhysicsShapeQueryParameters2D.new()
			query.shape = shape
			query.transform.origin = spawn
			query.collision_mask = 1
			assert(get_world_2d().direct_space_state.intersect_shape(query).is_empty(), "Spawn overlaps map collision")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var error := get_viewport().get_texture().get_image().save_png("res://dev_tools/generated_sources/mirage_pvp/map_overview.png")
		assert(error == OK)
	print("MIRAGE_MAP: 1001 floor tiles, 89 obstacles, 16 safe spawns / buy zones verified")
	get_tree().quit()
