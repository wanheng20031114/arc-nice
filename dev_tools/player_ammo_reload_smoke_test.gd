extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const PLAYER_TEST_RUNTIME := preload(
	"res://dev_tools/player_test_combat_runtime.gd"
)
const SNOW_WOLF_POJUN := preload(
	"res://resources/config/pickup_triggered_items/snow_wolf_pojun.tres"
)

var failures: Array[String] = []
var test_root: PlayerTestCombatRuntime
var player: PlayerWeishidaier


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = PLAYER_TEST_RUNTIME.new() as PlayerTestCombatRuntime
	test_root.name = "PlayerAmmoReloadSmokeRoot"
	root.add_child(test_root)
	current_scene = test_root

	player = PLAYER_SCENE.instantiate() as PlayerWeishidaier
	_expect(player != null, "Player scene must instantiate for ammo reload smoke test.")
	if player == null:
		await _finish()
		return
	test_root.add_child(player)
	test_root.bind_player_runtime_context(player)
	await process_frame
	await physics_frame
	_stop_audio_players(player)

	_test_initial_ammo_state()
	_test_ammo_bar_separator_threshold()
	_test_normal_shot_consumes_ammo()
	_test_empty_ammo_starts_reload_and_completes()
	_test_manual_reload_starts_from_empty()
	_test_free_shot_chance_never_consumes_at_100_percent()
	_test_snow_wolf_spiral_cadence_and_snapshot_repair()
	_test_spiral_shot_ignores_ammo_and_reload()
	_test_world_movement_mode_suppresses_ammo_hud()
	_test_death_hides_and_revive_refills_ammo()

	await _finish()


func _finish() -> void:
	_clear_player_bullets()
	if player != null and is_instance_valid(player):
		_stop_audio_players(player)
	if test_root != null:
		test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("PLAYER_AMMO_RELOAD_SMOKE_TEST_OK")
		quit(0)
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_initial_ammo_state() -> void:
	_expect(player.get_character_id() == &"weishidaier", "Weishidaier must keep its explicit character id.")
	_expect(player.uses_ammunition(), "Weishidaier must own the ammunition capability.")
	_expect(player.supports_projectile_attack_patterns(), "Weishidaier must own projectile attack patterns.")
	_expect(player.get_node_or_null("ArmedEffectSprite") is AnimatedSprite2D, "Weishidaier must author its armed effect in the character scene.")
	_expect(player.get_node_or_null("AmmoBar") is PlayerAmmoBar, "Weishidaier must author its ammunition bar in the character scene.")
	_expect(player.get_node_or_null("PrimaryAttackAudio") is AudioStreamPlayer2D, "Weishidaier primary audio must use a character-neutral node name.")
	_expect(player.get_node_or_null("ReloadAudio") is AudioStreamPlayer2D, "Weishidaier reload audio must be character-owned.")
	_expect(player.get_ammo_capacity() == 30, "Player default ammo capacity must be 30.")
	_expect(player.current_ammo == 30, "Player must start with full 30/30 ammo.")
	_expect(not player.is_reloading, "Player must not start in reload state.")
	_expect(is_equal_approx(player.reload_progress, 0.0), "Reload progress must start at 0.")
	_expect(player.ammo_bar.visible, "Ammo bar must be visible while player is alive.")
	_expect(int(player.ammo_bar.get("max_ammo")) == 30, "Ammo bar must receive the player ammo capacity.")
	_expect(int(player.ammo_bar.get("current_ammo")) == 30, "Ammo bar must receive current ammo.")


