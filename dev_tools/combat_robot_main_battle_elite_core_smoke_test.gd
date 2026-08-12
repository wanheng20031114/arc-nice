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

	_test_config_and_fail_closed_visual_contract()
	await _test_damage_geometry_and_statuses()
	await _test_attack_frame_timing_and_target_selection()
	await _test_airborne_direct_damage_and_periodic_contract()
	await _test_skill_lock_tracking_and_collision_toggle()
	await _test_proxy_action_and_status_contract()
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


func _test_config_and_fail_closed_visual_contract() -> void:
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
		and ENEMY_CONFIG.drop_table == DEFAULT_DROP_TABLE,
		"Main-battle robot stats/tags/drop contract mismatch."
	)
	var enemy := ENEMY_SCENE.instantiate() as CombatRobotMainBattleElite
	_expect(enemy != null, "Main-battle scene must instantiate its strong type.")
	if enemy == null:
		return
	_expect(
		bool(enemy.get_meta("runtime_visual_release_blocked", false))
		and String(enemy.get_meta("expected_runtime_sprite_frames", ""))
			== CombatRobotMainBattleElite.EXPECTED_RUNTIME_SPRITE_FRAMES_PATH
		and not enemy.has_released_runtime_visuals(),
		"Missing approved native SpriteFrames must remain explicit and fail closed."
	)
	_expect(
		enemy.get_node_or_null("AttackWarning") is Polygon2D
		and enemy.get_node_or_null("Skill1WarningLine") is Line2D
		and enemy.get_node_or_null("Skill1CircleRing") is Line2D
		and enemy.get_node_or_null("Skill2CrossMarker/Horizontal") is Line2D
		and enemy.get_node_or_null("Skill2FanWarning") is Polygon2D,
		"All gameplay indicators must be authored as static scene nodes."
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
	_expect(
		front.current_health == front_before - 96
		and bool(root.get_node("BurnStatusScheduler").call(
			"has_burn",
			front,
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY
		)),
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
	_expect(
		front.current_health == front_before - 120
		and is_equal_approx(float(slow_scheduler.call(
			"get_effective_multiplier",
			front
		)), 0.75)
		and int(slow_scheduler.call("get_source_count", front)) == 1,
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

	var test_frames := SpriteFrames.new()
	test_frames.add_animation(ENEMY_CONFIG.attack_animation_name)
	test_frames.set_animation_speed(ENEMY_CONFIG.attack_animation_name, 15.0)
	test_frames.set_animation_loop(ENEMY_CONFIG.attack_animation_name, false)
	for _frame_index in range(5):
		test_frames.add_frame(ENEMY_CONFIG.attack_animation_name, null)
	enemy.animated_sprite.sprite_frames = test_frames
	enemy.call("_start_attack_windup", near_player)
	_expect(
		enemy.animated_sprite.animation != ENEMY_CONFIG.attack_animation_name,
		"The 0.35-second warning must not consume the five slash frames."
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
		"Normal slash must not damage before the second 15 FPS frame."
	)
	enemy.call("_update_attack_slash", 0.002)
	_expect(
		near_player.current_health == health_before - 80,
		"Normal slash must resolve exactly once when frame 1 begins."
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
	proxy.queue_free()
	player.queue_free()
	await process_frame


func _test_host_only_registry_contract() -> void:
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


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
