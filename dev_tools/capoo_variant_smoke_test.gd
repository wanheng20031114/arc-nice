extends SceneTree

const MAGE_SCENE := preload("res://scene/enemy/capoo_mage.tscn")
const SNIPER_SCENE := preload("res://scene/enemy/capoo_sniper.tscn")
const SMG_SCENE := preload("res://scene/enemy/capoo_smg.tscn")
const FIREBALL_SCENE := preload("res://scene/enemy/capoo_mage_fireball.tscn")
const RETICLE_SCENE := preload("res://scene/enemy/capoo_sniper_lock_reticle.tscn")
const SMG_BULLET_SCENE := preload("res://scene/enemy/capoo_smg_bullet.tscn")
const PLAYER_SCENE := preload("res://scene/player.tscn")
const MAGE_CONFIG := preload("res://resources/config/enemies/capoo_mage.tres")
const SNIPER_CONFIG := preload("res://resources/config/enemies/capoo_sniper.tres")
const SMG_CONFIG := preload("res://resources/config/enemies/capoo_smg.tres")
const WAVE_09 := preload("res://resources/config/waves/wave_09.tres")
const WAVE_10 := preload("res://resources/config/waves/wave_10.tres")
const WAVE_11 := preload("res://resources/config/waves/wave_11.tres")
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")

