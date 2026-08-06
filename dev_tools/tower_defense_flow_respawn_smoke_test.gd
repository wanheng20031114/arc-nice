extends SceneTree

const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const STATUS_HUD_SCENE := preload("res://scene/tower_defense_status_hud.tscn")
const LIFE_STATUS_HUD_SCENE := preload(
	"res://scene/ui/shared/player_life_status_hud.tscn"
)


class NoRespawnTowerRuntime extends TowerDefenseGame:
	func allows_player_respawn(_peer_id: int) -> bool:
		return false


class NoRespawnTowerModeAdapter extends TowerDefenseMultiplayerModeAdapter:
	func allows_player_respawn(_peer_id: int) -> bool:
		return false

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_respawn_policy_and_permanent_death_hud()
	await _test_singleplayer_flow_and_respawn()
	await _test_singleplayer_transition_revive_policy()
	await _test_host_transition_revive_signal_policy()
	await _test_host_authoritative_revive_all()
	await _test_client_view_waits_for_authoritative_revive()
	await _test_multiplayer_all_dead_is_not_defeat()
	await _test_client_gate_warning_replication()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("TOWER_DEFENSE_FLOW_RESPAWN_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_respawn_policy_and_permanent_death_hud() -> void:
	var standard_runtime := TOWER_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(standard_runtime)
	_expect(
		standard_runtime.get_multiplayer_mode_adapter().allows_player_respawn(1),
		"Existing runtimes must retain the default allow-respawn policy."
	)
	standard_runtime.free()

	var no_respawn_runtime := NoRespawnTowerRuntime.new()
	var no_respawn_adapter := NoRespawnTowerModeAdapter.new()
	no_respawn_adapter.name = "MultiplayerModeAdapter"
	no_respawn_runtime.add_child(no_respawn_adapter)
	no_respawn_adapter.bind_runtime(no_respawn_runtime)
	no_respawn_runtime.multiplayer_mode_adapter = no_respawn_adapter
	no_respawn_runtime.tower_multiplayer_mode_adapter = no_respawn_adapter
	var mp_game := MP_GAME_SCENE.instantiate()
	mp_game.set("game", no_respawn_runtime)
	mp_game.set("_mode_adapter", no_respawn_adapter)
	mp_game.set("tower_mode_adapter", no_respawn_adapter)
	no_respawn_adapter.attach_multiplayer_session(mp_game)
	mp_game.call("_schedule_player_revive", 7)
	var revive_times := mp_game.get("_dead_player_revive_times") as Dictionary
	var revive_seconds := mp_game.get("_dead_player_revive_last_seconds") as Dictionary
	_expect(
		revive_times.is_empty() and revive_seconds.is_empty(),
		"The shared MpGame scheduler must not create a timer when the runtime forbids respawn."
	)
	revive_times[7] = 0.0
	revive_seconds[7] = 0
	mp_game.call("_revive_player_peer", 7, Vector2.ZERO)
	_expect(
		revive_times.is_empty() and revive_seconds.is_empty(),
		"The final revive sink must discard a stale timer instead of bypassing the runtime policy."
	)
	var mp_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_game.gd"
	)
	for lethal_function in [
		"request_multiplayer_player_damage_over_time_tick",
		"apply_luoxi_direct_health_loss",
		"_apply_player_hit_report",
	]:
		_expect(
			_get_function_source(mp_source, lethal_function).contains(
				"_schedule_player_revive("
			),
			"Every lethal player-damage path must route through the shared respawn-policy scheduler."
		)
	mp_game.free()
	no_respawn_runtime.free()

	var status_hud := STATUS_HUD_SCENE.instantiate() as TowerDefenseStatusHUD
	root.add_child(status_hud)
	await process_frame
	_expect(
		status_hud.player_life_status_hud is PlayerLifeStatusHUD
		and status_hud.player_life_status_hud.scene_file_path
		== LIFE_STATUS_HUD_SCENE.resource_path,
		"TowerDefenseStatusHUD must be a façade over the authored shared life-status component."
	)
	var shared_scene_source := FileAccess.get_file_as_string(
		"res://scene/ui/shared/player_life_status_hud.tscn"
	)
	_expect(
		shared_scene_source.contains("scene/ui/shared/player_death_screen.gdshader")
		and not shared_scene_source.contains("tower_defense_death_screen.gdshader")
		and not shared_scene_source.contains("tower_defense_gate_warning.gdshader")
		and not shared_scene_source.contains("home_gate_double_warning.wav")
		and status_hud.get_node_or_null("GateWarningOverlay") is ColorRect
		and status_hud.get_node_or_null("GateWarningAudio") is AudioStreamPlayer,
		"Shared death visuals must remain neutral while core warnings stay on the tower wrapper."
	)
	status_hud.set_dead_player_list_enabled(false)
	status_hud.show_local_permanent_death(7)
	_expect(
		status_hud.local_permanent_death_active
		and status_hud.local_dead_peer_id == 7
		and status_hud.death_screen_effect.visible
		and status_hud.local_death_center.visible,
		"Permanent local death must reuse the full-screen mask and central death card."
	)
	_expect(
		status_hud.local_countdown_label.text == "本次作战无法复活"
		and status_hud.local_compact_countdown_label.text == "观战中",
		"Permanent local death must use explicit spectator wording instead of a fake countdown."
	)
	_expect(
		status_hud.respawn_entries.is_empty()
		and not status_hud.dead_players_panel.visible
		and status_hud.dead_players_label.text.is_empty(),
		"Permanent local death must not populate or reveal the disabled right-side respawn list."
	)
	await create_timer(1.08).timeout
	_expect(
		not status_hud.local_death_full_content.visible
		and status_hud.local_death_compact_content.visible
		and status_hud.local_compact_countdown_label.text == "观战中",
		"The collapsed permanent-death card must remain an unambiguous spectator indicator."
	)
	status_hud.clear_player_respawn(7)
	_expect(
		not status_hud.local_permanent_death_active
		and not status_hud.death_screen_effect.visible
		and not status_hud.local_death_center.visible,
		"Clearing permanent local death must reset the reused presentation."
	)
	status_hud.set_player_respawn(7, "玩家", 5, true)
	_expect(
		not status_hud.local_permanent_death_active
		and status_hud.local_countdown_label.text == "5 秒后复活"
		and status_hud.local_compact_countdown_label.text == "5 秒后复活",
		"The legacy tower-defense countdown API must retain its existing behavior."
	)
	status_hud.clear_all_respawns()
	status_hud.queue_free()
	await process_frame


