extends SceneTree

const CAPOO_SCENE := preload("res://scene/enemy/capoo_ak47.tscn")
const BULLET_SCENE := preload("res://scene/enemy/capoo_ak47_bullet.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const AGAVE_SCENE := preload("res://scene/plant_defense/agave_cannon.tscn")
const CAPOO_CONFIG := preload("res://resources/config/enemies/capoo_ak47.tres")
const AGAVE_CONFIG := preload("res://resources/config/plant_defense/agave_cannon.tres")
const WAVE_06 := preload("res://resources/config/waves/wave_06.tres")
const WAVE_07 := preload("res://resources/config/waves/wave_07.tres")

var failures: Array[String] = []
var test_root: Node2D
var spawned_projectiles: Array[CapooAK47Bullet] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "CapooAK47SmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	test_root.child_entered_tree.connect(_on_child_entered_tree)

	_test_resource_contract()
	await _test_combat_sense_phase_semantics()
	_test_attack_phase_stagger_contract()
	await _test_two_round_attack_phase_stability()
	await _test_attack_timing_lock_cleanup()
	await _test_windup_and_locked_burst()
	await _test_plant_targeting_and_contact_depth()
	await _test_ranged_standoff_cache_and_fallback()
	await _test_projectile_damage_and_world_collision()
	await _test_death_interrupts_attack()
	await _test_proxy_action_visuals()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("CAPOO_AK47_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_contract() -> void:
	_expect(CAPOO_CONFIG is CapooAK47Config, "AK Capoo config must use CapooAK47Config.")
	_expect(CAPOO_CONFIG.display_name == "AK猫猫虫", "Display name mismatch.")
	_expect(CAPOO_CONFIG.max_health == 150, "AK Capoo health mismatch.")
	_expect(CAPOO_CONFIG.attack_damage == 20, "AK Capoo projectile damage mismatch.")
	_expect(CAPOO_CONFIG.burst_count == 10, "AK Capoo burst count must be 10.")
	_expect(is_equal_approx(CAPOO_CONFIG.attack_windup, 1.5), "AK Capoo windup must be 1.5 seconds.")
	_expect(is_equal_approx(CAPOO_CONFIG.projectile_speed, 142.5), "AK projectile speed mismatch.")
	_expect(CAPOO_CONFIG.enemy_scene == CAPOO_SCENE, "AK Capoo must use its own enemy scene.")
	_expect(CAPOO_CONFIG.projectile_scene == BULLET_SCENE, "AK Capoo must use AK bullet scene.")
	_expect(CAPOO_CONFIG.attack_audio_stream != null, "AK fire audio is missing.")
	var capoo_scene_instance := CAPOO_SCENE.instantiate()
	var attack_audio := capoo_scene_instance.get_node("AttackAudio") as AudioStreamPlayer2D
	var animated_sprite := capoo_scene_instance.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var body_shape := capoo_scene_instance.get_node("CollisionShape2D") as CollisionShape2D
	var touch_shape := capoo_scene_instance.get_node("TouchDamageArea/CollisionShape2D") as CollisionShape2D
	_expect(attack_audio.volume_db <= -16.0, "AK fire audio must stay quiet enough for bursts.")
	_expect(attack_audio.max_polyphony <= 3, "AK fire audio polyphony must avoid noisy overlap.")
	_expect(animated_sprite.scale.x < 0.5 and animated_sprite.scale.y < 0.5, "AK Capoo high resolution sprite must be scene-scaled down.")
	_expect(animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"move"), "AK scene must own its move animation.")
	_expect(body_shape.shape is RectangleShape2D, "AK body collision must be scene-owned rectangle.")
	_expect(touch_shape.shape is RectangleShape2D, "AK touch collision must be scene-owned rectangle.")
	_expect(body_shape.shape != touch_shape.shape, "AK body and touch shapes must be independently editable.")
	capoo_scene_instance.free()
	_expect(_count_wave_entries(WAVE_06) == 0, "Wave 6 must not spawn AK Capoos.")
	_expect(_count_wave_entries(WAVE_07) == 80, "Wave 7 must contain 80 AK Capoos.")

	var texture := load("res://resources/texture/capoo_ak47.png") as Texture2D
	var bullet_texture := load("res://resources/texture/capoo_ak47_bullet.png") as Texture2D
	_expect(texture != null and texture.get_size() == Vector2(384, 384), "AK Capoo sprite sheet size is incorrect.")
	_expect(
		bullet_texture != null and bullet_texture.get_size() == Vector2(24, 8),
		"AK bullet sprite sheet size is incorrect."
	)
	var bullet_instance := BULLET_SCENE.instantiate() as CapooAK47Bullet
	_expect(bullet_instance != null, "AK bullet scene did not instantiate CapooAK47Bullet.")
	if bullet_instance != null:
		var bullet_shape := bullet_instance.get_node_or_null("CollisionShape2D") as CollisionShape2D
		_expect(
			bullet_instance.collision_mask == CapooAK47Bullet.DAMAGEABLE_COLLISION_MASK,
			"AK bullet Area must scan Player and PlantDefense; its cached sweep owns World collision."
		)
		_expect(bullet_shape != null, "AK bullet collision shape must be a direct child of the Area2D.")
		_expect(bullet_shape != null and bullet_shape.shape is RectangleShape2D, "AK bullet collision should use the configured rectangle shape.")
		bullet_instance.free()


func _test_combat_sense_phase_semantics() -> void:
	var saved_sensing_enabled := Enemy.combat_sense_throttling_enabled
	Enemy.combat_sense_throttling_enabled = true
	var phase_players: Array[Player] = []
	var phase_enemies: Array[CapooAK47] = []
	for phase_delay in range(Enemy.DEFAULT_COMBAT_SENSE_UPDATE_INTERVAL_FRAMES):
		var fixture_y := float(phase_delay) * 256.0
		var player := _spawn_player(Vector2(100.0, fixture_y))
		var enemy := _spawn_capoo(Vector2(0.0, fixture_y), player)
		enemy.set_physics_process(false)
		enemy.combat_sense_update_interval_frames = (
			Enemy.DEFAULT_COMBAT_SENSE_UPDATE_INTERVAL_FRAMES
		)
		phase_players.append(player)
		phase_enemies.append(enemy)

	# Spawn helpers attach scenes before assigning their test coordinates. Allow
	# transient origin overlaps to emit their matching body_exited signal first.
	await _wait_physics_frames(2)
	var anchor_frame := Engine.get_physics_frames()
	for phase_delay in range(phase_enemies.size()):
		_expect(
			bool(phase_enemies[phase_delay].call(
				"_has_ranged_combat_line",
				phase_players[phase_delay],
				1,
				true
			)),
			"AK sensing phase fixture must start with a clear cached combat line."
		)
		phase_enemies[phase_delay].navigation_update_frame_offset = posmod(
			-(anchor_frame + phase_delay),
			Enemy.DEFAULT_COMBAT_SENSE_UPDATE_INTERVAL_FRAMES
		)

	var observed_delays: Array[int] = [-1, -1, -1]
	for tick_offset in range(Enemy.DEFAULT_COMBAT_SENSE_UPDATE_INTERVAL_FRAMES):
		for enemy_index in range(phase_enemies.size()):
			var enemy := phase_enemies[enemy_index]
			enemy.call("_physics_process", 1.0 / 60.0)
			if (
				observed_delays[enemy_index] < 0
				and enemy.combat_state != CapooAK47.CombatState.CHASE
			):
				observed_delays[enemy_index] = tick_offset
		if tick_offset + 1 < Enemy.DEFAULT_COMBAT_SENSE_UPDATE_INTERVAL_FRAMES:
			await physics_frame
	_expect(
		observed_delays == [0, 1, 2],
		(
			"AK 20 Hz combat sensing must distribute attack acquisition over "
			+ "offsets 0, 1 and 2; observed=%s."
		) % [observed_delays]
	)

	Enemy.combat_sense_throttling_enabled = false
	var unthrottled_player := _spawn_player(Vector2(100.0, 768.0))
	var unthrottled_enemy := _spawn_capoo(Vector2(0.0, 768.0), unthrottled_player)
	unthrottled_enemy.set_physics_process(false)
	await _wait_physics_frames(2)
	unthrottled_enemy.navigation_update_frame_offset = posmod(
		1 - Engine.get_physics_frames(),
		Enemy.DEFAULT_COMBAT_SENSE_UPDATE_INTERVAL_FRAMES
	)
	_expect(
		(
			Engine.get_physics_frames()
			+ unthrottled_enemy.navigation_update_frame_offset
		) % Enemy.DEFAULT_COMBAT_SENSE_UPDATE_INTERVAL_FRAMES != 0,
		"Unthrottled AK fixture must begin on a normally skipped sensing phase."
	)
	_expect(
		bool(unthrottled_enemy.call(
			"_has_ranged_combat_line",
			unthrottled_player,
			1,
			true
		)),
		"Unthrottled AK fixture must start with a clear cached combat line."
	)
	unthrottled_enemy.call("_physics_process", 1.0 / 60.0)
	_expect(
		unthrottled_enemy.combat_state == CapooAK47.CombatState.WINDUP,
		"Disabling combat-sense throttling must restore AK attack acquisition on the current tick."
	)
	var sensed_every_tick := true
	for tick_index in range(3):
		sensed_every_tick = (
			sensed_every_tick
			and bool(unthrottled_enemy.call("_is_combat_sense_refresh_due"))
		)
		if tick_index < 2:
			await physics_frame
	_expect(
		sensed_every_tick,
		"Disabling combat-sense throttling must make the AK sensing gate due every physics tick."
	)

	Enemy.combat_sense_throttling_enabled = saved_sensing_enabled
	for enemy in phase_enemies:
		enemy.queue_free()
	for player in phase_players:
		player.queue_free()
	unthrottled_enemy.queue_free()
	unthrottled_player.queue_free()
	await physics_frame


func _test_attack_phase_stagger_contract() -> void:
	_expect(
		CapooAK47.attack_phase_stagger_enabled,
		"AK deterministic attack phase staggering must be enabled by default."
	)
	var offsets: Array[int] = []
	var offset_sum := 0
	var minimum_offset := 100
	var maximum_offset := -100
	var authored_cycles_preserved := true
	for phase_identity in range(5):
		var offset := CapooAK47.calculate_attack_phase_offset_physics_frames(
			phase_identity
		)
		var offset_seconds := CapooAK47.calculate_attack_phase_offset_seconds(
			phase_identity,
			60
		)
		offsets.append(offset)
		offset_sum += offset
		minimum_offset = mini(minimum_offset, offset)
		maximum_offset = maxi(maximum_offset, offset)
		authored_cycles_preserved = (
			authored_cycles_preserved
			and is_equal_approx(
				CAPOO_CONFIG.attack_windup
				+ offset_seconds
				+ CAPOO_CONFIG.attack_interval
				- offset_seconds,
				CAPOO_CONFIG.attack_windup + CAPOO_CONFIG.attack_interval
			)
		)
	_expect(
		offsets == [0, -1, 1, -2, 2]
		and offset_sum == 0
		and minimum_offset == -2
		and maximum_offset == 2
		and authored_cycles_preserved,
		"AK attack phases must be center-first, zero-mean, and bounded to +/-2 physics ticks."
	)

	var baseline_buckets: Dictionary[int, int] = {}
	var staggered_buckets: Dictionary[int, int] = {}
	var baseline_first_tick_sum := 0
	var staggered_first_tick_sum := 0
	var windup_ticks := roundi(CAPOO_CONFIG.attack_windup * 60.0)
	for phase_identity in range(15):
		var sensing_delay := posmod(
			-phase_identity,
			Enemy.DEFAULT_COMBAT_SENSE_UPDATE_INTERVAL_FRAMES
		)
		var baseline_first_tick := sensing_delay + windup_ticks + 1
		var staggered_first_tick := (
			baseline_first_tick
			+ CapooAK47.calculate_attack_phase_offset_physics_frames(phase_identity)
		)
		baseline_first_tick_sum += baseline_first_tick
		staggered_first_tick_sum += staggered_first_tick
		baseline_buckets[baseline_first_tick] = int(
			baseline_buckets.get(baseline_first_tick, 0)
		) + 1
		staggered_buckets[staggered_first_tick] = int(
			staggered_buckets.get(staggered_first_tick, 0)
		) + 1
	_expect(
		baseline_first_tick_sum == staggered_first_tick_sum,
		"Combining three sensing phases with five attack phases must preserve average first-fire delay."
	)
	_expect(
		_get_peak_bucket_count(baseline_buckets) == 5
		and _get_peak_bucket_count(staggered_buckets) <= 3,
		"Five centered attack phases must lower a synchronized first-fire bucket from 5/15 to at most 3/15."
	)


func _test_two_round_attack_phase_stability() -> void:
	var saved_stagger_enabled := CapooAK47.attack_phase_stagger_enabled
	var saved_sensing_enabled := Enemy.combat_sense_throttling_enabled
	CapooAK47.attack_phase_stagger_enabled = true
	Enemy.combat_sense_throttling_enabled = true
	var fast_config := CAPOO_CONFIG.duplicate(true) as CapooAK47Config
	fast_config.attack_windup = 0.1
	fast_config.attack_interval = 0.2
	fast_config.burst_count = 1
	fast_config.projectile_lifetime = 0.1

	var player := _spawn_player(Vector2(120.0, 0.0))
	player.max_health = 1_000_000
	player.current_health = player.max_health
	var phase_minus_two := _spawn_capoo_with_config(Vector2(0.0, -24.0), player, fast_config)
	var phase_zero := _spawn_capoo_with_config(Vector2.ZERO, player, fast_config)
	var phase_plus_two := _spawn_capoo_with_config(Vector2(0.0, 24.0), player, fast_config)
	phase_minus_two.set_physics_process(false)
	phase_zero.set_physics_process(false)
	phase_plus_two.set_physics_process(false)
	# Offsets 3, 0 and 9 share the same 20 Hz sensing phase while selecting
	# attack offsets -2, 0 and +2 respectively.
	phase_minus_two.navigation_update_frame_offset = 3
	phase_zero.navigation_update_frame_offset = 0
	phase_plus_two.navigation_update_frame_offset = 9
	await physics_frame
	while Engine.get_physics_frames() % Enemy.DEFAULT_COMBAT_SENSE_UPDATE_INTERVAL_FRAMES != 0:
		await physics_frame

	_expect(
		bool(phase_minus_two.call("_try_start_windup", player))
		and bool(phase_zero.call("_try_start_windup", player))
		and bool(phase_plus_two.call("_try_start_windup", player)),
		"All two-round phase fixtures must enter windup on the same sensing tick."
	)
	var minus_two_cycle_sum := (
		phase_minus_two.committed_windup_duration_seconds
		+ fast_config.attack_interval
		- phase_minus_two.committed_attack_phase_offset_seconds
	)
	var zero_cycle_sum := (
		phase_zero.committed_windup_duration_seconds
		+ fast_config.attack_interval
		- phase_zero.committed_attack_phase_offset_seconds
	)
	var plus_two_cycle_sum := (
		phase_plus_two.committed_windup_duration_seconds
		+ fast_config.attack_interval
		- phase_plus_two.committed_attack_phase_offset_seconds
	)
	_expect(
		is_equal_approx(
			minus_two_cycle_sum,
			fast_config.attack_windup + fast_config.attack_interval
		)
		and is_equal_approx(
			zero_cycle_sum,
			fast_config.attack_windup + fast_config.attack_interval
		)
		and is_equal_approx(
			plus_two_cycle_sum,
			fast_config.attack_windup + fast_config.attack_interval
		),
		"Windup phase offsets and cooldown compensation must preserve the authored cycle sum."
	)
	phase_minus_two.set_physics_process(true)
	phase_zero.set_physics_process(true)
	phase_plus_two.set_physics_process(true)

	var minus_two_burst_frames: Array[int] = []
	var zero_burst_frames: Array[int] = []
	var plus_two_burst_frames: Array[int] = []
	for _frame_index in range(180):
		await physics_frame
		var current_frame := Engine.get_physics_frames()
		if phase_minus_two.action_sequence >= 2 and minus_two_burst_frames.is_empty():
			minus_two_burst_frames.append(current_frame)
		elif (
			phase_minus_two.action_sequence >= 4
			and minus_two_burst_frames.size() == 1
		):
			minus_two_burst_frames.append(current_frame)
		if phase_zero.action_sequence >= 2 and zero_burst_frames.is_empty():
			zero_burst_frames.append(current_frame)
		elif phase_zero.action_sequence >= 4 and zero_burst_frames.size() == 1:
			zero_burst_frames.append(current_frame)
		if phase_plus_two.action_sequence >= 2 and plus_two_burst_frames.is_empty():
			plus_two_burst_frames.append(current_frame)
		elif (
			phase_plus_two.action_sequence >= 4
			and plus_two_burst_frames.size() == 1
		):
			plus_two_burst_frames.append(current_frame)
		if (
			minus_two_burst_frames.size() == 2
			and zero_burst_frames.size() == 2
			and plus_two_burst_frames.size() == 2
		):
			break
	_expect(
		minus_two_burst_frames.size() == 2
		and zero_burst_frames.size() == 2
		and plus_two_burst_frames.size() == 2,
		"All three attack phases must commit two complete burst starts."
	)
	if (
		minus_two_burst_frames.size() == 2
		and zero_burst_frames.size() == 2
		and plus_two_burst_frames.size() == 2
	):
		var first_minus_phase_gap := minus_two_burst_frames[0] - zero_burst_frames[0]
		var second_minus_phase_gap := minus_two_burst_frames[1] - zero_burst_frames[1]
		var first_phase_gap := plus_two_burst_frames[0] - zero_burst_frames[0]
		var second_phase_gap := plus_two_burst_frames[1] - zero_burst_frames[1]
		var minus_two_period := minus_two_burst_frames[1] - minus_two_burst_frames[0]
		var zero_period := zero_burst_frames[1] - zero_burst_frames[0]
		var plus_two_period := plus_two_burst_frames[1] - plus_two_burst_frames[0]
		_expect(
			first_minus_phase_gap == -2
			and second_minus_phase_gap == first_minus_phase_gap
			and first_phase_gap == 2
			and second_phase_gap == first_phase_gap
			and minus_two_period == zero_period
			and zero_period == plus_two_period,
			"The -2/+2 phases must persist through round two without changing or drifting the authored attack period."
		)

	phase_minus_two.queue_free()
	phase_zero.queue_free()
	phase_plus_two.queue_free()
	player.queue_free()
	await physics_frame
	CapooAK47.attack_phase_stagger_enabled = saved_stagger_enabled
	Enemy.combat_sense_throttling_enabled = saved_sensing_enabled


func _test_attack_timing_lock_cleanup() -> void:
	var saved_stagger_enabled := CapooAK47.attack_phase_stagger_enabled
	CapooAK47.attack_phase_stagger_enabled = true
	var player := _spawn_player(Vector2(120.0, 0.0))
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	enemy.set_physics_process(false)
	enemy.navigation_update_frame_offset = 9
	await physics_frame

	_expect(
		bool(enemy.call("_try_start_windup", player))
		and enemy.committed_attack_phase_offset_seconds > 0.0,
		"Cleanup fixture must lock a non-zero attack phase."
	)
	enemy.call("_cancel_attack")
	_expect(
		enemy.windup_time_left == 0.0
		and enemy.committed_attack_phase_offset_seconds == 0.0
		and enemy.committed_windup_duration_seconds == 0.0,
		"Cancelling an attack must clear every committed timing field."
	)

	CapooAK47.attack_phase_stagger_enabled = false
	_expect(
		bool(enemy.call("_try_start_windup", player))
		and enemy.committed_attack_phase_offset_seconds == 0.0,
		"The static A/B switch must make the next windup use the authored zero phase."
	)
	CapooAK47.attack_phase_stagger_enabled = true
	enemy.call("_update_windup", CAPOO_CONFIG.attack_windup)
	_expect(
		is_equal_approx(enemy.attack_cooldown_left, CAPOO_CONFIG.attack_interval),
		"Changing the A/B switch mid-windup must not break the locked windup/cooldown pair."
	)

	enemy.setup(CAPOO_CONFIG, player)
	enemy.set_physics_process(false)
	_expect(
		enemy.combat_state == CapooAK47.CombatState.CHASE
		and enemy.committed_attack_phase_offset_seconds == 0.0
		and enemy.committed_windup_duration_seconds == 0.0,
		"Reapplying configuration must clear committed attack timing."
	)
	_expect(
		bool(enemy.call("_try_start_windup", player)),
		"Reconfigured cleanup fixture must be able to enter windup again."
	)
	enemy.apply_damage(CAPOO_CONFIG.max_health + 10)
	_expect(
		enemy.committed_attack_phase_offset_seconds == 0.0
		and enemy.committed_windup_duration_seconds == 0.0,
		"Death must clear committed attack timing immediately."
	)

	if is_instance_valid(enemy):
		enemy.queue_free()
	player.queue_free()
	await physics_frame
	CapooAK47.attack_phase_stagger_enabled = saved_stagger_enabled


func _test_windup_and_locked_burst() -> void:
	spawned_projectiles.clear()
	var player := _spawn_player(Vector2(120.0, 0.0))
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	await _wait_physics_frames(8)

	_expect(enemy.combat_state == CapooAK47.CombatState.WINDUP, "AK Capoo did not enter windup at medium range.")
	_expect(spawned_projectiles.is_empty(), "AK Capoo fired during early windup.")
	await _wait_physics_frames(45)
	_expect(spawned_projectiles.is_empty(), "AK Capoo fired before windup completed.")

	while enemy.combat_state == CapooAK47.CombatState.WINDUP:
		await physics_frame
	player.global_position = Vector2(120.0, 80.0)
	await _wait_physics_frames(70)

	_expect(spawned_projectiles.size() == CAPOO_CONFIG.burst_count, "AK Capoo did not fire exactly 10 bullets.")
	if not spawned_projectiles.is_empty() and is_instance_valid(spawned_projectiles[0]):
		_expect(
			spawned_projectiles[0].direction.dot(Vector2.RIGHT) > 0.99,
			"AK Capoo burst did not lock the windup-finished direction."
		)

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_projectile_damage_and_world_collision() -> void:
	var player := _spawn_player(Vector2(20.0, 0.0))
	player.invincibility_duration = 0.0
	player.current_health = 5
	var projectile := _spawn_projectile(Vector2.ZERO, Vector2.RIGHT)
	projectile.call("_on_body_entered", player)
	await physics_frame
	_expect(player.current_health == 4, "AK bullet did not deal 1 damage to the player.")
	_expect(not is_instance_valid(projectile), "AK bullet remained after hitting player.")

	var plant := _spawn_agave(Vector2(20.0, 40.0))
	var plant_health_before := plant.current_health
	var plant_projectile := _spawn_projectile(Vector2.ZERO, Vector2.RIGHT)
	plant_projectile.damage = 20
	plant_projectile.call("_on_body_entered", plant)
	await physics_frame
	_expect(
		plant.current_health == plant_health_before - 10,
		"AK bullet must damage a plant through its authored physical defense."
	)
	_expect(not is_instance_valid(plant_projectile), "AK bullet remained after hitting a plant.")

	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	var wall_shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 5.0
	wall_shape.shape = circle
	wall.add_child(wall_shape)
	test_root.add_child(wall)
	wall.global_position = Vector2(12.0, 0.0)

	var wall_projectile := _spawn_projectile(Vector2.ZERO, Vector2.RIGHT)
	await _wait_physics_frames(8)
	_expect(not is_instance_valid(wall_projectile), "AK bullet did not disappear on World collision.")

	wall.queue_free()
	plant.queue_free()
	player.queue_free()
	await physics_frame


func _test_plant_targeting_and_contact_depth() -> void:
	var player := _spawn_player(Vector2(400.0, 0.0))
	var plant := _spawn_agave(Vector2(100.0, 0.0))
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	enemy.set_physics_process(false)
	enemy.set_objective_target(plant)
	_expect(enemy.has_attackable_objective(), "A living plant must be an attackable enemy objective.")
	_expect(
		bool(enemy.call("_try_start_windup")),
		"AK Capoo must begin its ranged windup when a targeted plant is in range."
	)

	var gate := Node2D.new()
	test_root.add_child(gate)
	enemy.set_objective_target(gate)
	_expect(not enemy.has_attackable_objective(), "A Home/navigation node must not become a ranged attack target.")
	enemy.call("_cancel_attack")

	enemy.set_objective_target(plant)
	enemy.global_position = plant.global_position + Vector2(23.0, 0.0)
	enemy.call("_on_touch_damage_area_body_entered", plant)
	_expect(
		not bool(enemy.call("_has_player_contact")),
		"Initial plant overlap must not stop the enemy at the outer visual edge."
	)
	_expect(
		is_equal_approx(plant.get_enemy_approach_depth(), 6.0),
		"Agave must author a deeper six-pixel enemy approach inset."
	)
	enemy.global_position = plant.global_position + Vector2(18.0, 0.0)
	_expect(
		not bool(enemy.call("_has_player_contact")),
		"Agave contact must preserve the full six-pixel approach depth."
	)
	enemy.global_position = plant.global_position + Vector2(17.0, 0.0)
	_expect(
		bool(enemy.call("_has_player_contact")),
		"Enemy must stop after pressing six pixels into the Agave contact boundary."
	)

	enemy.queue_free()
	plant.queue_free()
	player.queue_free()
	gate.queue_free()
	await physics_frame


func _test_ranged_standoff_cache_and_fallback() -> void:
	var player := _spawn_player(Vector2(120.0, 0.0))
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	enemy.set_physics_process(false)
	var gate := Node2D.new()
	test_root.add_child(gate)
	enemy.set_objective_target(gate)
	var preferred_target := enemy.call("_get_preferred_ranged_combat_target") as Node2D
	_expect(
		preferred_target == player,
		"A navigation-only objective must fall back to the living player for ranged combat."
	)
	_expect(
		bool(enemy.call(
			"_is_ranged_combat_target_in_range",
			player,
			CAPOO_CONFIG.attack_range
		)),
		"Ranged combat range checks must accept the fallback player."
	)

	Enemy.set_performance_metrics_enabled(true)
	_expect(
		bool(enemy.call("_has_ranged_combat_line", player, 1, true)),
		"An exact ranged LOS commit must accept an unobstructed player."
	)
	var first_metrics := Enemy.get_performance_metrics()
	_expect(
		int(first_metrics["ranged_los_calls"]) == 1,
		"An exact ranged LOS commit must publish one measurable ray query."
	)
	_expect(
		bool(enemy.call("_has_ranged_combat_line", player, 1, false)),
		"A clear ranged LOS result must be cached."
	)
	var cached_metrics := Enemy.get_performance_metrics()
	_expect(
		int(cached_metrics["ranged_los_calls"]) == 1,
		"Reading a seeded ranged LOS cache in the same frame must not cast again."
	)
	enemy.cached_navigation_move_direction = Vector2.RIGHT
	_expect(
		bool(enemy.call(
			"_try_hold_ranged_attack_position",
			player,
			CAPOO_CONFIG.attack_range,
			1
		))
		and enemy.cached_navigation_move_direction == Vector2.ZERO,
		"Entering ranged standoff must clear the previous navigation direction once."
	)
	enemy.cached_navigation_move_direction = Vector2.LEFT
	enemy.call(
		"_try_hold_ranged_attack_position",
		player,
		CAPOO_CONFIG.attack_range,
		1
	)
	_expect(
		enemy.cached_navigation_move_direction == Vector2.LEFT,
		"Remaining in ranged standoff must not clear navigation every physics tick."
	)

	var wall := _spawn_world_wall(Vector2(60.0, 0.0), 8.0)
	await physics_frame
	_expect(
		not bool(enemy.call("_has_ranged_combat_line", player, 1, true)),
		"A forced attack commit must replace a clear cache when a wall appears."
	)
	var blocked_metrics := Enemy.get_performance_metrics()
	_expect(
		int(blocked_metrics["ranged_los_calls"]) == 2
		and not bool(enemy.call("_has_ranged_combat_line", player, 1, false)),
		"Blocked ranged LOS must be cached and included in performance metrics."
	)
	_expect(
		not bool(enemy.call(
			"_try_hold_ranged_attack_position",
			player,
			CAPOO_CONFIG.attack_range,
			1
		)),
		"A blocked ranged target must release standoff so navigation can resume."
	)
	enemy.cached_navigation_move_direction = Vector2.UP
	enemy.call("_reset_ranged_attack_position_state")
	_expect(
		enemy.cached_navigation_move_direction == Vector2.UP,
		"Resetting an already released standoff must not clear navigation again."
	)
	Enemy.set_performance_metrics_enabled(false)

	enemy.queue_free()
	wall.queue_free()
	gate.queue_free()
	player.queue_free()
	await physics_frame


func _test_death_interrupts_attack() -> void:
	spawned_projectiles.clear()
	var player := _spawn_player(Vector2(120.0, 0.0))
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	await _wait_physics_frames(8)

	_expect(enemy.combat_state == CapooAK47.CombatState.WINDUP, "Death test enemy did not enter windup.")
	enemy.apply_damage(CAPOO_CONFIG.max_health + 10)
	await _wait_physics_frames(120)
	_expect(spawned_projectiles.is_empty(), "Dead AK Capoo fired after attack interruption.")

	if is_instance_valid(enemy):
		enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_proxy_action_visuals() -> void:
	var player := _spawn_player(Vector2(120.0, 0.0))
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	var projectile_count_before := spawned_projectiles.size()
	enemy.configure_multiplayer_proxy()
	enemy.play_multiplayer_enemy_action(&"windup", Vector2.RIGHT, 1)
	await process_frame
	_expect(enemy.muzzle_heat.visible, "Proxy AK windup muzzle heat did not appear.")
	enemy.play_multiplayer_enemy_action(&"burst", Vector2.LEFT, 2)
	await process_frame
	_expect(enemy.muzzle_heat.visible, "Proxy AK burst muzzle heat did not appear.")
	_expect(
		Vector2.RIGHT.rotated(enemy.muzzle_heat.rotation).dot(Vector2.LEFT) > 0.99,
		"Stale proxy AK windup tween must not override newer burst direction."
	)
	await physics_frame
	_expect(
		spawned_projectiles.size() == projectile_count_before
		and not enemy.is_physics_processing(),
		"A multiplayer proxy must remain presentation-only and never emit authoritative bullets."
	)
	enemy.play_multiplayer_death_sequence()
	await process_frame
	_expect(
		not enemy.muzzle_heat.visible
		and enemy.committed_attack_phase_offset_seconds == 0.0
		and enemy.committed_windup_duration_seconds == 0.0,
		"Proxy AK death must clear muzzle heat and any local timing lock."
	)
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	return player


func _spawn_capoo(position: Vector2, player: Player) -> CapooAK47:
	return _spawn_capoo_with_config(position, player, CAPOO_CONFIG)


func _spawn_capoo_with_config(
	position: Vector2,
	player: Player,
	enemy_config: CapooAK47Config
) -> CapooAK47:
	var enemy := CAPOO_SCENE.instantiate() as CapooAK47
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(enemy_config, player)
	return enemy


func _spawn_agave(position: Vector2) -> AgaveCannon:
	var plant := AGAVE_SCENE.instantiate() as AgaveCannon
	test_root.add_child(plant)
	plant.global_position = position
	plant.setup(AGAVE_CONFIG, null, [Vector2i.ZERO])
	return plant


func _spawn_projectile(position: Vector2, direction: Vector2) -> CapooAK47Bullet:
	var projectile := BULLET_SCENE.instantiate() as CapooAK47Bullet
	test_root.add_child(projectile)
	projectile.global_position = position
	projectile.setup(direction, 1, CAPOO_CONFIG.projectile_speed, CAPOO_CONFIG.projectile_lifetime)
	return projectile


func _spawn_world_wall(position: Vector2, radius: float) -> StaticBody2D:
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


func _count_wave_entries(wave_config: WaveConfig) -> int:
	var total := 0
	for entry in wave_config.enemy_entries:
		if entry != null and entry.enemy_config == CAPOO_CONFIG:
			total += entry.count
	return total


func _get_peak_bucket_count(buckets: Dictionary[int, int]) -> int:
	var peak := 0
	for count in buckets.values():
		peak = maxi(peak, int(count))
	return peak


func _on_child_entered_tree(child: Node) -> void:
	var projectile := child as CapooAK47Bullet
	if projectile != null:
		spawned_projectiles.append(projectile)


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
