extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const VEGETATION_STAKE_CONFIG := preload(
	"res://resources/config/plant_defense/vegetation_stake.tres"
)
const OUTPUT_DIRECTORY := "res://dev_tools/output/vegetation_stake_range"
const CAPTURE_SIZE := Vector2i(768, 576)
const CAPTURE_NET_ID := 9_600_001
const OLD_RADIUS := 5
const OLD_CAPTURE_SECONDS := 49.9
const NEW_CAPTURE_SECONDS := 59.9
const MIN_ELIGIBLE_SPREAD_CELLS := 48

var failures: Array[String] = []
var game: TowerDefenseGame = null
var spread: VegetationSpreadSystem = null
var stake: VegetationStake = null
var anchor := Vector2i.MAX


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("植被桩实战范围图必须使用图形显示驱动运行。")
		quit(2)
		return
	_configure_capture_window()
	_mute_audio()
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	if run_state != null:
		run_state.set_selected_character(PlayerCharacterRegistry.WEISHIDAIER_ID)

	game = TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "实战范围图必须能实例化正式塔防场景。")
	if game == null:
		_finish()
		return
	game.auto_start_waves = false
	game.linglan_boss_enabled = false
	game.day_phase_announcements_enabled = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	await process_frame

	spread = game.get_node_or_null("VegetationSpreadSystem") as VegetationSpreadSystem
	_expect(
		spread != null and game.plant_system != null and game.player != null,
		"正式塔防场景必须完成植物与植被传播初始化。"
	)
	if not failures.is_empty():
		await _finish()
		return

	var old_offsets := _collect_offsets_through_radius(OLD_RADIUS)
	var new_offsets := _collect_offsets_through_radius(
		VegetationSpreadSystem.SPREAD_RADIUS
	)
	var added_offsets := _difference(new_offsets, old_offsets)
	_expect(old_offsets.size() == 88, "旧半径5必须保持88个有效扩散格。")
	_expect(new_offsets.size() == 120, "新半径6必须包含120个有效扩散格。")
	_expect(added_offsets.size() == 32, "半径提升必须只新增32格。")
	for offset in old_offsets:
		_expect(new_offsets.has(offset), "旧范围不能因半径提升而退化：%s" % offset)
	anchor = _select_capture_anchor(new_offsets)
	_expect(anchor != Vector2i.MAX, "正式地图中找不到可展示完整扩散范围的植被桩锚点。")
	if anchor == Vector2i.MAX:
		await _finish()
		return

	stake = game.plant_system.try_place_for_player(
		VEGETATION_STAKE_CONFIG,
		anchor,
		game.player,
		CAPTURE_NET_ID
	) as VegetationStake
	_expect(stake != null, "必须通过正式PlantSystem放置植被桩。")
	if stake == null:
		await _finish()
		return
	stake.construction_finished.connect(
		_on_capture_stake_construction_finished.bind(stake),
		CONNECT_ONE_SHOT
	)
	stake.call("_finish_construction", false)
	await process_frame
	_expect(
		stake.is_operational and spread.has_source(CAPTURE_NET_ID),
		"植被桩建造完成后必须注册真实扩散来源。"
	)
	if not failures.is_empty():
		await _finish()
		return
	spread.set_process(false)

	_stop_background_gameplay()
	_hide_capture_hud()
	_prepare_camera()
	var audit_overlay := RangeAuditOverlay.new()
	audit_overlay.name = "RangeAuditOverlay"
	audit_overlay.z_index = 8
	audit_overlay.configure(
		game.dual_grid_terrain.world_map_layer,
		anchor,
		old_offsets,
		added_offsets
	)
	game.add_child(audit_overlay)

	var current_elapsed := spread.get_source_elapsed_seconds(CAPTURE_NET_ID)
	spread.advance_time(maxf(OLD_CAPTURE_SECONDS - current_elapsed, 0.0))
	spread.call("_process", 0.0)
	audit_overlay.show_added_cells = false
	audit_overlay.queue_redraw()
	var old_path := await _capture("vegetation_stake_range_r5_49_9s.png")
	_expect(
		spread.get_source_elapsed_seconds(CAPTURE_NET_ID) < 50.0 + 0.001,
		"旧范围截图必须停在第五环结算前。"
	)

	current_elapsed = spread.get_source_elapsed_seconds(CAPTURE_NET_ID)
	spread.advance_time(maxf(NEW_CAPTURE_SECONDS - current_elapsed, 0.0))
	spread.call("_process", 0.0)
	audit_overlay.show_added_cells = true
	audit_overlay.queue_redraw()
	var new_path := await _capture("vegetation_stake_range_r6_59_9s.png")
	_expect(
		spread.get_source_elapsed_seconds(CAPTURE_NET_ID) < 60.0 + 0.001,
		"新范围截图必须停在第六环结算前。"
	)
	print(
		"VEGETATION_STAKE_RANGE_CAPTURE anchor=%s old=88 new=120 added=32 old_path=%s new_path=%s"
		% [str(anchor), old_path, new_path]
	)
	await _finish()