func _get_function_source(source: String, function_name: String) -> String:
	var marker := "func %s(" % function_name
	var function_start := source.find(marker)
	if function_start < 0:
		return ""
	var next_function := source.find("\nfunc ", function_start + marker.length())
	if next_function < 0:
		return source.substr(function_start)
	return source.substr(function_start, next_function - function_start)


func _test_singleplayer_flow_and_respawn() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(game)
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
	_expect(
		is_equal_approx(game.progression_config.initial_preparation_seconds, 90.0)
		and is_equal_approx(game.progression_config.wave_intermission_seconds, 30.0)
		and is_equal_approx(game.progression_config.new_day_preparation_seconds, 60.0),
		"Tower-defense flow must use separate 90/30/60 preparation durations."
	)
	_expect(game.player.current_xirang == 1000, "The player must enter tower defense with 1000 Xirang.")
	var first_step := game.current_flow_step
	_expect(game.wave_state == CombatFlowState.State.PRE_WAVE, "The first wave must wait in PRE_WAVE instead of starting immediately.")
	_expect(game.countdown_seconds == 90, "The first preparation period must start at 90 seconds.")
	_expect(game.wave_hud.start_wave_button.visible and not game.wave_hud.start_wave_button.disabled, "The rest HUD must expose an enabled early-start button.")
	_expect(
		game.wave_hud.stage_banner.visible
		and game.wave_hud.stage_label.text.contains("01:30"),
		"The tower-defense rest banner must use MM:SS formatting."
	)
	_expect(
		game.get_node_or_null("HomeBaseHUD") == null
		and game.wave_hud.tower_defense_stats.visible
		and game.wave_hud.core_value_label.text == "100/100",
		"Core health must be merged into the centered tower-defense HUD."
	)
	_expect(
		game.music_player.stream.resource_path
		== "res://resources/audio/shenmu_forest_intermission.ogg",
		"The initial tower-defense rest must play the forest pre-combat BGM."
	)
	_expect(game.tower_defense_status_hud.layer > 70, "Death and gate warnings must render above every gameplay HUD.")
	_expect(_all_control_descendants_ignore_mouse(game.tower_defense_status_hud), "The status HUD must never consume gameplay or menu input.")
	var status_hud: TowerDefenseStatusHUD = game.tower_defense_status_hud
	var local_death_rect := status_hud.local_death_center.get_global_rect()
	var top_bar_rect := game.wave_hud.top_bar.get_global_rect()
	var stage_banner_rect := game.wave_hud.stage_banner.get_global_rect()
	var early_start_rect := game.wave_hud.start_wave_button.get_global_rect()
	_expect(
		not local_death_rect.intersects(top_bar_rect)
		and not local_death_rect.intersects(stage_banner_rect)
		and not local_death_rect.intersects(early_start_rect),
		"The authored local-death region must not overlap the main HUD or rest controls."
	)
	_expect(
		local_death_rect.position.y >= early_start_rect.end.y + 6.0,
		"The compact local-death row must retain at least six pixels below the early-start button."
	)
	_expect(game.merchant.is_active and game.merchant.visible, "Zhuangfangyi must remain visible and interactive during rest.")
	_expect(game.luoxi_merchant.is_active and game.luoxi_merchant.visible, "Luoxi must remain visible and interactive during rest.")

	game.wave_hud.start_wave_button.pressed.emit()
	_expect(
		game.wave_state == CombatFlowState.State.PRE_WAVE
		and game.countdown_seconds == 3
		and game.countdown_audio.playing
		and not game.wave_hud.start_wave_button.visible,
		"Early-start must skip preparation to one non-repeatable 3-second final countdown."
	)
	_expect(
		not game.request_tower_defense_wave_start(0),
		"The final 3-second countdown must reject repeated early-start requests."
	)
	_finish_final_countdown(game)
	_expect(game.wave_state == CombatFlowState.State.WAVE_ACTIVE, "The third countdown tick must enter active combat exactly once.")
	_expect(
		not game.wave_hud.stage_banner.visible
		and game.wave_hud.tower_defense_stats.visible,
		"Active combat must hide only the phase banner while preserving the three metrics."
	)
	_expect(
		int(game.wave_hud.enemy_value_label.text) == game.hud_alive_enemy_ids.size()
		and game.hud_alive_enemy_ids.size() > 0,
		"Authoritative enemy spawns must update the independent on-field enemy metric."
	)
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
	_expect(
		game.wave_hud.enemy_value_label.text == "0",
		"Enemy tree exit must clear the on-field enemy metric without changing wave progress."
	)
	game.luoxi_merchant.refresh_counts_by_player_key[0] = 3
	game.luoxi_merchant.pending_choices_by_player_key[0] = []
	game.luoxi_collectible_claim_counts[0] = 1
	game.luoxi_merchant.choice_visible = true
	game.luoxi_merchant.result_visible = true
	game.luoxi_merchant.dialogue_bubble.show()
	game.call("_enter_intermission", first_step)
	_expect(game.wave_state == CombatFlowState.State.INTERMISSION, "Every cleared wave must enter a rest state.")
	_expect(game.countdown_seconds == 30, "Every ordinary between-wave rest must start at 30 seconds.")
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
	_expect(game.request_tower_defense_wave_start(0), "The between-wave rest button must also start the final countdown.")
	_expect(
		game.wave_state == CombatFlowState.State.INTERMISSION
		and game.countdown_seconds == 3,
		"An intermission early-start must retain the rest state through the final countdown."
	)
	_finish_final_countdown(game)
	_expect(
		game.wave_state == CombatFlowState.State.WAVE_ACTIVE,
		"The intermission final countdown must enter combat only after all three ticks."
	)
	game.enemy_spawn_timer.stop()
	game.player.call("_die")
	var death_shader := status_hud.death_screen_effect.material as ShaderMaterial
	_expect(
		status_hud.local_death_center.modulate.a < 0.05,
		"The local death card must begin transparent instead of appearing instantly."
	)
	_expect(
		not status_hud.dead_players_panel.visible
		and status_hud.dead_players_panel.modulate.a < 0.05,
		"Single-player death must keep the multiplayer dead-player list hidden."
	)
	_expect(
		float(death_shader.get_shader_parameter(&"intensity")) < 0.05,
		"The death screen effect must begin transparent instead of appearing instantly."
	)
	await physics_frame
	_expect(game.player.is_dead, "A killed tower-defense player must enter the dead state.")
	_expect(game.wave_state == CombatFlowState.State.WAVE_ACTIVE, "Player death must not end tower defense.")
	_expect(
		game.player.body_sprite.visible
		and game.player.body_sprite.animation == &"death"
		and game.player.body_sprite.is_playing(),
		"Tower-defense death must keep the authored death animation visible while controls are locked."
	)
	_expect(not game.player.nameplate_layer.visible, "No world-space revive countdown may remain over the death position.")
	_expect(game.player.collision_shape.disabled, "A dead tower-defense player must have no world collision.")
	_expect(game.map_camera.get_parent() == game, "The local camera must detach from the dead player for spectator movement.")
	_expect(status_hud.local_death_center.visible, "The local death HUD must be visible.")
	_expect(
		not status_hud.dead_players_panel.visible,
		"Single-player death must not show the right-side dead-player HUD."
	)
	_expect(game.singleplayer_respawn_last_seconds == 5, "The first death in a wave must use a five-second revive.")
	_expect(
		status_hud.local_death_center.position.y
		> status_hud.local_death_top_position.y + 80.0,
		"The local death card must begin near the screen center before moving upward."
	)
	_expect(
		status_hud.local_death_center.size.is_equal_approx(Vector2(372.0, 118.0)),
		"The local death presentation must begin as the complete 372x118 card."
	)
	_expect(
		status_hud.local_death_full_content.visible
		and status_hud.local_death_full_content.modulate.a > 0.99
		and status_hud.local_death_compact_content.modulate.a < 0.05,
		"Only the complete three-line death content may be readable at intro start."
	)
	_expect(
		status_hud.local_countdown_label.text == "5 秒后复活"
		and status_hud.local_compact_countdown_label.text == "5 秒后复活",
		"Full and compact death layouts must share the same initial revive countdown."
	)
	status_hud.set_player_respawn(77, "队友", 9, false)
	_expect(
		status_hud.respawn_entries.has(77)
		and status_hud.dead_players_label.text.is_empty()
		and not status_hud.dead_players_panel.visible
		and status_hud.dead_players_panel.modulate.a < 0.05,
		"Single-player mode must retain respawn data without rendering the multiplayer list."
	)
	var local_death_intro_position := status_hud.local_death_center.position

	await create_timer(0.72).timeout
	_expect(
		status_hud.local_death_center.position.y < local_death_intro_position.y
		and status_hud.local_death_center.position.y > status_hud.local_death_top_position.y,
		"The local death card must still be moving upward midway through its transition."
	)
	_expect(
		status_hud.local_death_center.size.x < 372.0
		and status_hud.local_death_center.size.x > 250.0
		and status_hud.local_death_center.size.y < 118.0
		and status_hud.local_death_center.size.y > 42.0,
		"The death frame must shrink in both axes while it moves upward."
	)
	_expect(
		status_hud.local_death_full_content.visible
		and status_hud.local_death_full_content.modulate.a < 0.95
		and status_hud.local_death_compact_content.visible
		and status_hud.local_death_compact_content.modulate.a > 0.05,
		"The full and one-line contents must cross-fade during the size transition."
	)

	await create_timer(0.8).timeout
	_expect(
		status_hud.local_death_center.position.is_equal_approx(
			status_hud.local_death_top_position
		),
		"The local death card must finish at its authored top position."
	)
	_expect(
		status_hud.local_death_center.size.is_equal_approx(Vector2(250.0, 42.0))
		and status_hud.local_death_center.size.is_equal_approx(status_hud.local_death_top_size),
		"The completed local death card must collapse to the authored 250x42 row."
	)
	_expect(
		status_hud.local_death_center.modulate.a > 0.99,
		"The local death card must finish fully visible."
	)
	_expect(
		not status_hud.dead_players_panel.visible
		and status_hud.dead_players_panel.modulate.a < 0.05
		and status_hud.dead_players_label.text.is_empty(),
		"The multiplayer dead-player list must remain hidden after the local intro finishes."
	)
	_expect(
		float(death_shader.get_shader_parameter(&"intensity")) > 0.99,
		"The death screen effect must reach its full authored intensity."
	)
	_expect(
		not status_hud.local_death_full_content.visible
		and status_hud.local_death_compact_content.visible
		and status_hud.local_death_compact_content.modulate.a > 0.99,
		"Only the compact countdown row may remain after the death intro finishes."
	)
	_expect(
		status_hud.local_compact_countdown_label.text == status_hud.local_countdown_label.text
		and status_hud.local_compact_countdown_label.text.contains("秒后复活")
		and not status_hud.local_compact_countdown_label.text.contains("\n")
		and status_hud.local_compact_countdown_label.label_settings.font_size == 18,
		"The compact death card must present only one restrained revive-countdown line."
	)
	status_hud.set_player_respawn(0, "玩家", 3, true)
	_expect(
		status_hud.local_compact_countdown_label.text == "3 秒后复活"
		and status_hud.local_death_center.position.is_equal_approx(status_hud.local_death_top_position)
		and status_hud.local_death_center.size.is_equal_approx(Vector2(250.0, 42.0))
		and not status_hud.local_death_intro_active
		and status_hud.local_death_tween == null,
		"Countdown updates in compact state must not resize or replay the death intro."
	)
	status_hud.clear_player_respawn(77)

	var camera_before := game.map_camera.global_position
	Input.action_press(&"move_right")
	game.call("_update_local_spectator_camera", 0.1)
	Input.action_release(&"move_right")
	_expect(game.map_camera.global_position.x > camera_before.x, "Movement input while dead must move only the spectator camera.")
	_expect(game.player.velocity == Vector2.ZERO, "Spectator input must not move the dead player body.")
	await create_timer(0.6).timeout
	_expect(
		not game.player.body_sprite.visible,
		"The tower-defense corpse must hide only after its non-looping death animation finishes."
	)

	game.singleplayer_respawn_time_left = 0.0
	game.call("_update_singleplayer_respawn", 0.01)
	await physics_frame
	_expect(not game.player.is_dead, "The single-player revive timer must revive the player.")
	_expect(game.player.global_position.is_equal_approx(game.player_spawn.global_position), "The player must revive at the authored point in front of the blue gate.")
	_expect(game.map_camera.get_parent() == game.player, "Reviving must restore camera follow to the player.")
	_expect(not status_hud.local_death_center.visible, "Reviving must clear the local death HUD.")
	_expect(
		status_hud.respawn_entries.is_empty()
		and not status_hud.death_screen_effect.visible
		and not status_hud.dead_players_panel.visible
		and status_hud.local_death_tween == null
		and status_hud.countdown_pulse_tween == null,
		"Reviving must clear every local death presentation and pending animation."
	)
	_expect(
		status_hud.local_death_center.position.is_equal_approx(status_hud.local_death_top_position)
		and status_hud.local_death_center.size.is_equal_approx(Vector2(250.0, 42.0))
		and status_hud.local_death_center.modulate.a < 0.05
		and status_hud.local_death_full_content.visible
		and status_hud.local_death_full_content.modulate.a > 0.99
		and status_hud.local_death_compact_content.modulate.a < 0.05,
		"Reviving must restore the hidden authored card state for the next death."
	)
	_expect(
		float(death_shader.get_shader_parameter(&"intensity")) < 0.05,
		"Reviving must completely clear the death-screen shader intensity."
	)

	var delays: Array[int] = []
	game.call("_reset_player_wave_death_counts")
	for _death_index in range(5):
		delays.append(roundi(game.consume_next_player_respawn_delay(0)))
	_expect(delays == [5, 10, 15, 20, 20], "Per-wave revive delays must be 5/10/15/20 and cap at 20 seconds.")
	game.call("_reset_player_wave_death_counts")
	_expect(roundi(game.consume_next_player_respawn_delay(0)) == 5, "Starting a new wave must reset the next revive delay to five seconds.")

	game.current_base_health = 1
	var defeat_zoom := game.map_camera.zoom
	var defeat_gate_center := game.home_objective_targets[0].global_position.round()
	game.call("_apply_base_damage", 1)
	_expect(game.wave_state == CombatFlowState.State.DEFEAT, "Blue-gate health reaching zero must still end the game.")
	_expect(not game.music_player.playing, "Tower-defense defeat must stop the active BGM immediately.")
	_expect(not game.wave_hud.result_overlay.visible, "The defeat overlay must wait until the camera reaches the blue gate.")
	_expect(not game.defeat_audio.playing, "The defeat cue must wait for the camera transition.")
	_expect(game.map_camera.get_parent() == game, "Defeat must detach the camera from the local player or spectator target.")
	_expect(game.map_camera.zoom.is_equal_approx(defeat_zoom), "Defeat camera travel must preserve the player's current zoom.")
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
	await create_timer(TowerDefenseGame.DEFEAT_CAMERA_TRAVEL_SECONDS + 0.1).timeout
	_expect(game.map_camera.global_position.is_equal_approx(defeat_gate_center), "The defeat camera must finish at the authoritative blue-gate center.")
	_expect(game.map_camera.zoom.is_equal_approx(defeat_zoom), "The completed defeat camera transition must not alter zoom.")
	_expect(game.wave_hud.result_overlay.visible, "The shared defeat overlay must appear after camera travel completes.")
	_expect(game.wave_hud.result_subtitle.text == "核心生命值归0，游戏结束", "Tower defense must show the exact core-health defeat subtitle.")
	_expect(game.defeat_audio.playing, "The defeat sound must play when the result overlay appears.")
	var defeat_audio_playback := game.defeat_audio.get_playback_position()
	game.call("_enter_defeat")
	_expect(game.defeat_audio.get_playback_position() >= defeat_audio_playback, "Duplicate defeat events must not restart the local presentation.")
	game.wave_hud.show_tower_defense_defeat()
	_expect(game.wave_hud.result_subtitle.text == "核心生命值归0，游戏结束", "TowerDefenseWaveHUD must retain its dedicated exact wording.")

	_stop_audio_players(game)
	game.queue_free()
	for _frame in range(4):
		await process_frame
		await physics_frame


