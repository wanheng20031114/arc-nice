extends SceneTree

const LARGE_SCENE := preload(
	"res://scene/enemy/artificial_creation/cardboard_monster_large.tscn"
)
const LARGE_CONFIG := preload(
	"res://resources/config/enemies/cardboard_monster_large.tres"
)
const ORDINARY_SCENE := preload(
	"res://scene/enemy/artificial_creation/cardboard_monster.tscn"
)
const ORDINARY_CONFIG := preload(
	"res://resources/config/enemies/cardboard_monster.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const AGAVE_SCENE := preload("res://scene/plant_defense/agave_cannon.tscn")
const AGAVE_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)
const DEFAULT_DROP_TABLE_PATH := (
	"res://resources/config/enemies/default_enemy_drop_table.tres"
)
const PAPER_SWORD_COLOR := Color8(225, 202, 159, 255)

var failures: Array[String] = []
var test_root: Node2D
var fake_runtime: FakeCombatRuntime


class FakeCombatRuntime:
	extends CombatRuntimeBase

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(_peer_id: int) -> Player:
		return null

	func get_enemy_for_net_id(_net_id: int) -> Enemy:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(_peer_id: int) -> void:
		pass

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "CardboardMonsterLargeCoreSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	fake_runtime = FakeCombatRuntime.new()
	fake_runtime.name = "FakeCombatRuntime"

	_test_resource_scene_and_animation_contract()
	await _test_fixed_damage_fifteen_hit_contract()
	await _test_windup_lock_sector_and_damage_frame()
	await _test_automatic_contact_reach_and_independent_damage()
	await _test_large_plant_contact_shape_reach()
	await _test_touch_tick_survives_windup_and_slash()

	fake_runtime.free()
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("CARDBOARD_MONSTER_LARGE_CORE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_scene_and_animation_contract() -> void:
	_expect(LARGE_CONFIG is CardboardMonsterLargeConfig, "Large config class mismatch.")
	_expect(LARGE_CONFIG is CardboardMonsterConfig, "Large config must extend CardboardMonsterConfig.")
	_expect(LARGE_CONFIG.display_name == "大纸箱怪", "Large display name mismatch.")
	_expect(LARGE_CONFIG.enemy_scene == LARGE_SCENE, "Large enemy scene mismatch.")
	_expect(LARGE_CONFIG.category_tags == PackedStringArray(["artificial_creation"]), "Large category must be artificial_creation only.")
	_expect(LARGE_CONFIG.max_health == 15, "Large health must be 15.")
	_expect(LARGE_CONFIG.attack_damage == 40, "Large attack must be 40.")
	_expect(LARGE_CONFIG.physical_defense == 0 and LARGE_CONFIG.magic_defense == 0, "Large defenses must be 0/0.")
	_expect(is_equal_approx(LARGE_CONFIG.move_speed, 22.0), "Large move speed must be 22.")
	_expect(LARGE_CONFIG.home_damage == 2, "Large home damage must be 2.")
	_expect(LARGE_CONFIG.xirang_kill_reward == 6, "Large kill reward must be 6.")
	_expect(
		LARGE_CONFIG.drop_table != null
		and LARGE_CONFIG.drop_table.resource_path == DEFAULT_DROP_TABLE_PATH,
		"Large cardboard must use the common drop table."
	)
	_expect(is_equal_approx(LARGE_CONFIG.attack_range, 24.0), "Large acquisition range must be 24.")
	_expect(is_equal_approx(LARGE_CONFIG.slash_inner_radius, 6.0), "Large slash inner radius must be 6.")
	_expect(is_equal_approx(LARGE_CONFIG.slash_outer_radius, 24.0), "Large slash outer radius must be 24.")
	_expect(is_equal_approx(LARGE_CONFIG.slash_angle_degrees, 60.0), "Large slash angle must be 60 degrees.")
	_expect(is_equal_approx(LARGE_CONFIG.attack_windup, 1.0 / 3.0), "Large windup must inherit one third second.")
	_expect(is_equal_approx(LARGE_CONFIG.slash_damage_delay, 1.0 / 15.0), "Large damage frame delay must be 1/15 second.")
	_expect(is_equal_approx(LARGE_CONFIG.slash_duration, 1.0 / 3.0), "Large slash must last one third second.")
	_expect(is_equal_approx(LARGE_CONFIG.attack_interval, 1.8), "Large cooldown must inherit 1.8 seconds.")
	_expect(LARGE_CONFIG.slash_effect_scene == null, "The paper sword must not spawn a collision/effect proxy.")

	var enemy := LARGE_SCENE.instantiate() as CardboardMonsterLarge
	_expect(enemy != null and enemy is CardboardMonster, "Large scene must extend CardboardMonster.")
	if enemy == null:
		return
	var sprite := enemy.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var body_shapes := _collect_direct_collision_shapes(enemy)
	var touch_shapes := _collect_direct_collision_shapes(enemy.get_node("TouchDamageArea"))
	_expect(body_shapes.size() == 1 and touch_shapes.size() == 1, "Paper sword must add no body/touch collision shape.")
	if body_shapes.size() == 1 and touch_shapes.size() == 1:
		var body_rect := body_shapes[0].shape as RectangleShape2D
		var touch_rect := touch_shapes[0].shape as RectangleShape2D
		_expect(body_rect != null and body_rect.size == Vector2(20, 18), "Large body collision must be 20x18.")
		_expect(touch_rect != null and touch_rect.size == Vector2(20, 18), "Large touch collision must be 20x18.")
		_expect(body_shapes[0].position == Vector2(0, -1), "Large body collision position must be (0,-1).")
		_expect(touch_shapes[0].position == Vector2(0, -1), "Large touch collision position must be (0,-1).")
		_expect(body_rect != touch_rect, "Large body and touch shapes must be independent resources.")
	var warning := enemy.get_node("WindupWarning") as Polygon2D
	_expect(warning != null and warning.polygon.size() == 26, "Large warning must contain 12-segment/26-point fan geometry.")
	if warning != null and warning.polygon.size() == 26:
		_expect(absf(warning.polygon[0].length() - 24.0) < 0.001, "Large warning outer radius drifted.")
		_expect(absf(warning.polygon[25].length() - 6.0) < 0.001, "Large warning inner radius drifted.")
	_expect(enemy.get_node_or_null("AttackAudio") is AudioStreamPlayer2D, "Large AttackAudio must be authored in the scene.")
	_expect(not enemy.sprite_faces_left_by_default and not sprite.flip_h, "Large native art must face right.")

	var expected := {
		&"move": [8, 9.0, true],
		&"windup": [3, 9.0, false],
		&"slash": [5, 15.0, false],
		&"death": [8, 12.0, false],
	}
	for animation_name in expected:
		var contract: Array = expected[animation_name]
		_expect(sprite.sprite_frames.has_animation(animation_name), "Missing large animation %s." % animation_name)
		_expect(sprite.sprite_frames.get_frame_count(animation_name) == int(contract[0]), "%s frame count drifted." % animation_name)
		_expect(is_equal_approx(sprite.sprite_frames.get_animation_speed(animation_name), float(contract[1])), "%s FPS drifted." % animation_name)
		_expect(sprite.sprite_frames.get_animation_loop(animation_name) == bool(contract[2]), "%s loop contract drifted." % animation_name)
		for frame_index in range(sprite.sprite_frames.get_frame_count(animation_name)):
			var atlas_texture := sprite.sprite_frames.get_frame_texture(animation_name, frame_index) as AtlasTexture
			_expect(
				atlas_texture != null
				and atlas_texture.filter_clip
				and atlas_texture.region.size == Vector2(48, 48),
				"%s frame %d must be a clipped 48x48 AtlasTexture." % [animation_name, frame_index]
			)
	var move_image := sprite.sprite_frames.get_frame_texture(&"move", 0).get_image()
	var sword_min_x := 48
	var sword_max_x := -1
	for y in range(move_image.get_height()):
		for x in range(move_image.get_width()):
			if move_image.get_pixel(x, y) == PAPER_SWORD_COLOR:
				sword_min_x = mini(sword_min_x, x)
				sword_max_x = maxi(sword_max_x, x)
	_expect(sword_min_x > 24 and sword_max_x >= 44, "Large move F0 paper sword must remain in the +X foreground.")
	_expect(enemy.call("_get_slash_damage_source_type") == &"cardboard_monster_large_slash", "Large slash source type mismatch.")
	_expect(enemy.call("_uses_inherited_touch_damage"), "Large cardboard must inherit independent touch damage.")
	_expect(enemy.call("_uses_contact_shape_slash_reach"), "Large cardboard must inherit contact-shape slash reach.")
	var profile := enemy.call("_create_damage_target_profile") as DamageTargetProfile
	_expect(profile != null and is_equal_approx(profile.fixed_damage_per_accepted_hit, 1.0), "Large cardboard must inherit fixed damage per accepted hit.")
	enemy.free()

	_expect(ORDINARY_CONFIG.max_health == 6 and ORDINARY_CONFIG.attack_damage == 25, "Ordinary cardboard stats regressed.")
	var ordinary := ORDINARY_SCENE.instantiate() as CardboardMonster
	_expect(ordinary != null and ordinary.call("_get_slash_damage_source_type") == &"cardboard_monster_slash", "Ordinary cardboard source type regressed.")
	ordinary.free()


func _test_fixed_damage_fifteen_hit_contract() -> void:
	var enemy := _spawn_large(Vector2.ZERO, null, true)
	var accepted := enemy.apply_damage(999_999, Vector2.RIGHT, EnemyConfig.DamageType.PHYSICAL, false)
	_expect(accepted and enemy.current_health == 14 and enemy.last_damage_taken == 1, "Huge physical hit must remove exactly 1 HP.")
	accepted = enemy.apply_damage(999_999, Vector2.LEFT, EnemyConfig.DamageType.MAGIC, false)
	_expect(accepted and enemy.current_health == 13 and enemy.last_damage_taken == 1, "Huge magic hit must remove exactly 1 HP.")
	var bypass := DamageRequest.new(999_999, CombatTypes.DamageType.PHYSICAL)
	bypass.with_flag(CombatTypes.DamageFlag.BYPASS_MITIGATION)
	var bypass_result := enemy.apply_combat_damage(bypass)
	_expect(bypass_result.accepted and bypass_result.applied_damage == 1 and enemy.current_health == 12, "Bypass-mitigation hit must still remove exactly 1 HP.")
	var zero_result := enemy.apply_combat_damage(DamageRequest.new(0, CombatTypes.DamageType.PHYSICAL))
	_expect(not zero_result.accepted and enemy.current_health == 12, "Zero damage must remain rejected.")
	enemy.queue_free()
	await process_frame

	var sequential := _spawn_large(Vector2.ZERO, null, true)
	for hit_index in range(14):
		var result := sequential.apply_combat_damage(DamageRequest.new(500, CombatTypes.DamageType.PHYSICAL))
		_expect(result.accepted and result.applied_damage == 1 and not result.lethal, "Accepted hit %d must deal exactly 1 and remain nonlethal." % (hit_index + 1))
	_expect(sequential.current_health == 1 and not sequential.is_dead, "Fourteen accepted hits must leave exactly 1 HP.")
	var lethal := sequential.apply_combat_damage(DamageRequest.new(500, CombatTypes.DamageType.PHYSICAL))
	_expect(lethal.accepted and lethal.applied_damage == 1 and lethal.lethal and sequential.current_health == 0 and sequential.is_dead, "The fifteenth accepted hit must be lethal.")
	var dead_result := sequential.apply_combat_damage(DamageRequest.new(500, CombatTypes.DamageType.PHYSICAL))
	_expect(not dead_result.accepted and dead_result.applied_damage == 0 and sequential.current_health == 0, "Dead large cardboard must reject later damage.")
	sequential.queue_free()
	await process_frame

	var batch_target := _spawn_large(Vector2.ZERO, null, true)
	var batch := DamageBatchRequest.new(
		PackedInt64Array([999]), PackedInt32Array([15]), CombatTypes.DamageType.PHYSICAL
	)
	var batch_result := batch_target.apply_combat_damage(batch)
	_expect(
		batch_result.accepted
		and batch_result.requested_hit_count == 15
		and batch_result.accepted_hit_count == 15
		and batch_result.applied_damage == 15
		and batch_result.lethal
		and batch_target.current_health == 0,
		"A 15-hit batch must settle as fifteen fixed 1-damage hits and kill exactly."
	)
	batch_target.queue_free()
	await process_frame

	var proxy := _spawn_large(Vector2.ZERO, null, true)
	proxy.configure_multiplayer_proxy()
	var proxy_result := proxy.apply_combat_damage(DamageRequest.new(999, CombatTypes.DamageType.PHYSICAL))
	_expect(not proxy_result.accepted and proxy_result.applied_damage == 0 and proxy.current_health == 15, "Proxy damage must be rejected before fixed-hit resolution.")
	proxy.queue_free()
	await process_frame


func _test_windup_lock_sector_and_damage_frame() -> void:
	var player := _spawn_player(Vector2(20, 0))
	var enemy := _spawn_large(Vector2.ZERO, player, true)
	enemy.collision_layer = 0
	enemy.collision_mask = 0
	await _wait_physics_frames(2)
	var started := bool(enemy.call("_try_start_windup", player))
	_expect(started and enemy.combat_state == CapooKnight.CombatState.WINDUP, "Large cardboard must enter windup inside 24px.")
	_expect(enemy.slash_direction.x > 0.0 and not enemy.animated_sprite.flip_h, "Right target must begin right-facing windup.")
	player.global_position = Vector2(-20, 0)
	enemy.call("_update_windup", 0.05)
	_expect(enemy.slash_direction.x < 0.0 and enemy.animated_sprite.flip_h, "Host windup must track the committed target position.")
	enemy.call("_update_windup", LARGE_CONFIG.attack_windup)
	_expect(enemy.combat_state == CapooKnight.CombatState.SLASH, "Large windup must transition to slash.")
	_expect(enemy.slash_direction.x < 0.0 and enemy.animated_sprite.flip_h, "Large slash must lock final windup direction.")
	player.global_position = Vector2(20, 0)
	await physics_frame
	var health_before_miss := player.current_health
	enemy.call("_apply_slash_damage")
	_expect(player.current_health == health_before_miss, "Target behind locked 60-degree fan must legally miss.")
	player.global_position = Vector2(-20, 0)
	await physics_frame
	enemy.call("_apply_slash_damage")
	_expect(player.current_health == health_before_miss - 40, "Locked large-cardboard fan must deal 40 physical damage in front.")

	enemy.touching_players.clear()
	_expect(not bool(enemy.call("_is_slash_target_in_radial_range", player, 5.999, 6.0, 24.0)), "Distance below inner radius must reject.")
	_expect(bool(enemy.call("_is_slash_target_in_radial_range", player, 6.0, 6.0, 24.0)), "Exact inner radius must accept.")
	_expect(bool(enemy.call("_is_slash_target_in_radial_range", player, 24.0, 6.0, 24.0)), "Exact outer radius must accept.")
	_expect(not bool(enemy.call("_is_slash_target_in_radial_range", player, 24.001, 6.0, 24.0)), "Distance above outer radius without contact must reject.")

	enemy.slash_direction = Vector2.RIGHT
	player.current_health = 200
	player.health_bar.setup(player.max_health, player.current_health)
	player.invincibility_time_left = 0.0
	player.global_position = Vector2.RIGHT.rotated(deg_to_rad(30.0)) * 18.0
	await physics_frame
	enemy.call("_apply_slash_damage")
	_expect(
		player.current_health == 160,
		"Exact +30-degree half-angle boundary must accept (health=%d pos=%s angle=%.8f)."
		% [
			player.current_health,
			str(player.global_position),
			rad_to_deg(Vector2.RIGHT.angle_to(player.global_position.normalized())),
		]
	)
	player.current_health = 200
	player.health_bar.setup(player.max_health, player.current_health)
	player.invincibility_time_left = 0.0
	player.global_position = Vector2.RIGHT.rotated(deg_to_rad(-30.0)) * 18.0
	await physics_frame
	enemy.call("_apply_slash_damage")
	_expect(player.current_health == 160, "Exact -30-degree half-angle boundary must accept.")
	player.current_health = 200
	player.health_bar.setup(player.max_health, player.current_health)
	player.invincibility_time_left = 0.0
	player.global_position = Vector2.RIGHT.rotated(deg_to_rad(30.2)) * 18.0
	await physics_frame
	enemy.call("_apply_slash_damage")
	_expect(player.current_health == 200, "Angle beyond +30 degrees must reject.")
	player.global_position = enemy.global_position
	await physics_frame
	enemy.call("_apply_slash_damage")
	_expect(player.current_health == 200, "Zero offset must reject.")

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_automatic_contact_reach_and_independent_damage() -> void:
	var previous_throttling := Enemy.combat_sense_throttling_enabled
	Enemy.combat_sense_throttling_enabled = true
	var player := _spawn_player(Vector2(12, 12))
	var enemy := LARGE_SCENE.instantiate() as CardboardMonsterLarge
	enemy.touch_damage_interval = 99.0
	test_root.add_child(enemy)
	enemy.global_position = Vector2.ZERO
	enemy.setup(LARGE_CONFIG, player, null, fake_runtime)
	var saw_contact := false
	var saw_windup := false
	var saw_slash := false
	var health_after_contact := player.current_health
	var health_after_slash := player.current_health
	for _physics_step in range(120):
		await physics_frame
		if not saw_contact and enemy.call("_has_player_contact"):
			saw_contact = true
			health_after_contact = player.current_health
		if enemy.combat_state == CapooKnight.CombatState.WINDUP:
			saw_windup = true
		elif enemy.combat_state == CapooKnight.CombatState.SLASH:
			saw_slash = true
		if enemy.slash_damage_done:
			health_after_slash = player.current_health
			break
	_expect(saw_contact, "Large diagonal fixture must create real touch overlap.")
	_expect(saw_windup and saw_slash, "Real player contact must drive automatic windup/slash.")
	_expect(health_after_contact == 160, "Initial body contact must independently deal 40 damage.")
	_expect(health_after_slash == 120, "Automatic paper-sword slash must independently deal a second 40 damage.")

	Enemy.combat_sense_throttling_enabled = previous_throttling
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_large_plant_contact_shape_reach() -> void:
	var previous_throttling := Enemy.combat_sense_throttling_enabled
	Enemy.combat_sense_throttling_enabled = true
	var plant := AGAVE_SCENE.instantiate() as AgaveCannon
	plant.global_position = Vector2(23, 18)
	test_root.add_child(plant)
	plant.setup(AGAVE_CONFIG, null, [Vector2i.ZERO])
	plant.attack_timer.stop()
	var initial_health := plant.current_health

	var enemy := LARGE_SCENE.instantiate() as CardboardMonsterLarge
	enemy.touch_damage_interval = 99.0
	test_root.add_child(enemy)
	enemy.global_position = Vector2.ZERO
	enemy.setup(LARGE_CONFIG, null, null, fake_runtime)
	enemy.set_objective_target(plant)
	_expect(
		enemy.global_position.distance_to(plant.global_position)
			> LARGE_CONFIG.slash_outer_radius,
		"Large-plant center must remain beyond the authored 24px radius."
	)

	var saw_contact := false
	var saw_windup := false
	var saw_slash := false
	var health_after_contact := initial_health
	var health_after_slash := initial_health
	for _physics_step in range(120):
		await physics_frame
		if not saw_contact and enemy.touching_plants.has(plant.get_instance_id()):
			saw_contact = true
			health_after_contact = plant.current_health
		if enemy.combat_state == CapooKnight.CombatState.WINDUP:
			saw_windup = true
		elif enemy.combat_state == CapooKnight.CombatState.SLASH:
			saw_slash = true
		if enemy.slash_damage_done:
			health_after_slash = plant.current_health
			break
	var contact_damage := initial_health - health_after_contact
	var slash_damage := health_after_contact - health_after_slash
	_expect(saw_contact, "Large plant must enter the real touch tracker beyond 24px center distance.")
	_expect(saw_windup and saw_slash, "Contact-shape reach must allow the large plant to reach windup/slash.")
	_expect(contact_damage > 0 and slash_damage == contact_damage, "Large-plant touch and slash must remain equal independent 40-damage claims before defense.")

	Enemy.combat_sense_throttling_enabled = previous_throttling
	enemy.queue_free()
	plant.queue_free()
	await physics_frame


func _test_touch_tick_survives_windup_and_slash() -> void:
	var player := _spawn_player(Vector2.ZERO)
	var enemy := _spawn_large(Vector2.ZERO, player, true)
	enemy.attack_cooldown_left = 99.0
	enemy.call("_on_touch_damage_area_body_entered", player)
	_expect(player.current_health == 160, "Initial large body contact must deal 40 damage.")
	enemy.combat_state = CapooKnight.CombatState.WINDUP
	enemy.committed_attack_target = player
	enemy.windup_time_left = 99.0
	enemy.call("_physics_process", 0.49)
	_expect(player.current_health == 160, "Touch must not repeat before 0.5 seconds during windup.")
	enemy.call("_physics_process", 0.02)
	_expect(player.current_health == 120, "Touch must repeat after 0.5 seconds during windup.")
	enemy.combat_state = CapooKnight.CombatState.SLASH
	enemy.committed_attack_target = player
	enemy.slash_time_left = 99.0
	enemy.slash_damage_done = true
	enemy.call("_physics_process", 0.49)
	_expect(player.current_health == 120, "Touch must keep its cadence before 0.5 seconds during slash.")
	enemy.call("_physics_process", 0.02)
	_expect(player.current_health == 80, "Touch must repeat independently during slash.")
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.global_position = position
	test_root.add_child(player)
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set("_base_max_health", 200)
	player.max_health = 200
	player.current_health = 200
	player.health_bar.setup(player.max_health, player.current_health)
	return player


func _spawn_large(position: Vector2, player: Player, disable_touch: bool) -> CardboardMonsterLarge:
	var enemy := LARGE_SCENE.instantiate() as CardboardMonsterLarge
	test_root.add_child(enemy)
	enemy.global_position = position
	if disable_touch:
		enemy.touch_damage_area.monitoring = false
		enemy.touch_damage_area.monitorable = false
	enemy.setup(LARGE_CONFIG, player, null, fake_runtime)
	enemy.set_physics_process(false)
	return enemy


func _collect_direct_collision_shapes(node: Node) -> Array[CollisionShape2D]:
	var shapes: Array[CollisionShape2D] = []
	for child in node.get_children():
		var shape := child as CollisionShape2D
		if shape != null:
			shapes.append(shape)
	return shapes


func _wait_physics_frames(count: int) -> void:
	for _frame in range(count):
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
