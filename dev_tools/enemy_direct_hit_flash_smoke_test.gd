extends SceneTree

const BASIC_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const SLIME_CONFIG := preload("res://resources/config/enemies/slime.tres")
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const ENEMY_CONFIG_DIRECTORY := "res://resources/config/enemies"
const STATUS_SHADER_PATH := (
	"res://scene/combat/feedback/shaders/entity_motion_status.gdshader"
)
const FLASH_PARAMETER := &"direct_hit_flash_strength"
const EXPECTED_FLASH_ENTRY_STRENGTH := 0.08
const EXPECTED_FLASH_PEAK_STRENGTH := 0.56
const EXPECTED_FLASH_FADE_IN_SECONDS := 0.01
const EXPECTED_FLASH_HOLD_SECONDS := 0.02
const EXPECTED_FLASH_FADE_OUT_SECONDS := 0.04
const EXPECTED_FLASH_DURATION_SECONDS := 0.07
const STRESS_ENEMY_COUNT := 1000
const STRESS_FLASH_COUNT := 256

var failures: Array[String] = []
var test_root: Node2D
var hit_flash_scheduler: Node


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "EnemyDirectHitFlashSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	hit_flash_scheduler = root.get_node_or_null("EnemyHitFlashScheduler")
	_expect(hit_flash_scheduler != null, "EnemyHitFlashScheduler autoload must exist.")
	if hit_flash_scheduler == null:
		await _finish()
		return
	hit_flash_scheduler.call("clear_all")

	_test_shader_contract()
	await _test_direct_and_suppressed_damage_contract()
	await _test_scheduler_timing_and_retrigger_contract()
	await _test_peak_render_frame_guard_contract()
	await _test_reparent_during_flash_contract()
	await _test_periodic_status_contract()
	await _test_lethal_and_proxy_contract()
	await _test_all_enemy_scene_contract()
	await _test_idle_and_concurrent_stress_contract()
	await _test_shared_player_shader_default_contract()

	await _finish()


func _finish() -> void:
	if hit_flash_scheduler != null:
		hit_flash_scheduler.call("clear_all")
	current_scene = null
	if test_root != null:
		test_root.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("ENEMY_DIRECT_HIT_FLASH_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_shader_contract() -> void:
	var shader_file := FileAccess.open(STATUS_SHADER_PATH, FileAccess.READ)
	_expect(shader_file != null, "Shared enemy status shader must be readable.")
	if shader_file == null:
		return
	var source := shader_file.get_as_text()
	var flash_uniform := source.find(
		"instance uniform float direct_hit_flash_strength"
	)
	var flash_color := source.find(
		"direct_hit_flash_color : source_color = vec4(1.0, 0.24, 0.26, 1.0)"
	)
	var flash_block := source.find("if (direct_hit_flash_strength")
	var revive_block := source.find("vec4 pre_revive_color")
	_expect(flash_uniform >= 0, "Direct-hit strength must be an instance uniform.")
	_expect(flash_color >= 0, "Direct-hit flash must use the approved pale blood red.")
	_expect(
		flash_block >= 0 and flash_block < revive_block,
		"Direct-hit red must compose after persistent statuses and before revive outline handling."
	)
	if flash_block >= 0 and revive_block > flash_block:
		var block := source.substr(flash_block, revive_block - flash_block)
		_expect(
			block.contains("texture_color.a > 0.0"),
			"Direct-hit flash must affect only authored body pixels."
		)


func _test_direct_and_suppressed_damage_contract() -> void:
	var enemy := _spawn_enemy(BASIC_CONFIG)
	if enemy == null:
		return
	var direct_request := DamageRequest.new(1, CombatTypes.DamageType.PHYSICAL)
	direct_request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	var direct_result := enemy.apply_combat_damage(direct_request)
	_expect(
		direct_result.accepted
		and direct_result.applied_damage > 0
		and is_equal_approx(
			enemy.direct_hit_flash_strength,
			EXPECTED_FLASH_ENTRY_STRENGTH
		),
		"An accepted direct hit must start the approved pale-red entry transition even when particles are suppressed."
	)
	_expect(
		enemy.animated_sprite.material == enemy.status_visual_material,
		"A flashing enemy must temporarily attach its shared status material."
	)
	hit_flash_scheduler.call("clear_target", enemy, true)

	var zero_direction_request := DamageRequest.new(1, CombatTypes.DamageType.MAGIC)
	zero_direction_request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	zero_direction_request.with_directions(Vector2.ZERO)
	var zero_direction_result := enemy.apply_combat_damage(zero_direction_request)
	_expect(
		zero_direction_result.accepted
		and is_equal_approx(
			enemy.direct_hit_flash_strength,
			EXPECTED_FLASH_ENTRY_STRENGTH
		),
		"A directionless but explicit attack must still flash."
	)
	hit_flash_scheduler.call("clear_target", enemy, true)

	var suppressed_request := DamageRequest.new(1)
	suppressed_request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	suppressed_request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_FLASH)
	var suppressed_result := enemy.apply_combat_damage(suppressed_request)
	_expect(
		suppressed_result.accepted
		and is_zero_approx(enemy.direct_hit_flash_strength)
		and int(hit_flash_scheduler.call("get_active_target_count")) == 0,
		"SUPPRESS_HIT_FLASH must independently suppress red without rejecting damage."
	)

	var batch_request := DamageBatchRequest.new(
		PackedInt64Array([1, 1]),
		PackedInt32Array([2, 3]),
		CombatTypes.DamageType.PHYSICAL
	)
	batch_request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	var batch_result := enemy.apply_combat_damage(batch_request)
	_expect(
		batch_result.accepted
		and batch_result.accepted_hit_count == 5
		and int(hit_flash_scheduler.call("get_active_target_count")) == 1,
		"One accepted DamageBatchRequest must create one flash state, not one per hit."
	)
	hit_flash_scheduler.call("clear_target", enemy, true)
	enemy.queue_free()
	await process_frame