func _test_singleplayer_transition_revive_policy() -> void:
	var intermission_game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(intermission_game)
	root.add_child(intermission_game)
	current_scene = intermission_game
	await process_frame
	await physics_frame
	var intermission_step := intermission_game.call("_get_start_flow_step") as FlowStepConfig
	var intermission_revives := {"count": 0}
	intermission_game.player.revived.connect(
		func() -> void:
			intermission_revives["count"] = int(intermission_revives["count"]) + 1
	)
	intermission_game.player.call("_die")
	_expect(intermission_game.player.is_dead, "The intermission revive test must begin with a dead single-player character.")
	intermission_game.call("_enter_intermission", intermission_step)
	_expect(not intermission_game.player.is_dead, "Entering a tower-defense intermission must revive a dead single-player character immediately.")
	_expect(int(intermission_revives["count"]) == 1, "Intermission entry must emit exactly one single-player revive transition.")
	_expect(
		intermission_game.player.global_position.is_equal_approx(intermission_game.player_spawn.global_position),
		"An intermission revive must use the authored tower-defense player spawn."
	)
	_expect(
		intermission_game.player.current_health == intermission_game.player.max_health
		and intermission_game.player.invincibility_time_left > 0.0,
		"An intermission revive must restore full health and the normal revive protection."
	)
	_expect(
		intermission_game.singleplayer_respawn_time_left < 0.0
		and intermission_game.singleplayer_respawn_last_seconds < 0
		and intermission_game.tower_defense_status_hud.respawn_entries.is_empty(),
		"An immediate intermission revive must clear its pending timer and death HUD entry."
	)

	var living_position := intermission_game.player_spawn.global_position + Vector2(23.0, -11.0)
	var living_health := intermission_game.player.max_health - 9
	var living_velocity := Vector2(7.0, -3.0)
	var living_invincibility := 0.75
	intermission_game.player.global_position = living_position
	intermission_game.player.current_health = living_health
	intermission_game.player.velocity = living_velocity
	intermission_game.player.invincibility_time_left = living_invincibility
	intermission_game.call("_enter_intermission", intermission_step)
	_expect(
		intermission_game.player.global_position.is_equal_approx(living_position)
		and intermission_game.player.current_health == living_health
		and intermission_game.player.velocity.is_equal_approx(living_velocity)
		and is_equal_approx(
			intermission_game.player.invincibility_time_left,
			living_invincibility
		),
		"Intermission entry must not heal, teleport, stop, or replace protection on a living player."
	)
	_expect(int(intermission_revives["count"]) == 1, "A living player must not emit a synthetic revive during intermission entry.")
	await _cleanup_tower_game(intermission_game)

	var zero_rest_game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(zero_rest_game)
	root.add_child(zero_rest_game)
	current_scene = zero_rest_game
	await process_frame
	await physics_frame
	var zero_rest_step := zero_rest_game.call("_get_start_flow_step") as FlowStepConfig
	var zero_rest_revives := {"count": 0}
	zero_rest_game.player.revived.connect(
		func() -> void:
			zero_rest_revives["count"] = int(zero_rest_revives["count"]) + 1
	)
	zero_rest_game.player.call("_die")
	zero_rest_game.progression_config = zero_rest_game.progression_config.duplicate(true)
	zero_rest_game.progression_config.wave_intermission_seconds = 0.0
	zero_rest_game.call("_enter_intermission", zero_rest_step)
	zero_rest_game.enemy_spawn_timer.stop()
	_expect(
		zero_rest_game.wave_state == CombatFlowState.State.WAVE_ACTIVE,
		"A zero-second intermission must continue directly into the next wave."
	)
	_expect(not zero_rest_game.player.is_dead, "A zero-second intermission must still revive a dead single-player character before the next wave begins.")
	_expect(int(zero_rest_revives["count"]) == 1, "The zero-second intermission path must revive exactly once.")
	_expect(
		zero_rest_game.singleplayer_respawn_time_left < 0.0
		and zero_rest_game.tower_defense_status_hud.respawn_entries.is_empty(),
		"The zero-second intermission path must not carry a stale respawn timer into the next wave."
	)
	await _cleanup_tower_game(zero_rest_game)

	var victory_game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(victory_game)
	root.add_child(victory_game)
	current_scene = victory_game
	await process_frame
	await physics_frame
	var victory_revives := {"count": 0}
	victory_game.player.revived.connect(
		func() -> void:
			victory_revives["count"] = int(victory_revives["count"]) + 1
	)
	victory_game.player.call("_die")
	victory_game.call("_enter_victory")
	_expect(victory_game.wave_state == CombatFlowState.State.VICTORY, "The single-player revive policy test must enter victory.")
	_expect(not victory_game.player.is_dead, "Victory must revive a dead single-player character immediately.")
	_expect(int(victory_revives["count"]) == 1, "Victory must perform exactly one single-player revive transition.")
	_expect(
		victory_game.singleplayer_respawn_time_left < 0.0
		and victory_game.tower_defense_status_hud.respawn_entries.is_empty(),
		"Victory revival must clear every pending single-player respawn state."
	)
	await _cleanup_tower_game(victory_game)

	var defeat_game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(defeat_game)
	root.add_child(defeat_game)
	current_scene = defeat_game
	await process_frame
	await physics_frame
	var defeat_revives := {"count": 0}
	defeat_game.player.revived.connect(
		func() -> void:
			defeat_revives["count"] = int(defeat_revives["count"]) + 1
	)
	defeat_game.player.call("_die")
	var defeat_position := defeat_game.player.global_position
	var defeat_health := defeat_game.player.current_health
	defeat_game.call("_enter_defeat")
	_expect(defeat_game.wave_state == CombatFlowState.State.DEFEAT, "The single-player defeat policy test must enter defeat.")
	_expect(
		defeat_game.player.is_dead
		and defeat_game.player.current_health == defeat_health
		and defeat_game.player.global_position.is_equal_approx(defeat_position),
		"Defeat must preserve the dead player state instead of reviving, healing, or teleporting it."
	)
	_expect(int(defeat_revives["count"]) == 0, "Defeat must never emit a player revive transition.")
	_expect(
		defeat_game.singleplayer_respawn_time_left < 0.0
		and defeat_game.tower_defense_status_hud.respawn_entries.is_empty(),
		"Defeat must cancel pending respawn state without reviving the player."
	)
	await _cleanup_tower_game(defeat_game)


