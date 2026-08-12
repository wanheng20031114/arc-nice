extends SceneTree

const ENEMY_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_main_battle_elite.tscn"
)
const ENEMY_CONFIG: CombatRobotMainBattleEliteConfig = preload(
	"res://resources/config/enemies/combat_robot_main_battle_elite.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const DEFAULT_DROP_TABLE := preload(
	"res://resources/config/enemies/default_enemy_drop_table.tres"
)
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/enemy_attack_audio_limiter.gd"
)

var failures: Array[String] = []
var runtime: EnemyGameplayGatewayTestRuntime = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	runtime = RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	current_scene = runtime
	root.get_node("BurnStatusScheduler").call("clear_all")
	root.get_node("PlayerTimedMoveSlowScheduler").call("clear_all")

	_test_config_and_runtime_visual_contract()
	await _test_damage_geometry_and_statuses()
	await _test_attack_frame_timing_and_target_selection()
	await _test_airborne_direct_damage_and_periodic_contract()
	await _test_skill_lock_tracking_and_collision_toggle()
	await _test_skill2_warning_and_fan_vfx_contract()
	await _test_proxy_action_and_status_contract()
	await _test_proxy_indicator_supersession_contract()
	await _test_dedicated_audio_state_contract()
	await _test_proxy_audio_offset_and_culling_contract()
	_test_host_only_registry_contract()

	root.get_node("BurnStatusScheduler").call("clear_all")
	root.get_node("PlayerTimedMoveSlowScheduler").call("clear_all")
	runtime.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame
	if failures.is_empty():
		print("COMBAT_ROBOT_MAIN_BATTLE_ELITE_CORE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_config_and_runtime_visual_contract() -> void:
	_expect(
		ENEMY_CONFIG.display_name == "主战机器人"
		and ENEMY_CONFIG.category_tags == PackedStringArray(["mechanical_life"])
		and ENEMY_CONFIG.max_health == 800
		and ENEMY_CONFIG.attack_damage == 80
		and ENEMY_CONFIG.physical_defense == 40
		and ENEMY_CONFIG.magic_defense == 35
		and is_equal_approx(ENEMY_CONFIG.move_speed, 28.0)
		and ENEMY_CONFIG.home_damage == 2
		and ENEMY_CONFIG.xirang_kill_reward == 10
		and ENEMY_CONFIG.drop_table == DEFAULT_DROP_TABLE
		and is_equal_approx(ENEMY_CONFIG.attack_damage_delay, 0.54)
		and is_equal_approx(ENEMY_CONFIG.attack_slash_duration, 1.1)
		and is_equal_approx(ENEMY_CONFIG.skill1_windup, 0.56)
		and is_equal_approx(ENEMY_CONFIG.skill1_recovery, 0.78)
		and is_equal_approx(ENEMY_CONFIG.skill2_takeoff_duration, 0.46)
		and is_equal_approx(ENEMY_CONFIG.skill2_recovery, 0.58),
		"Main-battle robot stats/tags/drop contract mismatch."
	)
	var enemy := ENEMY_SCENE.instantiate() as CombatRobotMainBattleElite
	_expect(enemy != null, "Main-battle scene must instantiate its strong type.")
	if enemy == null:
		return
	runtime.add_child(enemy)
	var sprite := enemy.get_node("AnimatedSprite2D") as AnimatedSprite2D
	_expect(
		String(enemy.get_meta("runtime_visual_strategy", ""))
		== "high_resolution_source_preserved_linear_display"
		and not bool(enemy.get_meta("runtime_visual_native64_eligible", true))
		and enemy.has_released_runtime_visuals()
		and sprite.visible
		and sprite.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR
		and sprite.scale.is_equal_approx(Vector2(0.125, 0.125))
		and sprite.position.is_equal_approx(Vector2(0.0, -17.0)),
		"Released high-resolution SpriteFrames must use one shared transform and linear display filtering without claiming native64."
	)
	var expected_frame_counts := {
		&"move": 8,
		&"attack": 8,
		&"skill1_windup": 4,
		&"skill1_dash": 4,
		&"skill1_circle_slash": 8,
		&"skill2_takeoff": 5,
		&"skill2_drop_slash": 8,
		&"death": 8,
	}
	for animation_name: StringName in expected_frame_counts:
		_expect(
			sprite.sprite_frames.get_frame_count(animation_name)
			== int(expected_frame_counts[animation_name]),
			"Released animation %s must keep its exact approved frame count."
			% animation_name
		)
		for frame_index in sprite.sprite_frames.get_frame_count(animation_name):
			var frame_texture := (
				sprite.sprite_frames.get_frame_texture(animation_name, frame_index)
				as AtlasTexture
			)
			_expect(
				frame_texture != null
				and frame_texture.filter_clip
				and frame_texture.get_size().is_equal_approx(Vector2(512.0, 688.0)),
				"Every released frame must preserve the shared 512x688 virtual canvas."
			)
	_expect(
		enemy.get_node_or_null("AttackWarning") is Polygon2D
		and enemy.get_node_or_null("Skill1WarningLine") is Line2D
		and enemy.get_node_or_null("Skill1CircleRing") is Line2D
		and enemy.get_node_or_null("Skill2CrossMarker/Horizontal") is Line2D
		and enemy.get_node_or_null("Skill2FanWarning") is Polygon2D
		and enemy.get_node_or_null("FanSlashVFX/AttackUpper") is GPUParticles2D
		and enemy.get_node_or_null("FanSlashVFX/AttackLower") is GPUParticles2D
		and enemy.get_node_or_null("FanSlashVFX/Skill2Upper") is GPUParticles2D
		and enemy.get_node_or_null("FanSlashVFX/Skill2Lower") is GPUParticles2D,
		"All gameplay indicators must be authored as static scene nodes."
	)
	var fan_particle_total := 0
	for particles in enemy.attack_fan_particles + enemy.skill2_fan_particles:
		fan_particle_total += particles.amount
		_expect(
			particles.one_shot
			and not particles.emitting
			and particles.process_material is ParticleProcessMaterial
			and not particles.local_coords,
			"Fan-slash particles must be static one-shot world-space GPU emitters."
		)
	_expect(
		fan_particle_total == 52
		and is_equal_approx(
			(enemy.attack_fan_particles[0].process_material as ParticleProcessMaterial).spread,
			45.0
		)
		and is_equal_approx(
			(enemy.skill2_fan_particles[0].process_material as ParticleProcessMaterial).spread,
			60.0
		),
		"Fan VFX must keep its bounded dual-sword particle budget and authored fan angles."
	)
	var attack_polygon := (
		enemy.get_node("AttackWarning") as Polygon2D
	).polygon
	_expect(
		attack_polygon.size() >= 8
		and absf(attack_polygon[1].length() - 32.0) < 0.01
		and absf(
			rad_to_deg(Vector2.RIGHT.angle_to(attack_polygon[1])) + 45.0
		) < 0.01
		and absf(
			rad_to_deg(Vector2.RIGHT.angle_to(attack_polygon[-1])) - 45.0
		) < 0.01,
		"Static normal-attack telegraph must cover the authored 32px/90-degree fan."
	)
	enemy.free()


func _test_damage_geometry_and_statuses() -> void:
	var front := _spawn_player(Vector2(24.0, 0.0))
	var behind := _spawn_player(Vector2(-24.0, 0.0))
	var enemy := _spawn_enemy(Vector2.ZERO, front)
	await physics_frame

	var front_before := front.current_health
	var behind_before := behind.current_health
	enemy.locked_direction = Vector2.RIGHT
	enemy.call(
		"_apply_fan_damage",
		32.0,
		90.0,
		80,
		&"combat_robot_main_battle_elite_attack",
		false,
		false
	)
	_expect(
		front.current_health == front_before - 80
		and behind.current_health == behind_before,
		"Normal 32px/90-degree slash must hit front once for 80 and reject behind."
	)

	front.invincibility_time_left = 0.0
	front_before = front.current_health
	enemy.call(
		"_apply_circle_damage",
		36.0,
		96,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL1
	)
	var burn_scheduler := root.get_node("BurnStatusScheduler")
	var burn_snapshot := burn_scheduler.call(
		"get_source_snapshot",
		front,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY
	) as Dictionary
	_expect(
		front.current_health == front_before - 96
		and bool(burn_scheduler.call(
			"has_burn",
			front,
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY
		))
		and is_equal_approx(
			float(burn_snapshot.get("time_left", 0.0)),
			CombatAttackRegistry.get_burn_duration(
				CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL1
			)
		)
		and int(burn_snapshot.get("tick_damage", 0))
			== CombatAttackRegistry.get_burn_tick_damage(
				CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL1
			),
		"Skill1 circle must deal 96 and register one shared 5x5 burn family."
	)

	front.invincibility_time_left = 0.0
	front_before = front.current_health
	enemy.call(
		"_apply_fan_damage",
		48.0,
		120.0,
		120,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL2,
		true,
		true
	)
	var slow_scheduler := root.get_node("PlayerTimedMoveSlowScheduler")
	var slow_snapshot := slow_scheduler.call(
		"get_source_snapshot",
		front,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SLOW_FAMILY
	) as Dictionary
	_expect(
		front.current_health == front_before - 120
		and is_equal_approx(float(slow_scheduler.call(
			"get_effective_multiplier",
			front
		)), 0.75)
		and int(slow_scheduler.call("get_source_count", front)) == 1
		and is_equal_approx(
			float(slow_snapshot.get("time_left", 0.0)),
			CombatAttackRegistry.get_timed_move_slow_duration(
				CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL2
			)
		)
		and is_equal_approx(
			float(slow_snapshot.get("multiplier", 1.0)),
			CombatAttackRegistry.get_timed_move_slow_multiplier(
				CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL2
			)
		),
		"Skill2 fan must deal 120 and apply one 1-second 0.75 slow."
	)
	front.apply_timed_move_slow(
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SLOW_FAMILY,
		1.0,
		0.75
	)
	_expect(
		int(slow_scheduler.call("get_source_count", front)) == 1,
		"Same-family timed slow must refresh without stacking."
	)
	front.call("_apply_cold_runtime_state", 1, 0.6)
	_expect(
		is_equal_approx(front.get_authoritative_move_speed_multiplier(), 0.6),
		"Timed slow and cold must take the lower multiplier, not multiply."
	)
	front.apply_timed_move_slow(&"test_stronger_slow", 1.0, 0.5)
	_expect(
		is_equal_approx(front.get_authoritative_move_speed_multiplier(), 0.5),
		"Different timed-slow families must expose the lowest multiplier."
	)

	enemy.queue_free()
	front.queue_free()
	behind.queue_free()
	await process_frame


func _test_attack_frame_timing_and_target_selection() -> void:
	var far_player := _spawn_player(Vector2(400.0, 0.0))
	var near_player := _spawn_player(Vector2(80.0, 0.0))
	var enemy := _spawn_enemy(Vector2.ZERO, far_player)
	await physics_frame
	enemy.skill2_cooldown_left = 0.0
	enemy.skill1_cooldown_left = 0.0
	_expect(
		bool(enemy.call("_try_start_ready_action"))
		and enemy.combat_state
			== CombatRobotMainBattleElite.CombatState.SKILL2_TAKEOFF
		and enemy.committed_target == near_player,
		"Skill2 must deterministically choose any valid nearby player/plant, not only the navigation objective."
	)
	enemy.call("_set_airborne", false, true)
	enemy.call("_finish_to_chase")

	enemy.call("_start_attack_windup", near_player)
	_expect(
		enemy.animated_sprite.animation != ENEMY_CONFIG.attack_animation_name,
		"The 0.35-second warning must not consume the eight slash frames."
	)
	near_player.invincibility_time_left = 0.0
	var health_before := near_player.current_health
	enemy.call("_start_attack_slash")
	_expect(
		enemy.animated_sprite.animation == ENEMY_CONFIG.attack_animation_name
		and enemy.animated_sprite.frame == 0
		and is_zero_approx(enemy.animated_sprite.frame_progress),
		"Slash entry must explicitly restart the attack animation at frame 0."
	)
	enemy.call(
		"_update_attack_slash",
		ENEMY_CONFIG.attack_damage_delay - 0.001
	)
	_expect(
		near_player.current_health == health_before,
		"Normal slash must not damage before the approved impact frame."
	)
	enemy.call("_update_attack_slash", 0.002)
	_expect(
		near_player.current_health == health_before - 80,
		"Normal slash must resolve exactly once when the approved impact frame begins."
	)
	_expect(
		not bool(enemy.call("_uses_inherited_touch_damage")),
		"Inherited touch damage must remain paused throughout attack actions."
	)

	enemy.queue_free()
	far_player.queue_free()
	near_player.queue_free()
	await process_frame


func _test_airborne_direct_damage_and_periodic_contract() -> void:
	var player := _spawn_player(Vector2(80.0, 0.0))
	var enemy := _spawn_enemy(Vector2.ZERO, player)
	var health_before := enemy.current_health
	enemy.call("_set_airborne", true, false)
	var direct_result := enemy.apply_combat_damage(
		DamageRequest.new(30, EnemyConfig.DamageType.MAGIC)
	)
	var periodic_request := DamageRequest.new(
		5,
		EnemyConfig.DamageType.MAGIC
	)
	periodic_request.flags = CombatTypes.DamageFlag.PERIODIC
	var periodic_result := enemy.apply_combat_damage(periodic_request)
	_expect(
		direct_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.INVULNERABLE
		)
		and periodic_result.accepted
		and enemy.current_health < health_before,
		"Airborne hook must reject direct hits while admitting periodic damage."
	)

	enemy.call("_set_airborne", false, false)
	enemy.apply_burn_status(&"airborne_dot_probe", 5.0, 5)
	enemy.call("_set_airborne", true, false)
	health_before = enemy.current_health
	enemy.call(
		"_advance_collectible_status_effects_to",
		float(enemy.get("collectible_status_clock")) + 1.01
	)
	_expect(
		enemy.current_health < health_before,
		"An established burn must continue ticking while the robot is airborne."
	)
	enemy.clear_collectible_statuses()
	enemy.current_health = 5
	enemy.combat_state = CombatRobotMainBattleElite.CombatState.SKILL2_TRACK
	enemy.animated_sprite.visible = false
	var lethal_periodic := DamageRequest.new(10, EnemyConfig.DamageType.MAGIC)
	lethal_periodic.flags = CombatTypes.DamageFlag.PERIODIC
	var lethal_result := enemy.apply_combat_damage(lethal_periodic)
	_expect(
		lethal_result.accepted
		and enemy.is_dead
		and enemy.animated_sprite.visible
		and enemy.animated_sprite.animation == &"death",
		"A periodic kill during hidden skill2 tracking must restore and play the death animation."
	)
	enemy.queue_free()
	player.queue_free()
	await process_frame


