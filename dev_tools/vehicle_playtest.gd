extends Node

## Real-time playability probe. Only normal player inputs and native UI actions
## drive combat: no enemy HP edits, forced kills, teleports, or timer skipping.
## The simple bot is a reproducible smoke test, not a human difficulty rating.
const OUTPUT_DIR := "res://dev_tools/output/vehicle_playtest"
const ACTIONS := [&"move_up", &"move_down", &"move_left", &"move_right", &"shoot_right", &"skill1"]

var runtime: VehicleGame
var driving := false
var failures := 0
var max_observed_speed := 0.0
var observed_reloads := 0
var previous_reloading := false
var skills_used := 0
var previous_skill_charge := 0.0
var previous_wave := -1
var wave_rows: Array[Dictionary] = []
var capture_enabled := true
var initial_position := Vector2.ZERO
var max_displacement := 0.0
var navigation_path := PackedVector2Array()
var path_refresh_left := 0.0
var wall_escape_left := 0.0
var stalled_combat_seconds := 0.0
var last_observed_kills := 0


func _ready() -> void:
	DisplayServer.window_set_title("Vehicle Playtest - live combat verification")
	capture_enabled = DisplayServer.get_name() != "headless"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	# Keep the probe separate from current_scene so production retry/menu
	# transitions can replace the actual game through GameLoadCoordinator.
	get_tree().current_scene = null
	get_tree().root.child_entered_tree.connect(_on_root_child_entered)
	_run.call_deferred()


func _on_root_child_entered(child: Node) -> void:
	if child is VehicleGame:
		(child as VehicleGame).save_run_records = false