func _test_host_transition_revive_signal_policy() -> void:
	var player_names := {1: "主机", 2: "队友"}
	var character_ids := {1: &"weishidaier", 2: &"tiyi"}

	var living_game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(living_game)
	living_game.auto_start_waves = false
	living_game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		player_names,
		character_ids
	)
	root.add_child(living_game)
	current_scene = living_game
	await process_frame
	await physics_frame
	var living_signals := {"count": 0}
	living_game.get_multiplayer_mode_adapter().revive_all_requested.connect(
		func() -> void:
			living_signals["count"] = int(living_signals["count"]) + 1
	)
	var living_step := living_game.call("_get_start_flow_step") as FlowStepConfig
	living_game.call("_enter_intermission", living_step)
	living_game.call("_enter_victory")
	_expect(
		int(living_signals["count"]) == 0,
		"A Host must not broadcast revive-all when every multiplayer player is already alive."
	)
	await _cleanup_tower_game(living_game)

	var intermission_game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(intermission_game)
	intermission_game.auto_start_waves = false
	intermission_game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		player_names,
		character_ids
	)
	root.add_child(intermission_game)
	current_scene = intermission_game
	await process_frame
	await physics_frame
	var intermission_signals := {"count": 0}
	intermission_game.get_multiplayer_mode_adapter().revive_all_requested.connect(
		func() -> void:
			intermission_signals["count"] = int(intermission_signals["count"]) + 1
	)
	for peer_id in [1, 2]:
		intermission_game.get_player_for_peer(peer_id).apply_multiplayer_death_state()
	var intermission_step := intermission_game.call("_get_start_flow_step") as FlowStepConfig
	intermission_game.progression_config = intermission_game.progression_config.duplicate(true)
	intermission_game.progression_config.wave_intermission_seconds = 0.0
	intermission_game.call("_enter_intermission", intermission_step)
	intermission_game.enemy_spawn_timer.stop()
	_expect(
		int(intermission_signals["count"]) == 1,
		"A Host zero-second intermission with multiple dead players must broadcast one revive-all event, not one per player."
	)
	_expect(
		_all_multiplayer_players_dead(intermission_game, [1, 2]),
		"The Host gameplay scene must leave multiplayer revival to the authoritative MpGame listener."
	)
	await _cleanup_tower_game(intermission_game)

	var victory_game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(victory_game)
	victory_game.auto_start_waves = false
	victory_game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		player_names,
		character_ids
	)
	root.add_child(victory_game)
	current_scene = victory_game
	await process_frame
	await physics_frame
	var victory_signals := {"count": 0}
	victory_game.get_multiplayer_mode_adapter().revive_all_requested.connect(
		func() -> void:
			victory_signals["count"] = int(victory_signals["count"]) + 1
	)
	for peer_id in [1, 2]:
		victory_game.get_player_for_peer(peer_id).apply_multiplayer_death_state()
	victory_game.call("_enter_victory")
	_expect(
		int(victory_signals["count"]) == 1,
		"A Host victory with multiple dead players must broadcast exactly one revive-all event."
	)
	_expect(
		_all_multiplayer_players_dead(victory_game, [1, 2]),
		"Host victory must not bypass MpGame by reviving multiplayer Player nodes directly."
	)
	await _cleanup_tower_game(victory_game)

	var defeat_game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(defeat_game)
	defeat_game.auto_start_waves = false
	defeat_game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		player_names,
		character_ids
	)
	root.add_child(defeat_game)
	current_scene = defeat_game
	await process_frame
	await physics_frame
	var defeat_signals := {"count": 0}
	defeat_game.get_multiplayer_mode_adapter().revive_all_requested.connect(
		func() -> void:
			defeat_signals["count"] = int(defeat_signals["count"]) + 1
	)
	for peer_id in [1, 2]:
		defeat_game.get_player_for_peer(peer_id).apply_multiplayer_death_state()
	defeat_game.call("_enter_defeat")
	_expect(int(defeat_signals["count"]) == 0, "A Host defeat must not broadcast revive-all.")
	_expect(
		_all_multiplayer_players_dead(defeat_game, [1, 2]),
		"A Host defeat must preserve every dead multiplayer player state."
	)
	await _cleanup_tower_game(defeat_game)