func _test_skill_lock_tracking_and_collision_toggle() -> void:
	var player := _spawn_player(Vector2(100.0, 0.0))
	var enemy := _spawn_enemy(Vector2.ZERO, player)
	enemy.call("_start_skill1_windup", player)
	player.global_position = Vector2(0.0, 100.0)
	enemy.call("_update_skill1_windup", ENEMY_CONFIG.skill1_windup)
	_expect(
		enemy.combat_state
			== CombatRobotMainBattleElite.CombatState.SKILL1_DASH
		and enemy.skill1_locked_position == Vector2(0.0, 100.0)
		and enemy.locked_direction.is_equal_approx(Vector2.DOWN),
		"Skill1 must lock target position/direction only on the launch frame."
	)
	player.global_position = Vector2(-100.0, 0.0)
	enemy.call("_update_skill1_dash", 0.1)
	_expect(
		enemy.locked_direction.is_equal_approx(Vector2.DOWN)
		and enemy.global_position.x == 0.0,
		"Skill1 dash must not turn after launch."
	)

	enemy.global_position = Vector2.ZERO
	enemy.committed_target = player
	player.global_position = Vector2(200.0, 0.0)
	enemy.combat_state = CombatRobotMainBattleElite.CombatState.SKILL2_TRACK
	enemy.state_time_left = 3.0
	enemy.call("_update_skill2_tracking", 1.0)
	_expect(
		is_equal_approx(enemy.global_position.x, 50.0)
		and is_equal_approx(enemy.state_time_left, 2.0),
		"Skill2 cross must track for simulation time at a fixed 50px/s cap."
	)
	enemy.global_position = player.global_position
	enemy.skill2_last_tracking_direction = Vector2.UP
	enemy.call("_start_skill2_drop")
	_expect(
		enemy.locked_direction.is_equal_approx(Vector2.UP),
		"A cross exactly on its target must keep the last valid tracking direction for the drop fan."
	)

	enemy.call("_set_airborne", true, true)
	await physics_frame
	_expect(
		enemy.is_temporarily_direct_damage_immune()
		and _all_shapes_disabled(enemy.body_collision_shapes)
		and _all_shapes_disabled(enemy.touch_damage_shapes)
		and not enemy.touch_damage_area.monitoring,
		"Takeoff must immediately latch immunity and deferred-disable body/contact shapes."
	)
	enemy.call("_set_airborne", false, true)
	await physics_frame
	_expect(
		not enemy.is_temporarily_direct_damage_immune()
		and not _all_shapes_disabled(enemy.body_collision_shapes)
		and not _all_shapes_disabled(enemy.touch_damage_shapes)
		and enemy.touch_damage_area.monitoring,
		"Landing must restore body/contact shapes and monitoring."
	)
	enemy.queue_free()
	player.queue_free()
	await process_frame


