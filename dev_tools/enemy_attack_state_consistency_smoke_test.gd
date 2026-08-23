extends SceneTree

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const AGAVE_SCENE := preload("res://scene/plant_defense/agave_cannon.tscn")
const AGAVE_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)
const SMG_SCENE := preload("res://scene/enemy/capoo/capoo_smg.tscn")
const SMG_CONFIG := preload("res://resources/config/enemies/capoo_smg.tres")
const SNIPER_SCENE := preload("res://scene/enemy/capoo/capoo_sniper.tscn")
const SNIPER_CONFIG := preload("res://resources/config/enemies/capoo_sniper.tres")
const KNIGHT_SCENE := preload("res://scene/enemy/capoo/capoo_knight.tscn")
const KNIGHT_CONFIG := preload("res://resources/config/enemies/capoo_knight.tres")
const MAIN_BATTLE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_main_battle_elite.tscn"
)
const MAIN_BATTLE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_main_battle_elite.tres"
)


class RecordingGameplaySession:
	extends EnemyGameplayGatewayTestSession

	var enemy_actions: Array[Dictionary] = []
	var enemy_target_actions: Array[Dictionary] = []
	var enemy_target_presentation_states: Array[Dictionary] = []


	func broadcast_enemy_action(
		net_id: int,
		action_name: StringName,
		direction: Vector2,
		action_position: Vector2,
		action_id: int
	) -> void:
		enemy_actions.append({
			"net_id": net_id,
			"action_name": action_name,
			"direction": direction,
			"action_position": action_position,
			"action_id": action_id,
		})


	func broadcast_enemy_target_action(
		net_id: int,
		action_name: StringName,
		target_descriptor: CombatTargetDescriptor,
		action_position: Vector2,
		action_id: int
	) -> void:
		enemy_target_actions.append({
			"net_id": net_id,
			"action_name": action_name,
			"target_descriptor": target_descriptor.duplicate(),
			"action_position": action_position,
			"action_id": action_id,
		})


	func broadcast_enemy_target_presentation_state(
		net_id: int,
		phase: int,
		target_descriptor: CombatTargetDescriptor,
		duration_seconds: float,
		action_position: Vector2,
		state_revision: int
	) -> void:
		enemy_target_presentation_states.append({
			"net_id": net_id,
			"phase": phase,
			"target_descriptor": target_descriptor.duplicate(),
			"duration_seconds": duration_seconds,
			"action_position": action_position,
			"state_revision": state_revision,
		})


