extends SceneTree

## Stage-seven Boss target regression. A real Linglan is registered through the
## same stable enemy identity used by multiplayer descriptors. Real basic and
## fire-ranged Yuanshi instances designate it, damage it through authored melee
## and naturally-colliding projectile paths, then exercise unregister and death
## fallback paths.

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const BOSS_CONFIG := preload(
	"res://resources/config/enemies/linglan_boss.tres"
)
const BASIC_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const FIRE_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_fire_ranged.tres"
)

const BOSS_NET_ID := 71_001
const MELEE_NET_ID := 71_002
const FIRE_NET_ID := 71_003
const MELEE_FALLBACK_NET_ID := 71_004
const FIRE_FALLBACK_NET_ID := 71_005

var failures: Array[String] = []
var runtime: EnemyGameplayGatewayTestRuntime


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	runtime = RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	current_scene = runtime
	await process_frame
	var simulation_coordinator := runtime.get_enemy_simulation_coordinator()
	if simulation_coordinator == null:
		failures.append("Boss fixture must author EnemySimulationCoordinator.")
	else:
		simulation_coordinator.set_mode(
			EnemySimulationPolicy.Mode.LAYERED_CONTACT
		)
		_expect(
			simulation_coordinator.mode
				== EnemySimulationPolicy.Mode.LAYERED_CONTACT,
			"Boss fixture must exercise the production LAYERED_CONTACT mode."
		)

	var boss := _spawn_boss(Vector2.ZERO)
	var melee := _spawn_basic_enemy(
		MELEE_NET_ID,
		Vector2.ZERO,
		42
	)
	var fire := _spawn_fire_enemy(
		FIRE_NET_ID,
		Vector2(-64.0, 0.0),
		37
	)
	var melee_fallback := _spawn_basic_enemy(
		MELEE_FALLBACK_NET_ID,
		Vector2(220.0, 48.0),
		1
	)
	var fire_fallback := _spawn_basic_enemy(
		FIRE_FALLBACK_NET_ID,
		Vector2(240.0, -48.0),
		1
	)
	if (
		boss == null
		or melee == null
		or fire == null
		or melee_fallback == null
		or fire_fallback == null
	):
		await _finish_runtime()
		return

	melee.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	fire.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	_expect(
		boss.get_parent() == runtime.get_node("BossContainer")
		and boss.is_boss_enemy()
		and boss.is_active
		and boss.is_centrally_simulated()
		and not boss.uses_anchored_compat_simulation()
		and boss.supports_layered_area_authoritative_simulation()
		and not boss.supports_layered_contact_authoritative_simulation()
		and boss.authoritative_simulation_driver
			== Enemy.AuthoritativeSimulationDriver.SCHEDULED_ACTIVE
		and not boss.is_physics_processing()
		and boss.get_combat_faction_id() == CombatRelationService.HOSTILE_WAVE
		and not boss.can_change_combat_faction(),
		"The real Linglan must use layered event/motion ownership, retain its authored "
		+ "Boss contact path, and keep its locked faction inside LAYERED_CONTACT."
	)
	_expect(
		boss.get_node_or_null("EnemySimulationPhaseAnchor") == null,
		"Migrated Linglan must not retain the obsolete tree-order COMPAT anchor."
	)
	# Freeze autonomous AI only after proving real layered ownership. The rest of
	# this regression drives authored attack sinks deterministically while physics
	# remains active for the real projectile/body collision.
	if simulation_coordinator != null:
		simulation_coordinator.set_physics_process(false)
	var rejected_faction_change := boss.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		1
	)
	_expect(
		not rejected_faction_change
		and boss.get_combat_faction_id() == CombatRelationService.HOSTILE_WAVE
		and boss.get_faction_revision() == 0,
		"Ordinary runtime mutation must not unlock or revise Linglan's faction."
	)

	_expect(
		melee.consider_automatic_combat_target(melee_fallback, 1)
		and fire.consider_automatic_combat_target(fire_fallback, 1),
		"Both attackers must retain a real hostile automatic fallback."
	)
	var boss_descriptor := CombatTargetDescriptor.create_enemy(
		BOSS_NET_ID,
		boss.get_faction_revision(),
		boss.global_position
	)
	_expect(
		boss_descriptor != null
		and boss_descriptor.kind == CombatTargetDescriptor.Kind.ENEMY
		and boss_descriptor.id == BOSS_NET_ID
		and melee.apply_designated_combat_target(
			boss_descriptor.duplicate(),
			1
		)
		and fire.apply_designated_combat_target(
			boss_descriptor.duplicate(),
			1
		)
		and melee.objective_target == boss
		and fire.objective_target == boss
		and melee.can_attack_combat_target(boss)
		and fire.can_attack_combat_target(boss),
		"Generic Enemy descriptors must resolve Linglan as the absolute hostile target."
	)

	# Let authored global transforms enter the physics space before the real LOS
	# query; the attack and collision assertions below remain deterministic.
	await physics_frame
	_test_real_melee_damage(melee, boss)
	await _test_real_fire_projectile_damage(fire, boss)

	# First invalidate only the stable identity while Linglan remains alive. The
	# fire attacker must suppress its designated descriptor and expose its cached
	# automatic target without relying on the raw object pointer.
	var unregistered_boss := runtime.unregister_network_enemy(BOSS_NET_ID, boss)
	fire.refresh_dynamic_combat_target_decision(Engine.get_physics_frames())
	_expect(
		unregistered_boss == boss
		and not boss.is_dead
		and fire.objective_target == fire_fallback
		and fire.get_automatic_combat_target() == fire_fallback,
		"An unregistered live Boss descriptor must fall back to the cached hostile target."
	)
	_expect(
		runtime.register_network_enemy(BOSS_NET_ID, boss),
		"The Boss identity must be restorable for the independent death path."
	)

	var lethal_request := DamageRequest.new(
		boss.current_health,
		CombatTypes.DamageType.PHYSICAL
	).with_source_snapshot(DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		1,
		MELEE_NET_ID,
		81_001,
		&"boss_dynamic_target_terminal"
	))
	lethal_request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	lethal_request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_FLASH)
	var lethal_result := boss.apply_combat_damage(lethal_request)
	melee.refresh_dynamic_combat_target_decision(
		Engine.get_physics_frames() + 1
	)
	_expect(
		lethal_result.lethal
		and boss.is_dead
		and melee.objective_target == melee_fallback
		and melee.get_automatic_combat_target() == melee_fallback,
		"A dead designated Boss must become unattackable and release melee to fallback."
	)

	await _finish_runtime()


