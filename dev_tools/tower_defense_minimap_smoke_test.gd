extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const MINIMAP_SCENE := preload("res://scene/tower_defense_minimap.tscn")
const REMOTE_PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const ENEMY_SCENE := preload("res://scene/enemy/yuanshi_insect_basic.tscn")
const MAX_SAMPLE_RATE_HZ := 30.0
const EXPECTED_HOME_GATE_CELL_COUNT := 4
const EXPECTED_MINIMAP_SIZE := Vector2(194.0, 130.0)
const EXPECTED_MAP_PANEL_SIZE := Vector2(194.0, 110.0)
const EXPECTED_CANVAS_SIZE := Vector2(192.0, 108.0)
const EXPECTED_COORDINATE_LABEL_SIZE := Vector2(194.0, 20.0)
const EXPECTED_ENEMY_BUCKET_CAPACITY := 48 * 27
const MAX_VIEWPORT_WIDTH_RATIO := 0.17
const MAX_VIEWPORT_HEIGHT_RATIO := 0.205
const MIN_MAIN_HUD_GAP_PX := 24.0

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Tower-defense scene must instantiate for minimap verification.")
	if game == null:
		_finish()
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await process_frame

	var independent_minimap := MINIMAP_SCENE.instantiate() as TowerDefenseMinimap
	_expect(
		independent_minimap != null,
		"Minimap must remain an independent instantiable scene."
	)
	if independent_minimap != null:
		independent_minimap.free()
	var minimap := game.tower_defense_minimap
	_expect(minimap != null, "Tower-defense scene must include the local minimap scene.")
	if minimap == null:
		game.queue_free()
		await process_frame
		_finish()
		return

	_verify_scene_structure(game, minimap)
	_verify_static_topology(minimap.minimap_canvas)
	_verify_projection_and_coordinate(game, minimap)
	await _verify_dynamic_markers(game, minimap.minimap_canvas)
	await _verify_multimesh_ab_isolation(minimap.minimap_canvas)

	game.queue_free()
	await process_frame
	await process_frame
	_finish()