var failures: Array[String] = []
var test_root: Node2D
var spawned_fireballs: Array[CapooMageFireball] = []
var spawned_smg_bullets: Array[CapooAK47Bullet] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "CapooVariantSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	test_root.child_entered_tree.connect(_on_child_entered_tree)

	_test_resource_contract()
	await _test_reticle_highest_progress_priority()
	await _test_mage_windup_fireball_and_obstruction()
	await _test_fireball_impact_damage_and_release()
	await _test_sniper_lock_cancel_and_damage()
	await _test_smg_scatter_fire()
	_test_multiplayer_projectile_registry()
	_test_wave_entries()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("CAPOO_VARIANT_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_contract() -> void:
	_expect(MAGE_CONFIG is CapooMageConfig, "Mage config must use CapooMageConfig.")
	_expect(SNIPER_CONFIG is CapooSniperConfig, "Sniper config must use CapooSniperConfig.")
	_expect(SMG_CONFIG is CapooSMGConfig, "SMG config must use CapooSMGConfig.")

	_expect(MAGE_CONFIG.enemy_scene == MAGE_SCENE, "Mage Capoo must use its own scene.")
	_expect(SNIPER_CONFIG.enemy_scene == SNIPER_SCENE, "Sniper Capoo must use its own scene.")
	_expect(SMG_CONFIG.enemy_scene == SMG_SCENE, "SMG Capoo must use its own scene.")
	_expect(MAGE_CONFIG.projectile_scene == FIREBALL_SCENE, "Mage Capoo must use the generated fireball scene.")
	_expect(SNIPER_CONFIG.lock_reticle_scene == RETICLE_SCENE, "Sniper Capoo must use the generated reticle scene.")
	_expect(SMG_CONFIG.projectile_scene == SMG_BULLET_SCENE, "SMG Capoo must use its short-lived bullet scene.")
	_expect(
		_resource_path(MAGE_CONFIG.attack_audio_stream).ends_with("capoo_mage_fireball_cast.wav"),
		"Mage Capoo must use the fireball cast audio stream."
	)
	_expect(
		_resource_path(SNIPER_CONFIG.attack_audio_stream).ends_with("capoo_sniper_fire.wav"),
		"Sniper Capoo must use the sniper fire audio stream."
	)

	_expect(MAGE_CONFIG.max_health == 200, "Mage health mismatch.")
	_expect(MAGE_CONFIG.attack_damage == 75, "Mage damage mismatch.")
	_expect(MAGE_CONFIG.physical_defense == 0 and MAGE_CONFIG.magic_defense == 0, "Mage defense mismatch.")
	_expect(is_equal_approx(MAGE_CONFIG.move_speed, 80.0), "Mage move speed mismatch.")
	_expect(is_equal_approx(MAGE_CONFIG.attack_windup, 1.0), "Mage windup mismatch.")
	_expect(is_equal_approx(MAGE_CONFIG.fireball_radius, 10.5), "Mage fireball radius mismatch.")
	_expect(MAGE_CONFIG.fireball_radius > 8.0, "Mage fireball should be slightly larger than a player body.")

	_expect(SNIPER_CONFIG.max_health == 100, "Sniper health mismatch.")
	_expect(SNIPER_CONFIG.attack_damage == 200, "Sniper damage mismatch.")
	_expect(SNIPER_CONFIG.physical_defense == 20 and SNIPER_CONFIG.magic_defense == 0, "Sniper defense mismatch.")
	_expect(is_equal_approx(SNIPER_CONFIG.move_speed, 80.0), "Sniper move speed mismatch.")
	_expect(is_equal_approx(SNIPER_CONFIG.lock_duration, 3.0), "Sniper lock duration mismatch.")

	_expect(SMG_CONFIG.max_health == 200, "SMG health mismatch.")
	_expect(SMG_CONFIG.attack_damage == 40, "SMG damage mismatch.")
	_expect(is_equal_approx(SMG_CONFIG.move_speed, 120.0), "SMG move speed mismatch.")
	_expect(is_equal_approx(SMG_CONFIG.fire_interval, 0.1), "SMG fire interval must represent 600 attack speed.")
	_expect(is_equal_approx(SMG_CONFIG.projectile_lifetime, 0.18), "SMG bullet lifetime must stay short.")
	_expect(is_equal_approx(SMG_CONFIG.spread_angle_degrees, 20.0), "SMG spread angle mismatch.")

	_expect(_texture_size("res://resources/texture/capoo_mage.png") == Vector2(1402, 1122), "Mage sprite sheet size mismatch.")
	_expect(_texture_size("res://resources/texture/capoo_sniper.png") == Vector2(512, 384), "Sniper sprite sheet size mismatch.")
	_expect(_texture_size("res://resources/texture/capoo_smg.png") == Vector2(640, 512), "SMG sprite sheet size mismatch.")
	_expect(_texture_size("res://resources/texture/capoo_mage_fireball.png") == Vector2(384, 128), "Fireball sheet size mismatch.")
	_expect(_texture_size("res://resources/texture/capoo_smg_bullet.png") == Vector2(48, 8), "SMG bullet sheet size mismatch.")
	_expect(_texture_size("res://resources/texture/capoo_sniper_lock_reticle.png") == Vector2(32, 32), "Sniper reticle texture size mismatch.")

	_expect(_has_capoo_frames(MAGE_CONFIG.enemy_scene, "Mage"), "Mage animation contract failed.")
	_expect(_has_mage_original_alpha_regions(), "Mage original alpha AtlasTexture regions failed.")
	_expect(_has_mage_visual_alignment(), "Mage visual alignment contract failed.")
	_expect(_has_capoo_frames(SNIPER_CONFIG.enemy_scene, "Sniper", Vector2(128.0, 96.0)), "Sniper animation contract failed.")
	_expect(_has_capoo_frames(SMG_CONFIG.enemy_scene, "SMG", Vector2(160.0, 128.0)), "SMG animation contract failed.")
	_expect(_has_smg_visual_alignment(), "SMG visual alignment contract failed.")
	_expect(_sprite_frames_count("res://resources/animation/capoo_mage_fireball.tres", &"fly") == 6, "Fireball frame count mismatch.")
	_expect(_sprite_frames_count("res://resources/animation/capoo_mage_fireball.tres", &"impact") == 6, "Fireball impact frame count mismatch.")
	_expect(_fireball_impact_animation_contract(), "Fireball impact animation contract failed.")
	_expect(_has_fireball_impact_audio(), "Fireball impact audio contract failed.")
	_expect(_sprite_frames_count("res://resources/animation/capoo_smg_bullet.tres", &"fly") == 3, "SMG bullet frame count mismatch.")
	_expect(_has_reticle_scene_contract(), "Sniper reticle scene contract failed.")


func _test_reticle_highest_progress_priority() -> void:
	var player := _spawn_player(Vector2.ZERO, 100)
	var slow_reticle := RETICLE_SCENE.instantiate() as CapooSniperLockReticle
	var urgent_reticle := RETICLE_SCENE.instantiate() as CapooSniperLockReticle
	player.add_child(slow_reticle)
	player.add_child(urgent_reticle)
	await process_frame

	slow_reticle.set_progress(0.35)
	urgent_reticle.set_progress(0.75)
	await process_frame
	_expect(not slow_reticle.is_progress_display_active(), "Lower sniper reticle progress must stay hidden.")
	_expect(urgent_reticle.is_progress_display_active(), "Highest sniper reticle progress must be visible.")

	urgent_reticle.set_progress(0.2)
	slow_reticle.set_progress(0.6)
	await process_frame
	_expect(slow_reticle.is_progress_display_active(), "Reticle priority did not move to the new highest progress.")
	_expect(not urgent_reticle.is_progress_display_active(), "Reticle with lower updated progress remained visible.")

	player.queue_free()
	await process_frame


func _test_mage_windup_fireball_and_obstruction() -> void:
	spawned_fireballs.clear()
	var blocked_player := _spawn_player(Vector2(240.0, 0.0), 200)
	var wall := _spawn_wall(Vector2(120.0, 0.0), 10.0)
	await physics_frame
	var blocked_mage := _spawn_mage(Vector2.ZERO, blocked_player)
	await _wait_physics_frames(12)
	_expect(blocked_mage.combat_state == CapooMage.CombatState.CHASE, "Mage Capoo attacked through a World wall.")
	_expect(spawned_fireballs.is_empty(), "Mage Capoo fired through a World wall.")
	blocked_mage.queue_free()
	wall.queue_free()
	blocked_player.queue_free()
	await physics_frame

	spawned_fireballs.clear()
	var player := _spawn_player(Vector2(240.0, 0.0), 200)
	var mage := _spawn_mage(Vector2.ZERO, player)
	await _wait_physics_frames(3)
	_expect(mage.combat_state == CapooMage.CombatState.WINDUP, "Mage Capoo did not enter windup.")
	_expect(spawned_fireballs.is_empty(), "Mage Capoo fired before windup.")
	var fireball_guard_frames := 0
	while spawned_fireballs.is_empty() and fireball_guard_frames < 90:
		await physics_frame
		fireball_guard_frames += 1
	_expect(spawned_fireballs.size() == 1, "Mage Capoo did not fire exactly one fireball after windup.")
	if not spawned_fireballs.is_empty() and is_instance_valid(spawned_fireballs[0]):
		_expect(is_equal_approx(spawned_fireballs[0].fireball_radius, MAGE_CONFIG.fireball_radius), "Fireball radius did not use config.")
		_expect(spawned_fireballs[0].target_player == player, "Fireball did not keep its soft-homing target.")
	for fireball in spawned_fireballs:
		if is_instance_valid(fireball):
			fireball.queue_free()
	spawned_fireballs.clear()
	mage.queue_free()
	player.queue_free()
	await physics_frame


func _test_fireball_impact_damage_and_release() -> void:
	var near_player := _spawn_player(Vector2(5.0, 0.0), 100)
	var far_player := _spawn_player(Vector2(48.0, 0.0), 100)
	await physics_frame
	var fireball := FIREBALL_SCENE.instantiate() as CapooMageFireball
	test_root.add_child(fireball)
	fireball.global_position = Vector2.ZERO
	fireball.setup(Vector2.RIGHT, 75, 0.0, 3.0, MAGE_CONFIG.fireball_radius)
	fireball.call("_explode")
	await process_frame

	_expect(near_player.current_health == 25, "Fireball impact did not damage the player inside radius.")
	_expect(far_player.current_health == 100, "Fireball impact damaged a player outside radius.")
	_expect(is_instance_valid(fireball), "Fireball must remain while impact animation plays.")
	if is_instance_valid(fireball):
		_expect(fireball.has_exploded, "Fireball did not enter exploded state.")
		_expect(not fireball.monitoring, "Exploded fireball must stop monitoring.")
		_expect(
			fireball.collision_layer == 0 and fireball.collision_mask == 0,
			"Exploded fireball collision layers must be disabled."
		)
		_expect(fireball.animated_sprite.animation == &"impact", "Fireball did not switch to impact animation.")
		_expect(
			fireball.animated_sprite.position == Vector2.ZERO,
			"Fireball impact animation must be centered on hit position."
		)
	_expect(_count_bullet_hit_effects() == 0, "Mage fireball must not spawn the generic bullet hit effect.")

	var release_guard_frames := 0
	while is_instance_valid(fireball) and release_guard_frames < 180:
		await process_frame
		release_guard_frames += 1
	_expect(not is_instance_valid(fireball), "Fireball impact animation/audio did not release the projectile.")
	near_player.queue_free()
	far_player.queue_free()
	await physics_frame


func _test_sniper_lock_cancel_and_damage() -> void:
	var blocked_player := _spawn_player(Vector2(360.0, 0.0), 260)
	var sniper := _spawn_sniper(Vector2.ZERO, blocked_player)
	await _wait_physics_frames(3)
	_expect(sniper.combat_state == CapooSniper.CombatState.LOCK, "Sniper Capoo did not enter lock state.")
	_expect(_count_reticles(blocked_player) == 1, "Sniper lock did not attach one reticle to the player.")
	_expect(_has_sniper_aim_line(sniper), "Sniper lock must show a thin source-to-target aim line.")
	var wall := _spawn_wall(Vector2(180.0, 0.0), 12.0)
	await _wait_physics_frames(6)
	_expect(sniper.combat_state == CapooSniper.CombatState.CHASE, "Sniper Capoo did not cancel lock when LOS was blocked.")
	_expect(_count_reticles(blocked_player) == 0, "Sniper reticle remained after lock cancel.")
	sniper.queue_free()
	wall.queue_free()
	blocked_player.queue_free()
	await physics_frame

	var player := _spawn_player(Vector2(360.0, 0.0), 300)
	await process_frame
	player.max_health = 300
	player.current_health = 300
	var expected_health_after_shot := player.current_health - SNIPER_CONFIG.attack_damage
	var firing_sniper := _spawn_sniper(Vector2.ZERO, player)
	await _wait_physics_frames(3)
	_expect(firing_sniper.combat_state == CapooSniper.CombatState.LOCK, "Sniper Capoo did not lock before damage test.")
	_expect(_has_sniper_aim_line(firing_sniper), "Sniper damage lock must show a thin source-to-target aim line.")
	var sniper_guard_frames := 0
	while player.current_health != expected_health_after_shot and sniper_guard_frames < 230:
		await physics_frame
		sniper_guard_frames += 1
	_expect(
		player.current_health == expected_health_after_shot,
		"Sniper lock did not deal exactly 200 damage after three seconds. health=%d expected=%d state=%s lock_left=%.2f reticles=%d invincible=%.2f"
		% [
			player.current_health,
			expected_health_after_shot,
			str(firing_sniper.combat_state),
			firing_sniper.lock_time_left,
			_count_reticles(player),
			player.invincibility_time_left,
		]
	)
	await process_frame
	await physics_frame
	_expect(_count_reticles(player) == 0, "Sniper reticle remained after firing.")
	firing_sniper.queue_free()
	player.queue_free()
	await physics_frame


func _test_smg_scatter_fire() -> void:
	spawned_smg_bullets.clear()
	var player := _spawn_player(Vector2(140.0, 0.0), 200)
	var smg := _spawn_smg(Vector2.ZERO, player)
	var smg_guard_frames := 0
	while spawned_smg_bullets.size() < 2 and smg_guard_frames < 36:
		await physics_frame
		smg_guard_frames += 1
	_expect(spawned_smg_bullets.size() >= 2, "SMG Capoo did not fire repeatedly while moving.")
	if not spawned_smg_bullets.is_empty() and is_instance_valid(spawned_smg_bullets[0]):
		_expect(is_equal_approx(spawned_smg_bullets[0].max_lifetime, SMG_CONFIG.projectile_lifetime), "SMG bullet lifetime mismatch.")
	smg.queue_free()
	player.queue_free()
	await physics_frame


func _test_multiplayer_projectile_registry() -> void:
	var mp_game := MP_GAME_SCRIPT.new()
	var fireball := mp_game.call(
		"_instantiate_projectile",
		&"capoo_mage_fireball",
		0,
		Vector2.RIGHT,
		75,
		MAGE_CONFIG.projectile_speed,
		MAGE_CONFIG.projectile_lifetime
	) as CapooMageFireball
	_expect(fireball != null, "Multiplayer registry did not instantiate capoo_mage_fireball.")
	if fireball != null:
		_expect(fireball.damage == 75, "Registry mage fireball damage mismatch.")
		_expect(is_equal_approx(fireball.speed, MAGE_CONFIG.projectile_speed), "Registry mage fireball speed mismatch.")
		fireball.free()

	var smg_bullet := mp_game.call(
		"_instantiate_projectile",
		&"capoo_smg_bullet",
		0,
		Vector2.RIGHT,
		40,
		SMG_CONFIG.projectile_speed,
		SMG_CONFIG.projectile_lifetime
	) as CapooAK47Bullet
	_expect(smg_bullet != null, "Multiplayer registry did not instantiate capoo_smg_bullet.")
	if smg_bullet != null:
		_expect(smg_bullet.damage == 40, "Registry SMG bullet damage mismatch.")
		_expect(is_equal_approx(smg_bullet.max_lifetime, SMG_CONFIG.projectile_lifetime), "Registry SMG bullet lifetime mismatch.")
		smg_bullet.free()
	mp_game.free()


func _test_wave_entries() -> void:
	_expect(_count_wave_entries_for_config(WAVE_09, MAGE_CONFIG) == 4, "Wave 9 mage count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_09, SNIPER_CONFIG) == 2, "Wave 9 sniper count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_09, SMG_CONFIG) == 6, "Wave 9 SMG count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_10, MAGE_CONFIG) == 6, "Wave 10 mage count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_10, SNIPER_CONFIG) == 4, "Wave 10 sniper count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_10, SMG_CONFIG) == 8, "Wave 10 SMG count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_11, MAGE_CONFIG) == 8, "Wave 11 mage count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_11, SNIPER_CONFIG) == 6, "Wave 11 sniper count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_11, SMG_CONFIG) == 10, "Wave 11 SMG count mismatch.")