var failures: Array[String] = []
var runtime: EnemyGameplayGatewayTestRuntime = null


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	runtime = RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	runtime.name = "EnemyAttackStateConsistencySmokeTest"
	root.add_child(runtime)
	current_scene = runtime
	await process_frame

	await _test_smg_non_hostile_targets_are_transparent()
	await _test_rejected_shape_damage_does_not_fill_hit_ledgers()
	await _test_sniper_non_player_lock_cancel_contract()
	await _test_main_battle_designated_skill2_target_priority()

	current_scene = null
	runtime.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("ENEMY_ATTACK_STATE_CONSISTENCY_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_smg_non_hostile_targets_are_transparent() -> void:
	await _run_smg_friendly_player_case(Vector2(0.0, 0.0))
	await _run_smg_friendly_plant_case(Vector2(400.0, 0.0))
	await _run_smg_friendly_enemy_case(Vector2(800.0, 0.0))
	await _run_smg_rejected_hostile_blocks_case(Vector2(1200.0, 0.0))


func _run_smg_friendly_player_case(origin: Vector2) -> void:
	var shooter := _spawn_smg(origin, CombatRelationService.PLAYER_ALLIED)
	var friendly_player := _spawn_player(origin + Vector2(20.0, 0.0))
	var hostile_enemy := _spawn_smg(
		origin + Vector2(42.0, 0.0),
		CombatRelationService.HOSTILE_WAVE
	)
	await _settle_physics()
	var friendly_health := friendly_player.current_health
	var hostile_health := hostile_enemy.current_health
	shooter.call("_fire_hitscan", Vector2.RIGHT)
	var hostile_request := (
		hostile_enemy.last_damage_result.request
		if hostile_enemy.last_damage_result != null
		else null
	)
	_expect(
		friendly_player.current_health == friendly_health
		and hostile_enemy.current_health < hostile_health
		and hostile_request != null
		and hostile_request.source_snapshot_is_explicit
		and hostile_request.get_or_create_source_snapshot().source_faction_id
			== CombatRelationService.PLAYER_ALLIED
		and hostile_request.source_type == &"capoo_smg_hitscan",
		"SMG hitscan must pass through a NON_HOSTILE Player and damage the hostile target behind it."
	)
	await _release_nodes([shooter, friendly_player, hostile_enemy])


func _run_smg_friendly_plant_case(origin: Vector2) -> void:
	var shooter := _spawn_smg(origin, CombatRelationService.PLAYER_ALLIED)
	var friendly_plant := _spawn_agave(origin + Vector2(20.0, 0.0))
	var hostile_enemy := _spawn_smg(
		origin + Vector2(42.0, 0.0),
		CombatRelationService.HOSTILE_WAVE
	)
	await _settle_physics()
	var friendly_health := friendly_plant.current_health
	var hostile_health := hostile_enemy.current_health
	shooter.call("_fire_hitscan", Vector2.RIGHT)
	_expect(
		friendly_plant.current_health == friendly_health
		and hostile_enemy.current_health < hostile_health,
		"SMG hitscan must pass through a NON_HOSTILE Plant and damage the hostile target behind it."
	)
	await _release_nodes([shooter, friendly_plant, hostile_enemy])


func _run_smg_friendly_enemy_case(origin: Vector2) -> void:
	var shooter := _spawn_smg(origin, CombatRelationService.HOSTILE_WAVE)
	var friendly_enemy := _spawn_smg(
		origin + Vector2(20.0, 0.0),
		CombatRelationService.HOSTILE_WAVE
	)
	var hostile_player := _spawn_player(origin + Vector2(42.0, 0.0))
	await _settle_physics()
	var friendly_health := friendly_enemy.current_health
	var hostile_health := hostile_player.current_health
	shooter.call("_fire_hitscan", Vector2.RIGHT)
	_expect(
		friendly_enemy.current_health == friendly_health
		and hostile_player.current_health < hostile_health,
		"SMG hitscan must pass through a NON_HOSTILE Enemy and damage the hostile target behind it."
	)
	await _release_nodes([shooter, friendly_enemy, hostile_player])


func _run_smg_rejected_hostile_blocks_case(origin: Vector2) -> void:
	var shooter := _spawn_smg(origin, CombatRelationService.HOSTILE_WAVE)
	var blocking_player := _spawn_player(origin + Vector2(20.0, 0.0))
	var rear_player := _spawn_player(origin + Vector2(42.0, 0.0))
	await _settle_physics()
	blocking_player.invincibility_time_left = 10.0
	var rear_health := rear_player.current_health
	var resolver := (
		runtime.get_enemy_combat_services().get_immediate_hitscan_resolver()
	)
	var query_count_before := resolver.get_query_count()
	shooter.call("_fire_hitscan", Vector2.RIGHT)
	_expect(
		blocking_player.last_damage_result != null
		and blocking_player.last_damage_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.INVULNERABLE
		)
		and rear_player.current_health == rear_health
		and resolver.get_query_count() == query_count_before + 1,
		"A hostile target that rejects damage must block the SMG ray, and an ordinary first hostile hit must use one shared query."
	)
	await _release_nodes([shooter, blocking_player, rear_player])