func _verify_scene_structure(
	game: GameTowerDefense,
	minimap: TowerDefenseMinimap
) -> void:
	_expect(minimap.layer == 9, "Minimap must render above the world in its own CanvasLayer.")
	_expect(
		minimap.layer < game.wave_hud.layer,
		"WaveHUD victory and defeat results must cover the minimap."
	)
	_expect(
		minimap.layer < game.currency_hud.layer,
		"The currency HUD layer must remain above the minimap."
	)
	var top_left_margin := minimap.get_node("TopLeftMargin") as MarginContainer
	var content := minimap.get_node("TopLeftMargin/Content") as VBoxContainer
	var map_panel := minimap.get_node(
		"TopLeftMargin/Content/MapPanel"
	) as PanelContainer
	_expect(
		top_left_margin.position.is_equal_approx(Vector2(8.0, 8.0)),
		"The minimap must occupy the true upper-left corner with an 8 px margin."
	)
	_expect(
		top_left_margin.size.is_equal_approx(EXPECTED_MINIMAP_SIZE),
		"The complete minimap, including coordinates, must remain 194 x 130 px; got %s."
		% top_left_margin.size
	)
	_expect(
		map_panel.size.is_equal_approx(EXPECTED_MAP_PANEL_SIZE),
		"The framed map must remain compact at 194 x 110 px."
	)
	_expect(
		minimap.minimap_canvas.size.is_equal_approx(EXPECTED_CANVAS_SIZE),
		"The drawable minimap canvas must remain 192 x 108 px."
	)
	_expect(
		minimap.coordinate_label.size.is_equal_approx(EXPECTED_COORDINATE_LABEL_SIZE),
		"The rendered coordinate row must remain a compact 20 px-high single line; got %s."
		% minimap.coordinate_label.size
	)
	_expect(
		minimap.coordinate_label.get_parent() == content
		and content.get_theme_constant("separation") <= 1,
		"The coordinate label must sit directly below the map with at most 1 px separation."
	)
	_expect(
		minimap.get_node_or_null("TopLeftMargin/Content/CoordinatePanel") == null
		and minimap.coordinate_label is Label,
		"The coordinate text must not use a panel or background frame."
	)
	var minimap_rect := top_left_margin.get_global_rect()
	var viewport_size := minimap.get_viewport().get_visible_rect().size
	_expect(
		minimap_rect.size.x <= viewport_size.x * MAX_VIEWPORT_WIDTH_RATIO
		and minimap_rect.size.y <= viewport_size.y * MAX_VIEWPORT_HEIGHT_RATIO,
		"The complete minimap must stay within 17%% width and 20.5%% height; got %s in %s."
		% [minimap_rect.size, viewport_size]
	)
	_expect(
		not minimap_rect.intersects(game.currency_hud.settings_button.get_global_rect()),
		"Moving the minimap to the true upper-left must not overlap the relocated settings button."
	)
	var main_hud_rect := game.wave_hud.top_bar.get_global_rect()
	_expect(
		not minimap_rect.intersects(main_hud_rect),
		"The upper-left minimap must remain clear of the centered main HUD."
	)
	_expect(
		main_hud_rect.position.x - minimap_rect.end.x >= MIN_MAIN_HUD_GAP_PX,
		"The compact minimap and centered HUD must retain at least 24 px of clear space."
	)
	_expect(
		is_equal_approx(minimap.sample_timer.wait_time, TowerDefenseMinimap.SAMPLE_INTERVAL_SECONDS),
		"Minimap must use its authored stagger timer interval."
	)
	_expect(
		1.0 / minimap.sample_timer.wait_time <= MAX_SAMPLE_RATE_HZ,
		"The aggregate minimap sample timer must not exceed 30 Hz."
	)
	_expect(
		not minimap.sample_timer.one_shot
		and minimap.sample_timer.timeout.is_connected(minimap._on_sample_timer_timeout),
		"The native Timer must repeat through the scene-authored timeout connection."
	)
	var canvas_size := minimap.minimap_canvas.size
	_expect(
		is_equal_approx(canvas_size.x / canvas_size.y, 16.0 / 9.0),
		"The authored map canvas must remain 16:9."
	)
	_expect(
		minimap.coordinate_label.get_theme_font_size("font_size") == 13
		and minimap.coordinate_label.get_theme_constant("outline_size") == 1,
		"Compact coordinates must use a readable 13 px font with a restrained 1 px outline."
	)
	_expect(
		minimap.minimap_canvas.get_node("StaticLayer") is Control
		and minimap.minimap_canvas.get_node("DynamicLayer") is Control,
		"Static topology and dynamic markers must use separate draw layers."
	)
	var dynamic_layer := minimap.minimap_canvas.dynamic_layer
	_expect(
		typeof(dynamic_layer._enemy_canvas_bucket_counts)
		== TYPE_PACKED_INT32_ARRAY
		and dynamic_layer._enemy_canvas_bucket_counts.size()
		== EXPECTED_ENEMY_BUCKET_CAPACITY,
		"The 192 x 108 minimap must use one reusable packed 48 x 27 enemy bucket table."
	)
	_expect(
		typeof(dynamic_layer._touched_enemy_bucket_indices)
		== TYPE_PACKED_INT32_ARRAY,
		"Enemy bucket cleanup must track only touched packed-array indices."
	)
	_expect(
		dynamic_layer.use_multimesh_batches
		and dynamic_layer.enemy_marker_multimesh != null
		and dynamic_layer.enemy_marker_multimesh.transform_format
		== MultiMesh.TRANSFORM_2D
		and dynamic_layer.enemy_marker_multimesh.use_colors,
		"Enemy density markers must use the authored colored 2D MultiMesh batch."
	)
	var static_layer := minimap.minimap_canvas.static_layer
	_expect(
		static_layer.use_multimesh_batches
		and static_layer.static_tile_mesh != null
		and static_layer.water_multimesh != null
		and static_layer.wall_multimesh != null
		and static_layer.enemy_gate_multimesh != null
		and static_layer.home_gate_multimesh != null,
		"Static topology must retain four authored MultiMesh batches in draw order."
	)
	_expect(
		minimap.find_children("*", "SubViewport", true, false).is_empty(),
		"The minimap must not render the world a second time through a SubViewport."
	)


