extends SceneTree

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const ICE_SPIKE_SCENE_PATH := (
	"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.tscn"
)
const TEST_HEALTH := 1000
const ICE_SPIKE_DAMAGE := 20
const ICE_SPIKE_SPEED := 100.0
const ICE_SPIKE_LIFETIME := 7.0
const ICE_SPIKE_TYPE: StringName = &"frost_sorcerer_ice_spike"
const COMBAT_RUNTIME_FIXTURE_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)


class TestMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var report_count := 0
	var last_reported_source_id := 0
	var last_reported_peer_id := 0
	var last_reported_source_type: StringName = &""
	var last_reported_damage_flags := 0
	var sent_methods: Array[StringName] = []
	var sent_arguments: Array[Array] = []

	func request_player_hit_report(
		source_id: int,
		player_peer_id: int,
		source_type: StringName,
		_impact_direction: Vector2,
		damage_flags: int
	) -> void:
		report_count += 1
		last_reported_source_id = source_id
		last_reported_peer_id = player_peer_id
		last_reported_source_type = source_type
		last_reported_damage_flags = damage_flags

	func _rpc_to_connected_clients(
		method_name: StringName,
		args: Array = []
	) -> void:
		sent_methods.append(method_name)
		sent_arguments.append(args.duplicate(true))


class TestNetManager:
	extends Node

	var host_mode := true
	var local_peer_id := 1
	var connected_players: Dictionary = {}

	func is_host() -> bool:
		return host_mode

	func is_client() -> bool:
		return not host_mode

	func get_local_peer_id() -> int:
		return local_peer_id

	func get_host_peer_id() -> int:
		return 1