func _test_skill2_warning_and_fan_vfx_contract() -> void:
	var player := _spawn_player(Vector2(48.0, 0.0))
	var enemy := _spawn_enemy(Vector2.ZERO, player)
	var cross := enemy.skill2_cross_marker
	_expect(
		is_equal_approx(float(enemy.call("_get_skill2_cross_flash_alpha", 1.0)), 1.0)
		and is_equal_approx(
			float(enemy.call("_get_skill2_cross_flash_alpha", 0.775)),
			CombatRobotMainBattleElite.SKILL2_CROSS_DIM_ALPHA
		)
		and is_equal_approx(float(enemy.call("_get_skill2_cross_flash_alpha", 0.35)), 1.0)
		and is_equal_approx(
			float(enemy.call("_get_skill2_cross_flash_alpha", 0.30)),
			CombatRobotMainBattleElite.SKILL2_CROSS_DIM_ALPHA
		),
		"Skill2 cross must stay steady, then flash at 4Hz and accelerate to 8Hz before landing."
	)
	enemy.call("_set_skill2_cross_visible", true)
	enemy.call("_update_skill2_cross_flash", 0.30)
	_expect(
		cross.visible
		and is_equal_approx(
			cross.modulate.a,
			CombatRobotMainBattleElite.SKILL2_CROSS_DIM_ALPHA
		),
		"Host warning marker must apply the shared landing-soon flash alpha."
	)
	enemy.call("_set_skill2_cross_visible", false)
	_expect(
		not cross.visible and is_equal_approx(cross.modulate.a, 1.0),
		"Hiding the cross for DROP/cancel/death must restore its neutral alpha."
	)

	enemy.locked_direction = Vector2.RIGHT
	enemy.call("_start_attack_slash")
	enemy.call("_update_attack_slash", 0.459)
	_expect(
		not enemy.attack_fan_particles[0].emitting
		and not enemy.attack_fan_particles[1].emitting,
		"Normal dual-sword particles must not fire before the authored 0.46s swing cue."
	)
	enemy.call("_update_attack_slash", 0.002)
	_expect(
		enemy.attack_fan_particles[0].emitting
		and enemy.attack_fan_particles[1].emitting
		and is_equal_approx(enemy.fan_slash_vfx.rotation, 0.0),
		"Normal attack must fire both sword emitters at the down-swing cue."
	)
	enemy.call("_stop_fan_slash_vfx")
	enemy.committed_target = player
	enemy.call("_start_skill2_drop")
	enemy.call("_update_skill2_drop", ENEMY_CONFIG.skill2_drop_duration - 0.001)
	_expect(
		not enemy.skill2_fan_particles[0].emitting
		and not enemy.skill2_fan_particles[1].emitting,
		"Drop particles must wait for the 0.18s landing/damage frame."
	)
	enemy.call("_update_skill2_drop", 0.002)
	_expect(
		enemy.skill2_fan_particles[0].emitting
		and enemy.skill2_fan_particles[1].emitting,
		"Landing must fire the stronger symmetric dual-sword particle fan."
	)
	enemy.queue_free()
	player.queue_free()
	await process_frame

	var proxy_player := _spawn_player(Vector2(48.0, 0.0))
	var proxy := _spawn_enemy(Vector2.ZERO, proxy_player)
	proxy.configure_multiplayer_proxy()
	var takeoff_track_total := (
		ENEMY_CONFIG.skill2_takeoff_duration
		+ ENEMY_CONFIG.skill2_tracking_duration
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL2_TAKEOFF,
		Vector2.RIGHT,
		proxy.global_position,
		1,
		takeoff_track_total - 0.775
	)
	proxy.apply_multiplayer_visual_status_mask(
		CombatRobotMainBattleElite.AIRBORNE_VISUAL_STATUS_MASK
	)
	_expect(
		proxy.skill2_cross_marker.visible
		and is_equal_approx(
			proxy.skill2_cross_marker.modulate.a,
			CombatRobotMainBattleElite.SKILL2_CROSS_DIM_ALPHA
		),
		"Late proxy TAKEOFF must reconstruct the same urgent flash phase from action_elapsed."
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL2_DROP,
		Vector2.LEFT,
		proxy.global_position,
		2,
		ENEMY_CONFIG.skill2_drop_duration
	)
	_expect(
		not proxy.skill2_cross_marker.visible
		and is_equal_approx(proxy.skill2_cross_marker.modulate.a, 1.0)
		and proxy.skill2_fan_particles[0].emitting
		and proxy.skill2_fan_particles[1].emitting
		and is_equal_approx(absf(proxy.fan_slash_vfx.rotation), PI),
		"Proxy DROP must clear the cross and seek both fan emitters to the landing cue."
	)
	proxy.set_multiplayer_proxy_visual_active(false)
	_expect(
		not proxy.skill2_fan_particles[0].emitting
		and not proxy.skill2_fan_particles[1].emitting,
		"Culling a proxy must immediately stop active fan particles without replay on restore."
	)
	proxy.queue_free()
	proxy_player.queue_free()
	await process_frame