func _spawn_player(position: Vector2, health: int) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	player.collision_layer = 2
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.max_health = health
	player.current_health = health
	return player


func _spawn_mage(position: Vector2, player: Player) -> CapooMage:
	var enemy := MAGE_SCENE.instantiate() as CapooMage
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(MAGE_CONFIG, player)
	return enemy


func _spawn_sniper(position: Vector2, player: Player) -> CapooSniper:
	var enemy := SNIPER_SCENE.instantiate() as CapooSniper
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(SNIPER_CONFIG, player)
	return enemy


func _spawn_smg(position: Vector2, player: Player) -> CapooSMG:
	var enemy := SMG_SCENE.instantiate() as CapooSMG
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(SMG_CONFIG, player)
	return enemy


func _spawn_wall(position: Vector2, radius: float) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	wall.collision_mask = 0
	var shape_node := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = radius
	shape_node.shape = circle
	wall.add_child(shape_node)
	test_root.add_child(wall)
	wall.global_position = position
	return wall


func _has_capoo_frames(scene: PackedScene, label: String, expected_frame_size := Vector2.ZERO) -> bool:
	var instance := scene.instantiate()
	var animated_sprite := instance.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var frames := animated_sprite.sprite_frames if animated_sprite != null else null
	var ok := frames != null
	for animation_name in [&"move", &"windup", &"attack", &"death"]:
		ok = ok and frames.has_animation(animation_name) and frames.get_frame_count(animation_name) == 4
		if frames == null or not frames.has_animation(animation_name):
			continue
		for frame_index in range(frames.get_frame_count(animation_name)):
			var atlas_texture := frames.get_frame_texture(animation_name, frame_index) as AtlasTexture
			ok = ok and atlas_texture != null
			if atlas_texture == null or expected_frame_size == Vector2.ZERO:
				continue
			var atlas_size := atlas_texture.atlas.get_size() if atlas_texture.atlas != null else Vector2.ZERO
			var region := atlas_texture.region
			ok = ok and atlas_texture.get_size() == expected_frame_size
			ok = ok and region.position.x >= 0.0 and region.position.y >= 0.0
			ok = ok and region.end.x <= atlas_size.x and region.end.y <= atlas_size.y
	if not ok:
		failures.append("%s scene animation frames are incomplete." % label)
	instance.free()
	return ok