func _verify_static_topology(canvas: TowerDefenseMinimapCanvas) -> void:
	var layer := canvas.static_layer
	_expect(not layer.wall_world_positions.is_empty(), "Minimap must cache wall cells.")
	_expect(not layer.water_world_positions.is_empty(), "Minimap must cache water cells.")
	_expect(
		layer.home_gate_world_positions.size() == EXPECTED_HOME_GATE_CELL_COUNT,
		"Minimap must render every blue Home gate cell."
	)
	_expect(
		not layer.enemy_gate_world_positions.is_empty(),
		"Minimap must render the authored red enemy gates."
	)
	_expect(
		canvas.dynamic_layer.plant_world_positions.is_empty(),
		"An empty PlantContainer must produce no phantom minimap plants."
	)
	_verify_static_multimesh_signature(
		layer.water_multimesh,
		layer.water_world_positions,
		layer._water_batch_world_positions,
		TowerDefenseMinimapStaticLayer.WATER_COLOR,
		"water"
	)
	_verify_static_multimesh_signature(
		layer.wall_multimesh,
		layer.wall_world_positions,
		layer._wall_batch_world_positions,
		TowerDefenseMinimapStaticLayer.WALL_COLOR,
		"wall"
	)
	_verify_static_multimesh_signature(
		layer.enemy_gate_multimesh,
		layer.enemy_gate_world_positions,
		layer._enemy_gate_batch_world_positions,
		TowerDefenseMinimapStaticLayer.ENEMY_GATE_COLOR,
		"enemy gate"
	)
	_verify_static_multimesh_signature(
		layer.home_gate_multimesh,
		layer.home_gate_world_positions,
		layer._home_gate_batch_world_positions,
		TowerDefenseMinimapStaticLayer.HOME_GATE_COLOR,
		"home gate"
	)
	_expect(
		layer.static_tile_mesh.size.is_equal_approx(layer.tile_world_size),
		"The shared static QuadMesh must preserve the authored world tile size."
	)


func _verify_static_multimesh_signature(
	multimesh: MultiMesh,
	positions: PackedVector2Array,
	batch_positions: PackedVector2Array,
	color: Color,
	label: String
) -> void:
	_expect(
		multimesh.instance_count == positions.size(),
		"The %s MultiMesh count must match its topology source." % label
	)
	_expect(
		batch_positions == positions,
		"The %s CPU batch signature must exactly match its legacy topology source."
		% label
	)
	_expect(
		color.a > 0.0,
		"The %s batch must retain a visible authored color." % label
	)