func _test_host_authoritative_revive_all() -> void:
	var net_manager := root.get_node_or_null("NetManager")
	_expect(net_manager != null, "The authoritative revive-all test requires NetManager.")
	if net_manager == null:
		return
	var previous_role := int(net_manager.get("net_role"))
	net_manager.set("net_role", 1)

	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(game)
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		{1: "主机", 2: "存活队友"},
		{1: &"weishidaier", 2: &"tiyi"}
	)
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	var dead_player := game.get_player_for_peer(1)
	var living_player := game.get_player_for_peer(2)
	var living_position := living_player.global_position + Vector2(19.0, -7.0)
	var living_health := living_player.max_health - 11
	living_player.global_position = living_position
	living_player.current_health = living_health
	dead_player.apply_multiplayer_death_state()
	game.update_player_respawn_countdown(1, 5)
	_expect(
		game.tower_defense_status_hud.dead_players_panel.visible
		and game.tower_defense_status_hud.dead_players_label.text.contains(
			"主机：5秒后复活"
		),
		"Host mode must keep the right-side multiplayer dead-player list enabled."
	)

	var mp_game := MP_GAME_SCENE.instantiate()
	mp_game.set("game", game)
	mp_game.set("net_manager", net_manager)
	var tower_adapter := (
		game.get_multiplayer_mode_adapter()
		as TowerDefenseMultiplayerModeAdapter
	)
	mp_game.set("_mode_adapter", tower_adapter)
	mp_game.set("tower_mode_adapter", tower_adapter)
	tower_adapter.attach_multiplayer_session(mp_game)
	var revive_times := mp_game.get("_dead_player_revive_times") as Dictionary
	var revive_seconds := mp_game.get("_dead_player_revive_last_seconds") as Dictionary
	revive_times[1] = 1000.0
	revive_times[77] = 2000.0
	revive_seconds[1] = 5
	revive_seconds[77] = 9
	var revive_events := {"dead": 0, "living": 0}
	var revive_all_requests := {"count": 0}
	dead_player.revived.connect(
		func() -> void:
			revive_events["dead"] = int(revive_events["dead"]) + 1
	)
	living_player.revived.connect(
		func() -> void:
			revive_events["living"] = int(revive_events["living"]) + 1
	)
	game.get_multiplayer_mode_adapter().revive_all_requested.connect(
		func() -> void:
			revive_all_requests["count"] = int(revive_all_requests["count"]) + 1
	)
	game.get_multiplayer_mode_adapter().revive_all_requested.connect(
		Callable(mp_game, "_on_host_revive_all_requested")
	)

	var next_step := game.call("_get_start_flow_step") as FlowStepConfig
	game.call("_enter_intermission", next_step)
	var fixed_spawn: Variant = game.get_fixed_multiplayer_respawn_position(1)
	_expect(
		not dead_player.is_dead
		and dead_player.current_health == dead_player.max_health
		and dead_player.invincibility_time_left > 0.0
		and fixed_spawn is Vector2
		and dead_player.global_position.is_equal_approx(fixed_spawn as Vector2),
		"Host revive-all must restore each dead player at its fixed tower-defense slot with full health and protection."
	)
	_expect(
		living_player.global_position.is_equal_approx(living_position)
		and living_player.current_health == living_health,
		"Host revive-all must not heal or teleport a living multiplayer player."
	)
	_expect(
		revive_times.is_empty()
		and revive_seconds.is_empty()
		and game.tower_defense_status_hud.respawn_entries.is_empty(),
		"Host revive-all must clear every pending revive timer and death HUD entry before completing."
	)
	_expect(
		int(revive_events["dead"]) == 1 and int(revive_events["living"]) == 0,
		"Host revive-all must emit one revive transition only for the dead player."
	)
	_expect(
		int(revive_all_requests["count"]) == 1,
		"A Host intermission must issue exactly one authoritative revive-all request."
	)
	var revision_after_revive := int(
		(mp_game.get("_player_health_revisions") as Dictionary).get(1, 0)
	)
	game.call("_enter_intermission", next_step)
	_expect(
		int(revive_events["dead"]) == 1
		and int((mp_game.get("_player_health_revisions") as Dictionary).get(1, 0))
		== revision_after_revive
		and int(revive_all_requests["count"]) == 1,
		"A repeated Host intermission must not request or perform revival for an already-living player."
	)

	mp_game.free()
	net_manager.set("net_role", previous_role)
	await _cleanup_tower_game(game)


