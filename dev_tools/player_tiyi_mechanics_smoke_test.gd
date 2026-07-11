extends SceneTree

const TIYI_SCENE := preload("res://scene/player/tiyi/player_tiyi.tscn")
const SNIPER_BULLET_SCENE := preload(
	"res://scene/player/tiyi/tiyi_sniper_bullet.tscn"
)
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")

var failures: Array[String] = []
var test_root: Node2D
var player: PlayerTiyi


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "PlayerTiyiMechanicsSmokeRoot"
	root.add_child(test_root)
	current_scene = test_root

	player = TIYI_SCENE.instantiate() as PlayerTiyi
	_expect(player != null, "Tiyi scene must instantiate as PlayerTiyi.")
	if player == null:
		await _finish()
		return
	test_root.add_child(player)
	await process_frame
	await physics_frame
	_stop_audio_players(player)
	player.set_physics_process(false)

	_test_stats_ammo_and_animation()
	await _test_sniper_sweep()
	await _test_high_noon()
	_test_attack_upgrade_progression()
	await _finish()


func _test_stats_ammo_and_animation() -> void:
	_expect(player.get_character_id() == &"tiyi", "Tiyi must keep its explicit character id.")
	_expect(player.max_health == 50, "Tiyi must start with 50 health.")
	_expect(is_equal_approx(player.move_speed, 120.0), "Tiyi must start at 120 move speed.")
	_expect(player.attack_damage == 100, "Tiyi must start at 100 attack damage.")
	_expect(player.get_ammo_capacity() == 5 and player.current_ammo == 5, "Tiyi must start at 5/5 ammo.")
	_expect(
		is_equal_approx(player.skill1_charge_duration, 28.0),
		"Tiyi High Noon must require 28 charge at upgrade level zero."
	)
	_expect(
		int(player.call("_get_primary_attack_damage_type"))
		== EnemyConfig.DamageType.MAGIC,
		"Tiyi ordinary sniper fire must use magic damage."
	)
	_expect(is_equal_approx(player.get_attacks_per_second(), 1.0), "250 attack speed must equal one shot per second for Tiyi.")
	player.collectible_attack_speed_bonus = 125.0
	_expect(is_equal_approx(player.get_attacks_per_second(), 1.5), "375 attack speed must equal 1.5 shots per second for Tiyi.")
	player.collectible_attack_speed_bonus = 0.0

	var body_sprite := player.get_node("BodySprite") as AnimatedSprite2D
	var movement_frame := body_sprite.sprite_frames.get_frame_texture(
		&"normal_right",
		0
	) as AtlasTexture
	var death_frame := body_sprite.sprite_frames.get_frame_texture(&"death", 0) as AtlasTexture
	_expect(
		movement_frame != null
		and movement_frame.atlas.resource_path == "res://resources/texture/player/tiyi/movement.png",
		"Tiyi movement animations must use the manually approved movement texture."
	)
	_expect(
		death_frame != null
		and death_frame.atlas.resource_path == "res://resources/texture/player/tiyi/body.png",
		"Tiyi death animation must remain on the separate purple death strip."
	)
	var cast_effect := player.high_noon_cast_effect_sprite
	_expect(
		cast_effect != null
		and not cast_effect.visible
		and not cast_effect.is_playing(),
		"Tiyi's authored High Noon cast effect must start hidden and stopped."
	)
	var cast_effect_base_position := cast_effect.position
	player.call("_set_multiplayer_visual_offset", Vector2(3.0, -2.0))
	_expect(
		cast_effect.position == cast_effect_base_position + Vector2(3.0, -2.0),
		"High Noon cast pixels must follow the multiplayer visual smoothing offset."
	)
	player.call("_set_multiplayer_visual_offset", Vector2.ZERO)
	player.velocity = Vector2.ZERO
	player.call("_update_animation")
	_expect(
		body_sprite.animation == &"normal_right" and body_sprite.is_playing(),
		"Tiyi must keep its directional four-frame loop playing while standing still."
	)
	player.velocity = Vector2.RIGHT
	player.call("_update_animation")
	_expect(body_sprite.animation == &"normal_right" and body_sprite.is_playing(), "Tiyi movement must play the directional four-frame gait.")
	player.velocity = Vector2.ZERO
	player.call("_update_animation")

	player.shooting_timer.stop()
	player.current_ammo = 5
	player.is_reloading = false
	_expect(not player.try_accept_authoritative_primary_shot(&"player_bullet"), "Tiyi must reject a forged projectile type.")
	_expect(player.try_accept_authoritative_primary_shot(&"tiyi_sniper_bullet"), "Host atomic validation must accept one legal sniper shot.")
	_expect(player.current_ammo == 4, "Host atomic validation must consume exactly one round.")
	_expect(not player.shooting_timer.is_stopped(), "Host atomic validation must start the one-second shot cooldown.")
	_expect(not player.try_accept_authoritative_primary_shot(&"tiyi_sniper_bullet"), "Host atomic validation must reject a shot during cooldown.")
	player.shooting_timer.stop()

	player.current_ammo = 1
	player.is_reloading = false
	_expect(player.try_accept_authoritative_primary_shot(&"tiyi_sniper_bullet"), "The fifth sniper round must still fire.")
	_expect(player.current_ammo == 0 and player.is_reloading, "The fifth round must automatically begin reload.")
	player.call("_update_reload", player.reload_duration)
	_expect(player.current_ammo == 5 and not player.is_reloading, "A 1.5 second reload must refill to 5/5.")
	player.shooting_timer.stop()