func _verify_projection_and_coordinate(
	game: GameTowerDefense,
	minimap: TowerDefenseMinimap
) -> void:
	var canvas := minimap.minimap_canvas
	var expected_coordinate := game.ground_tile_map_layer.local_to_map(
		game.ground_tile_map_layer.to_local(game.player.global_position)
	)
	_expect(
		canvas.get_tile_coordinate() == expected_coordinate,
		"Coordinate label data must use integer TileMapLayer coordinates."
	)
	_expect(
		minimap.coordinate_label.text == "当前坐标：%d, %d" % [
			expected_coordinate.x,
			expected_coordinate.y,
		],
		"The integer tile coordinate must be displayed below the map."
	)

	var view_rect := canvas.static_layer.get_projected_view_rect()
	_expect(
		is_equal_approx(view_rect.size.x / canvas.static_layer.size.x, 1.0 / 3.0),
		"The current-view frame width must occupy one third of the minimap."
	)
	_expect(
		is_equal_approx(view_rect.size.y / canvas.static_layer.size.y, 1.0 / 3.0),
		"The current-view frame height must occupy one third of the minimap."
	)
	_expect(
		canvas.dynamic_layer.local_player_world_position.is_equal_approx(
			game.player.global_position
		),
		"The local green marker must sample the local player node directly."
	)
	_expect(
		TowerDefenseMinimapDynamicLayer.LOCAL_PLAYER_COLOR
		== Color(0.18, 1.0, 0.38, 1.0),
		"The local-player marker must remain green."
	)
	_expect(
		TowerDefenseMinimapDynamicLayer.LOCAL_PLAYER_RADIUS >= 1.5
		and TowerDefenseMinimapDynamicLayer.LOCAL_PLAYER_RADIUS <= 1.7
		and TowerDefenseMinimapDynamicLayer.REMOTE_PLAYER_RADIUS >= 1.0
		and TowerDefenseMinimapDynamicLayer.REMOTE_PLAYER_RADIUS <= 1.25,
		"Local and remote player dots must remain compact without becoming sub-pixel marks."
	)
	_expect(
		TowerDefenseMinimapDynamicLayer.LOCAL_PLAYER_CENTER_RADIUS >= 0.45
		and (
			TowerDefenseMinimapDynamicLayer.LOCAL_PLAYER_CENTER_RADIUS
			< TowerDefenseMinimapDynamicLayer.LOCAL_PLAYER_RADIUS
		)
		and TowerDefenseMinimapDynamicLayer.PLAYER_MARKER_OUTLINE_WIDTH >= 0.3
		and TowerDefenseMinimapDynamicLayer.PLAYER_MARKER_OUTLINE_WIDTH <= 0.4,
		"The local player must retain a visible center and a thin contrasting outline."
	)
	var projected_origin := canvas.static_layer._world_to_canvas(Vector2.ZERO)
	var projected_east := canvas.static_layer._world_to_canvas(Vector2(16.0, 0.0))
	var projected_north := canvas.static_layer._world_to_canvas(Vector2(0.0, -16.0))
	_expect(
		projected_east.x > projected_origin.x
		and is_equal_approx(projected_east.y, projected_origin.y)
		and projected_north.y < projected_origin.y
		and is_equal_approx(projected_north.x, projected_origin.x),
		"World axes must project directly so north remains up on the minimap."
	)
	var expected_projection_scale := minf(
		canvas.static_layer.size.x / canvas.static_layer.overview_world_size.x,
		canvas.static_layer.size.y / canvas.static_layer.overview_world_size.y
	)
	_expect(
		is_equal_approx(
			canvas.static_layer._projection_scale,
			expected_projection_scale
		)
		and is_equal_approx(
			canvas.dynamic_layer._projection_scale,
			expected_projection_scale
		),
		"Both minimap layers must cache the shared world-to-canvas projection scale."
	)
	var static_redraw_count := canvas.static_layer._redraw_request_count
	var dynamic_redraw_count := canvas.dynamic_layer._redraw_request_count
	canvas.static_layer.set_projection(
		canvas.static_layer.world_center,
		canvas.static_layer.overview_world_size,
		canvas.static_layer.visible_world_size
	)
	canvas.dynamic_layer.set_projection(
		canvas.dynamic_layer.world_center,
		canvas.dynamic_layer.overview_world_size
	)
	canvas.dynamic_layer.set_local_player_position(
		canvas.dynamic_layer.local_player_world_position
	)
	_expect(
		canvas.static_layer._redraw_request_count == static_redraw_count
		and canvas.dynamic_layer._redraw_request_count == dynamic_redraw_count,
		"Unchanged projection and local-player samples must not request redraws."
	)
	var projected_tile_rect := canvas.static_layer._world_rect_to_canvas(
		Rect2(Vector2.ZERO, canvas.static_layer.tile_world_size)
	)
	_expect(
		projected_tile_rect.size.is_equal_approx(
			canvas.static_layer.tile_world_size * expected_projection_scale
		)
		and canvas.static_layer._projected_tile_size.is_equal_approx(
			projected_tile_rect.size
		),
		"Static topology must reuse one cached projected tile size for every cell."
	)

	var previous_coordinate := expected_coordinate
	game.player.global_position += Vector2(16.0, 0.0)
	canvas.sample_next_phase()
	canvas.sample_next_phase()
	_expect(
		canvas.get_tile_coordinate() == previous_coordinate + Vector2i.RIGHT,
		"Staggered sampling must refresh the local tile coordinate on its camera phase."
	)


