extends SceneTree

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const RPG_ROCKET_SCENE := preload(
	"res://scene/enemy/capoo/capoo_rpg_rocket.tscn"
)
const MAGE_FIREBALL_SCENE := preload(
	"res://scene/enemy/capoo/capoo_mage_fireball.tscn"
)
const SUICIDE_DRONE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn"
)
const MAIN_BATTLE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_main_battle_elite.tscn"
)
const MAIN_BATTLE_CONFIG: CombatRobotMainBattleEliteConfig = preload(
	"res://resources/config/enemies/combat_robot_main_battle_elite.tres"
)
const YUANSHI_BOMBER_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_bomber.tres"
)

var failures: Array[String] = []
var runtime: EnemyGameplayGatewayTestRuntime = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	runtime = RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	current_scene = runtime
	await physics_frame

	await _test_shape_aoe_records_only_accepted_enemy_damage()
	await _test_other_shape_aoe_ledgers_follow_sink_acceptance()
	await _test_yuanshi_helper_reports_only_accepted_enemy_damage()

	runtime.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("ENEMY_AOE_DAMAGE_ACCEPTANCE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_shape_aoe_records_only_accepted_enemy_damage() -> void:
	var target := _spawn_direct_immune_target(Vector2(96.0, 96.0))
	target.airborne = false
	target.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		1,
		true
	)
	var rocket := RPG_ROCKET_SCENE.instantiate() as CapooRPGRocket
	runtime.add_child(rocket)
	rocket.global_position = target.global_position
	rocket.bind_gameplay_context(
		runtime,
		runtime.get_multiplayer_gameplay_gateway()
	)
	rocket.setup(
		Vector2.RIGHT,
		37,
		0.0,
		1.0,
		44.0,
		_player_allied_source(41001, &"aoe_acceptance_rpg")
	)
	rocket.set_physics_process(false)
	var health_before := target.current_health
	var target_id := target.get_instance_id()

	rocket.call(
		"_apply_explosion_damage_to_body",
		target,
		rocket.explosion_damaged_bodies
	)
	_expect(
		target.current_health == health_before
		and not rocket.explosion_damaged_bodies.has(target_id),
		"Shape AoE must not reserve its hit ledger when faction admission rejects a friendly target."
	)

	target.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		2,
		true
	)
	rocket.call(
		"_apply_explosion_damage_to_body",
		target,
		rocket.explosion_damaged_bodies
	)
	var health_after_accept := target.current_health
	_expect(
		health_after_accept < health_before
		and rocket.explosion_damaged_bodies.has(target_id),
		"The same shape-AoE action must remain eligible after a friendly rejection and record the now-hostile target after acceptance."
	)
	rocket.call(
		"_apply_explosion_damage_to_body",
		target,
		rocket.explosion_damaged_bodies
	)
	_expect(
		target.current_health == health_after_accept,
		"An accepted shape-AoE hit must still be de-duplicated within the action."
	)

	rocket.queue_free()
	target.queue_free()
	await physics_frame


