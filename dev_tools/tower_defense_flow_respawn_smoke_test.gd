extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_singleplayer_flow_and_respawn()
	await _test_multiplayer_all_dead_is_not_defeat()
	await _test_client_gate_warning_replication()
	if failures.is_empty():
		print("TOWER_DEFENSE_FLOW_RESPAWN_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_singleplayer_flow_and_respawn() -> void:
	var game := TOWER_SCENE.instantiate() as GameTowerDefense
	var authored_status_hud := game.get_node("TowerDefenseStatusHUD") as CanvasLayer
	_expect(
		authored_status_hud != null and not authored_status_hud.visible,
		"TowerDefenseStatusHUD must be hidden in the authored tower-defense scene."
	)
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	_expect(game.tower_defense_status_hud.visible, "Tower-defense runtime must explicitly enable its status HUD.")
	_expect(is_equal_approx(game.pre_wave_duration, 300.0), "Tower-defense rest limit must default to five minutes.")
	_expect(game.player.current_xirang == 1000, "The player must enter tower defense with 1000 Xirang.")
	var first_step := game.current_flow_step
	_expect(game.wave_state == GameRuntimeBase.WaveState.PRE_WAVE, "The first wave must wait in PRE_WAVE instead of starting immediately.")
	_expect(game.countdown_seconds == 300, "The first preparation period must start at 300 seconds.")
	_expect(game.wave_hud.start_wave_button.visible and not game.wave_hud.start_wave_button.disabled, "The rest HUD must expose an enabled early-start button.")
	_expect(game.wave_hud.status_label.text.contains("05:00"), "The five-minute rest HUD must use MM:SS formatting.")
	_expect(
		game.music_player.stream.resource_path
		== "res://resources/audio/shenmu_forest_intermission.ogg",
		"The initial tower-defense rest must play the forest pre-combat BGM."
	)
	_expect(game.tower_defense_status_hud.layer > 70, "Death and gate warnings must render above every gameplay HUD.")
	_expect(_all_control_descendants_ignore_mouse(game.tower_defense_status_hud), "The status HUD must never consume gameplay or menu input.")
	_expect(game.merchant.is_active and game.merchant.visible, "Zhuangfangyi must remain visible and interactive during rest.")
	_expect(game.luoxi_merchant.is_active and game.luoxi_merchant.visible, "Luoxi must remain visible and interactive during rest.")

	game.wave_hud.start_wave_button.pressed.emit()
	_expect(game.wave_state == GameRuntimeBase.WaveState.WAVE_ACTIVE, "Early-start must enter active combat exactly once.")
	_expect(
		game.music_player.stream.resource_path
		== "res://resources/audio/shenmu_forest_combat.ogg",
		"Tower-defense combat through wave 8 must play the forest combat BGM."
	)
	_expect(game.merchant.is_active and game.merchant.visible, "Zhuangfangyi must remain standing during combat.")
	_expect(game.luoxi_merchant.is_active and game.luoxi_merchant.visible, "Luoxi must remain standing during combat.")
	_expect(not game.request_tower_defense_wave_start(0), "An early-start request during combat must be rejected.")

	game.enemy_spawn_timer.stop()
	for enemy_node in game.enemy_container.get_children():
		enemy_node.queue_free()
	await process_frame
	game.luoxi_merchant.refresh_counts_by_player_key[0] = 3
	game.luoxi_merchant.pending_choices_by_player_key[0] = []
	game.luoxi_collectible_claim_counts[0] = 1
	game.luoxi_merchant.choice_visible = true
	game.luoxi_merchant.result_visible = true
	game.luoxi_merchant.dialogue_bubble.show()
	game.call("_enter_intermission", first_step)
	_expect(game.wave_state == GameRuntimeBase.WaveState.INTERMISSION, "Every cleared wave must enter a rest state.")
	_expect(game.countdown_seconds == 300, "Every between-wave rest must start at 300 seconds.")
	_expect(
		game.music_player.stream.resource_path
		== "res://resources/audio/shenmu_forest_intermission.ogg",
		"The between-wave tower-defense rest must play the forest pre-combat BGM."
	)
	_expect(game.luoxi_merchant.get_player_refresh_count(0) == 0, "Luoxi must refresh choices when a new rest begins.")
	_expect(game.luoxi_merchant.pending_choices_by_player_key.is_empty(), "A new rest must discard Luoxi's previous pending choices.")
	_expect(game.luoxi_collectible_claim_counts.is_empty(), "A new rest must clear the authoritative Luoxi claim ledger.")
	_expect(not game.luoxi_merchant.choice_visible, "A new rest must close Luoxi's stale choice overlay.")
	_expect(not game.luoxi_merchant.result_visible, "A new rest must clear Luoxi's previous result state.")
	_expect(not game.luoxi_merchant.dialogue_bubble.visible, "A new rest must clear Luoxi's stale dialogue bubble.")
	game.luoxi_merchant.refresh_counts_by_player_key[0] = 2
	game.call("_set_merchant_active", true)
	_expect(game.luoxi_merchant.get_player_refresh_count(0) == 2, "Repeated state sync in one rest must not reset Luoxi twice.")
	_expect(game.request_tower_defense_wave_start(0), "The between-wave rest button must also start combat early.")
	game.enemy_spawn_timer.stop()
	game.player.call("_die")
	var death_shader := game.tower_defense_status_hud.death_screen_effect.material as ShaderMaterial
	_expect(
		game.tower_defense_status_hud.local_death_center.modulate.a < 0.05,
		"The local death card must begin transparent instead of appearing instantly."
	)
	_expect(
		game.tower_defense_status_hud.dead_players_panel.modulate.a < 0.05,
		"The dead-player list must remain transparent until the local death card reaches the top."
	)
	_expect(
		float(death_shader.get_shader_parameter(&"intensity")) < 0.05,
		"The death screen effect must begin transparent instead of appearing instantly."
	)
	await physics_frame
	_expect(game.player.is_dead, "A killed tower-defense player must enter the dead state.")
	_expect(game.wave_state == GameRuntimeBase.WaveState.WAVE_ACTIVE, "Player death must not end tower defense.")
	_expect(not game.player.body_sprite.visible, "No player body or death animation may remain in the world.")
	_expect(not game.player.nameplate_layer.visible, "No world-space revive countdown may remain over the death position.")
	_expect(game.player.collision_shape.disabled, "A dead tower-defense player must have no world collision.")
	_expect(game.map_camera.get_parent() == game, "The local camera must detach from the dead player for spectator movement.")
	_expect(game.tower_defense_status_hud.local_death_center.visible, "The local death HUD must be visible.")
	_expect(game.tower_defense_status_hud.dead_players_panel.visible, "The right-side dead-player HUD must be visible.")
	_expect(game.singleplayer_respawn_last_seconds == 5, "The first death in a wave must use a five-second revive.")
	_expect(
		game.tower_defense_status_hud.local_death_center.position.y
		> game.tower_defense_status_hud.local_death_top_position.y + 100.0,
		"The local death card must begin near the screen center before moving upward."
	)

	await create_timer(1.4).timeout
	_expect(
		game.tower_defense_status_hud.local_death_center.position.is_equal_approx(
			game.tower_defense_status_hud.local_death_top_position
		),
		"The local death card must finish at its authored top position."
	)
	_expect(
		game.tower_defense_status_hud.local_death_center.modulate.a > 0.99,
		"The local death card must finish fully visible."
	)
	_expect(
		game.tower_defense_status_hud.dead_players_panel.modulate.a > 0.99,
		"The dead-player list must fade in after the local death card moves upward."
	)
	_expect(
		float(death_shader.get_shader_parameter(&"intensity")) > 0.99,
		"The death screen effect must reach its full authored intensity."
	)
	_expect(
		game.tower_defense_status_hud.local_countdown_label.label_settings.font_size >= 26,
		"The local revive countdown must remain visually prominent."
	)

	var camera_before := game.map_camera.global_position
	Input.action_press(&"move_right")
	game.call("_update_local_spectator_camera", 0.1)
	Input.action_release(&"move_right")
	_expect(game.map_camera.global_position.x > camera_before.x, "Movement input while dead must move only the spectator camera.")
	_expect(game.player.velocity == Vector2.ZERO, "Spectator input must not move the dead player body.")

	game.singleplayer_respawn_time_left = 0.0
	game.call("_update_singleplayer_respawn", 0.01)
	await physics_frame
	_expect(not game.player.is_dead, "The single-player revive timer must revive the player.")
	_expect(game.player.global_position.is_equal_approx(game.player_spawn.global_position), "The player must revive at the authored point in front of the blue gate.")
	_expect(game.map_camera.get_parent() == game.player, "Reviving must restore camera follow to the player.")
	_expect(not game.tower_defense_status_hud.local_death_center.visible, "Reviving must clear the local death HUD.")

	var delays: Array[int] = []
	game.call("_reset_player_wave_death_counts")
	for _death_index in range(5):
		delays.append(roundi(game.consume_next_player_respawn_delay(0)))
	_expect(delays == [5, 10, 15, 20, 20], "Per-wave revive delays must be 5/10/15/20 and cap at 20 seconds.")
	game.call("_reset_player_wave_death_counts")
	_expect(roundi(game.consume_next_player_respawn_delay(0)) == 5, "Starting a new wave must reset the next revive delay to five seconds.")

	game.current_base_health = 1
	game.call("_apply_base_damage", 1)
	_expect(game.wave_state == GameRuntimeBase.WaveState.DEFEAT, "Blue-gate health reaching zero must still end the game.")
	_expect(game.wave_hud.result_subtitle.text.contains("蓝门"), "Defeat text must identify the lost blue gate instead of player deaths.")
	_expect(game.tower_defense_status_hud.gate_warning_overlay.visible, "A blue-gate hit must flash a transparent red edge warning.")
	_expect(game.tower_defense_status_hud.gate_warning_audio.playing, "A blue-gate hit must play the double warning beep.")
	_expect(is_equal_approx(game.tower_defense_status_hud.gate_warning_audio.volume_db, -3.0), "The warning beep must stay slightly below the -2 dB player gunshot node.")
	_expect(game.tower_defense_status_hud.gate_warning_audio.bus == &"SFX", "The warning beep must use the SFX bus.")
	var warning_length := game.tower_defense_status_hud.gate_warning_audio.stream.get_length()
	_expect(warning_length >= 0.3 and warning_length <= 0.5, "The two-beep warning sound must stay between 0.3 and 0.5 seconds.")
	_expect(not game.tower_defense_status_hud.play_gate_damage_warning(), "The warning audio must be throttled to once per 0.5 seconds.")
	var gate_shader := game.tower_defense_status_hud.gate_warning_overlay.material as ShaderMaterial
	_expect(death_shader.shader.code.contains("SCREEN_PIXEL_SIZE"), "The death vignette must compensate for viewport aspect ratio.")
	_expect(death_shader.shader.code.contains("corner_mask"), "The death vignette must darken the corners beyond the ordinary edges.")
	_expect(float(death_shader.get_shader_parameter(&"center_darkness")) <= 0.03, "The death vignette center must stay nearly unchanged.")
	_expect(float(death_shader.get_shader_parameter(&"edge_darkness")) >= 0.65, "The death vignette edges must clearly communicate the dead state.")
	_expect(gate_shader.shader.code.contains("SCREEN_PIXEL_SIZE"), "The gate vignette must compensate for viewport aspect ratio.")
	game.wave_hud.show_defeat()
	_expect(game.wave_hud.result_subtitle.text.contains("全员"), "The shared WaveHUD must retain standard-mode defeat wording.")
	game.wave_hud.show_tower_defense_defeat()
	_expect(game.wave_hud.result_subtitle.text.contains("蓝门"), "Tower defense must use its dedicated blue-gate defeat wording.")

	_stop_audio_players(game)
	game.queue_free()
	for _frame in range(4):
		await process_frame
		await physics_frame


func _test_client_gate_warning_replication() -> void:
	var game := TOWER_SCENE.instantiate() as GameTowerDefense
	game.auto_start_waves = false
	game.configure_multiplayer(
		GameRuntimeBase.RuntimeMode.CLIENT_VIEW,
		2,
		{1: "主机", 2: "客户端"},
		{1: &"weishidaier", 2: &"tiyi"}
	)
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	game.apply_remote_base_health(9, 10, 1)
	_expect(game.current_base_health == 9, "A client must apply the authoritative blue-gate health loss.")
	_expect(not game.tower_defense_status_hud.gate_warning_overlay.visible, "A late-join client's initial damaged-gate snapshot must not fake a new hit warning.")
	_expect(not game.tower_defense_status_hud.gate_warning_audio.playing, "Initial blue-gate synchronization must remain silent.")
	game.apply_remote_base_health(8, 10, 2)
	_expect(game.current_base_health == 8, "A client must apply later blue-gate damage revisions.")
	_expect(game.tower_defense_status_hud.gate_warning_overlay.visible, "A replicated blue-gate hit must flash on every client screen.")
	_expect(game.tower_defense_status_hud.gate_warning_audio.playing, "A replicated blue-gate hit must play the client warning sound.")

	_stop_audio_players(game)
	game.queue_free()
	for _frame in range(4):
		await process_frame
		await physics_frame


func _test_multiplayer_all_dead_is_not_defeat() -> void:
	var game := TOWER_SCENE.instantiate() as GameTowerDefense
	game.auto_start_waves = false
	game.configure_multiplayer(
		GameRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		{1: "主机", 2: "队友"},
		{1: &"weishidaier", 2: &"tiyi"}
	)
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	var first_step := game.call("_get_start_flow_step") as FlowStepConfig
	game.call("_enter_pre_flow_step", first_step)
	_expect(not game.request_tower_defense_wave_start(99), "The Host must reject an early-start request from an unknown peer.")
	_expect(game.request_tower_defense_wave_start(2), "A connected multiplayer client must be allowed to request early combat.")
	_expect(game.wave_state == GameRuntimeBase.WaveState.WAVE_ACTIVE, "The Host must authoritatively start combat after a valid client request.")
	game.enemy_spawn_timer.stop()
	for peer_id in [1, 2]:
		var player_instance := game.get_player_for_peer(peer_id)
		player_instance.apply_multiplayer_death_state()
	await physics_frame
	_expect(game.wave_state == GameRuntimeBase.WaveState.WAVE_ACTIVE, "A full multiplayer team wipe must not end tower defense.")
	for peer_id in [1, 2]:
		var player_instance := game.get_player_for_peer(peer_id)
		_expect(not player_instance.body_sprite.visible, "Every dead multiplayer body must disappear from the world.")
		player_instance.apply_multiplayer_death_state()
		_expect(not player_instance.body_sprite.visible, "Repeated death snapshots must not make a tower-defense corpse reappear.")
	var local_player := game.get_player_for_peer(1)
	local_player.apply_multiplayer_realtime_state(
		local_player.max_health,
		local_player.max_health,
		local_player.current_xirang,
		false,
		0.0,
		local_player.skill1_unlocked,
		local_player.skill1_charge,
		local_player.skill1_charge_duration,
		local_player.get_multiplayer_form_mode(),
		local_player.get_multiplayer_shot_pattern()
	)
	_expect(local_player.is_dead, "An older alive snapshot must not revive a tower-defense player before the reliable revive event.")
	_expect(not local_player.body_sprite.visible, "An ignored alive snapshot must keep the dead player hidden.")
	local_player.revive_multiplayer(
		game.get_fixed_multiplayer_respawn_position(1) as Vector2,
		local_player.max_health,
		3.0
	)
	_expect(not local_player.is_dead and local_player.body_sprite.visible, "The reliable revive path must release the tower-defense death lock.")
	game.update_player_respawn_countdown(1, 5)
	game.update_player_respawn_countdown(2, 5)
	_expect(game.tower_defense_status_hud.respawn_entries.size() == 2, "The right HUD must list every dead multiplayer player.")

	_stop_audio_players(game)
	game.queue_free()
	for _frame in range(4):
		await process_frame
		await physics_frame


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).stop()
	elif node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).stop()
	for child in node.get_children():
		_stop_audio_players(child)


func _all_control_descendants_ignore_mouse(node: Node) -> bool:
	for child in node.get_children():
		if child is Control and (child as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
			return false
		if not _all_control_descendants_ignore_mouse(child):
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