func _test_ammo_bar_separator_threshold() -> void:
	var bar_width := player.ammo_bar.size.x
	_expect(floori(bar_width) == 20, "Ammo bar must keep its authored 20-pixel width.")
	_expect(
		bool(player.ammo_bar.call("_has_room_for_ammo_separators", bar_width, 10)),
		"A 20-pixel ammo bar must retain one-pixel fills and separators at 10 rounds."
	)
	_expect(
		not bool(player.ammo_bar.call("_has_room_for_ammo_separators", bar_width, 11)),
		"A 20-pixel ammo bar must switch to a solid fill starting at 11 rounds."
	)
	_expect(
		not bool(player.ammo_bar.call("_has_room_for_ammo_separators", bar_width, 30)),
		"Weishidaier's 30-round ammo bar must remain a solid proportional fill."
	)


func _test_normal_shot_consumes_ammo() -> void:
	_clear_player_bullets()
	player.current_shot_pattern = PickupConfig.ShotPattern.NORMAL
	player.ammo_free_shot_chance_percent = 0.0
	player.current_ammo = player.get_ammo_capacity()
	player.is_reloading = false
	player.reload_progress = 0.0
	player.shooting_timer.stop()
	player.call("_update_ammo_bar")

	player.call("_try_shoot", Vector2.RIGHT)
	_expect(_get_player_bullet_count() == 1, "Normal shooting must spawn one player bullet.")
	_expect(player.current_ammo == player.get_ammo_capacity() - 1, "Normal shooting must consume one ammo after a successful shot.")
	_expect(not player.is_reloading, "Player must not reload before ammo reaches zero.")


func _test_empty_ammo_starts_reload_and_completes() -> void:
	_clear_player_bullets()
	player.current_shot_pattern = PickupConfig.ShotPattern.NORMAL
	player.current_ammo = 1
	player.is_reloading = false
	player.reload_progress = 0.0
	player.shooting_timer.stop()
	player.call("_update_ammo_bar")

	player.call("_try_shoot", Vector2.RIGHT)
	_expect(_get_player_bullet_count() == 1, "Last ammo shot must still spawn a bullet.")
	_expect(player.current_ammo == 0, "Last ammo shot must leave ammo at zero.")
	_expect(player.is_reloading, "Ammo reaching zero must start reload.")
	_expect(is_equal_approx(player.reload_progress, 0.0), "Auto reload must start from 0 progress.")
	_expect(bool(player.ammo_bar.get("is_reloading")), "Ammo bar must switch to reload mode.")

	player.shooting_timer.stop()
	player.call("_try_shoot", Vector2.RIGHT)
	_expect(_get_player_bullet_count() == 1, "Reloading must block normal shots.")

	player.call("_update_reload", player.reload_duration * 0.5)
	_expect(player.is_reloading, "Half duration must keep reload active.")
	_expect(player.reload_progress > 0.45 and player.reload_progress < 0.55, "Reload progress must advance proportionally.")
	player.call("_update_reload", player.reload_duration * 0.5)
	_expect(not player.is_reloading, "Full duration must complete reload.")
	_expect(player.current_ammo == player.get_ammo_capacity(), "Reload completion must refill ammo.")
	_expect(is_equal_approx(player.reload_progress, 0.0), "Reload progress must reset after completion.")


func _test_manual_reload_starts_from_empty() -> void:
	player.current_ammo = 12
	player.is_reloading = false
	player.reload_progress = 0.7
	player.shooting_timer.stop()
	player.call("_update_ammo_bar")

	var started := bool(player.call("_try_start_reload"))
	_expect(started, "Manual reload must start when ammo is below capacity.")
	_expect(player.current_ammo == 0, "Manual reload must immediately clear ammo.")
	_expect(player.is_reloading, "Manual reload must set reload state.")
	_expect(is_equal_approx(player.reload_progress, 0.0), "Manual reload must always start from 0 progress.")

	player.call("_update_reload", player.reload_duration)
	_expect(player.current_ammo == player.get_ammo_capacity(), "Manual reload must refill after full duration.")
	_expect(not player.is_reloading, "Manual reload must clear reload state after completion.")


