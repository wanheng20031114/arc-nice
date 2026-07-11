extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")

var failures: Array[String] = []
var test_root: Node2D
var player: PlayerWeishidaier


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "PlayerAmmoReloadSmokeRoot"
	root.add_child(test_root)
	current_scene = test_root

	player = PLAYER_SCENE.instantiate() as PlayerWeishidaier
	_expect(player != null, "Player scene must instantiate for ammo reload smoke test.")
	if player == null:
		await _finish()
		return
	test_root.add_child(player)
	await process_frame
	await physics_frame
	_stop_audio_players(player)

	_test_initial_ammo_state()
	_test_normal_shot_consumes_ammo()
	_test_empty_ammo_starts_reload_and_completes()
	_test_manual_reload_starts_from_empty()
	_test_free_shot_chance_never_consumes_at_100_percent()
	_test_spiral_shot_ignores_ammo_and_reload()
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