func _test_proxy_action_and_status_contract() -> void:
	var player := _spawn_player(Vector2(60.0, 0.0))
	var proxy := _spawn_enemy(Vector2.ZERO, player)
	proxy.configure_multiplayer_proxy()
	proxy.play_multiplayer_enemy_action(
		CombatRobotMainBattleElite.ACTION_SKILL1_DASH,
		Vector2.RIGHT,
		2
	)
	proxy.play_multiplayer_enemy_action(
		CombatRobotMainBattleElite.ACTION_ATTACK_SLASH,
		Vector2.LEFT,
		1
	)
	var health_before := player.current_health
	proxy.locked_direction = Vector2.RIGHT
	proxy.call(
		"_apply_fan_damage",
		48.0,
		120.0,
		120,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL2,
		true,
		true
	)
	proxy.apply_multiplayer_visual_status_mask(
		CombatRobotMainBattleElite.AIRBORNE_VISUAL_STATUS_MASK
	)
	_expect(
		proxy.latest_proxy_action_id == 2
		and player.current_health == health_before
		and proxy.get_node("Skill2CrossMarker").visible
		and not proxy.animated_sprite.visible,
		"Proxy must reject old actions, deal zero damage, and reconstruct airborne cross state."
	)
	proxy.apply_multiplayer_visual_status_mask(0)
	_expect(
		not proxy.get_node("Skill2CrossMarker").visible,
		"Clearing bit5 must restore grounded proxy presentation."
	)

	proxy.play_multiplayer_enemy_target_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL1_WINDUP,
		player,
		proxy.global_position,
		3,
		0.0
	)
	player.global_position = Vector2(80.0, 20.0)
	await create_timer(0.05).timeout
	_expect(
		proxy.skill1_warning_line.visible
		and proxy.skill1_warning_line.points.size() == 2
		and proxy.skill1_warning_line.points[1].is_equal_approx(
			proxy.to_local(player.global_position)
		),
		"Proxy skill1 telegraph must track the same moving target during its remaining windup."
	)

	proxy.play_multiplayer_enemy_target_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL2_TAKEOFF,
		player,
		proxy.global_position,
		4,
		0.0
	)
	proxy.apply_multiplayer_visual_status_mask(
		CombatRobotMainBattleElite.AIRBORNE_VISUAL_STATUS_MASK
	)
	_expect(
		proxy.proxy_takeoff_visual_override
		and not proxy.get_node("Skill2CrossMarker").visible,
		"Takeoff action must keep its body animation visible even when the same-frame bit5 snapshot arrives."
	)
	await create_timer(ENEMY_CONFIG.skill2_takeoff_duration + 0.03).timeout
	_expect(
		not proxy.proxy_takeoff_visual_override
		and proxy.get_node("Skill2CrossMarker").visible,
		"After takeoff animation, the proxy must transition to the tracked ground cross."
	)

	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL2_DROP,
		Vector2.RIGHT,
		proxy.global_position,
		5,
		0.0
	)
	proxy.apply_multiplayer_visual_status_mask(
		CombatRobotMainBattleElite.AIRBORNE_VISUAL_STATUS_MASK
	)
	_expect(
		proxy.proxy_drop_visual_override
		and not proxy.get_node("Skill2CrossMarker").visible,
		"Drop action must override a still-airborne snapshot without hiding the fall/slash body."
	)
	await create_timer(ENEMY_CONFIG.skill2_drop_duration + 0.03).timeout
	_expect(
		proxy.proxy_grounded_after_drop_latched
		and not proxy.get_node("Skill2CrossMarker").visible,
		"A stale bit5 snapshot must not resurrect the cross after the drop frame resolves."
	)
	proxy.apply_multiplayer_visual_status_mask(0)
	_expect(
		not proxy.proxy_grounded_after_drop_latched,
		"The first grounded snapshot must release the post-drop visual latch."
	)

	var warning_was_visible := proxy.attack_warning.visible
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_ATTACK_WINDUP,
		Vector2.RIGHT,
		proxy.global_position,
		10,
		ENEMY_CONFIG.attack_windup + 1.0
	)
	proxy.play_multiplayer_enemy_action(
		CombatRobotMainBattleElite.ACTION_ATTACK_WINDUP,
		Vector2.RIGHT,
		10
	)
	proxy.play_multiplayer_enemy_action(
		CombatRobotMainBattleElite.ACTION_ATTACK_WINDUP,
		Vector2.RIGHT,
		9
	)
	_expect(
		proxy.latest_proxy_action_id == 10
		and proxy.attack_warning.visible == warning_was_visible,
		"Expired actions must advance the watermark while duplicate/out-of-order actions remain visually inert."
	)
	proxy.apply_multiplayer_visual_status_mask(
		CombatRobotMainBattleElite.AIRBORNE_VISUAL_STATUS_MASK
	)
	proxy.play_multiplayer_death_sequence()
	_expect(
		proxy.is_dead
		and proxy.animated_sprite.visible
		and proxy.animated_sprite.animation == &"death"
		and not proxy.get_node("Skill2CrossMarker").visible,
		"A proxy death during hidden skill2 tracking must restore the body and clear the cross."
	)
	proxy.queue_free()
	player.queue_free()
	await process_frame