func _test_client_view_waits_for_authoritative_revive() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(game)
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		2,
		{1: "主机", 2: "客户端"},
		{1: &"weishidaier", 2: &"tiyi"}
	)
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	var revive_events := {"count": 0}
	var revive_all_events := {"count": 0}
	game.get_multiplayer_mode_adapter().revive_all_requested.connect(
		func() -> void:
			revive_all_events["count"] = int(revive_all_events["count"]) + 1
	)
	for peer_id in [1, 2]:
		var player_instance := game.get_player_for_peer(peer_id)
		player_instance.revived.connect(
			func() -> void:
				revive_events["count"] = int(revive_events["count"]) + 1
		)
		player_instance.apply_multiplayer_death_state()
	game.update_player_respawn_countdown(1, 7)
	_expect(
		game.tower_defense_status_hud.dead_players_panel.visible
		and game.tower_defense_status_hud.dead_players_label.text.contains(
			"主机：7秒后复活"
		),
		"ClientView mode must keep the right-side multiplayer dead-player list enabled."
	)
	var flow_step := game.call("_get_start_flow_step") as FlowStepConfig
	game.apply_remote_flow_state(
		flow_step.step_id,
		CombatFlowState.State.INTERMISSION,
		30
	)
	_expect(
		_all_multiplayer_players_dead(game, [1, 2]),
		"A ClientView intermission snapshot must wait for reliable authoritative revive events."
	)
	var countdown_audio := game.countdown_audio
	game.apply_remote_flow_state(
		flow_step.step_id,
		CombatFlowState.State.INTERMISSION,
		3
	)
	_expect(
		game.countdown_seconds == 3 and countdown_audio.playing,
		"A ClientView final-countdown snapshot must immediately play the 3-second tick."
	)
	countdown_audio.stop()
	game.apply_remote_flow_state(
		flow_step.step_id,
		CombatFlowState.State.INTERMISSION,
		3
	)
	_expect(
		not countdown_audio.playing,
		"A repeated ClientView countdown snapshot must not replay the same tick."
	)
	for expected_seconds in [2, 1]:
		game.call("_update_client_flow_countdown")
		_expect(
			game.countdown_seconds == expected_seconds and countdown_audio.playing,
			"ClientView must play each remaining final-countdown tick exactly once."
		)
		countdown_audio.stop()
	game.apply_remote_flow_state(
		flow_step.step_id,
		CombatFlowState.State.INTERMISSION,
		0
	)
	_expect(
		_all_multiplayer_players_dead(game, [1, 2]),
		"A zero-second ClientView intermission must not infer or perform revival locally."
	)
	game.apply_remote_victory()
	_expect(
		_all_multiplayer_players_dead(game, [1, 2]),
		"A ClientView victory presentation must still wait for the Host's reliable revive confirmations."
	)
	game.apply_remote_defeat()
	_expect(
		_all_multiplayer_players_dead(game, [1, 2]),
		"A ClientView defeat must preserve dead player state."
	)
	_expect(
		int(revive_events["count"]) == 0
		and int(revive_all_events["count"]) == 0,
		"ClientView flow updates must neither revive Player nodes nor originate revive-all requests."
	)
	await _cleanup_tower_game(game)