func _has_mage_visual_alignment() -> bool:
	var instance := MAGE_SCENE.instantiate()
	var animated_sprite := instance.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var ok := animated_sprite != null
	ok = ok and animated_sprite.position.is_equal_approx(Vector2(3.0, -2.0))
	ok = ok and is_equal_approx(animated_sprite.scale.x, 0.1)
	ok = ok and is_equal_approx(animated_sprite.scale.y, 0.1)
	if not ok:
		failures.append("Mage visual must keep the alpha-sheet body centered on its collision shape.")
	instance.free()
	return ok


func _has_smg_visual_alignment() -> bool:
	var instance := SMG_SCENE.instantiate()
	var animated_sprite := instance.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var ok := animated_sprite != null
	ok = ok and animated_sprite.position.is_equal_approx(Vector2(9.0, 3.0))
	ok = ok and is_equal_approx(animated_sprite.scale.x, 0.31)
	ok = ok and is_equal_approx(animated_sprite.scale.y, 0.31)
	if not ok:
		failures.append("SMG visual must keep the MP5-SD body centered on its collision shape.")
	instance.free()
	return ok


func _has_sniper_aim_line(sniper: CapooSniper) -> bool:
	var aim_line := sniper.get_node_or_null("AimGlow") as Polygon2D
	if aim_line == null or not aim_line.visible:
		return false
	var points := aim_line.polygon
	if points.size() != 4:
		return false
	var min_x := points[0].x
	var max_x := points[0].x
	var min_y := points[0].y
	var max_y := points[0].y
	for point in points:
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
		min_y = minf(min_y, point.y)
		max_y = maxf(max_y, point.y)
	var width := max_x - min_x
	var height := max_y - min_y
	return width >= 220.0 and height <= 4.0 and aim_line.color.a > 0.1 and aim_line.color.a < 0.5