func _test_scheduler_timing_and_retrigger_contract() -> void:
	_expect(
		EXPECTED_FLASH_HOLD_SECONDS >= 1.0 / 60.0,
		"The peak window must span at least one complete 60 Hz frame."
	)
	var enemy := _spawn_enemy(BASIC_CONFIG)
	if enemy == null:
		return
	enemy.play_multiplayer_damage_feedback(
		Vector2.ZERO,
		CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
	)
	_expect(
		is_equal_approx(
			enemy.direct_hit_flash_strength,
			EXPECTED_FLASH_ENTRY_STRENGTH
		),
		"A direct hit must begin at the low-opacity entry strength."
	)
	# advance_for_test() intentionally bypasses this safeguard, so exercise the
	# real path with a hitch-sized delta in the same Engine process frame.
	hit_flash_scheduler.call("_advance", 1.0, false)
	_expect(
		is_equal_approx(
			enemy.direct_hit_flash_strength,
			EXPECTED_FLASH_ENTRY_STRENGTH
		)
		and int(hit_flash_scheduler.call("get_active_target_count")) == 1,
		"A same-frame hitch must preserve the entry flash through at least one render opportunity."
	)
	hit_flash_scheduler.call(
		"advance_for_test",
		EXPECTED_FLASH_FADE_IN_SECONDS * 0.5
	)
	var entering_strength := enemy.direct_hit_flash_strength
	_expect(
		entering_strength > EXPECTED_FLASH_ENTRY_STRENGTH
		and entering_strength < EXPECTED_FLASH_PEAK_STRENGTH,
		"The first 0.01 seconds must rise smoothly from the low-opacity entry."
	)
	hit_flash_scheduler.call(
		"advance_for_test",
		EXPECTED_FLASH_FADE_IN_SECONDS * 0.5
	)
	_expect(
		is_equal_approx(
			enemy.direct_hit_flash_strength,
			EXPECTED_FLASH_PEAK_STRENGTH
		),
		"The fade-in must reach the reduced peak at 0.01 seconds."
	)
	hit_flash_scheduler.call(
		"advance_for_test",
		EXPECTED_FLASH_HOLD_SECONDS
	)
	_expect(
		is_equal_approx(
			enemy.direct_hit_flash_strength,
			EXPECTED_FLASH_PEAK_STRENGTH
		),
		"The peak must remain stable for the 0.02-second hold."
	)
	hit_flash_scheduler.call(
		"advance_for_test",
		EXPECTED_FLASH_FADE_OUT_SECONDS * 0.5
	)
	var fading_strength := enemy.direct_hit_flash_strength
	_expect(
		fading_strength > 0.0
		and fading_strength < EXPECTED_FLASH_PEAK_STRENGTH,
		"The final 0.04 seconds must fade smoothly from the reduced peak."
	)
	enemy.play_multiplayer_damage_feedback(
		Vector2.ZERO,
		CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
	)
	_expect(
		enemy.direct_hit_flash_strength >= fading_strength
		and int(hit_flash_scheduler.call("get_active_target_count")) == 1,
		"Rapid re-hits must restart one existing state without dimming or stacking scheduler entries."
	)
	hit_flash_scheduler.call(
		"advance_for_test",
		EXPECTED_FLASH_FADE_IN_SECONDS
	)
	_expect(
		is_equal_approx(
			enemy.direct_hit_flash_strength,
			EXPECTED_FLASH_PEAK_STRENGTH
		),
		"A rapid re-hit must rise back to the approved peak."
	)
	hit_flash_scheduler.call(
		"advance_for_test",
		EXPECTED_FLASH_DURATION_SECONDS
	)
	_expect(
		is_zero_approx(enemy.direct_hit_flash_strength)
		and enemy.animated_sprite.material == null
		and int(hit_flash_scheduler.call("get_active_target_count")) == 0
		and not hit_flash_scheduler.is_processing(),
		"After the 0.07-second transition the flash must clear and restore the unmaterialed batching path."
	)
	enemy.queue_free()
	await process_frame