func _test_proxy_indicator_supersession_contract() -> void:
	var player := _spawn_player(Vector2(60.0, 0.0))
	var proxy := _spawn_enemy(Vector2.ZERO, player)
	proxy.configure_multiplayer_proxy()

	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL1_CIRCLE,
		Vector2.RIGHT,
		proxy.global_position,
		1,
		0.0
	)
	_expect(
		proxy.skill1_circle_ring.visible,
		"Proxy circle action must first expose its own warning ring."
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_ATTACK_WINDUP,
		Vector2.RIGHT,
		proxy.global_position,
		2,
		0.1
	)
	_expect(
		proxy.attack_warning.visible
		and not proxy.skill1_warning_line.visible
		and not proxy.skill1_circle_ring.visible
		and not proxy.skill2_cross_marker.visible
		and not proxy.skill2_fan_warning.visible,
		"A newer attack windup must replace every stale proxy indicator."
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_ATTACK_SLASH,
		Vector2.RIGHT,
		proxy.global_position,
		3,
		0.0
	)
	_expect(
		_all_action_indicators_hidden(proxy),
		"Attack slash must clear its preceding windup without reviving older warnings."
	)

	proxy.play_multiplayer_enemy_target_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL1_WINDUP,
		player,
		proxy.global_position,
		4,
		0.0
	)
	_expect(
		proxy.skill1_warning_line.visible,
		"Proxy skill-one windup must expose only its tracking line."
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL1_CIRCLE,
		Vector2.RIGHT,
		proxy.global_position,
		5,
		0.0
	)
	_expect(
		not proxy.skill1_warning_line.visible
		and proxy.skill1_circle_ring.visible,
		"Skill-one circle must replace its windup line with the circle ring."
	)

	proxy.play_multiplayer_enemy_target_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL2_TAKEOFF,
		player,
		proxy.global_position,
		6,
		0.0
	)
	_expect(
		_all_action_indicators_hidden(proxy),
		"Skill-two takeoff must clear the preceding circle while its body is rising."
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL2_DROP,
		Vector2.LEFT,
		proxy.global_position,
		7,
		0.0
	)
	_expect(
		proxy.skill2_fan_warning.visible
		and not proxy.attack_warning.visible
		and not proxy.skill1_warning_line.visible
		and not proxy.skill1_circle_ring.visible
		and not proxy.skill2_cross_marker.visible,
		"Skill-two drop must replace takeoff tracking with only its landing fan."
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL1_CIRCLE,
		Vector2.RIGHT,
		proxy.global_position,
		8,
		0.0
	)
	_expect(
		proxy.skill1_circle_ring.visible
		and not proxy.skill2_fan_warning.visible,
		"A newer circle action must clear a stale landing fan warning."
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_ATTACK_WINDUP,
		Vector2.RIGHT,
		proxy.global_position,
		9,
		ENEMY_CONFIG.attack_windup + 1.0
	)
	_expect(
		proxy.latest_proxy_action_id == 9
		and _all_action_indicators_hidden(proxy),
		"An expired action that advances the watermark must retire every older indicator."
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL1_CIRCLE,
		Vector2.RIGHT,
		proxy.global_position,
		8,
		0.0
	)
	_expect(
		_all_action_indicators_hidden(proxy),
		"An out-of-order action must not revive presentation retired by a newer expired watermark."
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL1_CIRCLE,
		Vector2.RIGHT,
		proxy.global_position,
		10,
		0.0
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_ATTACK_WINDUP,
		Vector2.RIGHT,
		proxy.global_position,
		11,
		-0.1
	)
	_expect(
		proxy.latest_proxy_action_id == 11
		and _all_action_indicators_hidden(proxy),
		"An invalid elapsed time that advances the watermark must also retire older presentation."
	)

	proxy.queue_free()
	player.queue_free()
	await process_frame