func _test_free_shot_chance_never_consumes_at_100_percent() -> void:
	_clear_player_bullets()
	player.current_shot_pattern = PickupConfig.ShotPattern.NORMAL
	player.ammo_free_shot_chance_percent = 100.0
	player.current_ammo = 5
	player.is_reloading = false
	player.reload_progress = 0.0
	player.shooting_timer.stop()
	player.call("_update_ammo_bar")

	player.call("_try_shoot", Vector2.RIGHT)
	_expect(_get_player_bullet_count() == 1, "Free-ammo normal shot must still spawn a bullet.")
	_expect(player.current_ammo == 5, "Free-ammo chance at 100% must not consume ammo.")
	_expect(not player.is_reloading, "Free-ammo chance at 100% must not start reload when ammo remains.")
	player.ammo_free_shot_chance_percent = 0.0


func _test_snow_wolf_spiral_cadence_and_snapshot_repair() -> void:
	_clear_player_bullets()
	player.current_form_mode = PickupConfig.PlayerFormMode.NORMAL
	player.current_shot_pattern = PickupConfig.ShotPattern.NORMAL
	player.form_fire_rate_multiplier = Player.DEFAULT_FIRE_RATE_MULTIPLIER
	var base_interval := float(player.call("_get_effective_fire_interval"))
	_expect(
		player.apply_pickup(SNOW_WOLF_POJUN)
		and is_equal_approx(
			float(player.call("_get_effective_fire_interval")),
			base_interval / SNOW_WOLF_POJUN.fire_rate_multiplier
		),
		"Snow Wolf must accelerate Weishidaier's spiral volley cadence by exactly 10x."
	)
	for _volley_index in range(24):
		player.shooting_timer.stop()
		player.call("_try_auto_spiral_shoot")
	_expect(
		is_zero_approx(player.spiral_phase)
		and _get_player_bullet_count() == 48,
		"Twenty-four Snow Wolf volleys must complete one PI/12 spiral revolution with paired bullets."
	)
	player.call("_update_character_pickup_effects", SNOW_WOLF_POJUN.duration)
	_expect(
		player.current_form_mode == PickupConfig.PlayerFormMode.NORMAL
		and player.current_shot_pattern == PickupConfig.ShotPattern.NORMAL
		and is_equal_approx(
			float(player.call("_get_effective_fire_interval")),
			base_interval
		),
		"Snow Wolf expiry must restore Weishidaier's ordinary cadence."
	)

	player.call(
		"_apply_multiplayer_character_realtime_state",
		PickupConfig.PlayerFormMode.ARMED,
		PickupConfig.ShotPattern.SPIRAL,
		player.get_ammo_capacity(),
		player.current_ammo,
		player.is_reloading,
		player.reload_progress
	)
	var repaired_interval := float(player.call("_get_effective_fire_interval"))
	player.call(
		"_apply_multiplayer_character_realtime_state",
		PickupConfig.PlayerFormMode.ARMED,
		PickupConfig.ShotPattern.SPIRAL,
		player.get_ammo_capacity(),
		player.current_ammo,
		player.is_reloading,
		player.reload_progress
	)
	_expect(
		is_equal_approx(player.form_fire_rate_multiplier, 10.0)
		and is_equal_approx(repaired_interval, base_interval / 10.0)
		and is_equal_approx(
			float(player.call("_get_effective_fire_interval")),
			repaired_interval
		),
		"A fresh or repeated ARMED+SPIRAL multiplayer repair must restore, not stack or omit, Snow Wolf's 10x cadence."
	)
	player.call(
		"_apply_multiplayer_character_realtime_state",
		PickupConfig.PlayerFormMode.NORMAL,
		PickupConfig.ShotPattern.NORMAL,
		player.get_ammo_capacity(),
		player.current_ammo,
		player.is_reloading,
		player.reload_progress
	)
	_expect(
		is_equal_approx(player.form_fire_rate_multiplier, 1.0)
		and is_equal_approx(
			float(player.call("_get_effective_fire_interval")),
			base_interval
		),
		"A NORMAL multiplayer snapshot must remove the repaired Snow Wolf cadence."
	)
	_clear_player_bullets()