func _test_client_gate_warning_replication() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(game)
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		2,
		{1: "主机", 2: "客户端"},
		{1: &"weishidaier", 2: &"tiyi"}
	)
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	_expect(
		not game.wave_hud.start_wave_button.visible,
		"A multiplayer client must not see an early-start control reserved for the host."
	)
	game.apply_remote_base_health(9, 10, 1)
	_expect(game.current_base_health == 9, "A client must apply the authoritative blue-gate health loss.")
	_expect(
		game.wave_hud.core_value_label.text == "9/10",
		"A client's centered core-health metric must use the authoritative snapshot."
	)
	_expect(not game.tower_defense_status_hud.gate_warning_overlay.visible, "A late-join client's initial damaged-gate snapshot must not fake a new hit warning.")
	_expect(not game.tower_defense_status_hud.gate_warning_audio.playing, "Initial blue-gate synchronization must remain silent.")
	game.apply_remote_base_health(8, 10, 2)
	_expect(game.current_base_health == 8, "A client must apply later blue-gate damage revisions.")
	_expect(
		game.wave_hud.core_value_label.text == "8/10",
		"Later core-health revisions must update the centered metric independently."
	)
	game.wave_hud.set_tower_defense_wave_progress(2, 1, 4)
	game.apply_remote_enemy_count(7)
	_expect(
		game.wave_hud.enemy_value_label.text == "7"
		and game.wave_hud.wave_value_label.text == "25%",
		"Client enemy snapshots must update only the enemy metric without replacing wave progress."
	)
	_expect(game.tower_defense_status_hud.gate_warning_overlay.visible, "A replicated blue-gate hit must flash on every client screen.")
	_expect(game.tower_defense_status_hud.gate_warning_audio.playing, "A replicated blue-gate hit must play the client warning sound.")
	var client_defeat_zoom := Vector2(1.5, 1.5)
	game.map_camera.zoom = client_defeat_zoom
	game.music_player.play()
	game.apply_remote_defeat()
	var first_defeat_tween := game.defeat_camera_tween
	game.apply_remote_defeat()
	_expect(game.wave_state == CombatFlowState.State.DEFEAT, "A reliable defeat event must enter the shared client defeat state.")
	_expect(game.defeat_camera_tween == first_defeat_tween, "A duplicate reliable defeat event must not restart client camera travel.")
	_expect(not game.music_player.playing, "A client must stop its own BGM as soon as defeat is received.")
	_expect(not game.wave_hud.result_overlay.visible, "A client must also defer the defeat overlay until its local camera arrives.")
	await create_timer(TowerDefenseGame.DEFEAT_CAMERA_TRAVEL_SECONDS + 0.1).timeout
	_expect(game.map_camera.global_position.is_equal_approx(game.home_objective_targets[0].global_position.round()), "Every client camera must converge on the same blue-gate objective.")
	_expect(game.map_camera.zoom.is_equal_approx(client_defeat_zoom), "Client defeat presentation must preserve local camera zoom.")
	_expect(game.wave_hud.result_subtitle.text == "核心生命值归0，游戏结束", "Client defeat presentation must use the exact shared subtitle.")
	_expect(game.defeat_audio.playing, "Each client must play the defeat sound locally after camera travel.")

	_stop_audio_players(game)
	game.queue_free()
	for _frame in range(4):
		await process_frame
		await physics_frame