func _has_mage_original_alpha_regions() -> bool:
	var frames := load("res://resources/animation/capoo_mage.tres") as SpriteFrames
	var ok := frames != null
	if frames == null:
		failures.append("Mage original alpha SpriteFrames resource is missing.")
		return false
	for animation_name in [&"move", &"windup", &"attack", &"death"]:
		for frame_index in range(4):
			var atlas_texture := frames.get_frame_texture(animation_name, frame_index) as AtlasTexture
			ok = ok and atlas_texture != null
			if atlas_texture == null:
				continue
			var atlas_size := atlas_texture.atlas.get_size() if atlas_texture.atlas != null else Vector2.ZERO
			var region := atlas_texture.region
			ok = ok and atlas_texture.get_size() == Vector2(374.0, 300.0)
			ok = ok and region.position.x >= 0.0 and region.position.y >= 0.0
			ok = ok and region.end.x <= atlas_size.x and region.end.y <= atlas_size.y
	if not ok:
		failures.append("Mage must use margin-padded direct regions from capoo_mage_single_alpha.png without clipping.")
	return ok


func _has_reticle_scene_contract() -> bool:
	var instance := RETICLE_SCENE.instantiate() as CapooSniperLockReticle
	if instance == null:
		return false
	var has_static_mark := instance.get_node_or_null("CenterMark") is Sprite2D
	var has_old_animation := instance.get_node_or_null("Visual") is AnimatedSprite2D
	instance.set_progress(0.5)
	var has_progress := is_equal_approx(instance.progress_ratio, 0.5)
	instance.free()
	return has_static_mark and not has_old_animation and has_progress