func _test_peak_render_frame_guard_contract() -> void:
	var enemy := _spawn_enemy(BASIC_CONFIG)
	if enemy == null:
		return
	enemy.play_multiplayer_damage_feedback(
		Vector2.ZERO,
		CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
	)
	# Drive the real-path guard manually so a hitch-sized delta cannot skip from
	# the entry directly to clear. Disabling automatic processing keeps the
	# render-frame boundaries deterministic for this contract test.
	hit_flash_scheduler.set_process(false)
	hit_flash_scheduler.call("_advance", 1.0, false)
	_expect(
		is_equal_approx(
			enemy.direct_hit_flash_strength,
			EXPECTED_FLASH_ENTRY_STRENGTH
		),
		"The trigger frame must retain the visible entry even during a hitch."
	)
	await process_frame
	hit_flash_scheduler.call("_advance", 1.0, false)
	hit_flash_scheduler.set_process(false)
	_expect(
		is_equal_approx(
			enemy.direct_hit_flash_strength,
			EXPECTED_FLASH_PEAK_STRENGTH
		)
		and int(hit_flash_scheduler.call("get_active_target_count")) == 1,
		"The first frame after a hitch must present the peak instead of skipping it."
	)
	await process_frame
	_expect(
		is_equal_approx(
			enemy.direct_hit_flash_strength,
			EXPECTED_FLASH_PEAK_STRENGTH
		),
		"The guarded peak must survive one complete render opportunity."
	)
	hit_flash_scheduler.call("_advance", 1.0, false)
	_expect(
		is_equal_approx(
			enemy.direct_hit_flash_strength,
			EXPECTED_FLASH_ENTRY_STRENGTH
		)
		and int(hit_flash_scheduler.call("get_active_target_count")) == 1,
		"A hitch that skips the fade must present one low-strength tail instead of dropping directly from peak to clear."
	)
	await process_frame
	_expect(
		is_equal_approx(
			enemy.direct_hit_flash_strength,
			EXPECTED_FLASH_ENTRY_STRENGTH
		),
		"The hitch tail must survive one complete render opportunity."
	)
	hit_flash_scheduler.call("_advance", 1.0, false)
	_expect(
		is_zero_approx(enemy.direct_hit_flash_strength)
		and int(hit_flash_scheduler.call("get_active_target_count")) == 0,
		"After the guarded peak and tail have rendered, a later frame may finish the flash."
	)
	enemy.queue_free()
	await process_frame


func _test_reparent_during_flash_contract() -> void:
	var enemy := _spawn_enemy(BASIC_CONFIG)
	if enemy == null:
		return
	enemy.play_multiplayer_damage_feedback(
		Vector2.ZERO,
		CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
	)
	var new_parent := Node2D.new()
	test_root.add_child(new_parent)
	enemy.reparent(new_parent)
	_expect(
		is_zero_approx(enemy.direct_hit_flash_strength)
		and enemy.animated_sprite.material == null
		and int(hit_flash_scheduler.call("get_active_target_count")) == 0,
		"Reparenting a flashing enemy must clear both its scheduler state and transient material."
	)
	new_parent.queue_free()
	await process_frame


