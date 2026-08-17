extends SceneTree

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const AGAVE_SCENE := preload(
	"res://scene/plant_defense/agave_cannon.tscn"
)
const BASIC_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const BURN_VISUAL_MASK := 1
const BLEED_VISUAL_MASK := 2
const CHILL_VISUAL_MASK := 4
const MARK_VISUAL_MASK := 8

var failures: Array[String] = []
var fixture: Node2D = null
var burn_scheduler: Node = null
var bleed_scheduler: Node = null
var enemy_status_scheduler: Node = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "DamageOverTimeStatusTargetsSmokeTest"
	root.add_child(fixture)
	current_scene = fixture

	burn_scheduler = root.get_node("BurnStatusScheduler")
	bleed_scheduler = root.get_node("BleedStatusScheduler")
	enemy_status_scheduler = root.get_node("EnemyCollectibleStatusScheduler")
	_reset_schedulers()

	_test_burn_overlay_strength_contract()
	await _test_player_damage_type_and_independent_visual_lifecycle()
	await _test_plant_bleed_contract_and_movement_status_rejection()
	await _test_enemy_shared_timeline_and_scoped_clear()

	_reset_schedulers()
	current_scene = null
	fixture.queue_free()
	await process_frame
	await physics_frame

	if failures.is_empty():
		print("DAMAGE_OVER_TIME_STATUS_TARGETS_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_burn_overlay_strength_contract() -> void:
	_expect(
		is_equal_approx(Enemy.BURN_OVERLAY_ACTIVE_STRENGTH, 0.72)
		and is_equal_approx(
			Player.BURN_OVERLAY_ACTIVE_STRENGTH,
			Enemy.BURN_OVERLAY_ACTIVE_STRENGTH
		)
		and is_equal_approx(
			PlantDefense.BURN_OVERLAY_ACTIVE_STRENGTH,
			Enemy.BURN_OVERLAY_ACTIVE_STRENGTH
		),
		"Enemy, Player, and PlantDefense burn overlays must share the stronger 0.72 tint."
	)


func _test_player_damage_type_and_independent_visual_lifecycle() -> void:
	_reset_schedulers()
	var player := _spawn_player()
	var body_sprite := player.get_node("BodySprite") as AnimatedSprite2D
	player.physical_defense = 7
	player.current_health = player.max_health
	var health_before_tick := player.current_health

	_expect(
		player.apply_burn_status(&"target_test_burn", 3.0, 20)
		and player.apply_bleed_status(
			&"target_test_bleed",
			0.75,
			player.physical_defense + 6,
			0.5
		),
		"Player must accept burn and real bleed through the shared DOT contract."
	)
	_expect(
		player.has_damage_over_time_status(&"burn", &"target_test_burn")
		and player.has_damage_over_time_status(
			&"bleed",
			&"target_test_bleed"
		)
		and _get_shader_strength(
			body_sprite,
			Player.BURN_OVERLAY_STRENGTH_SHADER_PARAMETER
		) == Player.BURN_OVERLAY_ACTIVE_STRENGTH
		and _get_shader_strength(
			body_sprite,
			Player.BLEED_OVERLAY_STRENGTH_SHADER_PARAMETER
		) > 0.0,
		"Player burn and bleed must own independent active state and overlays."
	)

	bleed_scheduler.call("_advance_active_statuses", 0.5)
	_expect(
		player.current_health == health_before_tick - 6
		and player.last_damage_taken == 6,
		"Player bleed must deal PHYSICAL damage through current physical defense."
	)
	bleed_scheduler.call("_advance_active_statuses", 0.26)
	_expect(
		not player.has_damage_over_time_status(&"bleed")
		and player.has_damage_over_time_status(&"burn")
		and is_zero_approx(_get_shader_strength(
			body_sprite,
			Player.BLEED_OVERLAY_STRENGTH_SHADER_PARAMETER
		))
		and _get_shader_strength(
			body_sprite,
			Player.BURN_OVERLAY_STRENGTH_SHADER_PARAMETER
		) > 0.0,
		"Natural bleed expiry must clear only its overlay while burn remains active."
	)

	_expect(
		player.apply_bleed_status(&"target_test_bleed_reapply", 3.0, 8),
		"Player must accept bleed again after natural expiry."
	)
	player.clear_burn_status()
	_expect(
		not player.has_damage_over_time_status(&"burn")
		and player.has_damage_over_time_status(&"bleed")
		and is_zero_approx(_get_shader_strength(
			body_sprite,
			Player.BURN_OVERLAY_STRENGTH_SHADER_PARAMETER
		))
		and _get_shader_strength(
			body_sprite,
			Player.BLEED_OVERLAY_STRENGTH_SHADER_PARAMETER
		) > 0.0,
		"Clearing Player burn must not clear an independent bleed or its overlay."
	)
	player.clear_bleed_status()
	_expect(
		not player.has_damage_over_time_status(&"bleed")
		and is_zero_approx(_get_shader_strength(
			body_sprite,
			Player.BLEED_OVERLAY_STRENGTH_SHADER_PARAMETER
		)),
		"Explicit Player bleed clear must synchronously clear state and overlay."
	)

	player.queue_free()
	await process_frame


func _test_plant_bleed_contract_and_movement_status_rejection() -> void:
	_reset_schedulers()
	var plant := AGAVE_SCENE.instantiate() as AgaveCannon
	fixture.add_child(plant)
	plant.setup(
		PlantDefenseRegistry.get_config(&"agave_cannon"),
		null,
		[],
		false,
		-1,
		0,
		-1,
		false
	)
	plant.attack_timer.stop()
	var status_events: Array[Vector2i] = []
	plant.authoritative_damage_status_changed.connect(
		func(status_mask: int, revision: int) -> void:
			status_events.append(Vector2i(status_mask, revision))
	)

	_expect(
		plant.apply_bleed_status(&"building_bleed_source", 2.0, 9)
		and plant.has_damage_over_time_status(
			&"bleed",
			&"building_bleed_source"
		),
		"PlantDefense must expose the same real bleed application/query contract."
	)
	_expect(
		status_events == [Vector2i(PlantDefense.BLEED_DAMAGE_STATUS_MASK, 1)],
		"Authority buildings must emit one revisioned mask transition when bleed starts."
	)
	_expect(
		not plant.has_method("apply_cold_status")
		and not plant.set_damage_status_visual_active(&"cold", true)
		and not plant.set_damage_status_visual_active(&"slow", true)
		and not plant.set_damage_status_visual_active(&"haste", true)
		and not plant.clear_damage_over_time_status(&"cold")
		and plant.has_damage_over_time_status(&"bleed"),
		"Static buildings must reject cold/slow/haste without disturbing real bleed."
	)
	plant.clear_bleed_status()
	_expect(
		not plant.has_damage_over_time_status(&"bleed")
		and status_events == [
			Vector2i(PlantDefense.BLEED_DAMAGE_STATUS_MASK, 1),
			Vector2i(0, 2),
		],
		"PlantDefense.clear_bleed_status must clear state and emit the terminal mask revision."
	)

	var proxy := AGAVE_SCENE.instantiate() as AgaveCannon
	fixture.add_child(proxy)
	proxy.setup(
		PlantDefenseRegistry.get_config(&"agave_cannon"),
		null,
		[],
		true,
		-1,
		0,
		-1,
		false
	)
	proxy.attack_timer.stop()
	var proxy_body := proxy.get_node(
		"VisualRoot/BodySprite"
	) as AnimatedSprite2D
	_expect(
		proxy.apply_remote_damage_status_mask(
			PlantDefense.BURN_DAMAGE_STATUS_MASK
				| PlantDefense.BLEED_DAMAGE_STATUS_MASK,
			5
		)
		and proxy.get_damage_status_mask()
			== PlantDefense.VALID_DAMAGE_STATUS_MASK
		and _get_shader_strength(
			proxy_body,
			PlantDefense.BURN_OVERLAY_PARAMETER
		) == PlantDefense.BURN_OVERLAY_ACTIVE_STRENGTH
		and _get_shader_strength(
			proxy_body,
			PlantDefense.BLEED_OVERLAY_PARAMETER
		) > 0.0
		and not bool(burn_scheduler.call("has_status", proxy))
		and not bool(bleed_scheduler.call("has_status", proxy)),
		"A building proxy must render replicated burn/bleed masks without scheduling local damage."
	)
	_expect(
		not proxy.apply_remote_damage_status_mask(0, 4)
		and proxy.get_damage_status_mask()
			== PlantDefense.VALID_DAMAGE_STATUS_MASK,
		"A stale building damage-status revision must not roll proxy visuals back."
	)
	_expect(
		proxy.apply_remote_damage_status_mask(0, 6)
		and proxy.get_damage_status_mask() == 0
		and is_zero_approx(_get_shader_strength(
			proxy_body,
			PlantDefense.BURN_OVERLAY_PARAMETER
		))
		and is_zero_approx(_get_shader_strength(
			proxy_body,
			PlantDefense.BLEED_OVERLAY_PARAMETER
		)),
		"A newer zero mask must clear both replicated building overlays."
	)

	plant.queue_free()
	proxy.queue_free()
	await process_frame


func _test_enemy_shared_timeline_and_scoped_clear() -> void:
	_reset_schedulers()
	var enemy_config := BASIC_ENEMY_CONFIG.duplicate(true) as EnemyConfig
	enemy_config.max_health = 200
	enemy_config.physical_defense = 4
	enemy_config.xirang_kill_reward = 0
	enemy_config.drop_table = null
	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	fixture.add_child(enemy)
	enemy.setup(enemy_config, null, null)
	enemy.set_physics_process(false)
	enemy.set_process(false)
	enemy.hit_audio.stream = null

	enemy.apply_collectible_status(
		&"chill",
		71_001,
		4.0,
		0,
		0.5,
		EnemyConfig.DamageType.MAGIC,
		0.8
	)
	enemy.apply_collectible_status(&"mark", 71_002, 4.0)
	_expect(
		enemy.apply_burn_status(&"external_burn", 4.0, 12)
		and enemy.apply_bleed_status(
			&"external_bleed_a",
			3.0,
			enemy.get_effective_physical_defense() + 3,
			0.5
		)
		and enemy.apply_bleed_status(
			&"external_bleed_b",
			3.0,
			enemy.get_effective_physical_defense() + 5,
			0.5
		),
		"Enemy must accept external burn and independently keyed bleed sources."
	)
	_expect(
		enemy.has_damage_over_time_status(&"burn", &"external_burn")
		and enemy.has_damage_over_time_status(
			&"bleed",
			&"external_bleed_a"
		)
		and enemy.has_damage_over_time_status(
			&"bleed",
			&"external_bleed_b"
		)
		and enemy.has_collectible_status(&"chill")
		and enemy.has_collectible_status(&"mark")
		and is_equal_approx(
			enemy.burn_overlay_strength,
			Enemy.BURN_OVERLAY_ACTIVE_STRENGTH
		)
		and not bool(bleed_scheduler.call("has_status", enemy)),
		"Enemy external DOTs must live on its existing collectible timeline, not the Player/Plant bleed lane."
	)

	var health_before_ticks := enemy.current_health
	enemy_status_scheduler.call("advance_for_test", 0.5)
	_expect(
		enemy.current_health == health_before_ticks - 8,
		"Two Enemy bleed sources must tick independently and each use PHYSICAL defense."
	)

	_expect(
		enemy.clear_damage_over_time_status(&"bleed")
		and not enemy.has_damage_over_time_status(&"bleed")
		and not enemy.has_damage_over_time_status(
			&"bleed",
			&"external_bleed_a"
		)
		and enemy.has_damage_over_time_status(&"burn", &"external_burn")
		and enemy.has_collectible_status(&"chill")
		and enemy.has_collectible_status(&"mark"),
		"Enemy bleed clear must remove every bleed source without clearing burn, chill, or mark."
	)
	var mask_after_bleed_clear := enemy.get_collectible_visual_status_mask()
	_expect(
		(mask_after_bleed_clear & BLEED_VISUAL_MASK) == 0
		and (mask_after_bleed_clear & BURN_VISUAL_MASK) != 0
		and (mask_after_bleed_clear & CHILL_VISUAL_MASK) != 0
		and (mask_after_bleed_clear & MARK_VISUAL_MASK) != 0,
		"Enemy visual status mask must preserve burn/chill/mark when bleed clears."
	)

	_expect(
		not enemy.clear_damage_over_time_status(&"chill")
		and enemy.has_collectible_status(&"chill")
		and enemy.has_collectible_status(&"mark"),
		"The DOT clear API must reject movement statuses and leave them untouched."
	)
	enemy.clear_burn_status()
	_expect(
		not enemy.has_damage_over_time_status(&"burn")
		and enemy.has_collectible_status(&"chill")
		and enemy.has_collectible_status(&"mark"),
		"Enemy burn clear must also remain scoped to its corresponding DOT."
	)

	enemy.clear_collectible_statuses()
	enemy.queue_free()
	await process_frame


func _spawn_player() -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	player.set_physics_process(false)
	player.set_process(false)
	player.peer_id = 0
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	return player


func _get_shader_strength(
	sprite: AnimatedSprite2D,
	parameter_name: StringName
) -> float:
	return float(sprite.get_instance_shader_parameter(parameter_name))


func _reset_schedulers() -> void:
	for scheduler in [burn_scheduler, bleed_scheduler, enemy_status_scheduler]:
		if scheduler == null:
			continue
		scheduler.call("clear_all")
		scheduler.set_physics_process(false)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