func _test_attack_upgrade_progression() -> void:
	for upgrade_level in range(1, 11):
		player.upgrade_attack()
		_expect(
			player.attack_damage == 100 + upgrade_level * 20,
			"Tiyi attack upgrade level %d must add exactly 20 attack damage." % upgrade_level
		)
	_expect(player.attack_damage == 300, "Ten Tiyi attack upgrades must raise attack damage from 100 to 300.")


func _test_sniper_sweep() -> void:
	var near_enemy := _spawn_enemy(Vector2(30.0, 0.0))
	var far_enemy := _spawn_enemy(Vector2(62.0, 0.0))
	near_enemy.config.physical_defense = 999
	near_enemy.config.magic_defense = 25
	await physics_frame
	var bullet := _spawn_test_bullet(Vector2.ZERO)
	_expect(
		bullet.get_damage_type() == EnemyConfig.DamageType.MAGIC,
		"The Tiyi sniper bullet must report magic as its damage type."
	)
	bullet.call("_physics_process", 0.05)
	_expect(
		near_enemy.current_health == 925,
		"A non-piercing sniper shot must use percentage magic defense, not fixed physical defense."
	)
	_expect(far_enemy.current_health == 1000, "A non-piercing sniper shot must not damage a later enemy.")
	_expect(bullet.is_queued_for_deletion(), "A non-piercing sniper shot must retire after its first enemy.")
	near_enemy.queue_free()
	far_enemy.queue_free()
	await process_frame
	await physics_frame

	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	wall.collision_mask = 0
	wall.global_position = Vector2(44.0, 0.0)
	var wall_collision := CollisionShape2D.new()
	var wall_shape := RectangleShape2D.new()
	wall_shape.size = Vector2(2.0, 80.0)
	wall_collision.shape = wall_shape
	wall.add_child(wall_collision)
	test_root.add_child(wall)
	var blocked_enemy := _spawn_enemy(Vector2(70.0, 0.0))
	await physics_frame
	var blocked_bullet := _spawn_test_bullet(Vector2.ZERO)
	blocked_bullet.call("_physics_process", 0.05)
	_expect(blocked_bullet.is_queued_for_deletion(), "A thin world wall must stop the swept sniper shot.")
	_expect(blocked_enemy.current_health == 1000, "An enemy behind a thin wall must not take sniper damage.")
	wall.queue_free()
	blocked_enemy.queue_free()
	await process_frame
	await physics_frame

	var diagonal_enemy := _spawn_enemy(Vector2(48.0, 48.0))
	await physics_frame
	var diagonal_bullet := _spawn_test_bullet(
		Vector2.ZERO,
		Vector2(1.0, 1.0).normalized()
	)
	diagonal_bullet.call("_physics_process", 0.05)
	_expect(
		diagonal_enemy.current_health == 900,
		"A diagonal sniper sweep must hit an enemy along the complete frame displacement."
	)
	diagonal_enemy.queue_free()
	diagonal_bullet.queue_free()
	await process_frame
	await physics_frame

	var grazing_enemy := _spawn_enemy(Vector2(50.0, 9.5))
	await physics_frame
	var grazing_bullet := _spawn_test_bullet(Vector2.ZERO)
	grazing_bullet.call("_physics_process", 0.05)
	_expect(
		grazing_enemy.current_health == 900,
		"The radius-2.2 sniper sweep must register a valid edge graze."
	)
	grazing_enemy.queue_free()
	grazing_bullet.queue_free()
	await process_frame
	await physics_frame

	var overlap_enemy := _spawn_enemy(Vector2.ZERO)
	await physics_frame
	var overlap_bullet := _spawn_test_bullet(Vector2.ZERO)
	overlap_bullet.call("_physics_process", 0.01)
	_expect(
		overlap_enemy.current_health == 900,
		"A sniper spawned overlapping an enemy must resolve that enemy before moving on."
	)
	overlap_enemy.queue_free()
	overlap_bullet.queue_free()
	await process_frame
	await physics_frame

	var first_pierce_enemy := _spawn_enemy(Vector2(30.0, 0.0))
	var second_pierce_enemy := _spawn_enemy(Vector2(62.0, 0.0))
	await physics_frame
	var piercing_bullet := _spawn_test_bullet(Vector2.ZERO, Vector2.RIGHT, true)
	piercing_bullet.call("_physics_process", 0.05)
	_expect(
		first_pierce_enemy.current_health == 900
		and second_pierce_enemy.current_health == 900,
		"A piercing sniper shot must damage subsequent swept enemies exactly once each (got %d/%d)."
		% [first_pierce_enemy.current_health, second_pierce_enemy.current_health]
	)
	_expect(
		not piercing_bullet.is_queued_for_deletion(),
		"A piercing sniper shot must continue after enemy collisions."
	)
	first_pierce_enemy.queue_free()
	second_pierce_enemy.queue_free()
	piercing_bullet.queue_free()
	await process_frame
	await physics_frame

	var pierce_wall := StaticBody2D.new()
	pierce_wall.collision_layer = 1
	pierce_wall.collision_mask = 0
	pierce_wall.global_position = Vector2(44.0, 0.0)
	var pierce_wall_collision := CollisionShape2D.new()
	var pierce_wall_shape := RectangleShape2D.new()
	pierce_wall_shape.size = Vector2(2.0, 80.0)
	pierce_wall_collision.shape = pierce_wall_shape
	pierce_wall.add_child(pierce_wall_collision)
	test_root.add_child(pierce_wall)
	var pre_wall_enemy := _spawn_enemy(Vector2(28.0, 0.0))
	var post_wall_enemy := _spawn_enemy(Vector2(68.0, 0.0))
	await physics_frame
	var wall_limited_piercing_bullet := _spawn_test_bullet(
		Vector2.ZERO,
		Vector2.RIGHT,
		true
	)
	wall_limited_piercing_bullet.call("_physics_process", 0.05)
	_expect(
		pre_wall_enemy.current_health == 900
		and post_wall_enemy.current_health == 1000
		and wall_limited_piercing_bullet.is_queued_for_deletion(),
		"Piercing may continue through enemies but must still terminate at the first world wall."
	)
	pierce_wall.queue_free()
	pre_wall_enemy.queue_free()
	post_wall_enemy.queue_free()
	wall_limited_piercing_bullet.queue_free()
	await process_frame
	await physics_frame

	var homing_enemy := _spawn_enemy(Vector2(90.0, 24.0))
	await physics_frame
	var homing_bullet := _spawn_test_bullet(Vector2.ZERO)
	homing_bullet.setup_homing(homing_enemy)
	homing_bullet.call("_physics_process", 1.0 / 120.0)
	_expect(
		homing_bullet.direction.y > 0.0,
		"The sniper projectile must preserve the shared homing turn behavior."
	)
	homing_enemy.queue_free()
	homing_bullet.queue_free()
	await process_frame
	await physics_frame