func _test_dedicated_audio_state_contract() -> void:
	var player := _spawn_player(Vector2(24.0, 0.0))
	var enemy := _spawn_enemy(Vector2.ZERO, player)
	await physics_frame
	var sprite := enemy.animated_sprite
	sprite.pause()
	sprite.animation = ENEMY_CONFIG.move_animation_name
	enemy.combat_state = CombatRobotMainBattleElite.CombatState.CHASE
	enemy.velocity = Vector2.RIGHT
	enemy.move_stomp_variant_index = 0
	enemy.actual_motion_since_last_stomp = false
	sprite.set_frame_and_progress(0, 0.0)
	sprite.set_frame_and_progress(4, 0.0)
	_expect(
		enemy.move_stomp_variant_index == 0
		and not enemy.move_stomp_audio.playing,
		"仅速度非零但坐标未变化时不得误报重踏。"
	)
	var position_before_move := enemy.global_position
	enemy.global_position += Vector2.RIGHT
	enemy.call(
		"_record_actual_motion_for_audio",
		position_before_move,
		enemy.global_position
	)
	sprite.set_frame_and_progress(0, 0.0)
	sprite.set_frame_and_progress(4, 0.0)
	_expect(
		enemy.move_stomp_variant_index == 1
		and enemy.move_stomp_audio.stream == ENEMY_CONFIG.move_stomp_audio_stream_a
		and enemy.move_stomp_audio.playing
		and enemy.move_stomp_audio.pitch_scale >= 0.98
		and enemy.move_stomp_audio.pitch_scale <= 1.02,
		"CHASE实际移动到第5帧时必须播放重踏A并使用约±2%音高变化。"
	)
	position_before_move = enemy.global_position
	enemy.global_position += Vector2.RIGHT
	enemy.call(
		"_record_actual_motion_for_audio",
		position_before_move,
		enemy.global_position
	)
	sprite.set_frame_and_progress(7, 0.0)
	_expect(
		enemy.move_stomp_variant_index == 2
		and enemy.move_stomp_audio.stream == ENEMY_CONFIG.move_stomp_audio_stream_b,
		"第8帧必须固定轮换到重踏B。"
	)
	enemy.move_stomp_audio.stop()
	sprite.set_frame_and_progress(0, 0.0)
	sprite.set_frame_and_progress(4, 0.0)
	_expect(
		enemy.move_stomp_variant_index == 2
		and not enemy.move_stomp_audio.playing,
		"速度保持非零但没有新的实际位移时不得触发或推进重踏变体。"
	)

	ENEMY_ATTACK_AUDIO_LIMITER.reset_metrics()
	enemy.call("_start_attack_windup", player)
	_expect(
		enemy.attack_windup_audio.playing,
		"普通攻击蓄势入口必须播放专属蓄势音。"
	)
	enemy.call("_start_attack_slash")
	_expect(
		not enemy.attack_windup_audio.playing
		and enemy.attack_slash_audio.playing,
		"普通双剑斩入口必须停止蓄势并播放斩击音。"
	)
	enemy.call("_start_skill1_windup", player)
	_expect(
		not enemy.attack_slash_audio.playing
		and enemy.skill1_charge_audio.playing,
		"技能一充能必须替换此前动作音。"
	)
	enemy.call("_start_skill1_dash")
	_expect(
		not enemy.skill1_charge_audio.playing
		and enemy.skill1_dash_audio.playing,
		"技能一冲锋必须在切阶段时切换音节。"
	)
	enemy.call("_finish_skill1_dash")
	_expect(
		not enemy.skill1_dash_audio.playing
		and enemy.skill1_circle_slash_audio.playing,
		"技能一圆斩必须起始即播放重音并停止冲锋音。"
	)
	enemy.call("_start_skill2_takeoff", player)
	_expect(
		not enemy.skill1_circle_slash_audio.playing
		and enemy.skill2_takeoff_audio.playing,
		"技能二起飞入口必须播放专属起飞音。"
	)
	enemy.call("_update_skill2_takeoff", ENEMY_CONFIG.skill2_takeoff_duration)
	_expect(
		not enemy.skill2_takeoff_audio.playing
		and not _any_action_audio_playing(enemy),
		"技能二三秒追踪阶段必须完全静音。"
	)
	enemy.call("_start_skill2_drop")
	_expect(
		enemy.skill2_drop_audio.playing,
		"技能二落砸入口必须播放落地双斩音。"
	)
	enemy.call("_finish_to_chase")
	_expect(
		not _any_action_audio_playing(enemy),
		"动作结束或取消回追击时必须清理全部阶段音。"
	)
	_expect(
		int(ENEMY_ATTACK_AUDIO_LIMITER.get_metrics()[&"heavy_requests"]) == 7,
		"七个战斗瞬态必须各经重攻击限流器一次，移动重踏不得占用该配额。"
	)

	enemy.call("_set_airborne", false, false)
	enemy.hit_variant_index = 0
	enemy.apply_damage(1)
	_expect(
		enemy.hit_variant_index == 1
		and enemy.hit_audio.stream == ENEMY_CONFIG.hit_audio_stream_a
		and enemy.hit_audio.pitch_scale >= 0.98
		and enemy.hit_audio.pitch_scale <= 1.02,
		"首次非致命有效伤害必须选择受击A并使用约±2%音高。"
	)
	enemy.apply_damage(1)
	_expect(
		enemy.hit_variant_index == 2
		and enemy.hit_audio.stream == ENEMY_CONFIG.hit_audio_stream_b,
		"第二次非致命有效伤害必须固定轮换到受击B。"
	)
	enemy.current_health = 1
	var hit_variant_before_death := enemy.hit_variant_index
	enemy.apply_damage(2)
	_expect(
		enemy.is_dead
		and enemy.hit_variant_index == hit_variant_before_death
		and not enemy.hit_audio.playing
		and enemy.death_audio.stream == ENEMY_CONFIG.death_audio_stream
		and enemy.death_audio.playing,
		"致命伤害必须只播放专属死亡音，不叠加或推进受击音。"
	)
	enemy.queue_free()
	player.queue_free()
	await process_frame