func _on_capture_stake_construction_finished(
	vegetation_stake: VegetationStake
) -> void:
	game.plant_runtime_coordinator.call(
		"_on_vegetation_stake_construction_finished",
		vegetation_stake
	)


func _select_capture_anchor(offsets: Array[Vector2i]) -> Vector2i:
	var candidates := game.plant_system.get_valid_anchors_for_player(
		VEGETATION_STAKE_CONFIG,
		game.player
	)
	var best_anchor := Vector2i.MAX
	var best_eligible_count := -1
	var best_distance_squared := INF
	var preferred_world_position := Vector2(112, 336)
	for candidate in candidates:
		var eligible_count := 0
		for offset in offsets:
			var cell := candidate + offset
			if not spread.frozen_bounds.has_point(cell):
				continue
			var baseline := int(
				game.plant_runtime_coordinator.authored_terrain_baseline.get(
					cell,
					DualGridTilemap.TerrainType.METAL
				)
			)
			if baseline in [
				DualGridTilemap.TerrainType.EMPTY,
				DualGridTilemap.TerrainType.DIRT,
			]:
				eligible_count += 1
		var candidate_world := game.plant_system.get_anchor_world_position(
			candidate,
			VEGETATION_STAKE_CONFIG
		)
		var distance_squared := candidate_world.distance_squared_to(
			preferred_world_position
		)
		if (
			eligible_count > best_eligible_count
			or (
				eligible_count == best_eligible_count
				and distance_squared < best_distance_squared
			)
		):
			best_anchor = candidate
			best_eligible_count = eligible_count
			best_distance_squared = distance_squared
	_expect(
		best_eligible_count >= MIN_ELIGIBLE_SPREAD_CELLS,
		"实战范围图可绿化格过少：%d/%d。" % [best_eligible_count, offsets.size()]
	)
	print(
		"VEGETATION_STAKE_RANGE_ANCHOR cell=%s eligible=%d/%d"
		% [str(best_anchor), best_eligible_count, offsets.size()]
	)
	return best_anchor


func _prepare_camera() -> void:
	if game.player != null:
		game.player.global_position = stake.global_position + Vector2(48, 0)
		game.player.velocity = Vector2.ZERO
		game.player.reset_physics_interpolation()
	if game.map_camera == null:
		return
	if game.map_camera.get_parent() == game.player:
		game.map_camera.position = Vector2.ZERO
	else:
		game.map_camera.global_position = stake.global_position
	game.map_camera.zoom = Vector2(2, 2)
	game.map_camera.position_smoothing_enabled = false
	game.map_camera.enabled = true
	game.map_camera.reset_physics_interpolation()
	game.map_camera.force_update_scroll()


func _stop_background_gameplay() -> void:
	game.set_process(false)
	game.set_physics_process(false)
	spread.set_process(false)
	game.enemy_spawn_timer.stop()
	game.state_timer.stop()
	if game.day_night_controller != null:
		game.day_night_controller.set_night_factor_immediate(0.0)
	for candidate in game.find_children("*", "", true, false):
		if candidate is Timer:
			(candidate as Timer).stop()
		elif candidate is AudioStreamPlayer:
			(candidate as AudioStreamPlayer).stop()
		elif candidate is AudioStreamPlayer2D:
			(candidate as AudioStreamPlayer2D).stop()