func _fireball_impact_animation_contract() -> bool:
	var frames := load("res://resources/animation/capoo_mage_fireball.tres") as SpriteFrames
	var ok := frames != null
	if frames == null:
		failures.append("Fireball SpriteFrames resource is missing.")
		return false
	ok = ok and frames.has_animation(&"impact")
	ok = ok and not frames.get_animation_loop(&"impact")
	ok = ok and frames.get_animation_speed(&"impact") >= 20.0
	for frame_index in range(6):
		var atlas_texture := frames.get_frame_texture(&"impact", frame_index) as AtlasTexture
		ok = ok and atlas_texture != null
		if atlas_texture == null:
			continue
		ok = ok and atlas_texture.region == Rect2(frame_index * 64.0, 64.0, 64.0, 64.0)
	if not ok:
		failures.append("Fireball impact animation must be a non-looping second-row AtlasTexture animation.")
	return ok


func _has_fireball_impact_audio() -> bool:
	var instance := FIREBALL_SCENE.instantiate() as CapooMageFireball
	if instance == null:
		return false
	var impact_audio := instance.get_node_or_null("ImpactAudio") as AudioStreamPlayer2D
	var ok := impact_audio != null
	ok = ok and impact_audio.stream != null
	ok = ok and _resource_path(impact_audio.stream).ends_with("capoo_mage_fireball_impact.wav")
	ok = ok and impact_audio.volume_db <= -6.0
	ok = ok and impact_audio.max_polyphony <= 2
	if not ok:
		failures.append("Fireball scene must include a restrained ImpactAudio player.")
	instance.free()
	return ok