func _test_proxy_audio_offset_and_culling_contract() -> void:
	var player := _spawn_player(Vector2(60.0, 0.0))
	var proxy := _spawn_enemy(Vector2.ZERO, player)
	proxy.configure_multiplayer_proxy()
	ENEMY_ATTACK_AUDIO_LIMITER.reset_metrics()
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_ATTACK_SLASH,
		Vector2.RIGHT,
		proxy.global_position,
		1,
		0.2
	)
	await process_frame
	_expect(
		proxy.attack_slash_audio.playing
		and absf(proxy.attack_slash_audio.get_playback_position() - 0.2) <= 0.08,
		"可见代理必须按action_elapsed从普通斩正确偏移播放。"
	)
	proxy.call("_stop_action_audio")
	var requests_after_first := int(
		ENEMY_ATTACK_AUDIO_LIMITER.get_metrics()[&"heavy_requests"]
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_ATTACK_SLASH,
		Vector2.RIGHT,
		proxy.global_position,
		1,
		0.2
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_ATTACK_SLASH,
		Vector2.RIGHT,
		proxy.global_position,
		2,
		0.9
	)
	_expect(
		int(ENEMY_ATTACK_AUDIO_LIMITER.get_metrics()[&"heavy_requests"])
		== requests_after_first
		and not proxy.attack_slash_audio.playing,
		"重复ID不得重播，已超过0.78秒音频但仍在动作寿命内的包也必须静音。"
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL2_TAKEOFF,
		Vector2.UP,
		proxy.global_position,
		3,
		0.2
	)
	await process_frame
	_expect(
		proxy.skill2_takeoff_audio.playing
		and absf(proxy.skill2_takeoff_audio.get_playback_position() - 0.2) <= 0.08,
		"技能二起飞代理音必须支持原生偏移播放。"
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL2_TAKEOFF,
		Vector2.UP,
		proxy.global_position,
		4,
		0.6
	)
	_expect(
		not proxy.skill2_takeoff_audio.playing,
		"迟到至三秒追踪阶段的起飞动作不得补播起飞音。"
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_SKILL2_DROP,
		Vector2.DOWN,
		proxy.global_position,
		5,
		0.3
	)
	await process_frame
	_expect(
		proxy.skill2_drop_audio.playing
		and absf(proxy.skill2_drop_audio.get_playback_position() - 0.3) <= 0.08,
		"技能二落砸代理音必须按drop+recovery总时间轴偏移播放。"
	)
	proxy.current_health = 100
	proxy.hit_variant_index = 0
	proxy.play_multiplayer_damage_feedback(
		Vector2.RIGHT,
		CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
	)
	_expect(
		proxy.hit_audio.playing
		and proxy.hit_audio.stream == ENEMY_CONFIG.hit_audio_stream_a
		and proxy.hit_variant_index == 1,
		"代理收到一次已确认的非致命直击反馈时必须恰好播放一次专属受击音。"
	)
	proxy.set_multiplayer_proxy_visual_active(false)
	var requests_before_culled_action := int(
		ENEMY_ATTACK_AUDIO_LIMITER.get_metrics()[&"heavy_requests"]
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_ATTACK_SLASH,
		Vector2.RIGHT,
		proxy.global_position,
		6,
		0.2
	)
	_expect(
		not _any_action_audio_playing(proxy)
		and proxy.latest_proxy_action_id == 6
		and int(ENEMY_ATTACK_AUDIO_LIMITER.get_metrics()[&"heavy_requests"])
		== requests_before_culled_action,
		"代理不可见时必须消费动作水位但不请求音频，并立即停止正在播放的声音。"
	)
	proxy.set_multiplayer_proxy_visual_active(true)
	_expect(
		not _any_action_audio_playing(proxy),
		"代理恢复可见后不得补播裁剪期间的旧声音。"
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotMainBattleElite.ACTION_ATTACK_SLASH,
		Vector2.RIGHT,
		proxy.global_position,
		7,
		0.2
	)
	_expect(
		proxy.attack_slash_audio.playing,
		"恢复可见后仅下一条新动作可以发声。"
	)
	proxy.set_multiplayer_proxy_visual_active(false)
	proxy.play_multiplayer_death_sequence()
	_expect(
		proxy.is_dead
		and not proxy.death_audio.playing
		and not proxy.hit_audio.playing
		and not _any_action_audio_playing(proxy),
		"已裁剪代理的死亡只推进状态，不得发声或残留旧动作音。"
	)
	proxy.queue_free()
	player.queue_free()
	await process_frame