func _verify_dynamic_markers(
	game: GameTowerDefense,
	canvas: TowerDefenseMinimapCanvas
) -> void:
	var remote_player := REMOTE_PLAYER_SCENE.instantiate() as Player
	remote_player.uses_local_input = false
	remote_player.set_physics_process(false)
	game.add_child(remote_player)
	remote_player.global_position = game.player.global_position + Vector2(48.0, 0.0)

	var enemy := ENEMY_SCENE.instantiate() as Enemy
	enemy.set_process(false)
	enemy.set_physics_process(false)
	game.enemy_container.add_child(enemy)
	enemy.global_position = game.player.global_position + Vector2(-48.0, -32.0)

	var plant := PlantDefense.new()
	game.plant_container.add_child(plant)
	plant.global_position = game.player.global_position + Vector2(24.0, 48.0)
	await process_frame

	canvas._sample_world_entities()
	_expect(
		canvas.dynamic_layer.remote_player_world_positions.has(remote_player.global_position),
		"A sampled remote player must enter the white-marker data layer."
	)
	_expect(
		canvas.dynamic_layer.enemy_world_positions.has(enemy.global_position),
		"A sampled living enemy must enter the red-marker data layer."
	)
	_expect(
		canvas.dynamic_layer.plant_world_positions.has(plant.global_position),
		"A sampled plant must enter the light-green square data layer."
	)
	_expect(
		TowerDefenseMinimapDynamicLayer.REMOTE_PLAYER_COLOR == Color(0.96, 0.98, 1.0, 1.0),
		"Remote-player markers must remain white."
	)
	_expect(
		TowerDefenseMinimapDynamicLayer.ENEMY_COLOR == Color(1.0, 0.18, 0.14, 1.0),
		"Enemy markers must remain red."
	)
	_expect(
		TowerDefenseMinimapDynamicLayer.PLANT_COLOR == Color(0.52, 0.91, 0.54, 0.96),
		"Plant markers must remain light green."
	)
	var redraw_count := canvas.dynamic_layer._redraw_request_count
	canvas.dynamic_layer.set_world_entities(
		canvas.dynamic_layer.remote_player_world_positions,
		canvas.dynamic_layer.enemy_world_positions,
		canvas.dynamic_layer.plant_world_positions
	)
	_expect(
		canvas.dynamic_layer._redraw_request_count == redraw_count,
		"An unchanged entity snapshot must not request another dynamic redraw."
	)
	_verify_enemy_marker_aggregation(canvas.dynamic_layer, enemy.global_position)


func _verify_enemy_marker_aggregation(
	dynamic_layer: TowerDefenseMinimapDynamicLayer,
	anchor_world_position: Vector2
) -> void:
	dynamic_layer.enemy_world_positions = PackedVector2Array(
		[
			anchor_world_position,
			anchor_world_position + Vector2(1.0, 0.0),
			anchor_world_position + Vector2(2.0, 0.0),
			anchor_world_position + Vector2(3.0, 0.0),
			anchor_world_position + Vector2(4.0, 0.0),
		]
	)
	var overview_rect := Rect2(
		dynamic_layer.world_center - dynamic_layer.overview_world_size * 0.5,
		dynamic_layer.overview_world_size
	)
	var buckets := dynamic_layer._build_enemy_canvas_buckets(overview_rect)
	_expect(
		buckets.size() == 1 and buckets[0]["count"] == 5,
		"Enemies inside one 4 px canvas bucket must collapse into one density marker."
	)
	_expect(
		dynamic_layer.enemy_marker_multimesh.visible_instance_count == 1
		and dynamic_layer._enemy_marker_canvas_centers[0].is_equal_approx(
			buckets[0]["canvas_position"]
		)
		and is_equal_approx(
			dynamic_layer._enemy_marker_radii[0],
			dynamic_layer.get_enemy_marker_radius(5)
		)
		and dynamic_layer._enemy_marker_bucket_indices[0]
		== dynamic_layer._touched_enemy_bucket_indices[0],
		"The batched enemy marker must preserve the dense bucket center, radius, and color."
	)
	_expect(
		dynamic_layer.get_enemy_marker_radius(1)
		< dynamic_layer.get_enemy_marker_radius(2)
		and dynamic_layer.get_enemy_marker_radius(2)
		< dynamic_layer.get_enemy_marker_radius(5),
		"Single, medium, and high enemy densities must use distinct marker radii."
	)
	_expect(
		dynamic_layer.get_enemy_marker_radius(5) <= 2.0,
		"Even the highest enemy-density marker must remain below a 2 px radius."
	)
	_expect(
		TowerDefenseMinimapDynamicLayer.ENEMY_SINGLE_RADIUS >= 1.0
		and (
			TowerDefenseMinimapDynamicLayer.ENEMY_HIGH_RADIUS * 2.0
			<= TowerDefenseMinimapDynamicLayer.ENEMY_BUCKET_SIZE_PX
		),
		"Enemy dots must remain visible while adjacent highest-density buckets cannot overlap."
	)

	# Stress the exact boundary that used to leave averaged representatives almost coincident.
	dynamic_layer.set_projection(dynamic_layer.size * 0.5, dynamic_layer.size)
	dynamic_layer.enemy_world_positions = PackedVector2Array(
		[
			Vector2(3.99, 40.0),
			Vector2(3.99, 40.0),
			Vector2(3.99, 40.0),
			Vector2(3.99, 40.0),
			Vector2(3.99, 40.0),
			Vector2(4.01, 40.0),
			Vector2(4.01, 40.0),
			Vector2(4.01, 40.0),
			Vector2(4.01, 40.0),
			Vector2(4.01, 40.0),
		]
	)
	var boundary_overview_rect := Rect2(Vector2.ZERO, dynamic_layer.size)
	var boundary_buckets := dynamic_layer._build_enemy_canvas_buckets(
		boundary_overview_rect
	)
	var boundary_centers := PackedVector2Array()
	for bucket in boundary_buckets:
		boundary_centers.append(bucket["canvas_position"])
	_expect(
		boundary_buckets.size() == 2
		and boundary_centers.has(Vector2(2.0, 42.0))
		and boundary_centers.has(Vector2(6.0, 42.0)),
		"Enemies at 3.99 px and 4.01 px must use adjacent fixed bucket centers."
	)
	_expect(
		dynamic_layer.enemy_marker_multimesh.visible_instance_count
		== boundary_buckets.size(),
		"The enemy MultiMesh visible count must exactly match touched buckets."
	)
	if boundary_buckets.size() == 2:
		var first_boundary_bucket: Dictionary = boundary_buckets[0]
		var second_boundary_bucket: Dictionary = boundary_buckets[1]
		var first_boundary_center: Vector2 = first_boundary_bucket["canvas_position"]
		var second_boundary_center: Vector2 = second_boundary_bucket["canvas_position"]
		var boundary_distance := first_boundary_center.distance_to(second_boundary_center)
		var combined_radii := (
			dynamic_layer.get_enemy_marker_radius(first_boundary_bucket["count"])
			+ dynamic_layer.get_enemy_marker_radius(second_boundary_bucket["count"])
		)
		_expect(
			boundary_distance >= combined_radii,
			"Adjacent high-density bucket markers must not overlap across a 4 px boundary."
		)

	# Rebuilding a different bucket set must clear only the previously touched
	# packed slots; stale density counts cannot leak into a later draw.
	dynamic_layer.enemy_world_positions = PackedVector2Array(
		[Vector2(12.0, 12.0), Vector2(12.0, 12.0)]
	)
	dynamic_layer._rebuild_enemy_canvas_bucket_counts(boundary_overview_rect)
	var previous_bucket_index := int(dynamic_layer._touched_enemy_bucket_indices[0])
	_expect(
		dynamic_layer._enemy_canvas_bucket_counts[previous_bucket_index] == 2,
		"The packed enemy bucket table must accumulate density in-place."
	)
	dynamic_layer.enemy_world_positions = PackedVector2Array([Vector2(100.0, 80.0)])
	dynamic_layer._rebuild_enemy_canvas_bucket_counts(boundary_overview_rect)
	var replacement_bucket_index := int(dynamic_layer._touched_enemy_bucket_indices[0])
	_expect(
		previous_bucket_index != replacement_bucket_index
		and dynamic_layer._enemy_canvas_bucket_counts[previous_bucket_index] == 0
		and dynamic_layer._enemy_canvas_bucket_counts[replacement_bucket_index] == 1
		and dynamic_layer._touched_enemy_bucket_indices.size() == 1,
		"Touched-index cleanup must zero old packed slots without retaining stale buckets."
	)