func _test_multiplayer_all_dead_is_not_defeat() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(game)
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
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
	_expect(
		not game.request_tower_defense_wave_start(2),
		"A connected non-host player must not end preparation for the team."
	)
	_expect(
		game.request_tower_defense_wave_start(1),
		"The Host must be able to confirm the team's final countdown."
	)
	_expect(
		game.wave_state == CombatFlowState.State.PRE_WAVE
		and game.countdown_seconds == 3,
		"The Host confirmation must authoritatively enter the final countdown."
	)
	_finish_final_countdown(game)
	_expect(game.wave_state == CombatFlowState.State.WAVE_ACTIVE, "The Host must start combat after the authoritative 3-second countdown.")
	game.enemy_spawn_timer.stop()
	for peer_id in [1, 2]:
		var player_instance := game.get_player_for_peer(peer_id)
		player_instance.apply_multiplayer_death_state()
	await physics_frame
	_expect(game.wave_state == CombatFlowState.State.WAVE_ACTIVE, "A full multiplayer team wipe must not end tower defense.")
	for peer_id in [1, 2]:
		var player_instance := game.get_player_for_peer(peer_id)
		_expect(
			player_instance.body_sprite.visible
			and player_instance.body_sprite.animation == &"death"
			and player_instance.body_sprite.is_playing(),
			"Every multiplayer character must begin its authored death animation before disappearing."
		)
		player_instance.apply_multiplayer_death_state()
		_expect(
			player_instance.body_sprite.visible
			and player_instance.body_sprite.animation == &"death",
			"Repeated death snapshots must preserve, not restart or hide, an active death animation."
		)
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
	_expect(
		local_player.body_sprite.visible and local_player.body_sprite.animation == &"death",
		"An ignored alive snapshot must leave the active death presentation intact."
	)
	local_player.revive_multiplayer(
		game.get_fixed_multiplayer_respawn_position(1) as Vector2,
		local_player.max_health,
		3.0
	)
	_expect(not local_player.is_dead and local_player.body_sprite.visible, "The reliable revive path must release the tower-defense death lock.")
	game.update_player_respawn_countdown(1, 5)
	game.update_player_respawn_countdown(2, 5)
	_expect(game.tower_defense_status_hud.respawn_entries.size() == 2, "The right HUD must list every dead multiplayer player.")
	var defeat_signals := {"count": 0}
	game.get_multiplayer_mode_adapter().defeat_started.connect(
		func() -> void: defeat_signals["count"] = int(defeat_signals["count"]) + 1
	)
	game.current_base_health = 1
	game.call("_apply_base_damage", 1)
	_expect(int(defeat_signals["count"]) == 1, "The Host must broadcast defeat immediately when core health reaches zero.")
	game.call("_enter_defeat")
	_expect(int(defeat_signals["count"]) == 1, "Repeated Host defeat entry must not broadcast a second reliable event.")

	_stop_audio_players(game)
	game.queue_free()
	for _frame in range(4):
		await process_frame
		await physics_frame


func _finish_final_countdown(game: TowerDefenseGame) -> void:
	for expected_seconds in [2, 1, 0]:
		game.countdown_audio.stop()
		game.call("_on_state_timer_timeout")
		_expect(
			game.countdown_seconds == expected_seconds,
			"The authoritative final countdown must advance through 3, 2, 1, then 0."
		)


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


func _all_multiplayer_players_dead(game: TowerDefenseGame, peer_ids: Array[int]) -> bool:
	for peer_id in peer_ids:
		var player_instance := game.get_player_for_peer(peer_id)
		if player_instance == null or not player_instance.is_dead:
			return false
	return true


func _cleanup_tower_game(game: TowerDefenseGame) -> void:
	_stop_audio_players(game)
	if current_scene == game:
		current_scene = null
	game.queue_free()
	for _frame in range(4):
		await process_frame
		await physics_frame


func _disable_tower_fixture_background_loads(game: TowerDefenseGame) -> void:
	var coordinator := game.get_node_or_null("FateCoordinator") as FateCoordinator
	if coordinator != null:
		coordinator.elite_enemy_config_loads_requested = true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