func _any_action_audio_playing(enemy: CombatRobotMainBattleElite) -> bool:
	for audio_player in enemy.call("_get_action_audio_players"):
		if (audio_player as AudioStreamPlayer2D).playing:
			return true
	return false


func _test_host_only_registry_contract() -> void:
	for duplicated_property in [
		&"burn_duration",
		&"burn_level",
		&"skill2_slow_duration",
		&"skill2_slow_multiplier",
	]:
		_expect(
			not _object_has_property(ENEMY_CONFIG, duplicated_property),
			"Main-battle status tuning must not have a second config source: %s."
			% duplicated_property
		)
	_expect(
		CombatAttackRegistry.encode_player_hit_source(
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL1
		) == CombatAttackRegistry.PlayerHitWireId.INVALID
		and CombatAttackRegistry.encode_player_hit_source(
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL2
		) == CombatAttackRegistry.PlayerHitWireId.INVALID
		and CombatAttackRegistry.get_burn_family(
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL1
		) == CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY
		and CombatAttackRegistry.get_burn_family(
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL2
		) == CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY
		and is_equal_approx(CombatAttackRegistry.get_burn_duration(
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL2
		), 5.0)
		and CombatAttackRegistry.get_burn_tick_damage(
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL2
		) == 5
		and is_equal_approx(
			CombatAttackRegistry.get_timed_move_slow_multiplier(
				CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL2
			),
			0.75
		),
		"S1/S2 statuses must be trusted Host semantics without new player-hit wire IDs."
	)


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	runtime.add_child(player)
	player.global_position = position
	player.max_health = 2000
	player.current_health = 2000
	player.set("_base_max_health", 2000)
	player.physical_defense = 0
	player.magic_defense = 0
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	return player


func _spawn_enemy(position: Vector2, player: Player) -> CombatRobotMainBattleElite:
	var enemy := ENEMY_SCENE.instantiate() as CombatRobotMainBattleElite
	runtime.get_node("EnemyContainer").add_child(enemy)
	enemy.global_position = position
	enemy.setup(ENEMY_CONFIG, player, null, runtime)
	enemy.set_physics_process(false)
	return enemy


func _all_shapes_disabled(shapes: Array[CollisionShape2D]) -> bool:
	if shapes.is_empty():
		return false
	for shape in shapes:
		if shape == null or not shape.disabled:
			return false
	return true


func _all_action_indicators_hidden(enemy: CombatRobotMainBattleElite) -> bool:
	return (
		not enemy.attack_warning.visible
		and not enemy.skill1_warning_line.visible
		and not enemy.skill1_circle_ring.visible
		and not enemy.skill2_cross_marker.visible
		and not enemy.skill2_fan_warning.visible
	)


func _object_has_property(object: Object, property_name: StringName) -> bool:
	for property_info in object.get_property_list():
		if StringName(property_info.get("name", &"")) == property_name:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