func _test_periodic_status_contract() -> void:
	var enemy := _spawn_enemy(BASIC_CONFIG)
	if enemy == null:
		return
	var periodic_request := DamageRequest.new(1, CombatTypes.DamageType.MAGIC)
	periodic_request.with_flag(CombatTypes.DamageFlag.PERIODIC)
	periodic_request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	var periodic_result := enemy.apply_combat_damage(periodic_request)
	_expect(
		periodic_result.accepted
		and is_zero_approx(enemy.direct_hit_flash_strength)
		and int(hit_flash_scheduler.call("get_active_target_count")) == 0,
		"An accepted PERIODIC damage request must not flash."
	)

	enemy.apply_burn_status(&"hit_flash_smoke_burn", 2.0, 1)
	var direct_request := DamageRequest.new(1)
	direct_request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	enemy.apply_combat_damage(direct_request)
	hit_flash_scheduler.call(
		"advance_for_test",
		EXPECTED_FLASH_DURATION_SECONDS
	)
	_expect(
		is_zero_approx(enemy.direct_hit_flash_strength)
		and enemy.burn_overlay_strength > 0.0
		and enemy.animated_sprite.material == enemy.status_visual_material,
		"Finishing a direct flash must preserve a concurrently active burn overlay material."
	)
	var health_before_tick := enemy.current_health
	var status_scheduler := root.get_node_or_null("EnemyCollectibleStatusScheduler")
	_expect(status_scheduler != null, "Enemy collectible status scheduler must exist.")
	if status_scheduler != null:
		status_scheduler.call("advance_for_test", 1.01)
	_expect(
		enemy.current_health < health_before_tick
		and is_zero_approx(enemy.direct_hit_flash_strength)
		and int(hit_flash_scheduler.call("get_active_target_count")) == 0,
		"A real burn status tick must reduce health without retriggering red."
	)
	enemy.clear_burn_status()
	_expect(
		enemy.animated_sprite.material == null,
		"Clearing the last persistent overlay after a flash must restore batching."
	)
	enemy.queue_free()
	await process_frame


func _test_lethal_and_proxy_contract() -> void:
	var lethal_enemy := _spawn_enemy(BASIC_CONFIG)
	if lethal_enemy == null:
		return
	lethal_enemy.current_health = 1
	var lethal_request := DamageRequest.new(100000)
	lethal_request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	var lethal_result := lethal_enemy.apply_combat_damage(lethal_request)
	_expect(
		lethal_result.lethal
		and lethal_enemy.is_dead
		and is_equal_approx(
			lethal_enemy.direct_hit_flash_strength,
			EXPECTED_FLASH_ENTRY_STRENGTH
		)
		and lethal_enemy.animated_sprite.material == lethal_enemy.status_visual_material,
		"A lethal direct hit must begin its pale-red transition during the start of the death animation."
	)
	hit_flash_scheduler.call("clear_target", lethal_enemy, true)

	var proxy := _spawn_enemy(BASIC_CONFIG)
	if proxy == null:
		lethal_enemy.queue_free()
		await process_frame
		return
	proxy.configure_multiplayer_proxy()
	var proxy_result := proxy.apply_combat_damage(DamageRequest.new(1))
	_expect(
		not proxy_result.accepted
		and is_zero_approx(proxy.direct_hit_flash_strength),
		"A client proxy must reject local damage and never infer a flash from health mutation."
	)
	proxy.play_multiplayer_damage_feedback(
		Vector2.ZERO,
		CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
	)
	_expect(
		is_equal_approx(
			proxy.direct_hit_flash_strength,
			EXPECTED_FLASH_ENTRY_STRENGTH
		),
		"A proxy must flash when the authoritative presentation flag arrives."
	)
	hit_flash_scheduler.call("clear_target", proxy, true)
	proxy.queue_free()
	if is_instance_valid(lethal_enemy):
		lethal_enemy.queue_free()
	await process_frame