func _hide_capture_hud() -> void:
	for candidate in game.find_children("*", "CanvasLayer", true, false):
		(candidate as CanvasLayer).hide()
	for canvas_item in [
		game.currency_hud,
		game.wave_hud,
		game.day_phase_announcement,
		game.tower_defense_status_hud,
		game.tower_defense_minimap,
		game.oak_warehouse_panel,
		game.production_building_panel,
		game.research_center_panel,
		game.player_profile_panel,
		game.get_node_or_null("SettingsLayer"),
	]:
		if canvas_item is CanvasLayer:
			(canvas_item as CanvasLayer).hide()
		elif canvas_item is CanvasItem:
			(canvas_item as CanvasItem).hide()


func _capture(file_name: String) -> String:
	await process_frame
	var image := root.get_texture().get_image()
	var output_path := "%s/%s" % [OUTPUT_DIRECTORY, file_name]
	var absolute_path := ProjectSettings.globalize_path(output_path)
	_expect(
		image != null and not image.is_empty() and image.save_png(absolute_path) == OK,
		"无法保存植被桩实战范围图：%s" % absolute_path
	)
	return absolute_path


func _collect_offsets_through_radius(radius: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for ring in range(1, radius + 1):
		result.append_array(VegetationSpreadSystem.get_ring_offsets(ring))
	return result


func _difference(
	all_offsets: Array[Vector2i],
	base_offsets: Array[Vector2i]
) -> Array[Vector2i]:
	var base_set: Dictionary = {}
	for offset in base_offsets:
		base_set[offset] = true
	var result: Array[Vector2i] = []
	for offset in all_offsets:
		if not base_set.has(offset):
			result.append(offset)
	return result


func _configure_capture_window() -> void:
	Engine.max_fps = 60
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(CAPTURE_SIZE)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	root.content_scale_size = CAPTURE_SIZE
	root.size = CAPTURE_SIZE


func _mute_audio() -> void:
	for bus_index in range(AudioServer.bus_count):
		AudioServer.set_bus_mute(bus_index, true)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _finish() -> void:
	if game != null and is_instance_valid(game):
		game.queue_free()
	await process_frame
	await process_frame
	if failures.is_empty():
		print("VEGETATION_STAKE_RANGE_VISUAL_CAPTURE_OK")
		quit(0)
		return
	print("VEGETATION_STAKE_RANGE_VISUAL_CAPTURE_FAILED count=%d" % failures.size())
	quit(1)


class RangeAuditOverlay:
	extends Node2D

	var tile_map_layer: TileMapLayer = null
	var origin_cell := Vector2i.ZERO
	var old_offsets: Array[Vector2i] = []
	var added_offsets: Array[Vector2i] = []
	var show_added_cells := false

	func configure(
		new_tile_map_layer: TileMapLayer,
		new_origin_cell: Vector2i,
		new_old_offsets: Array[Vector2i],
		new_added_offsets: Array[Vector2i]
	) -> void:
		tile_map_layer = new_tile_map_layer
		origin_cell = new_origin_cell
		old_offsets = new_old_offsets.duplicate()
		added_offsets = new_added_offsets.duplicate()
		queue_redraw()

	func _draw() -> void:
		if tile_map_layer == null or tile_map_layer.tile_set == null:
			return
		var tile_size := Vector2(tile_map_layer.tile_set.tile_size)
		var old_color := Color(0.35, 1.0, 0.42, 0.78)
		var added_color := Color(1.0, 0.78, 0.18, 0.95)
		for offset in old_offsets:
			_draw_cell_outline(origin_cell + offset, tile_size, old_color)
		if show_added_cells:
			for offset in added_offsets:
				_draw_cell_outline(origin_cell + offset, tile_size, added_color)

	func _draw_cell_outline(
		cell: Vector2i,
		tile_size: Vector2,
		color: Color
	) -> void:
		var global_center := tile_map_layer.to_global(
			tile_map_layer.map_to_local(cell)
		)
		var local_center := to_local(global_center)
		var rect := Rect2(local_center - tile_size * 0.5, tile_size)
		draw_rect(rect, color, false, 0.5, false)