func _test_real_melee_damage(
	melee: YuanshiInsect,
	boss: LinglanBoss
) -> void:
	melee.global_position = boss.global_position
	melee.touch_damage_cooldown_left = 0.0
	var health_before := boss.current_health
	melee.call(&"_try_deal_touch_damage")
	_expect(
		health_before - boss.current_health == 42
		and boss.last_damage_result != null
		and boss.last_damage_result.accepted
		and boss.last_damage_result.applied_damage == 42
		and boss.last_damage_result.resolved_damage == 42
		and boss.last_damage_result.request.get_or_create_source_snapshot(
		).source_faction_id == CombatRelationService.PLAYER_ALLIED,
		"A descriptor-targeted basic Yuanshi must damage the real Boss via touch combat."
	)


func _test_real_fire_projectile_damage(
	fire: YuanshiInsectFireRanged,
	boss: LinglanBoss
) -> void:
	var clear_line := bool(fire.call(
		&"_has_ranged_combat_line",
		boss,
		YuanshiInsectFireRanged.WORLD_COLLISION_MASK,
		true
	))
	var attack_started := bool(fire.call(
		&"_try_start_ranged_attack",
		boss
	))
	var projectile_ids_before := _get_fire_projectile_instance_ids()
	var projectile_fired := bool(fire.call(&"_try_fire_ranged_projectile"))
	# Directly consuming the authored fire edge must also close the animation
	# edge, preventing a later visual frame from creating a duplicate projectile.
	fire.attack_has_fired = projectile_fired
	var projectile := _find_new_fire_projectile(projectile_ids_before)
	var health_before := boss.current_health
	var launch_snapshot: DamageSourceSnapshot = null
	var launch_position := Vector2.ZERO
	var launch_direction := Vector2.ZERO
	var projectile_finished_state := {"count": 0}
	if projectile != null:
		launch_position = projectile.global_position
		launch_direction = projectile.direction
		if projectile.damage_source_snapshot != null:
			launch_snapshot = projectile.damage_source_snapshot.duplicate_snapshot()
		projectile.projectile_finished.connect(Callable(
			self,
			&"_capture_projectile_finished"
		).bind(projectile_finished_state))
	var launch_contract_valid := (
		projectile != null
		and launch_snapshot != null
		and launch_snapshot.source_faction_id
			== CombatRelationService.PLAYER_ALLIED
		and launch_snapshot.instigator_entity_id == FIRE_NET_ID
		and launch_snapshot.source_type == &"yuanshi_fire_projectile"
		and (projectile.collision_mask & boss.collision_layer) != 0
		and launch_position.x < boss.global_position.x
		and launch_direction.dot(
			launch_position.direction_to(boss.global_position)
		) > 0.99
	)
	# No render-frame timing participates: the authored Area2D moves and reports
	# its own body_entered edge on bounded physics ticks.
	for _physics_step in range(90):
		if int(projectile_finished_state["count"]) > 0:
			break
		await physics_frame
	var health_after_hit := boss.current_health
	await physics_frame
	await physics_frame
	_expect(
		clear_line
		and attack_started
		and projectile_fired
		and launch_contract_valid
		and int(projectile_finished_state["count"]) == 1
		and health_before - health_after_hit == 37
		and boss.current_health == health_after_hit
		and boss.last_damage_result != null
		and boss.last_damage_result.accepted
		and boss.last_damage_result.applied_damage == 37
		and boss.last_damage_result.resolved_damage == 37
		and boss.last_damage_result.request.get_or_create_source_snapshot(
		).source_faction_id == CombatRelationService.PLAYER_ALLIED
		and boss.last_damage_result.request.has_flag(
			CombatTypes.DamageFlag.RANGED
		),
		"A descriptor-targeted fire Yuanshi projectile must naturally hit "
		+ "Linglan once with frozen source attribution."
	)
	fire.call(&"_finish_ranged_attack")