func _test_all_enemy_scene_contract() -> void:
	var config_count := 0
	for file_name in DirAccess.get_files_at(ENEMY_CONFIG_DIRECTORY):
		if not file_name.ends_with(".tres"):
			continue
		var resource := load("%s/%s" % [ENEMY_CONFIG_DIRECTORY, file_name])
		var config := resource as EnemyConfig
		if config == null or config.enemy_scene == null:
			continue
		config_count += 1
		var enemy := _spawn_enemy(config)
		if enemy == null:
			continue
		var sprite := enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		_expect(sprite != null, "%s must retain one canonical body sprite." % file_name)
		_expect(
			enemy.status_visual_material != null
			and enemy.status_visual_material.shader != null
			and enemy.status_visual_material.shader.resource_path == STATUS_SHADER_PATH,
			"%s must use the shared hit-flash shader." % file_name
		)
		enemy.play_multiplayer_damage_feedback(
			Vector2.ZERO,
			CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
		)
		_expect(
			is_equal_approx(
				enemy.direct_hit_flash_strength,
				EXPECTED_FLASH_ENTRY_STRENGTH
			),
			"%s must accept the shared direct-hit flash." % file_name
		)
		hit_flash_scheduler.call("clear_target", enemy, true)
		enemy.queue_free()
		await process_frame
	_expect(config_count == 63, "Exactly 63 formal EnemyConfig resources must be covered; got %d." % config_count)


func _test_idle_and_concurrent_stress_contract() -> void:
	var enemies: Array[Enemy] = []
	var shared_material: ShaderMaterial = null
	for index in range(STRESS_ENEMY_COUNT):
		var enemy := _spawn_enemy(SLIME_CONFIG)
		if enemy == null:
			break
		enemies.append(enemy)
		if shared_material == null:
			shared_material = enemy.status_visual_material
		_expect(
			enemy.status_visual_material == shared_material
			and enemy.animated_sprite.material == null,
			"Idle stress enemies must share one cached material while keeping it detached."
		)
	_expect(
		int(hit_flash_scheduler.call("get_active_target_count")) == 0
		and not hit_flash_scheduler.is_processing(),
		"One thousand idle enemies must create zero active flash work."
	)
	if enemies.size() != STRESS_ENEMY_COUNT:
		for enemy in enemies:
			enemy.queue_free()
		await process_frame
		return
	for index in range(STRESS_FLASH_COUNT):
		enemies[index].play_multiplayer_damage_feedback(
			Vector2.ZERO,
			CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
		)
	_expect(
		int(hit_flash_scheduler.call("get_active_target_count")) == STRESS_FLASH_COUNT,
		"Concurrent flashes must allocate exactly one weak state per affected enemy."
	)
	for index in range(STRESS_FLASH_COUNT):
		_expect(
			enemies[index].status_visual_material == shared_material
			and enemies[index].animated_sprite.material == shared_material,
			"Every concurrently flashing enemy must bind the one shared status material."
		)
	for index in range(STRESS_FLASH_COUNT, STRESS_ENEMY_COUNT):
		_expect(
			enemies[index].animated_sprite.material == null,
			"Enemies outside the flashing cohort must remain on the unmaterialed batching path."
		)
	hit_flash_scheduler.call(
		"advance_for_test",
		EXPECTED_FLASH_DURATION_SECONDS
	)
	_expect(
		int(hit_flash_scheduler.call("get_active_target_count")) == 0
		and not hit_flash_scheduler.is_processing(),
		"The concurrent cohort must drain completely after one flash duration."
	)
	for enemy in enemies:
		_expect(
			enemy.animated_sprite.material == null,
			"Every stress enemy must return to the batching fast path."
		)
		enemy.queue_free()
	for _cleanup_frame in range(4):
		await process_frame


func _test_shared_player_shader_default_contract() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	await process_frame
	var sprite := player.get_node_or_null("BodySprite") as AnimatedSprite2D
	_expect(sprite != null, "Player body sprite must exist for shared shader regression.")
	if sprite != null:
		var value: Variant = sprite.get_instance_shader_parameter(FLASH_PARAMETER)
		_expect(
			value == null or is_zero_approx(float(value)),
			"Players sharing the status shader must keep hit flash at the neutral default."
		)
	player.queue_free()
	await process_frame


func _spawn_enemy(config: EnemyConfig) -> Enemy:
	if config == null or config.enemy_scene == null:
		failures.append("Enemy fixture must provide a loadable PackedScene.")
		return null
	var enemy := config.enemy_scene.instantiate() as Enemy
	if enemy == null:
		failures.append(
			"Enemy fixture failed to instantiate as Enemy: %s"
			% config.enemy_scene.resource_path
		)
		return null
	test_root.add_child(enemy)
	enemy.setup(config, null)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	return enemy


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