func _texture_size(path: String) -> Vector2:
	var texture := load(path) as Texture2D
	return texture.get_size() if texture != null else Vector2.ZERO


func _resource_path(resource: Resource) -> String:
	return resource.resource_path if resource != null else ""


func _sprite_frames_count(path: String, animation_name: StringName) -> int:
	var frames := load(path) as SpriteFrames
	if frames == null or not frames.has_animation(animation_name):
		return 0
	return frames.get_frame_count(animation_name)


func _count_reticles(player: Player) -> int:
	var total := 0
	for child in player.get_children():
		if child is CapooSniperLockReticle:
			total += 1
	return total


func _count_bullet_hit_effects() -> int:
	var total := 0
	for child in test_root.get_children():
		if child is BulletHitEffect:
			total += 1
	return total


func _count_wave_entries_for_config(wave_config: WaveConfig, enemy_config: EnemyConfig) -> int:
	var total := 0
	for entry in wave_config.enemy_entries:
		if entry != null and entry.enemy_config == enemy_config:
			total += entry.count
	return total


func _on_child_entered_tree(child: Node) -> void:
	var fireball := child as CapooMageFireball
	if fireball != null:
		spawned_fireballs.append(fireball)
	var smg_bullet := child as CapooAK47Bullet
	if smg_bullet != null:
		spawned_smg_bullets.append(smg_bullet)


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