func _test_rejected_shape_damage_does_not_fill_hit_ledgers() -> void:
	var knight_origin := Vector2(1200.0, 0.0)
	var knight_player := _spawn_player(knight_origin + Vector2(42.0, 0.0))
	knight_player.invincibility_time_left = 10.0
	var knight := KNIGHT_SCENE.instantiate() as CapooKnight
	runtime.get_node("EnemyContainer").add_child(knight)
	knight.global_position = knight_origin
	knight.setup(KNIGHT_CONFIG, knight_player, null, runtime)
	knight.set_physics_process(false)
	_expect(bool(knight.call("_try_start_windup", knight_player)), "Knight test windup must start.")
	await _settle_physics()
	var knight_health := knight_player.current_health
	knight.slash_hit_target_ids.clear()
	knight.call("_apply_slash_damage")
	_expect(
		knight_player.current_health == knight_health
		and knight_player.last_damage_result != null
		and knight_player.last_damage_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.INVULNERABLE
		)
		and not knight.slash_hit_target_ids.has(knight_player.get_instance_id()),
		"Knight must not record an INVULNERABLE rejection as a slash hit."
	)
	await _release_nodes([knight, knight_player])

	var main_origin := Vector2(1500.0, 0.0)
	var main_player := _spawn_player(main_origin + Vector2(24.0, 0.0))
	main_player.invincibility_time_left = 10.0
	var main_battle := _spawn_main_battle(main_origin, main_player)
	main_battle.locked_direction = Vector2.RIGHT
	main_battle.action_damage_source_snapshot = (
		main_battle.create_damage_source_snapshot(
			1,
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL1
		)
	)
	await _settle_physics()
	var main_health := main_player.current_health
	main_battle.call(
		"_apply_circle_damage",
		36.0,
		96,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL1
	)
	_expect(
		main_player.current_health == main_health
		and main_player.last_damage_result != null
		and main_player.last_damage_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.INVULNERABLE
		)
		and not main_battle.hit_target_ids.has(main_player.get_instance_id()),
		"MainBattle must not record an INVULNERABLE rejection as a shape hit."
	)
	await _release_nodes([main_battle, main_player])