func _run() -> void:
	get_tree().change_scene_to_file("res://scene/main_menu.tscn")
	await get_tree().scene_changed
	var entry_menu := get_tree().current_scene as MainMenu
	_expect(entry_menu != null, "The actual main menu loads")
	if entry_menu == null:
		_finish()
		return
	entry_menu.vehicle_mode_button.pressed.emit()
	var workshop := entry_menu.vehicle_mode_choice_overlay
	_expect(workshop.is_open(), "The vehicle menu entry opens its paint workshop")
	workshop.preset_buttons[1].pressed.emit()
	var selected_paint := workshop.selected_color
	await _capture("00_paint_workshop")
	workshop.start_button.pressed.emit()
	if not await _wait_for_vehicle():
		_finish()
		return
	_expect(RunState.get_vehicle_paint_color().is_equal_approx(selected_paint), "Paint selection reaches the run state")
	var portrait_material := runtime.player_profile_panel.portrait.material as ShaderMaterial
	_expect((portrait_material.get_shader_parameter(&"paint_color") as Color).is_equal_approx(selected_paint),
		"Inventory preview and cockpit retain the selected vehicle paint")
	await _capture("01_briefing")
	_expect(runtime._briefing_open and runtime.player.controls_locked, "A fresh run waits at its briefing")
	runtime.vehicle_hud.action_button.pressed.emit()
	initial_position = runtime.player.global_position
	await _capture("02_launch")
	runtime.vehicle_hud.inventory_button.pressed.emit()
	await _capture("03_profile")
	_expect(get_tree().paused, "The actual inventory button pauses combat")
	_purchase_upgrades()
	await _capture("04_upgrades")
	runtime.player_profile_panel.close()
	driving = true
	var wall_deadline := Time.get_ticks_msec() + 900000
	var next_status := Time.get_ticks_msec() + 30000
	while not runtime.run_progress.finished and Time.get_ticks_msec() < wall_deadline:
		if stalled_combat_seconds > 90.0:
			_expect(false, "The simple driver made no combat progress for ninety seconds; inspect its route")
			break
		if runtime.wave_reward.is_open():
			driving = false
			_release_actions()
			_record_wave()
			await _capture("wave_%02d_reward" % (runtime.current_wave_index + 1))
			var best_index := _choose_reward(runtime.wave_reward.choice_overlay.choices)
			runtime.wave_reward.choice_overlay.choice_selected.emit(best_index)
			if not runtime.run_progress.finished:
				runtime._open_inventory()
				_purchase_upgrades()
				runtime.player_profile_panel.close()
			driving = true
		if runtime.current_wave_index != previous_wave and runtime.wave_state == CombatFlowState.State.WAVE_ACTIVE:
			previous_wave = runtime.current_wave_index
			print("VEHICLE_PLAYTEST wave=%d health=%d/%d attack=%d" % [
				previous_wave + 1, runtime.player.current_health, runtime.player.max_health, runtime.player.attack_damage,
			])
		if Time.get_ticks_msec() >= next_status:
			next_status += 30000
			print("VEHICLE_PLAYTEST time=%s wave=%d kills=%d health=%d speed=%.1f" % [
				VehicleRunProgress.format_time(runtime.run_progress.combat_seconds), runtime.current_wave_index + 1,
				runtime.run_progress.kills, runtime.player.current_health, max_observed_speed,
			])
			await _capture("combat_%02d_%d" % [runtime.current_wave_index + 1, runtime.run_progress.kills])
		await get_tree().process_frame
	driving = false
	_release_actions()
	_expect(runtime.run_progress.finished, "Live run reaches a terminal result before the fifteen-minute limit")
	_expect(runtime.run_progress.kills > 0, "Actual forward projectiles defeat live enemies")
	_expect(max_observed_speed > 25.0 and max_observed_speed <= 100.01 and max_displacement > 50.0,
		"Throttle, steering and collision movement work within the speed cap")
	_expect(observed_reloads > 0, "Live firing depletes and reloads the magazine")
	_expect(skills_used > 0, "Live skill input launches grenades and consumes their charge")
	await _capture("90_result")
	var result := {
		"victory": runtime.run_progress.victory,
		"cleared_waves": runtime.run_progress.cleared_waves,
		"kills": runtime.run_progress.kills,
		"score": runtime.run_progress.score,
		"combat_seconds": runtime.run_progress.combat_seconds,
		"health_loss": runtime.run_progress.total_health_loss,
		"max_speed": max_observed_speed,
		"max_displacement": max_displacement,
		"reloads": observed_reloads,
		"skills_used": skills_used,
		"waves": wave_rows,
	}
	var output := FileAccess.open(OUTPUT_DIR.path_join("result.json"), FileAccess.WRITE)
	output.store_string(JSON.stringify(result, "\t"))
	output.close()
	print("VEHICLE_PLAYTEST_RESULT " + JSON.stringify(result))
	if runtime.run_progress.finished:
		var old_runtime_id := runtime.get_instance_id()
		runtime.vehicle_hud.action_button.pressed.emit()
		runtime = null
		if await _wait_for_vehicle(old_runtime_id):
			_expect(runtime.run_progress.score == 0 and runtime.run_progress.cleared_waves == 0,
				"Retry loads a fresh run with no previous score")
			_expect(RunState.get_player_stat_bonus_value(0, &"attack_damage") == 0 and RunState.get_upgrade_level(RunStateStore.StatType.ATTACK) == 0,
				"Retry clears service and profile upgrades")
			_expect(runtime.player.attack_damage == 10 and runtime.player.max_health == 100,
				"Retry restores the authored baseline vehicle")
			await _capture("91_retry_briefing")
			runtime.vehicle_hud.return_button.pressed.emit()
			runtime = null
			var menu_deadline := Time.get_ticks_msec() + 30000
			while Time.get_ticks_msec() < menu_deadline:
				var scene := get_tree().current_scene
				if scene != null and scene.scene_file_path == "res://scene/main_menu.tscn":
					break
				await get_tree().process_frame
			_expect(get_tree().current_scene != null and get_tree().current_scene.scene_file_path == "res://scene/main_menu.tscn",
				"Return button reaches the actual main menu")
			_expect(not get_tree().paused, "Returning to menu leaves no modal pause")
			await _capture("92_main_menu")
			# Let the menu's real threaded encyclopedia preload finish before
			# shutting down the engine; quitting mid-load produces unrelated
			# resource parse errors on Godot's background loader at destruction.
			var menu := get_tree().current_scene as MainMenu
			var preload_deadline := Time.get_ticks_msec() + 120000
			while menu != null and menu._encyclopedia_load_state in [MainMenu.EncyclopediaLoadState.IDLE, MainMenu.EncyclopediaLoadState.LOADING] and Time.get_ticks_msec() < preload_deadline:
				await get_tree().process_frame
			_expect(menu != null and menu._encyclopedia_load_state == MainMenu.EncyclopediaLoadState.LOADED,
				"Main menu finishes its background encyclopedia preload before test shutdown")
	_finish()