func _test_high_noon() -> void:
	var expected_charge_durations := [28.0, 26.0, 24.0, 22.0, 20.0]
	for upgrade_level in range(expected_charge_durations.size()):
		player.apply_skill1_upgrade_state(upgrade_level)
		_expect(
			is_equal_approx(
				player.skill1_charge_duration,
				float(expected_charge_durations[upgrade_level])
			),
			"High Noon charge must remain 28 minus two per upgrade level (level %d)."
			% upgrade_level
		)
	player.apply_skill1_upgrade_state(0)

	var enemies: Array[Enemy] = []
	for enemy_index in range(26):
		enemies.append(_spawn_enemy(Vector2(20.0 + float(enemy_index) * 15.0, -10.0)))
	await physics_frame
	player.unlock_skill1()
	player.skill1_charge = player.skill1_charge_duration
	_expect(bool(player.call("_try_use_skill1")), "A fully charged Tiyi must start High Noon.")
	_expect(player.is_high_noon_active(), "High Noon must become active immediately.")
	_expect(player.get_high_noon_target_count() == 1, "High Noon must acquire its first target at t=0.")
	_expect(
		player.high_noon_cast_effect_sprite.visible
		and player.high_noon_cast_effect_sprite.is_playing(),
		"High Noon must show and play its rotating casting units for the full lock phase."
	)
	var first_activation_id := player.get_high_noon_activation_id()
	player.skill1_charge = player.skill1_charge_duration
	player.set("_last_skill_activation_msec", Time.get_ticks_msec() - 1000)
	_expect(
		not bool(player.call("_try_use_skill1")),
		"An active High Noon must reject a second activation even when charge and cooldown are ready."
	)
	_expect(
		player.get_high_noon_activation_id() == first_activation_id
		and player.get_high_noon_target_count() == 1,
		"A rejected reactivation must not replace or reset the active High Noon round."
	)

	player.current_ammo = player.get_ammo_capacity()
	player.is_reloading = false
	player.shooting_timer.stop()
	player.call("_try_shoot", Vector2.UP)
	_expect(
		player.current_ammo == 4 and player.is_high_noon_active(),
		"High Noon must not block ordinary sniper fire or consume skill ammunition."
	)
	_expect(
		bool(player.call("_try_start_reload")) and player.is_high_noon_active(),
		"High Noon must allow a manual reload while locks remain active."
	)
	player.call("_update_reload", player.reload_duration)
	_expect(
		player.current_ammo == 5 and player.is_high_noon_active(),
		"Reload completion must remain independent from High Noon."
	)
	player.dash_cooldown_timer.stop()
	_expect(
		bool(player.call("_try_start_dash", Vector2.RIGHT))
		and player.is_dashing()
		and player.is_high_noon_active(),
		"High Noon must allow the normal dash action."
	)
	player.call("_finish_dash")
	player.dash_cooldown_timer.stop()

	enemies[0].global_position = Vector2(420.0, 0.0)
	player.call("_update_high_noon", 1.92)
	_expect(
		player.is_high_noon_active()
		and player.get_high_noon_target_count() == 25
		and player.high_noon_cast_effect_sprite.visible
		and player.high_noon_cast_effect_sprite.is_playing(),
		"One t=0 lock plus 0.08-second beats must lock all 25 targets by 1.92 seconds."
	)
	_expect(
		enemies.all(func(enemy: Enemy) -> bool: return enemy.current_health == 1000),
		"Locking all 25 targets early must not deal damage before the four-second finish."
	)
	player.call("_update_high_noon", 2.07)
	_expect(
		player.is_high_noon_active()
		and enemies.all(func(enemy: Enemy) -> bool: return enemy.current_health == 1000)
		and player.high_noon_cast_effect_sprite.visible
		and player.high_noon_cast_effect_sprite.is_playing(),
		"High Noon must keep all locks without resolving before four seconds."
	)
	player.call("_update_high_noon", 0.02)
	_expect(not player.is_high_noon_active(), "High Noon must finish at four seconds.")
	_expect(
		not player.high_noon_cast_effect_sprite.visible
		and not player.high_noon_cast_effect_sprite.is_playing(),
		"High Noon must stop and hide its casting units after the four-second finish."
	)
	_expect(enemies[0].current_health == 650, "A locked target must still be hit after leaving the 400 range.")
	_expect(enemies[24].current_health == 650, "The extended 400 range must include and damage a target beyond 350.")
	_expect(enemies[25].current_health == 1000, "The twenty-sixth target must remain unhit beyond the 25-target cap.")

	for enemy in enemies:
		if enemy != null and is_instance_valid(enemy):
			enemy.queue_free()
	await process_frame
	await physics_frame

	var cap_enemies: Array[Enemy] = []
	for enemy_index in range(26):
		cap_enemies.append(_spawn_enemy(Vector2(20.0 + float(enemy_index) * 15.0, -10.0)))
	await physics_frame
	player.set("_last_skill_activation_msec", Time.get_ticks_msec() - 1000)
	player.skill1_charge = player.skill1_charge_duration
	_expect(bool(player.call("_try_use_skill1")), "High Noon must restart for hard-cap coverage.")
	for _lock_attempt in range(30):
		player.call("_acquire_next_high_noon_target")
	_expect(
		player.get_high_noon_target_count() == 25,
		"Direct lock attempts must never exceed the explicit 25-target hard cap."
	)
	player.call("_cancel_high_noon", false)
	_expect(
		not player.high_noon_cast_effect_sprite.visible
		and not player.high_noon_cast_effect_sprite.is_playing(),
		"Cancelling High Noon must stop and hide its casting units."
	)
	for enemy in cap_enemies:
		if enemy != null and is_instance_valid(enemy):
			enemy.queue_free()
	await process_frame
	await physics_frame

	var los_wall := StaticBody2D.new()
	los_wall.collision_layer = 1
	los_wall.collision_mask = 0
	los_wall.global_position = Vector2(48.0, 0.0)
	var los_wall_collision := CollisionShape2D.new()
	var los_wall_shape := RectangleShape2D.new()
	los_wall_shape.size = Vector2(3.0, 96.0)
	los_wall_collision.shape = los_wall_shape
	los_wall.add_child(los_wall_collision)
	test_root.add_child(los_wall)
	var visible_enemy := _spawn_enemy(Vector2(30.0, 34.0))
	var blocked_enemy := _spawn_enemy(Vector2(86.0, 0.0))
	var outside_enemy := _spawn_enemy(Vector2(410.0, 80.0))
	await physics_frame
	visible_enemy.config.physical_defense = 999
	visible_enemy.config.magic_defense = 50
	visible_enemy.collectible_status_effects[&"test_burn"] = {
		"status_id": &"burn",
		"time_left": 10.0,
	}
	visible_enemy.collectible_status_effects[&"test_bleed"] = {
		"status_id": &"bleed",
		"time_left": 10.0,
	}
	player.collectible_damage_against_burning_multiplier = 1.25
	player.collectible_damage_against_bleeding_multiplier = 1.2
	player.set("_last_skill_activation_msec", Time.get_ticks_msec() - 1000)
	player.skill1_charge = player.skill1_charge_duration
	_expect(bool(player.call("_try_use_skill1")), "High Noon must restart for LOS coverage.")
	_expect(
		player.get_high_noon_target_count() == 1,
		"Initial acquisition must exclude a wall-blocked and an out-of-range enemy."
	)
	visible_enemy.global_position = Vector2(420.0, 0.0)
	player.call("_update_high_noon", 3.75)
	_expect(
		player.get_high_noon_target_count() == 1
		and visible_enemy.current_health == 1000
		and blocked_enemy.current_health == 1000
		and outside_enemy.current_health == 1000,
		"A locked target must retain its line after crossing range and LOS, without early damage."
	)
	player.call("_update_high_noon", 0.25)
	_expect(
		visible_enemy.current_health == 738
		and blocked_enemy.current_health == 1000
		and outside_enemy.current_health == 1000,
		"The 350% finish hit must apply burn/bleed multipliers and percentage magic defense only to the acquired target."
	)
	player.collectible_damage_against_burning_multiplier = 1.0
	player.collectible_damage_against_bleeding_multiplier = 1.0

	los_wall.queue_free()
	visible_enemy.queue_free()
	blocked_enemy.queue_free()
	outside_enemy.queue_free()
	await process_frame
	await physics_frame

	var released_enemy := _spawn_enemy(Vector2(20.0, 0.0))
	var replacement_enemy := _spawn_enemy(Vector2(34.0, 18.0))
	await physics_frame
	player.set("_last_skill_activation_msec", Time.get_ticks_msec() - 1000)
	player.skill1_charge = player.skill1_charge_duration
	_expect(bool(player.call("_try_use_skill1")), "A recharged High Noon must start for replacement testing.")
	released_enemy.is_dead = true
	player.call("_update_high_noon", 0.08)
	_expect(
		player.get_high_noon_target_count() == 1,
		"A dead locked target must release its slot for replacement on the next beat."
	)
	var health_before_cancel := replacement_enemy.current_health
	player.set_controls_locked(true)
	_expect(not player.is_high_noon_active(), "An external controls lock must cancel High Noon immediately.")
	_expect(
		not player.high_noon_cast_effect_sprite.visible
		and not player.high_noon_cast_effect_sprite.is_playing(),
		"A controls lock must also clear the High Noon casting animation."
	)
	player.call("_update_high_noon", 5.0)
	_expect(replacement_enemy.current_health == health_before_cancel, "A cancelled High Noon must deal no delayed damage.")
	player.set_controls_locked(false)
	var residual_bullet := _spawn_test_bullet(Vector2(-120.0, -120.0))
	player.apply_multiplayer_death_state()
	var body_sprite := player.get_node("BodySprite") as AnimatedSprite2D
	_expect(
		body_sprite.visible and body_sprite.animation == &"death" and body_sprite.is_playing(),
		"Tiyi must play the authored purple death animation for multiplayer death."
	)
	_expect(not player.ammo_bar.visible, "Tiyi death must hide the ammunition bar.")
	_expect(
		not player.high_noon_cast_effect_sprite.visible
		and not player.high_noon_cast_effect_sprite.is_playing(),
		"Tiyi death must leave the High Noon casting animation stopped."
	)
	_expect(residual_bullet.is_queued_for_deletion(), "Tiyi death must clear its residual sniper bullets.")
	player.revive_multiplayer(Vector2.ZERO, player.max_health, 0.0)
	_expect(player.current_ammo == 5 and player.ammo_bar.visible, "Tiyi revive must restore 5/5 ammo and its bar.")
	var remote_activation_id := int(player.get("_high_noon_last_seen_activation_id")) + 1
	player.play_remote_high_noon_started(remote_activation_id)
	player.play_remote_high_noon_started(remote_activation_id + 1)
	_expect(
		player.is_high_noon_active()
		and player.get_high_noon_activation_id() == remote_activation_id
		and player.high_noon_cast_effect_sprite.visible
		and player.high_noon_cast_effect_sprite.is_playing(),
		"A newer remote start event must not replace an unfinished High Noon activation."
	)
	player.cancel_remote_high_noon(remote_activation_id)
	_expect(
		not player.high_noon_cast_effect_sprite.visible
		and not player.high_noon_cast_effect_sprite.is_playing(),
		"A matching remote cancellation must stop the High Noon casting animation."
	)

	released_enemy.queue_free()
	replacement_enemy.queue_free()
	await process_frame


func _spawn_enemy(spawn_position: Vector2) -> Enemy:
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	var config := EnemyConfig.new()
	config.max_health = 1000
	config.physical_defense = 0
	config.magic_defense = 0
	enemy.config = config
	test_root.add_child(enemy)
	enemy.global_position = spawn_position
	enemy.set_physics_process(false)
	_stop_audio_players(enemy)
	return enemy


func _spawn_test_bullet(
	spawn_position: Vector2,
	direction: Vector2 = Vector2.RIGHT,
	pierces_enemies: bool = false
) -> TiyiSniperBullet:
	var bullet := SNIPER_BULLET_SCENE.instantiate() as TiyiSniperBullet
	bullet.setup(direction, 100, pierces_enemies)
	bullet.setup_collectible_owner(player)
	test_root.add_child(bullet)
	bullet.global_position = spawn_position
	bullet.set_physics_process(false)
	return bullet


func _finish() -> void:
	if test_root != null:
		test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("PLAYER_TIYI_MECHANICS_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


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