func _test_sniper_non_player_lock_cancel_contract() -> void:
	var session := RecordingGameplaySession.new()
	runtime.attach_gameplay_session(session)
	var anchor_player := _spawn_player(Vector2(1900.0, 300.0))
	var sniper := SNIPER_SCENE.instantiate() as CapooSniper
	runtime.get_node("EnemyContainer").add_child(sniper)
	sniper.global_position = Vector2(1900.0, 0.0)
	sniper.setup(SNIPER_CONFIG, anchor_player, null, runtime)
	sniper.set_physics_process(false)
	sniper.set_meta(&"net_id", 71)

	var faction_target := _spawn_smg(
		Vector2(2000.0, 0.0),
		CombatRelationService.PLAYER_ALLIED
	)
	faction_target.set_meta(&"net_id", 81)
	await _settle_physics()
	_expect(
		bool(sniper.call("_try_start_lock", faction_target)),
		"Sniper must start a lock on a hostile dynamic Enemy."
	)
	faction_target.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		2,
		true
	)
	sniper.call("_update_lock", 0.0)
	_expect_target_action_pair(
		session.enemy_target_actions,
		0,
		81,
		"A faction change must cancel the dynamic Enemy lock."
	)

	var dead_target := _spawn_smg(
		Vector2(2000.0, 0.0),
		CombatRelationService.PLAYER_ALLIED
	)
	dead_target.set_meta(&"net_id", 82)
	await _settle_physics()
	_expect(bool(sniper.call("_try_start_lock", dead_target)), "Sniper death-cancel lock must start.")
	dead_target.is_dead = true
	sniper.call("_update_lock", 0.0)
	_expect_target_action_start(
		session.enemy_target_actions,
		2,
		82,
		"A dead dynamic Enemy must have emitted a typed target start before death; reliable NONE owns the later clear."
	)

	var cancelled_target := _spawn_smg(
		Vector2(2000.0, 0.0),
		CombatRelationService.PLAYER_ALLIED
	)
	cancelled_target.set_meta(&"net_id", 83)
	await _settle_physics()
	_expect(bool(sniper.call("_try_start_lock", cancelled_target)), "Sniper explicit-cancel lock must start.")
	sniper.call("_cancel_lock")
	_expect_target_action_pair(
		session.enemy_target_actions,
		3,
		83,
		"An explicit dynamic Enemy lock cancellation must retain the same typed target identity."
	)
	_expect(
		session.enemy_actions.is_empty()
		and session.enemy_target_presentation_states.size() == 6,
		"Sniper production lock flow must use descriptor target actions plus ACTIVE/NONE reliable state, not legacy positional actions."
	)
	for presentation_index in range(
		0,
		session.enemy_target_presentation_states.size(),
		2
	):
		var active_state := session.enemy_target_presentation_states[
			presentation_index
		]
		var clear_state := session.enemy_target_presentation_states[
			presentation_index + 1
		]
		var expected_target_id := 81 + floori(
			float(presentation_index) / 2.0
		)
		var active_descriptor := active_state.get(
			"target_descriptor"
		) as CombatTargetDescriptor
		var clear_descriptor := clear_state.get(
			"target_descriptor"
		) as CombatTargetDescriptor
		_expect(
			int(active_state.get("phase", -1))
			== Enemy.TargetPresentationPhase.SNIPER_LOCK
			and active_descriptor != null
			and active_descriptor.kind == CombatTargetDescriptor.Kind.ENEMY
			and active_descriptor.id == expected_target_id
			and int(clear_state.get("phase", -1))
			== Enemy.TargetPresentationPhase.NONE
			and clear_descriptor != null
			and clear_descriptor.kind == CombatTargetDescriptor.Kind.NONE,
			"Each typed Sniper start must converge through an explicit reliable NONE state."
	)

	var proxy := SNIPER_SCENE.instantiate() as CapooSniper
	runtime.get_node("EnemyContainer").add_child(proxy)
	proxy.global_position = Vector2(2200.0, 0.0)
	proxy.setup(SNIPER_CONFIG, anchor_player, null, runtime)
	proxy.set_physics_process(false)
	proxy.configure_multiplayer_proxy()
	proxy.play_multiplayer_enemy_action(
		CapooSniper.ACTION_NON_PLAYER_LOCK_START,
		Vector2(100.0, 0.0),
		1
	)
	var warning_system := (
		runtime.get_enemy_combat_services().get_enemy_warning_presentation_system()
	)
	var proxy_line_handle := proxy.sniper_line_warning_handle
	_expect(
		proxy.proxy_plant_lock_active
		and proxy.get_node_or_null("AimGlow") == null
		and warning_system.is_handle_live(proxy_line_handle)
		and proxy.sniper_reticle_warning_handle == 0,
		"Client proxy must use a shared line-only non-player lock warning."
	)
	proxy.play_multiplayer_enemy_action(
		CapooSniper.ACTION_NON_PLAYER_LOCK_CANCEL,
		Vector2.ZERO,
		2
	)
	_expect(
		not proxy.proxy_plant_lock_active
		and proxy.sniper_line_warning_handle == 0
		and proxy.sniper_reticle_warning_handle == 0
		and not warning_system.is_handle_live(proxy_line_handle)
		and proxy.animated_sprite.animation == SNIPER_CONFIG.move_animation_name,
		"Client proxy start+cancel must clear every generic non-player warning state."
	)

	proxy.apply_multiplayer_target_presentation_state(
		Enemy.TargetPresentationPhase.SNIPER_LOCK,
		cancelled_target,
		proxy.global_position,
		3,
		0.0,
		1.0
	)
	var presentation_line_handle := proxy.sniper_line_warning_handle
	var presentation_reticle_handle := proxy.sniper_reticle_warning_handle
	var elapsed_before_frames := proxy.proxy_lock_elapsed
	# SceneTree emits process_frame before it dispatches Node._process. The first
	# await enters the real scheduling window; the next two sample completed
	# render callbacks without directly invoking the Sniper method.
	await process_frame
	await process_frame
	var elapsed_after_first_frame := proxy.proxy_lock_elapsed
	await process_frame
	var elapsed_after_second_frame := proxy.proxy_lock_elapsed
	_expect(
		proxy.is_processing()
		and elapsed_after_first_frame > elapsed_before_frames
		and elapsed_after_second_frame > elapsed_after_first_frame,
		"A reliable Sniper lock must remain scheduled across real SceneTree render frames instead of stopping after its first _process call."
	)
	proxy.apply_multiplayer_target_presentation_state(
		Enemy.TargetPresentationPhase.NONE,
		null,
		proxy.global_position,
		4,
		0.0,
		0.0
	)
	_expect(
		proxy.proxy_locked_target == null
		and proxy.sniper_line_warning_handle == 0
		and proxy.sniper_reticle_warning_handle == 0
		and not warning_system.is_handle_live(presentation_line_handle)
		and not warning_system.is_handle_live(presentation_reticle_handle)
		and not proxy.is_processing()
		and proxy.animated_sprite.animation == SNIPER_CONFIG.move_animation_name,
		"A reliable Sniper NONE state must clear the lock, stop its render work, and restore locomotion immediately."
	)

	proxy.apply_multiplayer_target_presentation_state(
		Enemy.TargetPresentationPhase.SNIPER_LOCK,
		cancelled_target,
		proxy.global_position,
		5,
		0.0,
		0.03
	)
	var expiring_line_handle := proxy.sniper_line_warning_handle
	var expiring_reticle_handle := proxy.sniper_reticle_warning_handle
	await create_timer(0.08).timeout
	await process_frame
	_expect(
		proxy.proxy_locked_target == null
		and proxy.sniper_line_warning_handle == 0
		and proxy.sniper_reticle_warning_handle == 0
		and not warning_system.is_handle_live(expiring_line_handle)
		and not warning_system.is_handle_live(expiring_reticle_handle)
		and not proxy.is_processing()
		and proxy.animated_sprite.animation == SNIPER_CONFIG.move_animation_name,
		"A reliable Sniper lock must expire through real SceneTree scheduling and return to locomotion without a cancel edge."
	)
	proxy.apply_multiplayer_target_presentation_state(
		Enemy.TargetPresentationPhase.NONE,
		null,
		proxy.global_position,
		6,
		0.0,
		0.0
	)
	proxy.play_multiplayer_enemy_target_action(
		&"sniper_lock_start",
		cancelled_target,
		6
	)
	_expect(
		proxy.latest_proxy_target_action_id == 0
		and proxy.proxy_locked_target == null
		and proxy.sniper_line_warning_handle == 0
		and proxy.sniper_reticle_warning_handle == 0,
		"Sniper NONE must reject an equal-revision delayed start without consuming the later fire edge."
	)
	proxy.play_multiplayer_enemy_target_action(
		&"sniper_lock_fire",
		cancelled_target,
		6
	)
	_expect(
		proxy.latest_proxy_presentation_revision == 6
		and proxy.latest_proxy_target_action_id == 6,
		"Sniper reliable NONE arriving first must not consume the equal-revision CH7 fire edge."
	)

	runtime.detach_gameplay_session(session)
	session.free()
	await _release_nodes([
		sniper,
		proxy,
		anchor_player,
		faction_target,
		dead_target,
		cancelled_target,
	])