func _test_spiral_shot_ignores_ammo_and_reload() -> void:
	_clear_player_bullets()
	player.current_shot_pattern = PickupConfig.ShotPattern.SPIRAL
	player.current_form_mode = PickupConfig.PlayerFormMode.ARMED
	player.current_ammo = 3
	player.is_reloading = true
	player.reload_progress = 0.2
	player.shooting_timer.stop()
	player.call("_update_ammo_bar")

	player.call("_try_auto_spiral_shoot")
	_expect(_get_player_bullet_count() == 2, "Spiral shot must spawn its forward and backward bullets.")
	_expect(player.current_ammo == 3, "Spiral shot must not consume ammo.")
	_expect(player.is_reloading, "Spiral shot must not cancel reload state.")
	player.call("_update_reload", player.reload_duration)
	_expect(player.current_ammo == player.get_ammo_capacity(), "Reload progress must continue and refill during spiral mode.")

	player.current_shot_pattern = PickupConfig.ShotPattern.NORMAL
	player.current_form_mode = PickupConfig.PlayerFormMode.NORMAL


func _test_world_movement_mode_suppresses_ammo_hud() -> void:
	player.is_reloading = false
	player.reload_progress = 0.0
	player.ammo_bar.show()
	player.set_world_movement_mode(true, false)
	_expect(
		not player.ammo_bar.visible,
		"World movement mode must hide AmmoRangedPlayer's authored ammunition HUD."
	)

	player.call("_update_ammo_bar")
	_expect(
		not player.ammo_bar.visible,
		"Ammo refresh must not show the ammunition HUD during world movement mode."
	)
	player.current_ammo = 0
	player.is_reloading = true
	player.call("_update_reload", player.reload_duration * 0.5)
	_expect(
		not player.ammo_bar.visible,
		"Reload progress refresh must keep the ammunition HUD suppressed."
	)

	player.set_world_movement_mode(true, true)
	player.call("_update_ammo_bar")
	_expect(
		not player.ammo_bar.visible,
		"Changing world-mode dash permission must not overwrite the saved HUD state."
	)
	player.set_world_movement_mode(false)
	_expect(
		player.ammo_bar.visible,
		"Leaving world movement mode must restore the ammunition HUD's saved visibility."
	)

	player.ammo_bar.hide()
	player.set_world_movement_mode(true, false)
	player.call("_update_ammo_bar")
	player.set_world_movement_mode(false)
	_expect(
		not player.ammo_bar.visible,
		"A pre-hidden ammunition HUD must remain hidden after leaving world movement mode."
	)
	player.call("_update_ammo_bar")
	_expect(
		player.ammo_bar.visible,
		"Normal ammunition refresh must resume after world movement mode ends."
	)


func _test_death_hides_and_revive_refills_ammo() -> void:
	player.current_ammo = 4
	player.is_reloading = true
	player.reload_progress = 0.5
	player.current_health = player.max_health
	player.invincibility_time_left = 0.0
	player.call("_set_hurt_blink_enabled", false)
	player.apply_damage(player.max_health)
	_expect(player.is_dead, "Lethal damage must kill player in ammo smoke test.")
	_expect(not player.ammo_bar.visible, "Death must hide ammo bar.")

	player.revive_multiplayer(Vector2.ZERO, player.max_health, 0.0)
	_expect(not player.is_dead, "Revive must clear death state.")
	_expect(player.current_ammo == player.get_ammo_capacity(), "Revive must restore full ammo.")
	_expect(player.ammo_bar.visible, "Revive must show ammo bar.")


func _get_player_bullet_count() -> int:
	var bullet_count := 0
	for child in test_root.get_children():
		if child is Bullet:
			bullet_count += 1
	return bullet_count


func _clear_player_bullets() -> void:
	if test_root == null:
		return
	for child in test_root.get_children():
		if child is Bullet:
			child.free()


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


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