func _wait_for_vehicle(old_id: int = 0) -> bool:
	var deadline := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < deadline:
		var current := get_tree().current_scene as VehicleGame
		if current != null and current.get_instance_id() != old_id and current.runtime_activated and current.is_runtime_preparation_complete():
			# Loading has its own short finishing animation; user controls start
			# only after that native overlay has gone away.
			if not GameLoadCoordinator.overlay.visible:
				runtime = current
				return true
		await get_tree().process_frame
	_expect(false, "Production loader creates and activates a new vehicle scene")
	return false


func _physics_process(delta: float) -> void:
	if not driving or runtime == null or not is_instance_valid(runtime) or runtime.wave_state != CombatFlowState.State.WAVE_ACTIVE or get_tree().paused:
		_release_actions()
		return
	var car := runtime.player as PlayerVehicle
	if runtime.run_progress.kills == last_observed_kills:
		stalled_combat_seconds += delta
	else:
		last_observed_kills = runtime.run_progress.kills
		stalled_combat_seconds = 0.0
	path_refresh_left -= delta
	wall_escape_left = maxf(wall_escape_left - delta, 0.0)
	max_observed_speed = maxf(max_observed_speed, absf(car.longitudinal_speed))
	max_displacement = maxf(max_displacement, car.global_position.distance_to(initial_position))
	if car.is_reloading and not previous_reloading:
		observed_reloads += 1
	previous_reloading = car.is_reloading
	if previous_skill_charge > 1.0 and car.skill1_charge < previous_skill_charge - 1.0:
		skills_used += 1
	previous_skill_charge = car.skill1_charge
	var target: Enemy
	var best_distance := INF
	for node in runtime.enemy_container.get_children():
		var enemy := node as Enemy
		if enemy == null or enemy.is_dead:
			continue
		var distance := car.global_position.distance_squared_to(enemy.global_position)
		if distance < best_distance:
			best_distance = distance
			target = enemy
	if target == null:
		_release_actions()
		return
	var aim := car.global_position.direction_to(target.global_position)
	var angle := car.heading.angle_to(aim)
	var distance := sqrt(best_distance)
	var ray := PhysicsRayQueryParameters2D.create(car.global_position, target.global_position, 1, [car.get_rid(), target.get_rid()])
	var blocked := not car.get_world_2d().direct_space_state.intersect_ray(ray).is_empty()
	# A human moves around a wall instead of firing into it indefinitely. The
	# test driver uses the game's existing navigation grid to select waypoints,
	# but still travels through normal throttle/steering/physics collisions.
	if car.get_slide_collision_count() > 0 and absf(car.longitudinal_speed) < 2.0:
		wall_escape_left = 1.0
	if blocked or wall_escape_left > 0.0:
		if path_refresh_left <= 0.0:
			path_refresh_left = 0.35
			var goal: Vector2 = target.global_position if blocked else runtime.get_node("Camera2D").global_position
			navigation_path = runtime.grid_pathfinder.get_global_path(car.global_position, goal, Vector2(7.5, 7.5))
		while not navigation_path.is_empty() and car.global_position.distance_to(navigation_path[0]) < 5.0:
			navigation_path.remove_at(0)
		if not navigation_path.is_empty():
			var drive_aim := car.global_position.direction_to(navigation_path[0])
			var drive_angle := car.heading.angle_to(drive_aim)
			_set_action(&"move_left", drive_angle < -0.035)
			_set_action(&"move_right", drive_angle > 0.035)
			_set_action(&"move_down", false)
			_set_action(&"move_up", absf(drive_angle) < 0.25)
			_set_action(&"shoot_right", not blocked and absf(angle) < 0.3)
			_set_action(&"skill1", false)
			return
	_set_action(&"move_left", angle < -0.035)
	_set_action(&"move_right", angle > 0.035)
	_set_action(&"move_down", distance < 135.0 and absf(angle) < 0.5)
	_set_action(&"move_up", distance > 185.0 and absf(angle) < 0.4)
	_set_action(&"shoot_right", absf(angle) < 0.3)
	_set_action(&"skill1", car.skill1_charge >= car.skill1_charge_duration and absf(angle) < 0.2 and distance < 220.0)