func _test_main_battle_designated_skill2_target_priority() -> void:
	var origin := Vector2(2600.0, 0.0)
	var designated_player := _spawn_player(origin + Vector2(90.0, 0.0))
	var nearer_player := _spawn_player(origin + Vector2(30.0, 0.0))
	var main_battle := _spawn_main_battle(origin, designated_player)
	await _settle_physics()
	var descriptor := CombatTargetDescriptor.create_player(
		9001,
		1,
		designated_player.global_position
	)
	main_battle.targeting_state.apply_assignment(descriptor)
	main_battle.set_objective_target(designated_player)
	main_battle.skill2_cooldown_left = 0.0
	_expect(
		main_battle.targeting_state.is_active_target_assigned()
		and bool(main_battle.call("_try_start_ready_action"))
		and main_battle.combat_state
			== CombatRobotMainBattleElite.CombatState.SKILL2_TAKEOFF
		and main_battle.committed_target == designated_player
		and main_battle.committed_target != nearer_player,
		"MainBattle Skill2 must prefer the valid assigned objective over a nearer automatic target."
	)
	await _release_nodes([main_battle, designated_player, nearer_player])


func _expect_target_action_pair(
	actions: Array[Dictionary],
	start_index: int,
	expected_target_id: int,
	message: String
) -> void:
	var start_descriptor := (
		actions[start_index].get("target_descriptor") as CombatTargetDescriptor
		if actions.size() > start_index
		else null
	)
	var cancel_descriptor := (
		actions[start_index + 1].get("target_descriptor") as CombatTargetDescriptor
		if actions.size() > start_index + 1
		else null
	)
	_expect(
		actions.size() >= start_index + 2
		and actions[start_index].get("action_name")
			== &"sniper_lock_start"
		and actions[start_index + 1].get("action_name")
			== &"sniper_lock_cancel"
		and start_descriptor != null
		and start_descriptor.kind == CombatTargetDescriptor.Kind.ENEMY
		and start_descriptor.id == expected_target_id
		and cancel_descriptor != null
		and cancel_descriptor.same_identity(start_descriptor),
		message
	)