var failures: Array[String] = []
var test_scene: EnemyGameplayGatewayTestRuntime = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_scene = (
		COMBAT_RUNTIME_FIXTURE_SCENE.instantiate()
		as EnemyGameplayGatewayTestRuntime
	)
	test_scene.name = "FrostSorcererNetworkContactSmoke"
	root.add_child(test_scene)
	_get_cold_scheduler().call("clear_all")

	_test_runtime_authority_boundary()
	_test_record_key_and_global_consumption_contract()
	_test_terminal_record_consumption()
	_test_network_instantiation_and_lifetime_compensation()
	_test_host_authoritative_damage_and_cold_guards()
	_test_client_confirmation_and_revision_deduplication()

	_get_cold_scheduler().call("clear_all")
	test_scene.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("FROST_SORCERER_NETWORK_CONTACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_runtime_authority_boundary() -> void:
	var gameplay_session := EnemyGameplayGatewayTestSession.new()
	_get_cold_scheduler().call("clear_all")
	test_scene.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var singleplayer := _spawn_player(Vector2(-1400.0, -900.0), 90)
	var singleplayer_health_before := singleplayer.current_health
	var local_spike := _spawn_bound_ice_spike(0, true)
	local_spike.call("_handle_collision_body", singleplayer)
	_expect(
		singleplayer.current_health
			== singleplayer_health_before - ICE_SPIKE_DAMAGE
		and _get_cold_stack_count(singleplayer) == 1,
		"Frost spike must apply damage and cold only under explicit SINGLEPLAYER authority."
	)

	test_scene.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	test_scene.attach_gameplay_session(gameplay_session)
	var host_projectile_id := 82990
	_remember_ice_spike_record(gameplay_session, host_projectile_id)
	var host_player := _spawn_player(Vector2(-1500.0, -900.0), 91)
	var host_health_before := host_player.current_health
	var host_spike := _spawn_bound_ice_spike(host_projectile_id, true)
	host_spike.call("_handle_collision_body", host_player)
	_expect(
		gameplay_session.player_damage_requests.size() == 1
		and bool(gameplay_session.player_damage_requests[0].get(
			"contact_preconsumed",
			false
		))
		and int(gameplay_session.player_damage_requests[0].get(
			"damage_type",
			-1
		)) == int(EnemyConfig.DamageType.MAGIC)
		and host_player.current_health == host_health_before
		and _get_cold_stack_count(host_player) == 0,
		"HOST Frost spike must delegate its preconsumed magic hit through the typed gameplay gateway."
	)

	var request_count_before_client := gameplay_session.player_damage_requests.size()
	test_scene.detach_gameplay_session(gameplay_session)
	test_scene.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	var client_player := _spawn_player(Vector2(-1600.0, -900.0), 92)
	var client_health_before := client_player.current_health
	var client_spike := _spawn_bound_ice_spike(82991, false)
	client_spike.call("_handle_collision_body", client_player)
	_expect(
		client_player.current_health == client_health_before
		and _get_cold_stack_count(client_player) == 0
		and gameplay_session.player_damage_requests.size()
			== request_count_before_client,
		"CLIENT_VIEW Frost spike without an injected gateway must fail closed."
	)

	for node in [
		singleplayer,
		local_spike,
		host_player,
		host_spike,
		client_player,
		client_spike,
	]:
		if node != null and is_instance_valid(node):
			node.queue_free()
	gameplay_session.free()
	_get_cold_scheduler().call("clear_all")
	test_scene.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY


func _test_record_key_and_global_consumption_contract() -> void:
	var mp_game := TestMpGame.new()
	var projectile_id := 82001
	_remember_ice_spike_record(mp_game, projectile_id)

	var peer_two_key := String(mp_game.call(
		"_get_multiplayer_player_hit_key",
		projectile_id,
		2,
		ICE_SPIKE_TYPE
	))
	var peer_three_key := String(mp_game.call(
		"_get_multiplayer_player_hit_key",
		projectile_id,
		3,
		ICE_SPIKE_TYPE
	))
	var ordinary_peer_two_key := String(mp_game.call(
		"_get_multiplayer_player_hit_key",
		projectile_id,
		2,
		&"player_bullet"
	))
	var ordinary_peer_three_key := String(mp_game.call(
		"_get_multiplayer_player_hit_key",
		projectile_id,
		3,
		&"player_bullet"
	))
	_expect(
		peer_two_key == peer_three_key
		and peer_two_key == "%d:%s" % [projectile_id, String(ICE_SPIKE_TYPE)]
		and ordinary_peer_two_key != ordinary_peer_three_key,
		"Frost ice-spike hit keys must omit target_peer_id while ordinary projectile keys retain it."
	)
	_expect(
		int(mp_game.call(
			"_get_frost_ice_spike_record_damage",
			projectile_id,
			ICE_SPIKE_TYPE
		)) == ICE_SPIKE_DAMAGE,
		"The Frost ice-spike record must retain the authoritative 20 damage."
	)
	_expect(
		not bool(mp_game.call(
			"try_consume_frost_sorcerer_ice_spike_contact",
			projectile_id,
			&"player_bullet"
		))
		and bool(mp_game.call(
			"try_consume_frost_sorcerer_ice_spike_contact",
			projectile_id,
			ICE_SPIKE_TYPE
		))
		and bool(mp_game.call(
			"_is_frost_ice_spike_contact_consumed",
			projectile_id,
			ICE_SPIKE_TYPE
		))
		and not bool(mp_game.call(
			"try_consume_frost_sorcerer_ice_spike_contact",
			projectile_id,
			ICE_SPIKE_TYPE
		)),
		"One Frost ice-spike record must accept exactly one contact globally, and a wrong source must not poison it."
	)
	mp_game.free()


func _test_terminal_record_consumption() -> void:
	var mp_game := TestMpGame.new()
	var projectile_id := 82030
	_remember_ice_spike_record(mp_game, projectile_id)
	test_scene.attach_gameplay_session(mp_game)

	var projectile := load(ICE_SPIKE_SCENE_PATH).instantiate() as FrostSorcererIceSpike
	projectile.bind_gameplay_context(
		test_scene,
		test_scene.get_multiplayer_gameplay_gateway()
	)
	test_scene.add_child(projectile)
	projectile.global_position = Vector2(5000.0, 5000.0)
	projectile.setup(
		Vector2.RIGHT,
		ICE_SPIKE_DAMAGE,
		ICE_SPIKE_SPEED,
		ICE_SPIKE_LIFETIME
	)
	projectile.setup_multiplayer(projectile_id, 1, ICE_SPIKE_TYPE)
	projectile.set_physics_process(false)
	projectile.call("_begin_retire_effect", &"expire")
	_expect(
		projectile.has_hit
		and projectile.multiplayer_contact_consumed
		and bool(mp_game.call(
			"_is_frost_ice_spike_contact_consumed",
			projectile_id,
			ICE_SPIKE_TYPE
		)),
		"Wall, building, or lifetime retirement must consume the authoritative Frost contact record before disabling the projectile."
	)
	_expect(
		not bool(mp_game.call(
			"try_consume_frost_sorcerer_ice_spike_contact",
			projectile_id,
			ICE_SPIKE_TYPE
		)),
		"A terminally consumed Frost record must reject every later delayed contact report."
	)

	projectile.queue_free()
	test_scene.detach_gameplay_session(mp_game)
	mp_game.free()


func _test_network_instantiation_and_lifetime_compensation() -> void:
	var mp_game := TestMpGame.new()
	var net_manager := TestNetManager.new()
	mp_game.set("net_manager", net_manager)
	test_scene.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	mp_game.set("game", test_scene)
	var projectile := mp_game.call(
		"_instantiate_projectile",
		ICE_SPIKE_TYPE,
		1,
		Vector2.RIGHT,
		ICE_SPIKE_DAMAGE,
		ICE_SPIKE_SPEED,
		ICE_SPIKE_LIFETIME,
		false,
		0,
		0
	) as FrostSorcererIceSpike
	_expect(
		projectile != null,
		"Multiplayer projectile dispatch must instantiate a Frost ice spike."
	)
	if projectile == null:
		net_manager.free()
		mp_game.free()
		return

	var projectile_id := 82002
	mp_game.call(
		"_setup_projectile_network_identity",
		projectile,
		projectile_id,
		1,
		ICE_SPIKE_TYPE
	)
	var finished_callable := Callable(
		mp_game,
		"_on_network_projectile_finished"
	)
	_expect(
		projectile.scene_file_path == ICE_SPIKE_SCENE_PATH
		and projectile.damage == ICE_SPIKE_DAMAGE
		and is_equal_approx(projectile.speed, ICE_SPIKE_SPEED)
		and is_equal_approx(projectile.max_lifetime, ICE_SPIKE_LIFETIME)
		and is_equal_approx(
			projectile.remaining_lifetime,
			ICE_SPIKE_LIFETIME
		)
		and projectile.direction == Vector2.RIGHT
		and projectile.projectile_id == projectile_id
		and projectile.owner_peer_id == 1
		and projectile.source_type == ICE_SPIKE_TYPE
		and projectile.is_connected(
			&"projectile_finished",
			finished_callable
		),
		"Network instantiation must preserve the Frost scene, 20 damage, 100 speed, 7-second lifetime, direction, and identity contract."
	)

	var net_time := float(mp_game.call("_get_net_time"))
	var compensation_age := float(mp_game.call(
		"_get_projectile_time_compensation_age",
		net_time - 1.0,
		ICE_SPIKE_LIFETIME
	))
	mp_game.call(
		"_apply_projectile_lifetime_compensation",
		projectile,
		ICE_SPIKE_LIFETIME,
		compensation_age
	)
	_expect(
		is_equal_approx(compensation_age, 0.25)
		and is_equal_approx(projectile.remaining_lifetime, 6.75),
		"A delayed network Frost ice spike must cap compensation at 0.25 seconds and subtract it from the authored 7-second lifetime."
	)

	projectile.free()
	net_manager.free()
	mp_game.free()


func _test_host_authoritative_damage_and_cold_guards() -> void:
	var cold_scheduler := _get_cold_scheduler()
	cold_scheduler.call("clear_all")
	var mp_game := TestMpGame.new()
	var net_manager := TestNetManager.new()
	var game := test_scene
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	mp_game.set("net_manager", net_manager)
	mp_game.set("game", game)

	var hit_player := _spawn_player(Vector2(-800.0, -400.0), 10)
	var blocked_second_player := _spawn_player(
		Vector2(-900.0, -400.0),
		11
	)
	var dodge_player := _spawn_player(Vector2(-1000.0, -400.0), 12)
	var invincible_player := _spawn_player(
		Vector2(-1100.0, -400.0),
		13
	)
	var lethal_player := _spawn_player(Vector2(-1200.0, -400.0), 14)
	for player in [
		hit_player,
		blocked_second_player,
		dodge_player,
		invincible_player,
		lethal_player,
	]:
		game.peer_players[player.peer_id] = player

	hit_player.physical_defense = 99
	hit_player.set("_base_physical_defense", 99)
	hit_player.magic_defense = 20
	hit_player.set("_base_magic_defense", 20)
	var hit_projectile_id := 82010
	_remember_ice_spike_record(mp_game, hit_projectile_id)
	mp_game.sent_methods.clear()
	mp_game.sent_arguments.clear()
	var hit_was_handled := mp_game.request_multiplayer_player_damage(
		hit_projectile_id,
		hit_player.peer_id,
		999,
		ICE_SPIKE_TYPE,
		EnemyConfig.DamageType.PHYSICAL,
		Vector2.RIGHT,
		true
	)
	var damage_event_index := mp_game.sent_methods.find(
		&"net_player_damage_applied"
	)
	var damage_event_arguments: Array = (
		mp_game.sent_arguments[damage_event_index]
		if damage_event_index >= 0
		else []
	)
	_expect(
		hit_was_handled
		and hit_player.current_health == TEST_HEALTH - 16
		and hit_player.last_damage_taken == 16
		and not hit_player.is_dead
		and _get_cold_stack_count(hit_player) == 1
		and damage_event_arguments.size() == 10
		and int(damage_event_arguments[4]) == 16
		and int(damage_event_arguments[6])
			== int(EnemyConfig.DamageType.MAGIC)
		and bool(damage_event_arguments[8])
		and int(damage_event_arguments[9])
			== CombatTypes.DamageRejectionReason.NONE,
		"Host Frost contact must replace forged 999 physical damage with the recorded 20 magic damage, apply the 20-percent magic-defense result once, and add exactly L1 cold while the player survives."
	)

	var sent_count_after_first_target := mp_game.sent_methods.size()
	mp_game.request_multiplayer_player_damage(
		hit_projectile_id,
		blocked_second_player.peer_id,
		ICE_SPIKE_DAMAGE,
		ICE_SPIKE_TYPE,
		EnemyConfig.DamageType.MAGIC,
		Vector2.RIGHT,
		true
	)
	_expect(
		blocked_second_player.current_health == TEST_HEALTH
		and _get_cold_stack_count(blocked_second_player) == 0
		and mp_game.sent_methods.size() == sent_count_after_first_target,
		"One consumed Frost ice spike must not damage or chill any later target."
	)

	var dodge_projectile_id := 82011
	_remember_ice_spike_record(mp_game, dodge_projectile_id)
	dodge_player.dodge_chance = 1.0
	mp_game.request_multiplayer_player_damage(
		dodge_projectile_id,
		dodge_player.peer_id,
		ICE_SPIKE_DAMAGE,
		ICE_SPIKE_TYPE,
		EnemyConfig.DamageType.MAGIC,
		Vector2.RIGHT,
		true
	)
	_expect(
		dodge_player.current_health == TEST_HEALTH
		and dodge_player.last_damage_taken == 0
		and _get_cold_stack_count(dodge_player) == 0
		and _last_sent_cold_flag(mp_game) == false
		and _last_sent_combat_outcome(mp_game)
			== CombatTypes.DamageRejectionReason.DODGED,
		"A fully dodged Host Frost contact must be consumed without adding cold."
	)

	var invincible_projectile_id := 82012
	_remember_ice_spike_record(mp_game, invincible_projectile_id)
	invincible_player.invincibility_time_left = 1.0
	mp_game.request_multiplayer_player_damage(
		invincible_projectile_id,
		invincible_player.peer_id,
		ICE_SPIKE_DAMAGE,
		ICE_SPIKE_TYPE,
		EnemyConfig.DamageType.MAGIC,
		Vector2.RIGHT,
		true
	)
	_expect(
		invincible_player.current_health == TEST_HEALTH
		and invincible_player.last_damage_taken == 0
		and _get_cold_stack_count(invincible_player) == 0
		and _last_sent_cold_flag(mp_game) == false,
		"An invincible Host player must consume Frost contact without adding cold."
	)

	var lethal_projectile_id := 82013
	_remember_ice_spike_record(mp_game, lethal_projectile_id)
	lethal_player.current_health = 10
	lethal_player.health_bar.set_health(10, TEST_HEALTH)
	game.wave_state = CombatFlowState.State.VICTORY
	mp_game.request_multiplayer_player_damage(
		lethal_projectile_id,
		lethal_player.peer_id,
		ICE_SPIKE_DAMAGE,
		ICE_SPIKE_TYPE,
		EnemyConfig.DamageType.MAGIC,
		Vector2.RIGHT,
		true
	)
	_expect(
		lethal_player.current_health == 0
		and lethal_player.is_dead
		and lethal_player.last_damage_taken == 10
		and _get_cold_stack_count(lethal_player) == 0
		and _last_sent_cold_flag(mp_game) == false,
		"A lethal Host Frost hit must deal its actual damage but never leave cold on the dead player."
	)

	cold_scheduler.call("clear_all")
	game.peer_players.clear()
	mp_game.free()
	net_manager.free()


func _test_client_confirmation_and_revision_deduplication() -> void:
	var cold_scheduler := _get_cold_scheduler()
	cold_scheduler.call("clear_all")
	var mp_game := TestMpGame.new()
	var net_manager := TestNetManager.new()
	net_manager.host_mode = false
	net_manager.local_peer_id = 21
	var game := test_scene
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	var player := _spawn_player(Vector2(-800.0, -600.0), 21)
	player.physical_defense = 99
	player.set("_base_physical_defense", 99)
	player.magic_defense = 20
	player.set("_base_magic_defense", 20)
	game.peer_players[player.peer_id] = player
	mp_game.set("net_manager", net_manager)
	mp_game.set("game", game)

	var projectile_id := 82020
	_remember_ice_spike_record(mp_game, projectile_id)
	player.current_health = 10
	player.health_bar.set_health(10, TEST_HEALTH)
	var request_was_handled := mp_game.request_multiplayer_player_damage(
		projectile_id,
		player.peer_id,
		999,
		ICE_SPIKE_TYPE,
		EnemyConfig.DamageType.PHYSICAL,
		Vector2.RIGHT,
		true
	)
	_expect(
		request_was_handled
		and player.current_health == 10
		and not player.is_dead
		and player.last_damage_taken == 0
		and _get_cold_stack_count(player) == 0
		and mp_game.report_count == 0,
		"A false-positive lethal client contact must not mutate health, enter death lifecycle, add cold, or send a claim."
	)
	player.current_health = TEST_HEALTH
	player.health_bar.set_health(TEST_HEALTH, TEST_HEALTH)

	mp_game.net_player_damage_applied(
		player.peer_id,
		TEST_HEALTH - 16,
		false,
		1,
		16,
		Vector2.LEFT,
		int(EnemyConfig.DamageType.MAGIC),
		true,
		false
	)
	_expect(
		_get_cold_stack_count(player) == 0,
		"A client damage confirmation without apply_confirmed_cold must not add cold."
	)

	mp_game.net_player_damage_applied(
		player.peer_id,
		TEST_HEALTH - 16,
		false,
		2,
		16,
		Vector2.LEFT,
		int(EnemyConfig.DamageType.MAGIC),
		true,
		true
	)
	_expect(
		_get_cold_stack_count(player) == 1,
		"A newer authoritative confirmation with apply_confirmed_cold=true must add exactly L1 cold."
	)

	mp_game.net_player_damage_applied(
		player.peer_id,
		TEST_HEALTH - 16,
		false,
		3,
		0,
		Vector2.ZERO,
		int(EnemyConfig.DamageType.MAGIC),
		false,
		false,
		CombatTypes.DamageRejectionReason.DODGED
	)
	_expect(
		player.current_health == TEST_HEALTH - 16
		and not player.is_dead
		and player.dodge_feedback_tween != null,
		"A confirmed client dodge must play presentation only without changing life state."
	)

	mp_game.net_player_damage_applied(
		player.peer_id,
		900,
		false,
		3,
		16,
		Vector2.LEFT,
		int(EnemyConfig.DamageType.MAGIC),
		true,
		true
	)
	_expect(
		player.current_health == TEST_HEALTH - 16
		and _get_cold_stack_count(player) == 1,
		"Replaying the same health revision must not mutate health or add a duplicate cold stack."
	)

	mp_game.net_player_damage_applied(
		player.peer_id,
		TEST_HEALTH - 16,
		false,
		4,
		0,
		Vector2.ZERO,
		int(EnemyConfig.DamageType.MAGIC),
		true,
		true
	)
	_expect(
		_get_cold_stack_count(player) == 1,
		"A zero-damage confirmation must not add cold even when its cold flag is true."
	)

	cold_scheduler.call("clear_all")
	game.peer_players.clear()
	mp_game.free()
	net_manager.free()
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY


func _remember_ice_spike_record(
	mp_game: MultiplayerGameplaySession,
	projectile_id: int
) -> void:
	mp_game.call(
		"_remember_projectile_record",
		projectile_id,
		1,
		ICE_SPIKE_TYPE,
		ICE_SPIKE_DAMAGE,
		ICE_SPIKE_LIFETIME
	)


func _spawn_player(position: Vector2, peer_id: int) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_scene.add_child(player)
	test_scene.bind_player_runtime_context(player)
	player.global_position = position
	player.peer_id = peer_id
	player.collision_layer = 0
	player.collision_mask = 0
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set("_base_max_health", TEST_HEALTH)
	player.max_health = TEST_HEALTH
	player.current_health = TEST_HEALTH
	player.health_bar.setup(TEST_HEALTH, TEST_HEALTH)
	player.set_process(false)
	player.set_physics_process(false)
	return player


func _spawn_bound_ice_spike(
	projectile_id: int,
	bind_gateway: bool
) -> FrostSorcererIceSpike:
	var projectile := (
		load(ICE_SPIKE_SCENE_PATH).instantiate()
		as FrostSorcererIceSpike
	)
	projectile.bind_gameplay_context(
		test_scene,
		test_scene.get_multiplayer_gameplay_gateway()
			if bind_gateway
			else null
	)
	projectile.setup(
		Vector2.RIGHT,
		ICE_SPIKE_DAMAGE,
		ICE_SPIKE_SPEED,
		ICE_SPIKE_LIFETIME
	)
	test_scene.add_child(projectile)
	if projectile_id > 0:
		projectile.setup_multiplayer(projectile_id, 1, ICE_SPIKE_TYPE)
	projectile.set_physics_process(false)
	return projectile


func _get_cold_scheduler() -> Node:
	return root.get_node("ColdStatusScheduler")


func _get_cold_stack_count(target: Object) -> int:
	return int(_get_cold_scheduler().call("get_stack_count", target))


func _last_sent_cold_flag(mp_game: TestMpGame) -> bool:
	var event_index := mp_game.sent_methods.rfind(
		&"net_player_damage_applied"
	)
	if event_index < 0:
		return false
	var event_arguments := mp_game.sent_arguments[event_index]
	return event_arguments.size() >= 9 and bool(event_arguments[8])


func _last_sent_combat_outcome(mp_game: TestMpGame) -> int:
	var event_index := mp_game.sent_methods.rfind(
		&"net_player_damage_applied"
	)
	if event_index < 0:
		return CombatTypes.DamageRejectionReason.NONE
	var event_arguments := mp_game.sent_arguments[event_index]
	return (
		int(event_arguments[9])
		if event_arguments.size() >= 10
		else CombatTypes.DamageRejectionReason.NONE
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
