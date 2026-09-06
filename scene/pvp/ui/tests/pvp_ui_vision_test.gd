extends Node2D
## Run headless for assertions, or pass -- --capture for presentation PNGs.

const VisibilityScript := preload("res://scene/pvp/pvp_visibility.gd")
var _failed := 0
var _requested := 0
var _modal_changes: Array[bool] = []


func _ready() -> void:
	if "--capture" in OS.get_cmdline_user_args():
		get_window().mode = Window.MODE_WINDOWED
		get_window().size = Vector2i(1280, 720)
	_test_shadow_geometry()
	$Players/Local.team = "CT"
	$Players/HiddenEnemy.team = "T"
	$Players/VisibleEnemy.team = "T"
	$Players/Teammate.team = "CT"
	$Visibility.set_context($Players/Local, $Map, $Players)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_expect(not $Players/HiddenEnemy.visible, "Enemy behind wall must be hidden, including its name")
	_expect($Players/VisibleEnemy.visible, "Unobstructed enemy must remain visible")
	_expect($Players/Teammate.visible, "Teammate must remain visible")
	$Players/Local.alive = false
	await get_tree().physics_frame
	_expect($Visibility.observer == $Players/Teammate, "Death view must follow a living teammate")
	$Players/Teammate.alive = false
	await get_tree().physics_frame
	_expect($Visibility.observer == $Players/Local, "Team wipe must retain last personal view")
	$Players/Local.alive = true
	$Players/Teammate.alive = true
	$HUD.buy_ak_requested.connect(func() -> void: _requested += 1)
	$HUD.buy_menu_toggled.connect(func(opened: bool) -> void: _modal_changes.append(opened))
	var state := _make_state()
	var loading_state := state.duplicate(true)
	loading_state["phase"] = "loading"
	loading_state["local_player"] = {}
	$HUD.update_match_state(loading_state)
	_expect($HUD.buy_button.disabled, "Loading before the local roster arrives must safely disable buying")
	$HUD.update_match_state(state)
	$HUD.set_buy_open(true)
	_expect($HUD.is_buy_open(), "B purchase panel must open")
	_expect(not $HUD.buy_button.disabled, "AK purchase allowed at $4000 in buy zone")
	$HUD.buy_button.set_meta("skip_ui_click_audio", true)
	$HUD.buy_button.pressed.emit()
	_expect(_requested == 1, "Purchase button must emit exactly one server request")
	state["local_player"]["money"] = 1000
	$HUD.update_match_state(state)
	_expect($HUD.buy_button.disabled, "Insufficient balance blocks purchase")
	state["local_player"]["money"] = 4000
	state["buy_allowed"] = false
	$HUD.update_match_state(state)
	_expect($HUD.buy_button.disabled, "Leaving buy zone blocks purchase")
	state["buy_allowed"] = true
	state["local_player"]["loadout"]["ak"] = {"ammo": 30, "reserve": 90}
	$HUD.update_match_state(state)
	_expect($HUD.buy_button.disabled, "Already owned AK must not be repurchased")
	state["local_player"]["loadout"].erase("ak")
	state["phase"] = "live"
	$HUD.update_match_state(state)
	_expect(not $HUD.is_buy_open(), "Combat starts with purchase overlay closed")
	_expect(_modal_changes.back() == false, "Closing panel restores combat input")
	state["phase"] = "buy"
	$HUD.update_match_state(state)
	$HUD.add_kill_feed("CT 玩家", "T 玩家", "deagle", true)
	await get_tree().process_frame
	await get_tree().process_frame
	_expect($HUD.get_node("Screen/Crosshair").visible, "Living player has a crosshair during gameplay")
	if "--capture" in OS.get_cmdline_user_args():
		await _capture("visibility")
		_test_rendered_shadow()
		$HUD.set_buy_open(true)
		await get_tree().create_timer(0.3).timeout
		_expect(not $HUD.get_node("Screen/Crosshair").visible, "Weapon menu hides gameplay crosshair")
		await _capture("buy")
		$HUD.set_buy_open(false)
		$HUD.scoreboard.show()
		await _capture("scoreboard")
		$HUD.scoreboard.hide()
		get_window().size = Vector2i(1280, 900)
		await get_tree().process_frame
		await get_tree().process_frame
		$Floor.size = get_viewport_rect().size
		await _capture("resized")
		_expect($Visibility.shadow_viewport.size == Vector2i(get_viewport_rect().size), "Shadow mask tracks the resized viewport")
		_test_rendered_shadow()
	await get_tree().process_frame
	print("PVP_UI_VISION_TEST: %s" % ("PASS" if _failed == 0 else "FAIL (%d)" % _failed))
	get_tree().quit(0 if _failed == 0 else 1)


