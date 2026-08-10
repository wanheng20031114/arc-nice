extends SceneTree

const CARDBOARD_SCENE := preload(
	"res://scene/enemy/artificial_creation/cardboard_monster.tscn"
)
const CARDBOARD_CONFIG := preload(
	"res://resources/config/enemies/cardboard_monster.tres"
)
const KNIGHT_SCENE := preload("res://scene/enemy/capoo/capoo_knight.tscn")
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
const PAPER_STICK_COLOR := Color8(225, 202, 159, 255)

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
	test_root.name = "CardboardMonsterCoreSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	fake_runtime = FakeCombatRuntime.new()
	fake_runtime.name = "FakeCombatRuntime"

	_test_resource_and_scene_contract()
	await _test_fixed_damage_profile()
	await _test_facing_windup_lock_and_slash_geometry()
	await _test_slash_damage_frame_timing()
	await _test_automatic_diagonal_contact_slash()
	await _test_automatic_large_plant_contact_slash()
	await _test_touch_damage_interval()

	fake_runtime.free()
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("CARDBOARD_MONSTER_CORE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_and_scene_contract() -> void:
	_expect(
		CARDBOARD_CONFIG is CardboardMonsterConfig,
		"Cardboard config must use CardboardMonsterConfig."
	)
	_expect(CARDBOARD_CONFIG.display_name == "纸箱怪", "Display name mismatch.")
	_expect(CARDBOARD_CONFIG.enemy_scene == CARDBOARD_SCENE, "Enemy scene mismatch.")
	_expect(CARDBOARD_CONFIG.category_tags == PackedStringArray(["artificial_creation"]), "Category must be artificial_creation only.")
	_expect(CARDBOARD_CONFIG.max_health == 6, "Health must be 6.")
	_expect(CARDBOARD_CONFIG.attack_damage == 25, "Attack damage must be 25.")
	_expect(CARDBOARD_CONFIG.physical_defense == 0, "Physical defense must be 0.")
	_expect(CARDBOARD_CONFIG.magic_defense == 0, "Magic defense must be 0.")
	_expect(is_equal_approx(CARDBOARD_CONFIG.move_speed, 32.0), "Move speed must be 32.")
	_expect(CARDBOARD_CONFIG.home_damage == 1, "Home damage must be 1.")
	_expect(CARDBOARD_CONFIG.xirang_kill_reward == 3, "Kill reward must be 3.")
	_expect(
		CARDBOARD_CONFIG.drop_table != null
		and CARDBOARD_CONFIG.drop_table.resource_path == DEFAULT_DROP_TABLE_PATH,
		"Cardboard monster must use the common drop table."
	)
	_expect(is_equal_approx(CARDBOARD_CONFIG.attack_range, 16.0), "Attack acquisition range must be 16.")
	_expect(is_equal_approx(CARDBOARD_CONFIG.slash_outer_radius, 16.0), "Slash outer radius must be 16.")
	_expect(is_equal_approx(CARDBOARD_CONFIG.slash_inner_radius, 5.0), "Slash inner radius must be 5.")
	_expect(is_equal_approx(CARDBOARD_CONFIG.slash_angle_degrees, 45.0), "Slash angle must be 45 degrees.")
	_expect(is_equal_approx(CARDBOARD_CONFIG.attack_windup, 1.0 / 3.0), "Windup must last one third second.")
	_expect(is_equal_approx(CARDBOARD_CONFIG.slash_duration, 1.0 / 3.0), "Slash must last one third second.")
	_expect(is_equal_approx(CARDBOARD_CONFIG.slash_damage_delay, 1.0 / 15.0), "Damage must begin on slash frame 2.")
	_expect(is_equal_approx(CARDBOARD_CONFIG.attack_interval, 1.8), "Attack cooldown must be 1.8 seconds.")
	_expect(CARDBOARD_CONFIG.attack_animation_name == &"slash", "Attack animation must be slash.")
	_expect(CARDBOARD_CONFIG.slash_effect_scene == null, "Paper-stick slash must not spawn a separate effect.")

	var enemy := CARDBOARD_SCENE.instantiate() as CardboardMonster
	_expect(enemy != null, "Cardboard scene must instantiate CardboardMonster.")
	if enemy == null:
		return
	var sprite := enemy.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var body_shapes := _collect_direct_collision_shapes(enemy)
	var touch_shapes := _collect_direct_collision_shapes(enemy.get_node("TouchDamageArea"))
	_expect(not enemy.sprite_faces_left_by_default, "Native cardboard art must face right by default.")
	_expect(not sprite.flip_h and sprite.scale == Vector2.ONE, "Editor preview must be unscaled and face right.")
	_expect(body_shapes.size() == 1 and touch_shapes.size() == 1, "Body/touch must each own exactly one shape; the paper stick has no collision.")
	if body_shapes.size() == 1 and touch_shapes.size() == 1:
		var body_rect := body_shapes[0].shape as RectangleShape2D
		var touch_rect := touch_shapes[0].shape as RectangleShape2D
		_expect(body_rect != null and body_rect.size == Vector2(14, 12), "Body collision must be 14x12.")
		_expect(touch_rect != null and touch_rect.size == Vector2(14, 12), "Touch area must be 14x12.")
		_expect(body_shapes[0].position == Vector2(0, 2), "Body collision position must be (0,2).")
		_expect(touch_shapes[0].position == Vector2(0, 2), "Touch collision position must be (0,2).")
		_expect(body_rect != touch_rect, "Body and touch shapes must be independently editable.")
	var warning := enemy.get_node("WindupWarning") as Polygon2D
	_expect(warning != null and warning.polygon.size() == 26, "WindupWarning must contain the 12-segment, 26-point fan.")
	_expect(enemy.get_node_or_null("AttackAudio") is AudioStreamPlayer2D, "AttackAudio must be authored in the scene.")

	var frames := sprite.sprite_frames
	var expected := {
		&"move": [8, 12.0, true],
		&"windup": [3, 9.0, false],
		&"slash": [5, 15.0, false],
		&"death": [8, 8.0, false],
	}
	for animation_name in expected:
		var contract: Array = expected[animation_name]
		_expect(frames.has_animation(animation_name), "Missing animation %s." % animation_name)
		_expect(frames.get_frame_count(animation_name) == int(contract[0]), "%s frame count drifted." % animation_name)
		_expect(is_equal_approx(frames.get_animation_speed(animation_name), float(contract[1])), "%s FPS drifted." % animation_name)
		_expect(frames.get_animation_loop(animation_name) == bool(contract[2]), "%s loop contract drifted." % animation_name)
		for frame_index in range(frames.get_frame_count(animation_name)):
			var atlas_texture := frames.get_frame_texture(animation_name, frame_index) as AtlasTexture
			_expect(atlas_texture != null and atlas_texture.filter_clip, "%s frame %d must use filter_clip AtlasTexture." % [animation_name, frame_index])

	var move_texture := frames.get_frame_texture(&"move", 0)
	var move_image := move_texture.get_image() if move_texture != null else null
	var paper_stick_min_x := 32
	var paper_stick_max_x := -1
	if move_image != null:
		for y in range(move_image.get_height()):
			for x in range(move_image.get_width()):
				if move_image.get_pixel(x, y) == PAPER_STICK_COLOR:
					paper_stick_min_x = mini(paper_stick_min_x, x)
					paper_stick_max_x = maxi(paper_stick_max_x, x)
	_expect(paper_stick_min_x > 16 and paper_stick_max_x >= 28, "Right-facing move F0 paper stick must remain on +X.")
	_expect(enemy.call("_get_slash_damage_source_type") == &"cardboard_monster_slash", "Cardboard slash source type mismatch.")
	_expect(
		enemy.call("_uses_contact_shape_slash_reach"),
		"Cardboard monster must opt into collider-aware reach at a real contact boundary."
	)
	enemy.free()

	var knight := KNIGHT_SCENE.instantiate() as CapooKnight
	_expect(knight.call("_get_slash_damage_source_type") == &"capoo_knight_slash", "CapooKnight default slash source must remain unchanged.")
	_expect(
		not knight.call("_uses_contact_shape_slash_reach"),
		"Other knight-family enemies must retain their authored center-distance reach."
	)
	knight.free()


func _test_fixed_damage_profile() -> void:
	var enemy := CARDBOARD_SCENE.instantiate() as CardboardMonster
	test_root.add_child(enemy)
	enemy.setup(CARDBOARD_CONFIG, null)
	enemy.set_physics_process(false)
	var profile := enemy.call("_create_damage_target_profile") as DamageTargetProfile
	_expect(profile != null and is_equal_approx(profile.fixed_damage_per_accepted_hit, 1.0), "Cardboard target profile must fix every accepted hit to 1 damage.")
	var accepted := enemy.apply_damage(999, Vector2.RIGHT, EnemyConfig.DamageType.PHYSICAL, false)
	_expect(accepted and enemy.current_health == 5 and enemy.last_damage_taken == 1, "A large physical hit must remove exactly 1 HP.")
	accepted = enemy.apply_damage(999, Vector2.LEFT, EnemyConfig.DamageType.MAGIC, false)
	_expect(accepted and enemy.current_health == 4 and enemy.last_damage_taken == 1, "A large magic hit must remove exactly 1 HP.")
	var rejected := enemy.apply_damage(0, Vector2.ZERO, EnemyConfig.DamageType.PHYSICAL, false)
	_expect(not rejected and enemy.current_health == 4, "A rejected zero-damage request must not consume HP.")
	enemy.queue_free()
	await process_frame


func _test_facing_windup_lock_and_slash_geometry() -> void:
	var player := _spawn_player(Vector2(12, 0))
	var enemy := _spawn_cardboard(Vector2.ZERO, player, true)
	await _wait_physics_frames(2)
	enemy.call("_set_facing_left", true)
	_expect(enemy.animated_sprite.flip_h, "Left move facing must mirror the +X paper stick.")
	enemy.call("_set_facing_left", false)
	_expect(not enemy.animated_sprite.flip_h, "Right move facing must restore the native +X paper stick.")
	var started := bool(enemy.call("_try_start_windup", player))
	_expect(started and enemy.combat_state == CapooKnight.CombatState.WINDUP, "Cardboard monster must enter windup inside 16px range.")
	_expect(enemy.slash_direction.x > 0.0 and not enemy.animated_sprite.flip_h, "Right-side target must begin a right-facing windup.")

	player.global_position = Vector2(-12, 0)
	enemy.call("_update_windup", 0.05)
	_expect(enemy.slash_direction.x < 0.0 and enemy.animated_sprite.flip_h, "Windup must keep tracking when the target crosses sides.")
	_expect(is_equal_approx(absf(enemy.windup_warning.rotation), PI), "Windup warning must rotate with the tracked left direction.")
	enemy.call("_update_windup", CARDBOARD_CONFIG.attack_windup)
	_expect(enemy.combat_state == CapooKnight.CombatState.SLASH, "Windup must transition into slash.")
	_expect(enemy.slash_direction.x < 0.0 and enemy.animated_sprite.flip_h, "Slash must lock the final windup direction.")
	_expect(enemy.animated_sprite.animation == &"slash", "Slash state must play the slash animation.")

	player.global_position = Vector2(12, 0)
	await physics_frame
	enemy.call("_update_slash", 0.01)
	_expect(enemy.slash_direction.x < 0.0 and enemy.animated_sprite.flip_h, "A target crossing behind after slash start must not reverse facing.")
	var health_before_miss := player.current_health
	enemy.call("_apply_slash_damage")
	_expect(player.current_health == health_before_miss, "A target behind the locked 45-degree fan must be a legal miss.")

	player.global_position = Vector2(-12, 0)
	await physics_frame
	enemy.call("_apply_slash_damage")
	_expect(player.current_health == health_before_miss - 25, "The locked left fan/query must hit a target 12px in front.")
	player.global_position = Vector2(-24, 0)
	await physics_frame
	var health_before_range_miss := player.current_health
	enemy.call("_apply_slash_damage")
	_expect(player.current_health == health_before_range_miss, "A target that dodges beyond 16px after lock must miss.")

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_slash_damage_frame_timing() -> void:
	var player := _spawn_player(Vector2(12, 0))
	var enemy := _spawn_cardboard(Vector2.ZERO, player, true)
	await _wait_physics_frames(2)
	var started := bool(enemy.call("_try_start_windup", player))
	_expect(started, "Slash timing fixture must acquire the in-range target.")
	enemy.call("_start_slash", Vector2.RIGHT)
	var health_before_damage_frame := player.current_health
	enemy.call("_update_slash", 0.05)
	_expect(
		player.current_health == health_before_damage_frame,
		"Slash damage must not occur before the second 15 FPS slash frame."
	)
	enemy.call("_update_slash", 0.02)
	_expect(
		player.current_health == health_before_damage_frame - 25,
		(
			"Slash damage must begin when elapsed time crosses 1/15 second "
			+ "(health=%d, damage_done=%s, time_left=%.6f, player=%s, enemy=%s)."
			% [
				player.current_health,
				str(enemy.slash_damage_done),
				enemy.slash_damage_time_left,
				str(player.global_position),
				str(enemy.global_position),
			]
		)
	)
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_automatic_diagonal_contact_slash() -> void:
	var previous_combat_sense_throttling := Enemy.combat_sense_throttling_enabled
	Enemy.combat_sense_throttling_enabled = true
	var player := _spawn_player(Vector2(12, 12))
	var enemy := CARDBOARD_SCENE.instantiate() as CardboardMonster
	# Keep the initial contact hit, but isolate the authored slash from the next
	# 0.5-second contact tick; that cadence has its own focused test below.
	enemy.touch_damage_interval = 99.0
	test_root.add_child(enemy)
	enemy.global_position = Vector2.ZERO
	enemy.setup(CARDBOARD_CONFIG, player, null, fake_runtime)
	var center_distance := enemy.global_position.distance_to(player.global_position)
	_expect(
		center_distance > CARDBOARD_CONFIG.slash_outer_radius,
		"Diagonal contact fixture must keep the target center beyond the 16px slash radius."
	)

	var saw_contact := false
	var saw_windup := false
	var saw_slash := false
	var health_after_contact := player.current_health
	var health_after_slash := player.current_health
	for _physics_step in range(90):
		await physics_frame
		if not saw_contact and enemy.call("_has_player_contact"):
			saw_contact = true
			health_after_contact = player.current_health
		if enemy.combat_state == CapooKnight.CombatState.WINDUP:
			saw_windup = true
			_expect(
				enemy.animated_sprite.animation == &"windup",
				"Automatic diagonal contact must play the authored windup animation."
			)
		elif enemy.combat_state == CapooKnight.CombatState.SLASH:
			saw_slash = true
			_expect(
				enemy.animated_sprite.animation == &"slash",
				"Automatic diagonal contact must play the authored slash animation."
			)
		if enemy.slash_damage_done:
			health_after_slash = player.current_health
			break

	_expect(saw_contact, "Diagonal fixture must produce a real TouchDamageArea overlap.")
	_expect(saw_windup, "A contacted target beyond 16px center distance must automatically enter windup.")
	_expect(saw_slash, "Automatic windup must transition into slash without direct method calls.")
	_expect(
		health_after_contact == 75,
		"Initial diagonal body contact must remain an independent 25-damage hit."
	)
	_expect(
		health_after_slash == health_after_contact - 25,
		"The automatic paper-stick slash must deal a separate 25-damage hit at the contact boundary."
	)

	Enemy.combat_sense_throttling_enabled = previous_combat_sense_throttling
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_automatic_large_plant_contact_slash() -> void:
	var previous_combat_sense_throttling := Enemy.combat_sense_throttling_enabled
	Enemy.combat_sense_throttling_enabled = true
	var plant := AGAVE_SCENE.instantiate() as AgaveCannon
	plant.global_position = Vector2(18, 0)
	test_root.add_child(plant)
	plant.setup(AGAVE_CONFIG, null, [Vector2i.ZERO])
	plant.attack_timer.stop()
	var initial_health := plant.current_health

	var enemy := CARDBOARD_SCENE.instantiate() as CardboardMonster
	enemy.touch_damage_interval = 99.0
	test_root.add_child(enemy)
	enemy.global_position = Vector2.ZERO
	enemy.setup(CARDBOARD_CONFIG, null, null, fake_runtime)
	enemy.set_objective_target(plant)
	_expect(
		enemy.global_position.distance_to(plant.global_position)
			> CARDBOARD_CONFIG.slash_outer_radius,
		"Large-plant fixture must keep the building center beyond the 16px slash radius."
	)

	var saw_plant_contact := false
	var saw_windup := false
	var saw_slash := false
	var health_after_contact := initial_health
	var health_after_slash := initial_health
	for _physics_step in range(90):
		await physics_frame
		if (
			not saw_plant_contact
			and enemy.touching_plants.has(plant.get_instance_id())
		):
			saw_plant_contact = true
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
	_expect(saw_plant_contact, "The 28x27 plant collider must enter the real touch tracker.")
	_expect(saw_windup and saw_slash, "A contacted large plant must automatically reach windup and slash.")
	_expect(contact_damage > 0, "Large-plant body contact must remain independently damaging.")
	_expect(
		slash_damage == contact_damage,
		"The paper-stick slash and body contact must submit the same independent 25 physical damage before defense."
	)

	Enemy.combat_sense_throttling_enabled = previous_combat_sense_throttling
	enemy.queue_free()
	plant.queue_free()
	await physics_frame


func _test_touch_damage_interval() -> void:
	var player := _spawn_player(Vector2.ZERO)
	var enemy := _spawn_cardboard(Vector2.ZERO, player, true)
	enemy.attack_cooldown_left = 99.0
	enemy.call("_on_touch_damage_area_body_entered", player)
	_expect(player.current_health == 75, "Initial body contact must deal 25 physical damage.")
	enemy.set_physics_process(false)
	enemy.call("_physics_process", 0.49)
	_expect(player.current_health == 75, "Touch damage must not repeat before 0.5 seconds.")
	enemy.call("_physics_process", 0.02)
	_expect(player.current_health == 50, "Touch damage must repeat after the 0.5-second interval.")
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.global_position = position
	test_root.add_child(player)
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set("_base_max_health", 100)
	player.max_health = 100
	player.current_health = 100
	player.health_bar.setup(player.max_health, player.current_health)
	return player


func _spawn_cardboard(position: Vector2, player: Player, disable_touch: bool) -> CardboardMonster:
	var enemy := CARDBOARD_SCENE.instantiate() as CardboardMonster
	test_root.add_child(enemy)
	enemy.global_position = position
	if disable_touch:
		enemy.touch_damage_area.monitoring = false
		enemy.touch_damage_area.monitorable = false
	enemy.setup(CARDBOARD_CONFIG, player, null, fake_runtime)
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
