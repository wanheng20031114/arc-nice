extends SceneTree

const GAME_SCENE := preload("res://scene/game.tscn")
const APPLE_COLLECTIBLE := preload("res://resources/config/collectibles/collectible_apple.tres")

var failures: Array[String] = []
var game: Node2D
var player: Player


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	game = GAME_SCENE.instantiate() as Node2D
	game.set("auto_start_waves", false)
	var test_music_player := game.get_node("MusicPlayer") as AudioStreamPlayer
	test_music_player.autoplay = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	player = game.get_node("Player") as Player
	await _test_world_mouse_fire()
	await _test_dodge_success_feedback()
	await _test_profile_button_does_not_fire()
	await _test_settings_button_opens_and_closes()
	await _test_profile_inventory_blank_click_clears_selection()
	await _test_profile_upgrade_levels_and_skill_details()

	_release_left_mouse(Vector2.ZERO)
	_clear_player_bullets()
	_stop_audio_players(game)
	game.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("PLAYER_MOUSE_FIRE_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_world_mouse_fire() -> void:
	var target_viewport_position := (
		player.get_global_transform_with_canvas() * Vector2(80.0, 0.0)
	)
	_press_left_mouse(target_viewport_position)
	await process_frame
	await process_frame
	await _wait_physics_frames(2)

	_expect(player.mouse_fire_held, "World left click did not start mouse firing.")
	var first_bullet := _find_player_bullet()
	_expect(
		first_bullet != null,
		"World left click did not spawn a bullet. Mouse viewport position: %s, player: %s."
		% [player.mouse_viewport_position, player.global_position]
	)
	if first_bullet != null:
		_expect(
			first_bullet.z_index >= 4,
			"Mouse-fired player bullets must render above player and enemy body sprites."
		)
		_expect(
			first_bullet.direction.dot(Vector2.RIGHT) > 0.99,
			"Mouse-fired bullet did not travel toward the cursor. Direction: %s, mouse world: %s, target viewport: %s."
			% [
				first_bullet.direction,
				player.get_canvas_transform().affine_inverse()
				* player.mouse_viewport_position,
				target_viewport_position,
			]
		)
	_expect(
		player.facing_suffix == &"right",
		"Player did not face the mouse firing direction. Facing: %s." % player.facing_suffix
	)

	var initial_bullet_count := _get_player_bullet_count()
	await _wait_physics_frames(16)
	_expect(
		_get_player_bullet_count() > initial_bullet_count,
		"Holding left click did not continue firing."
	)

	_release_left_mouse(target_viewport_position)
	await process_frame
	await process_frame
	await physics_frame
	_expect(not player.mouse_fire_held, "Releasing left click did not stop mouse firing.")

	player.mouse_fire_held = true
	player.call("_on_window_focus_exited")
	_expect(not player.mouse_fire_held, "Losing window focus did not stop mouse firing.")


func _test_profile_button_does_not_fire() -> void:
	for child in game.get_children():
		if child is Bullet:
			child.queue_free()
	await process_frame

	var profile_button := game.get_node(
		"CurrencyHUD/TopRightMargin/Content/ProfileButton"
	) as Button
	var profile_panel := game.get_node("PlayerProfilePanel") as PlayerProfilePanel
	var button_position := profile_button.get_global_rect().get_center()

	_press_left_mouse(button_position)
	await process_frame
	await process_frame
	await physics_frame
	var hovered_control := root.gui_get_hovered_control()
	_expect(
		not player.mouse_fire_held,
		"Clicking the profile button leaked into player firing. Button rect: %s, click: %s, hovered: %s."
		% [profile_button.get_global_rect(), button_position, hovered_control]
	)
	_expect(
		_get_player_bullet_count() == 0,
		"Clicking the profile button spawned a player bullet."
	)

	_release_left_mouse(button_position)
	await process_frame
	await process_frame
	await physics_frame
	_expect(
		profile_panel.is_open(),
		"Profile button did not open the profile panel. Viewport size: %s."
		% root.get_visible_rect().size
	)
	_expect(player.controls_locked, "Opening the profile panel did not lock player controls.")
	_expect(not player.mouse_fire_held, "Opening the profile panel left mouse firing active.")
	profile_panel.close()


func _test_settings_button_opens_and_closes() -> void:
	_clear_player_bullets()
	player.set_controls_locked(false)
	await process_frame

	var settings_button := game.get_node(
		"CurrencyHUD/TopRightMargin/Content/SettingsButton"
	) as Button
	var settings_panel := game.get_node("SettingsLayer/SettingsPanel") as SettingsPanel
	var button_position := settings_button.get_global_rect().get_center()

	_press_left_mouse(button_position)
	await process_frame
	await process_frame
	await physics_frame
	var hovered_control := root.gui_get_hovered_control()
	_expect(
		not player.mouse_fire_held,
		"Clicking the settings button leaked into player firing. Button rect: %s, click: %s, hovered: %s."
		% [settings_button.get_global_rect(), button_position, hovered_control]
	)
	_expect(
		_get_player_bullet_count() == 0,
		"Clicking the settings button spawned a player bullet."
	)

	_release_left_mouse(button_position)
	await process_frame
	await process_frame
	await physics_frame
	_expect(settings_panel.is_open(), "Settings button did not open the settings panel.")
	_expect(player.controls_locked, "Opening settings did not lock player controls.")

	_send_action(&"ui_cancel", true)
	await process_frame
	await process_frame
	_send_action(&"ui_cancel", false)
	await process_frame
	await physics_frame
	_expect(not settings_panel.is_open(), "ui_cancel did not close the in-game settings panel.")
	_expect(not player.controls_locked, "Closing settings did not unlock player controls.")


func _test_profile_inventory_blank_click_clears_selection() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	var profile_panel := game.get_node("PlayerProfilePanel") as PlayerProfilePanel
	run_state.begin_new_run()
	run_state.set_active_multiplayer_peer(0)
	_expect(run_state.try_add_item(APPLE_COLLECTIBLE), "Profile blank-click test must place an inventory item.")

	profile_panel.open()
	await process_frame
	profile_panel.call("_on_slot_selected", 0)
	await process_frame

	var first_slot := profile_panel.get_node("Overlay/PanelRoot/InventoryGrid/Slot00") as InventorySlot
	var item_detail_panel := profile_panel.get_node("Overlay/PanelRoot/ItemDetailPanel") as PanelContainer
	_expect(first_slot.button_pressed, "Selecting an inventory item must mark the slot selected.")
	_expect(item_detail_panel.visible, "Selecting an inventory item must show the detail panel.")

	var panel_root := profile_panel.get_node("Overlay/PanelRoot") as Control
	var blank_position := panel_root.get_global_transform_with_canvas() * Vector2(150.0, 86.0)
	_press_left_mouse(blank_position)
	await process_frame
	await process_frame
	_release_left_mouse(blank_position)
	await process_frame

	_expect(not first_slot.button_pressed, "Clicking profile panel blank space must clear the selected inventory slot.")
	_expect(not item_detail_panel.visible, "Clicking profile panel blank space must hide the item detail panel.")
	profile_panel.close()


func _test_dodge_success_feedback() -> void:
	player.dodge_chance = 1.0
	player.current_health = player.max_health
	player.invincibility_time_left = 0.0
	player.call("_set_hurt_blink_enabled", false)
	player.call("_stop_dodge_feedback")

	var health_before := player.current_health
	var applied_damage := player.apply_damage(999)
	var sprite_material := player.body_sprite.material as ShaderMaterial
	_expect(not applied_damage, "Successful dodge must report that no damage was applied.")
	_expect(player.current_health == health_before, "Successful dodge must not reduce health.")
	_expect(player.invincibility_time_left > 0.0, "Successful dodge must start invincibility.")
	if sprite_material != null:
		_expect(
			sprite_material.get_shader_parameter(&"blink_enabled") == false,
			"Successful dodge must not enable hurt blink."
		)
		_expect(
			float(sprite_material.get_shader_parameter(&"dodge_effect_strength")) > 0.0,
			"Successful dodge must raise the dodge shader effect."
		)
		_expect(
			float(sprite_material.get_shader_parameter(&"dodge_outline_width")) >= 3.0,
			"Successful dodge shader must keep a visible outline width."
		)

	player.dodge_chance = 0.0
	player.invincibility_time_left = 0.0
	player.call("_set_hurt_blink_enabled", false)
	player.call("_stop_dodge_feedback")


func _test_profile_upgrade_levels_and_skill_details() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	var profile_panel := game.get_node("PlayerProfilePanel") as PlayerProfilePanel
	run_state.begin_new_run()
	run_state.set_active_multiplayer_peer(0)
	player.current_xirang = 100000

	var attack_base := player.attack_damage
	var health_base := player.max_health
	var fire_interval_base := player.fire_interval
	var dodge_base := player.dodge_chance
	var attack_costs := [100, 200, 400, 700, 1000, 1600, 2200, 3000, 3800, 4700]
	var health_costs := [40, 70, 90, 180, 450, 700, 1000, 1500, 2000, 2700]
	var speed_costs := [40, 70, 90, 180, 450, 700, 1000, 1500, 2000, 2700]
	var dodge_costs := [40, 70, 90, 180, 450, 700, 1000, 1500, 2000, 2700]

	_expect(run_state.get_max_upgrade_level(RunStateStore.StatType.ATTACK) == 10, "Attack max upgrade level must be 10.")
	_expect(run_state.get_max_upgrade_level(RunStateStore.StatType.HEALTH) == 10, "Health max upgrade level must be 10.")
	_expect(run_state.get_max_upgrade_level(RunStateStore.StatType.ATTACK_SPEED) == 10, "Attack speed max upgrade level must be 10.")
	_expect(run_state.get_max_upgrade_level(RunStateStore.StatType.DODGE) == 10, "Dodge max upgrade level must be 10.")

	_upgrade_stat_to_max(run_state, RunStateStore.StatType.ATTACK, attack_costs)
	_upgrade_stat_to_max(run_state, RunStateStore.StatType.HEALTH, health_costs)
	_upgrade_stat_to_max(run_state, RunStateStore.StatType.ATTACK_SPEED, speed_costs)
	_upgrade_stat_to_max(run_state, RunStateStore.StatType.DODGE, dodge_costs)

	_expect(player.attack_damage == attack_base + 40, "Ten attack upgrades must add 40 attack.")
	_expect(player.max_health == health_base + 50, "Ten health upgrades must add 50 max health.")
	_expect(is_equal_approx(player.fire_interval, fire_interval_base * pow(0.95, 10.0)), "Ten speed upgrades must apply 0.95 multiplier each level.")
	_expect(is_equal_approx(player.dodge_chance, dodge_base + 0.2), "Ten dodge upgrades must add 20 percentage points.")
	_expect(not run_state.try_upgrade(RunStateStore.StatType.ATTACK, player), "Eleventh attack upgrade must fail.")

	profile_panel.open()
	await process_frame
	var attack_row := profile_panel.get_node("Overlay/PanelRoot/UpgradePanel/AttackRow") as UpgradeRow
	_expect(attack_row.progress_blocks.size() == 10, "Upgrade rows must expose ten progress blocks.")
	_expect(attack_row.level_label.text == "10/10", "Upgrade row must show 10/10 at max level.")
	_expect(attack_row.upgrade_button.disabled, "Maxed upgrade row button must be disabled.")
	_expect(attack_row.upgrade_button.text == "已满", "Maxed upgrade row button must read 已满.")

	var skill_info := profile_panel.get_node("Overlay/PanelRoot/SkillInfo") as Control
	_expect(not skill_info.visible, "Skill details must stay hidden before skill1 is purchased.")

	player.unlock_skill1()
	player.skill1_charge = 4.0
	await process_frame
	_expect(skill_info.visible, "Skill details must show after skill1 is purchased.")
	var skill_description := profile_panel.get_node("Overlay/PanelRoot/SkillInfo/SkillDescription") as Label
	var skill_icon := profile_panel.get_node("Overlay/PanelRoot/SkillInfo/SkillIcon") as TextureRect
	var skill_name := profile_panel.get_node("Overlay/PanelRoot/SkillInfo/SkillName") as Label
	var skill_cost := profile_panel.get_node("Overlay/PanelRoot/SkillInfo/SkillCost") as Label
	_expect(
		not profile_panel.has_node("Overlay/PanelRoot/SkillInfo/SkillCharge"),
		"Skill details must not show current charge anymore."
	)
	_expect(skill_icon.texture != null, "Skill details must show the dialogue skill icon.")
	_expect(skill_name.text == "经典技能", "Skill details must show the requested skill display name.")
	_expect(
		skill_description.text == "向上一次射击位置发射一枚炸弹造成攻击力330%的大范围伤害",
		"Skill details must show the expected skill description."
	)
	_expect(skill_description.size.y >= 48.0, "Skill details description must have enough height for wrapped text.")
	_expect(skill_cost.text == "技力需求18", "Skill details must show the base required charge.")
	_expect(skill_cost.size.y >= 24.0, "Skill details cost line must have enough height for outlined text.")

	player.current_xirang = 500
	_expect(player.try_upgrade_skill1(), "Skill1 first upgrade should succeed in profile smoke test.")
	await process_frame
	_expect(skill_cost.text == "技力需求16", "Skill details must update required charge after skill1 upgrade.")
	profile_panel.close()


func _upgrade_stat_to_max(
	run_state: RunStateStore,
	stat_type: int,
	expected_costs: Array
) -> void:
	for level_index in range(expected_costs.size()):
		_expect(
			run_state.get_upgrade_cost(stat_type) == expected_costs[level_index],
			"Upgrade cost mismatch for stat %d at level %d." % [stat_type, level_index]
		)
		var xirang_before := player.current_xirang
		_expect(run_state.try_upgrade(stat_type, player), "Upgrade should succeed for stat %d level %d." % [stat_type, level_index + 1])
		_expect(
			player.current_xirang == xirang_before - int(expected_costs[level_index]),
			"Upgrade deducted the wrong cost for stat %d level %d." % [stat_type, level_index + 1]
		)
	_expect(run_state.get_upgrade_level(stat_type) == 10, "Stat %d must reach level 10." % stat_type)
	_expect(run_state.get_upgrade_cost(stat_type) == -1, "Maxed stat %d must not expose another cost." % stat_type)


func _press_left_mouse(position: Vector2) -> void:
	_send_mouse_motion(position)
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.pressed = true
	root.push_input(event, true)


func _release_left_mouse(position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = 0
	event.pressed = false
	root.push_input(event, true)


func _send_mouse_motion(position: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	root.push_input(event, true)


func _send_action(action: StringName, pressed: bool) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	event.strength = 1.0 if pressed else 0.0
	root.push_input(event, true)


func _find_player_bullet() -> Bullet:
	for child in game.get_children():
		var bullet := child as Bullet
		if bullet != null:
			return bullet
	return null


func _get_player_bullet_count() -> int:
	var bullet_count := 0
	for child in game.get_children():
		if child is Bullet:
			bullet_count += 1
	return bullet_count


func _clear_player_bullets() -> void:
	for child in game.get_children():
		if child is Bullet:
			child.queue_free()


func _stop_audio_players(node: Node) -> void:
	for child in node.get_children():
		var audio_player := child as AudioStreamPlayer
		if audio_player != null:
			audio_player.stop()
			audio_player.stream = null
		var audio_player_2d := child as AudioStreamPlayer2D
		if audio_player_2d != null:
			audio_player_2d.stop()
			audio_player_2d.stream = null
		_stop_audio_players(child)


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