func _verify_multimesh_ab_isolation(
	canvas: TowerDefenseMinimapCanvas
) -> void:
	var dynamic_layer := canvas.dynamic_layer
	var dynamic_sync_count := dynamic_layer._multimesh_sync_count
	var stale_dynamic_visible_count := (
		dynamic_layer.enemy_marker_multimesh.visible_instance_count
	)
	var stale_dynamic_transform := Transform2D.IDENTITY
	if stale_dynamic_visible_count > 0:
		stale_dynamic_transform = (
			dynamic_layer.enemy_marker_multimesh.get_instance_transform_2d(0)
		)
	dynamic_layer.use_multimesh_batches = false
	await process_frame
	await process_frame
	_expect(
		not dynamic_layer._last_draw_used_multimesh_batches
		and dynamic_layer._multimesh_sync_count == dynamic_sync_count,
		(
			"Disabling dynamic batches alone must redraw immediately without "
			+ "uploading a replacement MultiMesh snapshot."
		)
	)
	var replacement_enemy_positions := PackedVector2Array([
		dynamic_layer.world_center + Vector2(-32.0, 0.0),
		dynamic_layer.world_center + Vector2(32.0, 0.0),
	])
	dynamic_layer.set_world_entities(
		PackedVector2Array(),
		replacement_enemy_positions,
		PackedVector2Array()
	)
	await process_frame
	await process_frame
	var dynamic_buffer_unchanged := (
		dynamic_layer.enemy_marker_multimesh.visible_instance_count
		== stale_dynamic_visible_count
	)
	if stale_dynamic_visible_count > 0:
		dynamic_buffer_unchanged = (
			dynamic_buffer_unchanged
			and dynamic_layer.enemy_marker_multimesh.get_instance_transform_2d(0)
			== stale_dynamic_transform
		)
	_expect(
		dynamic_layer._multimesh_sync_count == dynamic_sync_count
		and dynamic_buffer_unchanged
		and not dynamic_layer._last_draw_used_multimesh_batches,
		"Legacy dynamic update+draw must not upload or draw the stale enemy MultiMesh."
	)
	dynamic_layer.use_multimesh_batches = true
	var rebuilt_dynamic_marker_count := dynamic_layer._touched_enemy_bucket_indices.size()
	_expect(
		dynamic_layer._multimesh_sync_count == dynamic_sync_count + 1
		and dynamic_layer.enemy_marker_multimesh.visible_instance_count
		== rebuilt_dynamic_marker_count,
		(
			"Re-enabling dynamic batches must rebuild the latest snapshot exactly once "
			+ "(sync %d -> %d, visible %d, expected %d)."
		)
		% [
			dynamic_sync_count,
			dynamic_layer._multimesh_sync_count,
			dynamic_layer.enemy_marker_multimesh.visible_instance_count,
			rebuilt_dynamic_marker_count,
		]
	)
	await process_frame
	await process_frame
	_expect(
		dynamic_layer._last_draw_used_multimesh_batches,
		"Re-enabled dynamic rendering must return to the MultiMesh draw path."
	)

	var static_layer := canvas.static_layer
	var static_upload_pass_count := static_layer._multimesh_upload_pass_count
	var stale_wall_count := static_layer.wall_multimesh.instance_count
	var stale_wall_transform := Transform2D.IDENTITY
	if stale_wall_count > 0:
		stale_wall_transform = static_layer.wall_multimesh.get_instance_transform_2d(0)
	static_layer.use_multimesh_batches = false
	await process_frame
	await process_frame
	_expect(
		not static_layer._last_draw_used_multimesh_batches
		and static_layer._multimesh_upload_pass_count == static_upload_pass_count,
		(
			"Disabling static batches alone must redraw immediately without "
			+ "uploading replacement topology buffers."
		)
	)
	var replacement_walls := PackedVector2Array([
		static_layer.world_center + Vector2(-16.0, 0.0),
		static_layer.world_center + Vector2(16.0, 0.0),
		static_layer.world_center + Vector2(0.0, -16.0),
	])
	static_layer.set_topology(
		static_layer.tile_world_size,
		replacement_walls,
		PackedVector2Array([static_layer.world_center + Vector2(0.0, 16.0)]),
		PackedVector2Array(),
		PackedVector2Array()
	)
	await process_frame
	await process_frame
	var static_buffer_unchanged := (
		static_layer.wall_multimesh.instance_count == stale_wall_count
	)
	if stale_wall_count > 0:
		static_buffer_unchanged = (
			static_buffer_unchanged
			and static_layer.wall_multimesh.get_instance_transform_2d(0)
			== stale_wall_transform
		)
	_expect(
		static_layer._multimesh_upload_pass_count == static_upload_pass_count
		and static_buffer_unchanged
		and not static_layer._last_draw_used_multimesh_batches,
		"Legacy static update+draw must not upload or draw any topology MultiMesh."
	)
	static_layer.use_multimesh_batches = true
	_expect(
		static_layer._multimesh_upload_pass_count == static_upload_pass_count + 1
		and static_layer.wall_multimesh.instance_count == replacement_walls.size()
		and static_layer._wall_batch_world_positions == replacement_walls,
		(
			"Re-enabling static batches must rebuild the latest topology exactly once "
			+ "(pass %d -> %d, walls %d, expected %d)."
		)
		% [
			static_upload_pass_count,
			static_layer._multimesh_upload_pass_count,
			static_layer.wall_multimesh.instance_count,
			replacement_walls.size(),
		]
	)
	await process_frame
	await process_frame
	_expect(
		static_layer._last_draw_used_multimesh_batches,
		"Re-enabled static rendering must return to the MultiMesh draw path."
	)


func _finish() -> void:
	if failures.is_empty():
		print("TOWER_DEFENSE_MINIMAP_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