func _test_shadow_geometry() -> void:
	var obstacle := Rect2(600, 200, 80, 300)
	var polygon := VisibilityScript.build_shadow_polygon(obstacle, Vector2(350, 350), 12000.0)
	_expect(Geometry2D.is_point_in_polygon(Vector2(850, 350), polygon), "Directly behind obstacle belongs to shadow")
	_expect(not Geometry2D.is_point_in_polygon(Vector2(500, 350), polygon), "Before wall remains visible")
	_expect(not Geometry2D.is_point_in_polygon(Vector2(850, 15), polygon), "Above shadow cone remains visible")
	# Compare exact segment/edge intersections with the shadow hull across 17,800 points.
	for origin: Vector2 in [Vector2(350, 350), Vector2(900, 350), Vector2(630, 80), Vector2(200, 580)]:
		polygon = VisibilityScript.build_shadow_polygon(obstacle, origin, 12000.0)
		var corners := PackedVector2Array([obstacle.position, Vector2(680, 200), obstacle.end, Vector2(600, 500)])
		for x: int in range(5, 1152, 13):
			for y: int in range(3, 648, 13):
				var point := Vector2(x, y)
				var blocked := obstacle.has_point(point)
				for edge: int in 4:
					blocked = blocked or Geometry2D.segment_intersects_segment(origin, point, corners[edge], corners[(edge + 1) % 4]) != null
				if Geometry2D.is_point_in_polygon(point, polygon) != blocked:
					# Godot's point-in-polygon treats the subpixel boundary as inside.
					var boundary_distance := INF
					for edge: int in polygon.size():
						boundary_distance = minf(boundary_distance, point.distance_to(Geometry2D.get_closest_point_to_segment(point, polygon[edge], polygon[(edge + 1) % polygon.size()])))
					if boundary_distance < 0.2:
						continue
					_expect(false, "Shadow hull disagrees with line-of-sight at %s from %s" % [point, origin])
					return


func _make_state() -> Dictionary:
	var local := {"peer_id": 1, "team": "CT", "display_name": "维什戴尔", "health": 100, "alive": true, "money": 4000, "current_weapon": "deagle", "ammo": 7, "reserve": 35, "reloading": false, "kills": 3, "deaths": 1, "loadout": {"deagle": {"ammo": 7, "reserve": 35}}}
	var enemy: Dictionary = local.duplicate(true)
	enemy["peer_id"] = 2
	enemy["team"] = "T"
	enemy["display_name"] = "沙漠来客"
	return {"phase": "buy", "phase_time_left": 15.0, "round_number": 3, "scores": {"CT": 2, "T": 1}, "winner_team": "", "local_peer_id": 1, "players": [local, enemy], "local_player": local, "buy_allowed": true, "callout": "中路 / MID", "nearby_weapon": "ak"}


func _capture(suffix: String) -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("res://reports/mirage")
	DirAccess.make_dir_recursive_absolute(path)
	_get_srgb_image().save_png(path.path_join("pvp_ui_%s.png" % suffix))


func _test_rendered_shadow() -> void:
	var rendered := _get_srgb_image()
	var pixel_scale := Vector2(rendered.get_size()) / get_viewport_rect().size
	var visible_pixel := Vector2i(Vector2(500, 350) * pixel_scale)
	var hidden_pixel := Vector2i(Vector2(850, 350) * pixel_scale)
	var visible_color := rendered.get_pixelv(visible_pixel)
	var hidden_color := rendered.get_pixelv(hidden_pixel)
	_expect(absf(visible_color.r - $Floor.color.r) < 0.04, "Visible terrain retains its original color")
	_expect(hidden_color.r < visible_color.r * 0.5, "Occluded terrain is visibly darker")
	_expect(absf(hidden_color.r - hidden_color.b) < 0.025, "Occluded terrain is neutral black gray")


func _get_srgb_image() -> Image:
	var rendered := get_viewport().get_texture().get_image()
	# Forward+ HDR readback is linear; PNGs and expected UI colors are sRGB.
	if get_viewport().use_hdr_2d and RenderingServer.get_current_rendering_method() != "gl_compatibility":
		rendered.convert(Image.FORMAT_RGBA8)
		rendered.linear_to_srgb()
	return rendered


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed += 1
		push_error(message)