func _choose_reward(choices: Array[PickupConfig]) -> int:
	var best_index := 0
	var best_value := -INF
	for index in range(choices.size()):
		var item := choices[index]
		var value := float(item.collectible_attack_bonus) * 3.0 + float(item.collectible_max_health_bonus) * 0.3
		value += item.collectible_attack_speed_bonus * 40.0 + item.bullet_pierce_chance * 20.0
		value += float(item.collectible_physical_defense_bonus) + float(item.collectible_magic_defense_bonus)
		if value > best_value:
			best_value = value
			best_index = index
	return best_index


func _record_wave() -> void:
	wave_rows.append({
		"wave": runtime.current_wave_index + 1,
		"combat_seconds": runtime.run_progress.wave_seconds,
		"health": runtime.player.current_health,
		"max_health": runtime.player.max_health,
		"attack": runtime.player.attack_damage,
		"score": runtime.run_progress.score,
	})


func _purchase_upgrades() -> void:
	var profile := runtime.player_profile_panel
	profile.tab_bar.current_tab = 1
	# A simple, explicit build using only the existing upgrade UI. No currency
	# or stat injection: the same starting funds and enemy drops fund every buy.
	for index in range(3):
		for stat_type in [RunStateStore.StatType.ATTACK, RunStateStore.StatType.HEALTH, RunStateStore.StatType.ATTACK_SPEED]:
			if RunState.get_upgrade_level(stat_type) > index:
				continue
			var row: UpgradeRow
			match stat_type:
				RunStateStore.StatType.ATTACK:
					row = profile.attack_row
				RunStateStore.StatType.HEALTH:
					row = profile.health_row
				RunStateStore.StatType.ATTACK_SPEED:
					row = profile.speed_row
			if not row.upgrade_button.disabled:
				row.upgrade_button.pressed.emit()


func _set_action(action: StringName, pressed: bool) -> void:
	if Input.is_action_pressed(action) == pressed:
		return
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	Input.parse_input_event(event)


func _release_actions() -> void:
	for action in ACTIONS:
		_set_action(action, false)


func _capture(label: String) -> void:
	if not capture_enabled:
		return
	await get_tree().create_timer(0.6, true, false, true).timeout
	await RenderingServer.frame_post_draw
	var path := OUTPUT_DIR.path_join(label + ".png")
	_expect(get_viewport().get_texture().get_image().save_png(path) == OK, "Capture " + label)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("VEHICLE_PLAYTEST: " + message)


func _finish() -> void:
	driving = false
	_release_actions()
	if is_instance_valid(runtime):
		runtime.prepare_for_scene_teardown()
		runtime.queue_free()
	await get_tree().process_frame
	print("VEHICLE_PLAYTEST failures=%d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
