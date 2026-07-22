extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const SPEED_PICKUP := preload("res://resources/config/pickups/pickup_speed.tres")
const TENPURA_PICKUP := preload("res://resources/config/pickups/pickup_tenpura.tres")
const MOTION_STATUS_SHADER_PATH := "res://scene/entity_motion_status.gdshader"
const SLOW_OVERLAY_PARAMETER := &"slow_overlay_strength"
const BURN_OVERLAY_PARAMETER := &"burn_overlay_strength"
const BLEED_OVERLAY_PARAMETER := &"bleed_overlay_strength"
const BLINK_PARAMETER := &"blink_enabled"
const SPEED_TRAIL_SCENE := preload("res://scene/move_speed_trail_effect.tscn")
const NETWORK_STATUS_BENCHMARK_ITERATIONS := 120000

var failures: Array[String] = []
var test_root: Node2D
var session_object_pool: SessionObjectPool


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "MovementStatusVisualsSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	session_object_pool = SessionObjectPool.new()
	session_object_pool.name = "SessionObjectPool"
	test_root.add_child(session_object_pool)
	session_object_pool.register_scene(SPEED_TRAIL_SCENE, 0, 4)

	_test_motion_status_shader_preserves_default_texture_color()
	await _test_player_movement_status_visuals()
	await _test_enemy_movement_status_visuals()
	await _test_active_enemy_speed_trail_teardown()

	test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("MOVEMENT_STATUS_VISUALS_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_motion_status_shader_preserves_default_texture_color() -> void:
	var shader_file := FileAccess.open(MOTION_STATUS_SHADER_PATH, FileAccess.READ)
	_expect(shader_file != null, "Motion status shader must be readable.")
	if shader_file == null:
		return
	var shader_source := shader_file.get_as_text()
	_expect(
		shader_source.find("vec4 color = COLOR;") >= 0,
		"Motion status shader must preserve Godot's default textured COLOR as its base."
	)
	_expect(
		shader_source.find("texture_color * COLOR") < 0,
		"Motion status shader must not multiply the sprite texture into COLOR a second time."
	)
	_expect(
		shader_source.find("bleed_overlay_strength") >= 0,
		"Motion status shader must expose a dedicated bleed overlay parameter."
	)
	_expect(
		shader_source.find("instance uniform float slow_overlay_strength") >= 0
		and shader_source.find("instance uniform float burn_overlay_strength") >= 0
		and shader_source.find("instance uniform float bleed_overlay_strength") >= 0,
		"High-volume enemy status strengths must use per-CanvasItem instance uniforms."
	)
	_expect(
		shader_source.find("burn_overlay_color : source_color = vec4(1.0, 0.56, 0.18, 0.46)") >= 0,
		"Burn overlay default color must be translucent light orange."
	)
	var burn_block_start := shader_source.find("if (burn_overlay_strength")
	var bleed_block_start := shader_source.find("if (bleed_overlay_strength")
	var revive_block_start := shader_source.find("vec4 pre_revive_color")
	_expect(burn_block_start >= 0, "Motion status shader must include a burn overlay block.")
	_expect(bleed_block_start > burn_block_start, "Bleed overlay block must remain separate from burn overlay.")
	if burn_block_start >= 0 and bleed_block_start > burn_block_start:
		var burn_block := shader_source.substr(burn_block_start, bleed_block_start - burn_block_start)
		_expect(
			burn_block.find("texture_color.a > 0.0") >= 0,
			"Burn overlay must only render inside existing sprite pixels."
		)
		_expect(
			burn_block.find("neighbor_alpha - texture_color.a") < 0,
			"Burn overlay must not use an outward outline mask."
		)
		_expect(
			burn_block.find("burn_overlay_color.a") >= 0,
			"Burn overlay must use the configured transparent orange alpha."
		)
		_expect(
			burn_block.find("TIME *") >= 0 and burn_block.find("UV.y") >= 0,
			"Burn overlay must keep a cyclic gradient over the sprite."
		)
	if bleed_block_start >= 0 and revive_block_start > bleed_block_start:
		var bleed_block := shader_source.substr(bleed_block_start, revive_block_start - bleed_block_start)
		_expect(
			bleed_block.find("vec2 inner_edge_offset = TEXTURE_PIXEL_SIZE;") >= 0,
			"Bleed interior tint must use a narrow one-pixel inner edge mask."
		)
		_expect(
			bleed_block.find("inner_min_alpha") >= 0,
			"Bleed interior tint must be limited by immediate neighboring alpha."
		)
		_expect(
			bleed_block.find("bleed_overlay_strength * 0.22") >= 0,
			"Bleed interior tint must stay subtle so sprite centers remain unaffected."
		)


func _test_player_movement_status_visuals() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	await process_frame

	var sprite := player.get_node("BodySprite") as AnimatedSprite2D
	var sprite_material := sprite.material as ShaderMaterial
	var speed_trail := player.get_node("MoveSpeedTrailEffect") as Node2D
	var trail_particles := speed_trail.get_node_or_null("TrailParticles") as GPUParticles2D
	var all_trail_particles: Array[GPUParticles2D] = (
		_collect_trail_particles(speed_trail)
		if speed_trail != null
		else [] as Array[GPUParticles2D]
	)
	_expect(sprite_material != null, "Player body sprite must use a ShaderMaterial.")
	_expect(
		sprite_material != null and sprite_material.shader.resource_path == MOTION_STATUS_SHADER_PATH,
		"Player body sprite must use the motion status shader."
	)
	_expect(speed_trail != null, "Player must include a speed trail effect node.")
	_expect(trail_particles != null, "Player speed trail must use particle speed lines.")
	_expect(all_trail_particles.size() >= 4, "Player speed trail must use several staggered speed lines.")
	_expect(
		speed_trail.process_mode == Node.PROCESS_MODE_DISABLED,
		"An idle player speed trail must disable its particle subtree processing."
	)
	_expect(
		trail_particles != null and not trail_particles.local_coords,
		"Player speed trail particles must remain in world space after emission."
	)
	_expect(
		trail_particles != null
		and trail_particles.texture != null
		and trail_particles.texture.get_size().x <= 16.0
		and trail_particles.texture.get_size().y >= 3.0,
		"Player speed trail particle texture must stay short and visible."
	)
	_expect(
		speed_trail.z_index >= 0 and sprite.z_index > speed_trail.z_index,
		"Player speed trail must render above ground but behind the body sprite."
	)

	player.apply_pickup(SPEED_PICKUP)
	player.velocity = Vector2.RIGHT * 120.0
	player.call("_update_movement_status_visuals", Vector2.RIGHT)
	_expect(speed_trail.visible, "Player temporary speed boost must show speed trail lines.")
	_expect(
		speed_trail.process_mode == Node.PROCESS_MODE_INHERIT,
		"An active player speed trail must restore its particle subtree processing."
	)
	_expect(
		is_equal_approx(_get_instance_shader_float(sprite, SLOW_OVERLAY_PARAMETER), 0.0),
		"Player speed boost must not apply the slow overlay."
	)

	player.apply_pickup(TENPURA_PICKUP)
	player.velocity = Vector2.RIGHT * 120.0
	player.call("_update_movement_status_visuals", Vector2.RIGHT)
	_expect(speed_trail.visible, "Tempura must not remove an active speed boost or hide its trail lines.")
	_expect(
		is_equal_approx(_get_instance_shader_float(sprite, SLOW_OVERLAY_PARAMETER), 0.0),
		"Tempura must no longer apply the slow overlay."
	)

	player.queue_free()
	await process_frame


func _test_enemy_movement_status_visuals() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	test_root.add_child(enemy)
	enemy.setup(BASIC_CONFIG, player, null)
	var second_enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	test_root.add_child(second_enemy)
	second_enemy.setup(BASIC_CONFIG, player, null)
	await process_frame

	var sprite := enemy.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var visual_material := enemy.status_visual_material
	var second_sprite := second_enemy.get_node("AnimatedSprite2D") as AnimatedSprite2D
	_expect(enemy.material == null, "Enemy root must not hold the visual material.")
	_expect(not sprite.use_parent_material, "Enemy sprite must not inherit a root material.")
	_expect(visual_material != null, "Enemy sprite must use a ShaderMaterial.")
	_expect(
		visual_material != null and visual_material.shader.resource_path == MOTION_STATUS_SHADER_PATH,
		"Enemy sprite must use the motion status shader."
	)
	_expect(
		second_enemy.status_visual_material == visual_material,
		"Enemies of the same visual type must share one material for 2D batching."
	)
	_expect(
		sprite.material == null and second_sprite.material == null,
		"Enemies without active status overlays must use the unmaterialed batching fast path."
	)
	_expect(
		enemy.get_node_or_null("MoveSpeedTrailEffect") == null,
		"Idle enemies must not carry a resident speed-trail container or GPU emitters."
	)
	var initial_pool_metrics := session_object_pool.get_metrics(SPEED_TRAIL_SCENE.resource_path)
	_expect(
		int(initial_pool_metrics.get("created", -1)) == 0,
		"The enemy speed-trail pool must stay cold until an enemy is actually hasted."
	)
	_benchmark_unchanged_network_status_mask(second_enemy, second_sprite)

	enemy.velocity = Vector2.LEFT * 60.0
	enemy.add_move_speed_modifier(101, 0.5)
	enemy.call("_update_movement_status_visuals")
	_expect(
		not enemy.is_processing(),
		"A static slow overlay must update event-wise without enabling Enemy._process."
	)
	_expect(
		_get_instance_shader_float(sprite, SLOW_OVERLAY_PARAMETER) > 0.0,
		"Enemy speed down modifier must apply the slow overlay."
	)
	_expect(
		sprite.material == visual_material,
		"An active status overlay must attach the shared status material."
	)
	_expect(
		is_zero_approx(_get_instance_shader_float(second_sprite, SLOW_OVERLAY_PARAMETER)),
		"Shared enemy materials must keep slow strength isolated per CanvasItem instance."
	)
	_expect(
		enemy.speed_trail_effect == null,
		"Enemy speed down modifiers must not acquire a speed-trail lease."
	)

	enemy.remove_move_speed_modifier(101)
	enemy.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	enemy.add_move_speed_modifier(102, 1.35)
	enemy.call("_update_movement_status_visuals")
	_expect(
		enemy.is_processing(),
		"Haste must retain Enemy._process so its pooled trail follows live velocity."
	)
	var speed_trail := enemy.speed_trail_effect as Node2D
	var trail_particles := (
		speed_trail.get_node_or_null("TrailParticles") as GPUParticles2D
		if speed_trail != null
		else null
	)
	var all_trail_particles: Array[GPUParticles2D] = (
		_collect_trail_particles(speed_trail)
		if speed_trail != null
		else [] as Array[GPUParticles2D]
	)
	_expect(
		is_equal_approx(_get_instance_shader_float(sprite, SLOW_OVERLAY_PARAMETER), 0.0),
		"Enemy speed boost modifier must clear the slow overlay."
	)
	_expect(
		sprite.material == null,
		"Clearing the final status overlay must restore the unmaterialed batching fast path."
	)
	_expect(speed_trail != null, "A moving hasted enemy must lease one speed-trail effect.")
	_expect(
		speed_trail != null and speed_trail.visible,
		"Enemy speed boost modifier must show speed trail lines while moving."
	)
	_expect(trail_particles != null, "The leased enemy speed trail must use particle speed lines.")
	_expect(all_trail_particles.size() >= 4, "The leased enemy speed trail must preserve all authored staggered lines.")
	_expect(
		trail_particles != null and not trail_particles.local_coords,
		"Leased enemy speed-trail particles must remain in world space after emission."
	)
	_expect(
		trail_particles != null
		and trail_particles.texture != null
		and trail_particles.texture.get_size().x <= 16.0
		and trail_particles.texture.get_size().y >= 3.0,
		"Leased enemy speed-trail particle texture must stay short and visible."
	)
	_expect(
		speed_trail != null
		and bool(speed_trail.get_meta(SessionObjectPool.POOL_ACTIVE_META, false)),
		"An active enemy speed trail must be owned by the session object pool."
	)
	_expect(
		speed_trail != null and speed_trail.process_mode == Node.PROCESS_MODE_INHERIT,
		"An active enemy speed trail must restore its particle subtree processing."
	)
	_expect(
		speed_trail != null
		and speed_trail.get_parent() == enemy
		and speed_trail.position == Vector2.ZERO
		and speed_trail.physics_interpolation_mode
			== Node.PHYSICS_INTERPOLATION_MODE_INHERIT,
		"A leased trail must temporarily inherit the authoritative enemy's 2D interpolation timeline."
	)
	enemy.remove_move_speed_modifier(102)
	_expect(
		enemy.speed_trail_effect == null,
		"Removing the final haste modifier must immediately return the speed-trail lease."
	)
	_expect(
		int(session_object_pool.get_metrics(SPEED_TRAIL_SCENE.resource_path).get("in_use", -1)) == 0,
		"The speed-trail pool must report no in-use lease after haste expires."
	)
	_expect(
		not enemy.is_processing(),
		"Removing the final haste must disable status processing when no timed status remains."
	)
	_expect(
		is_instance_valid(speed_trail)
		and speed_trail.get_parent() == session_object_pool
		and not bool(speed_trail.get_meta(SessionObjectPool.POOL_ACTIVE_META, true)),
		"A released trail must return to the pool hierarchy without retaining the enemy parent."
	)
	enemy.apply_collectible_status(&"mark", 304, 0.2)
	_expect(
		not enemy.is_processing()
		and int(root.get_node("EnemyCollectibleStatusScheduler").call(
			"get_active_target_count"
		)) == 1,
		"A timed collectible status must use one shared deadline entry without enabling Enemy._process."
	)
	root.get_node("EnemyCollectibleStatusScheduler").call("advance_for_test", 0.21)
	_expect(
		not enemy.is_processing()
		and int(root.get_node("EnemyCollectibleStatusScheduler").call(
			"get_active_target_count"
		)) == 0,
		"Expiring the final timed status must retire its shared deadline entry."
	)
	var health_before_hit := enemy.current_health
	enemy.apply_damage(1, Vector2.RIGHT)
	_expect(enemy.current_health == health_before_hit - 1, "Enemy hit sanity check must apply damage.")
	_expect(
		visual_material.get_shader_parameter(BLINK_PARAMETER) != true,
		"Enemy hit feedback must not enable hurt blink."
	)

	enemy.queue_free()
	second_enemy.queue_free()
	player.queue_free()
	await process_frame


func _benchmark_unchanged_network_status_mask(
	enemy: Enemy,
	sprite: AnimatedSprite2D
) -> void:
	enemy.configure_multiplayer_proxy()
	enemy.apply_multiplayer_visual_status_mask(0b0001)
	_expect(
		_get_instance_shader_float(sprite, BURN_OVERLAY_PARAMETER) > 0.0,
		"The network-status benchmark must start with an active burn overlay."
	)

	var cached_started_usec := Time.get_ticks_usec()
	for _iteration in range(NETWORK_STATUS_BENCHMARK_ITERATIONS):
		enemy.apply_multiplayer_visual_status_mask(0b0001)
	var cached_elapsed_usec := Time.get_ticks_usec() - cached_started_usec

	# Reproduce the retired stable-active path: decode the mask, dispatch the
	# three parameter setters, clamp each value and submit three renderer writes.
	var direct_write_started_usec := Time.get_ticks_usec()
	for _iteration in range(NETWORK_STATUS_BENCHMARK_ITERATIONS):
		_apply_legacy_network_visual_status_mask(sprite, 0b0001)
	var direct_write_elapsed_usec := Time.get_ticks_usec() - direct_write_started_usec
	_expect(
		cached_elapsed_usec < direct_write_elapsed_usec,
		"Unchanged network status masks must beat repeated instance-shader writes."
	)
	print(
		"ENEMY_STATUS_MASK_CACHE_AB updates=%d cached_ms=%.3f direct_writes_ms=%.3f speedup=%.2fx"
		% [
			NETWORK_STATUS_BENCHMARK_ITERATIONS,
			float(cached_elapsed_usec) / 1000.0,
			float(direct_write_elapsed_usec) / 1000.0,
			float(direct_write_elapsed_usec) / maxf(float(cached_elapsed_usec), 1.0),
		]
	)
	enemy.apply_multiplayer_visual_status_mask(0)
	_expect(
		sprite.material == null,
		"Clearing the benchmark mask must restore the unmaterialed batching path."
	)


func _apply_legacy_network_visual_status_mask(
	sprite: AnimatedSprite2D,
	status_mask: int
) -> void:
	var safe_mask := status_mask & 0x0f
	_set_legacy_visual_shader_parameter(
		sprite,
		SLOW_OVERLAY_PARAMETER,
		0.6 if (safe_mask & 4) != 0 else 0.0
	)
	_set_legacy_visual_shader_parameter(
		sprite,
		BURN_OVERLAY_PARAMETER,
		0.72 if (safe_mask & 1) != 0 else 0.0
	)
	_set_legacy_visual_shader_parameter(
		sprite,
		BLEED_OVERLAY_PARAMETER,
		0.7 if (safe_mask & 2) != 0 else 0.0
	)


func _set_legacy_visual_shader_parameter(
	sprite: AnimatedSprite2D,
	parameter_name: StringName,
	value: float
) -> void:
	var strength := clampf(value, 0.0, 1.0)
	sprite.set_instance_shader_parameter(parameter_name, strength)


func _test_active_enemy_speed_trail_teardown() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	test_root.add_child(enemy)
	enemy.setup(BASIC_CONFIG, player, null)
	enemy.velocity = Vector2.RIGHT * 60.0
	enemy.add_move_speed_modifier(303, 1.25)
	var leased_trail := enemy.speed_trail_effect as Node2D
	_expect(
		leased_trail != null
		and bool(leased_trail.get_meta(SessionObjectPool.POOL_ACTIVE_META, false)),
		"A moving hasted teardown fixture must own one active trail lease."
	)

	enemy.queue_free()
	await process_frame
	_expect(
		int(session_object_pool.get_metrics(SPEED_TRAIL_SCENE.resource_path).get("in_use", -1)) == 0,
		"Freeing an enemy during active haste must return its trail lease."
	)
	_expect(
		is_instance_valid(leased_trail)
		and leased_trail.get_parent() == session_object_pool
		and not bool(leased_trail.get_meta(SessionObjectPool.POOL_ACTIVE_META, true)),
		"Active-haste teardown must detach the trail from the enemy before it is freed."
	)
	player.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)


func _get_instance_shader_float(canvas_item: CanvasItem, parameter_name: StringName) -> float:
	if canvas_item == null:
		return 0.0
	var value: Variant = canvas_item.get_instance_shader_parameter(parameter_name)
	return float(value) if value != null else 0.0


func _collect_trail_particles(speed_trail: Node) -> Array[GPUParticles2D]:
	var result: Array[GPUParticles2D] = []
	for child in speed_trail.get_children():
		var particles := child as GPUParticles2D
		if particles != null:
			result.append(particles)
	return result