func _test_other_shape_aoe_ledgers_follow_sink_acceptance() -> void:
	var mage_target := _spawn_direct_immune_target(Vector2(160.0, 176.0))
	var fireball := MAGE_FIREBALL_SCENE.instantiate() as CapooMageFireball
	runtime.add_child(fireball)
	fireball.global_position = mage_target.global_position
	fireball.bind_gameplay_context(
		runtime,
		runtime.get_multiplayer_gameplay_gateway()
	)
	fireball.setup(
		Vector2.RIGHT,
		31,
		0.0,
		1.0,
		24.0,
		null,
		0.0,
		_player_allied_source(43001, &"aoe_acceptance_mage")
	)
	fireball.set_physics_process(false)
	var mage_health_before := mage_target.current_health
	var mage_target_id := mage_target.get_instance_id()
	fireball.call(
		"_apply_explosion_damage_to_body",
		mage_target,
		fireball.explosion_damaged_bodies
	)
	_expect(
		mage_target.current_health == mage_health_before
		and not fireball.explosion_damaged_bodies.has(mage_target_id),
		"Mage shape AoE must leave its ledger open after an invulnerable rejection."
	)
	mage_target.airborne = false
	fireball.call(
		"_apply_explosion_damage_to_body",
		mage_target,
		fireball.explosion_damaged_bodies
	)
	_expect(
		mage_target.current_health < mage_health_before
		and fireball.explosion_damaged_bodies.has(mage_target_id),
		"Mage shape AoE must record only its later accepted retry."
	)

	var drone_target := _spawn_direct_immune_target(Vector2(288.0, 176.0))
	var drone := SUICIDE_DRONE_SCENE.instantiate() as CombatRobotSuicideDrone
	runtime.add_child(drone)
	drone.global_position = drone_target.global_position
	drone.bind_gameplay_context(
		runtime,
		runtime.get_multiplayer_gameplay_gateway()
	)
	drone.setup(
		Vector2.RIGHT,
		29,
		0.0,
		1.0,
		28.0,
		null,
		_player_allied_source(44001, &"aoe_acceptance_drone")
	)
	drone.target_position = drone_target.global_position
	var drone_health_before := drone_target.current_health
	var drone_target_id := drone_target.get_instance_id()
	drone.call("_apply_explosion_damage_to_body", drone_target)
	_expect(
		drone_target.current_health == drone_health_before
		and not drone.explosion_damaged_bodies.has(drone_target_id),
		"Drone shape AoE must leave its ledger open after an invulnerable rejection."
	)
	drone_target.airborne = false
	drone.call("_apply_explosion_damage_to_body", drone_target)
	_expect(
		drone_target.current_health < drone_health_before
		and drone.explosion_damaged_bodies.has(drone_target_id),
		"Drone shape AoE must record only its later accepted retry."
	)

	fireball.queue_free()
	mage_target.queue_free()
	drone.queue_free()
	drone_target.queue_free()
	await physics_frame


func _test_yuanshi_helper_reports_only_accepted_enemy_damage() -> void:
	var target := _spawn_direct_immune_target(Vector2(224.0, 96.0))
	var exploder := (
		YUANSHI_BOMBER_CONFIG.enemy_scene.instantiate()
		as YuanshiInsectExploder
	)
	runtime.get_node("EnemyContainer").add_child(exploder)
	exploder.global_position = Vector2(192.0, 96.0)
	exploder.setup(YUANSHI_BOMBER_CONFIG, null, null, runtime)
	exploder.set_physics_process(false)
	exploder.outgoing_explosion_damage_snapshot = 43
	exploder.outgoing_explosion_source_snapshot = _player_allied_source(
		42001,
		&"aoe_acceptance_yuanshi"
	)
	var health_before := target.current_health

	var rejected := bool(exploder.call(
		"_try_apply_explosion_damage_to_enemy",
		target
	))
	_expect(
		not rejected and target.current_health == health_before,
		"Yuanshi enemy helper must report false when direct immunity rejects its request."
	)

	target.airborne = false
	var accepted := bool(exploder.call(
		"_try_apply_explosion_damage_to_enemy",
		target
	))
	_expect(
		accepted and target.current_health < health_before,
		"Yuanshi enemy helper must remain retryable and report true only after sink acceptance."
	)

	exploder.queue_free()
	target.queue_free()
	await physics_frame


func _spawn_direct_immune_target(
	position: Vector2
) -> CombatRobotMainBattleElite:
	var target := MAIN_BATTLE_SCENE.instantiate() as CombatRobotMainBattleElite
	runtime.get_node("EnemyContainer").add_child(target)
	target.global_position = position
	target.setup(MAIN_BATTLE_CONFIG, null, null, runtime)
	target.set_physics_process(false)
	target.airborne = true
	return target


func _player_allied_source(
	event_source_id: int,
	source_type: StringName
) -> DamageSourceSnapshot:
	return DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		1,
		1,
		event_source_id,
		source_type
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