func _capture_projectile_finished(
	_projectile_id: int,
	_finished_projectile: Node,
	capture_state: Dictionary
) -> void:
	capture_state["count"] = int(capture_state["count"]) + 1


func _spawn_boss(position: Vector2) -> LinglanBoss:
	var enemy_config := BOSS_CONFIG.duplicate(true) as EnemyConfig
	enemy_config.max_health = 200
	enemy_config.physical_defense = 0
	enemy_config.magic_defense = 0
	enemy_config.xirang_kill_reward = 0
	enemy_config.drop_table = null
	var boss := enemy_config.enemy_scene.instantiate() as LinglanBoss
	if boss == null:
		failures.append("The real Linglan scene could not be instantiated.")
		return null
	var boss_container := runtime.get_node("BossContainer") as Node2D
	boss_container.add_child(boss)
	boss.global_position = position
	boss.setup(enemy_config, null, runtime.grid_pathfinder, runtime)
	boss.set_active(true)
	boss.set_process(false)
	if not runtime.register_network_enemy(BOSS_NET_ID, boss):
		failures.append("Linglan could not enter the stable combat target index.")
	return boss


func _spawn_basic_enemy(
	net_id: int,
	position: Vector2,
	attack_damage: int
) -> YuanshiInsect:
	var enemy_config := BASIC_CONFIG.duplicate(true) as YuanshiInsectConfig
	enemy_config.attack_damage = maxi(attack_damage, 1)
	enemy_config.xirang_kill_reward = 0
	enemy_config.drop_table = null
	var enemy := enemy_config.enemy_scene.instantiate() as YuanshiInsect
	if enemy == null:
		failures.append("Basic Yuanshi %d could not instantiate." % net_id)
		return null
	runtime.enemy_container.add_child(enemy)
	enemy.global_position = position
	enemy.setup(enemy_config, null, runtime.grid_pathfinder, runtime)
	enemy.set_process(false)
	enemy.set_authoritative_simulation_enabled(false)
	if not runtime.register_network_enemy(net_id, enemy):
		failures.append("Basic Yuanshi %d could not register." % net_id)
	return enemy


func _spawn_fire_enemy(
	net_id: int,
	position: Vector2,
	attack_damage: int
) -> YuanshiInsectFireRanged:
	var enemy_config := (
		FIRE_CONFIG.duplicate(true) as YuanshiInsectFireRangedConfig
	)
	enemy_config.attack_damage = maxi(attack_damage, 1)
	enemy_config.xirang_kill_reward = 0
	enemy_config.drop_table = null
	var enemy := (
		enemy_config.enemy_scene.instantiate() as YuanshiInsectFireRanged
	)
	if enemy == null:
		failures.append("Fire Yuanshi %d could not instantiate." % net_id)
		return null
	runtime.enemy_container.add_child(enemy)
	enemy.global_position = position
	enemy.setup(enemy_config, null, runtime.grid_pathfinder, runtime)
	enemy.set_process(false)
	enemy.set_authoritative_simulation_enabled(false)
	if not runtime.register_network_enemy(net_id, enemy):
		failures.append("Fire Yuanshi %d could not register." % net_id)
	return enemy


func _get_fire_projectile_instance_ids() -> Dictionary[int, bool]:
	var result: Dictionary[int, bool] = {}
	for child in runtime.get_children():
		if child is YuanshiInsectFireProjectile:
			result[child.get_instance_id()] = true
	return result


func _find_new_fire_projectile(
	previous_ids: Dictionary[int, bool]
) -> YuanshiInsectFireProjectile:
	for child in runtime.get_children():
		var projectile := child as YuanshiInsectFireProjectile
		if (
			projectile != null
			and not previous_ids.has(projectile.get_instance_id())
		):
			return projectile
	return null


func _finish_runtime() -> void:
	current_scene = null
	if runtime != null and is_instance_valid(runtime):
		runtime.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("ENEMY_BOSS_DYNAMIC_TARGET_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