func _expect_target_action_start(
	actions: Array[Dictionary],
	start_index: int,
	expected_target_id: int,
	message: String
) -> void:
	var descriptor := (
		actions[start_index].get("target_descriptor") as CombatTargetDescriptor
		if actions.size() > start_index
		else null
	)
	_expect(
		actions.size() > start_index
		and actions[start_index].get("action_name") == &"sniper_lock_start"
		and descriptor != null
		and descriptor.kind == CombatTargetDescriptor.Kind.ENEMY
		and descriptor.id == expected_target_id,
		message
	)


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	runtime.add_child(player)
	player.global_position = position
	player.bind_combat_runtime(runtime)
	player.set_physics_process(false)
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set("_base_max_health", 2000)
	player.max_health = 2000
	player.current_health = 2000
	player.health_bar.setup(player.max_health, player.current_health)
	return player


func _spawn_agave(position: Vector2) -> AgaveCannon:
	var plant := AGAVE_SCENE.instantiate() as AgaveCannon
	runtime.add_child(plant)
	plant.global_position = position
	plant.setup(AGAVE_CONFIG, null, [Vector2i.ZERO])
	plant.attack_timer.stop()
	return plant


func _spawn_smg(position: Vector2, faction_id: int) -> CapooSMG:
	var enemy := SMG_SCENE.instantiate() as CapooSMG
	runtime.get_node("EnemyContainer").add_child(enemy)
	enemy.global_position = position
	enemy.setup(SMG_CONFIG, null, null, runtime)
	enemy.set_physics_process(false)
	enemy.set_combat_faction_id(faction_id, -1, true)
	return enemy


func _spawn_main_battle(
	position: Vector2,
	target_player: Player
) -> CombatRobotMainBattleElite:
	var enemy := MAIN_BATTLE_SCENE.instantiate() as CombatRobotMainBattleElite
	runtime.get_node("EnemyContainer").add_child(enemy)
	enemy.global_position = position
	enemy.setup(MAIN_BATTLE_CONFIG, target_player, null, runtime)
	enemy.set_physics_process(false)
	return enemy


func _settle_physics() -> void:
	await process_frame
	await physics_frame
	await physics_frame


func _release_nodes(nodes: Array) -> void:
	for node_variant in nodes:
		var node := node_variant as Node
		if node != null and is_instance_valid(node):
			node.queue_free()
	await process_frame
	await physics_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
