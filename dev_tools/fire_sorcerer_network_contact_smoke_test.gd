extends SceneTree

const FIREBALL_VOLLEY_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn"
)
const ELITE_FIREBALL_VOLLEY_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const TEST_HEALTH := 1000
const FIREBALL_DAMAGE := 40
const ELITE_FIREBALL_DAMAGE := 70
const FIREBALL_TYPE: StringName = &"fire_sorcerer_fireball_volley"
const ELITE_FIREBALL_TYPE: StringName = (
	&"fire_sorcerer_elite_fireball_volley"
)


class TestMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var report_count := 0
	var last_reported_source_id := 0
	var last_reported_peer_id := 0
	var last_reported_health := -1
	var last_reported_applied_damage := -1
	var sent_methods: Array[StringName] = []
	var sent_arguments: Array[Array] = []

	func request_player_hit_report(
		source_id: int,
		player_peer_id: int,
		_damage: int,
		_source_type: StringName,
		reported_health_after: int,
		_reported_is_dead: bool,
		reported_applied_damage: int,
		_impact_direction: Vector2,
		_damage_type: EnemyConfig.DamageType
	) -> void:
		report_count += 1
		last_reported_source_id = source_id
		last_reported_peer_id = player_peer_id
		last_reported_health = reported_health_after
		last_reported_applied_damage = reported_applied_damage

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


class ContactAuthorityScene:
	extends Node2D

	var authority: Node = null
	var player_damage_request_count := 0
	var every_player_request_was_preconsumed := true
	var every_player_request_used_magic_damage := true
	var last_player_damage_type := int(EnemyConfig.DamageType.PHYSICAL)

	func try_consume_fire_sorcerer_fireball_contact(
		projectile_id: int,
		source_type: StringName
	) -> bool:
		return bool(authority.call(
			"try_consume_fire_sorcerer_fireball_contact",
			projectile_id,
			source_type
		))

	func request_multiplayer_player_damage(
		_source_id: int,
		_target_peer_id: int,
		_damage: int,
		_source_type: StringName,
		_damage_type_or_source_direction: Variant = (
			EnemyConfig.DamageType.PHYSICAL
		),
		_source_direction_or_is_ranged: Variant = Vector2.ZERO,
		_is_ranged: bool = false,
		fire_contact_preconsumed: bool = false
	) -> bool:
		player_damage_request_count += 1
		var resolved_damage_type := int(EnemyConfig.DamageType.PHYSICAL)
		if _damage_type_or_source_direction is int:
			resolved_damage_type = int(_damage_type_or_source_direction)
		last_player_damage_type = resolved_damage_type
		every_player_request_used_magic_damage = (
			every_player_request_used_magic_damage
			and resolved_damage_type == int(EnemyConfig.DamageType.MAGIC)
		)
		every_player_request_was_preconsumed = (
			every_player_request_was_preconsumed
			and fire_contact_preconsumed
		)
		return true


var failures: Array[String] = []
var test_scene: ContactAuthorityScene = null
var contact_authority: TestMpGame = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	contact_authority = TestMpGame.new()
	test_scene = ContactAuthorityScene.new()
	test_scene.name = "FireSorcererNetworkContactSmoke"
	test_scene.authority = contact_authority
	root.add_child(test_scene)
	current_scene = test_scene
	root.get_node("BurnStatusScheduler").call("clear_all")

	_test_dedup_key_and_source_mask_contract()
	_test_elite_projectile_instantiation_contract()
	_test_elite_volley_source_family_and_first_contact()
	_test_host_successful_hits_register_burn_statuses()
	_test_host_invincible_first_contact_is_consumed()
	_test_client_invincible_first_contact_reports_zero()
	_test_volley_player_plant_and_world_first_contact()
	await _test_compensation_sweep_and_normal_path_cost()

	FireSorcererFireballVolley.set_performance_metrics_enabled(false)
	root.get_node("BurnStatusScheduler").call("clear_all")
	current_scene = null
	test_scene.queue_free()
	contact_authority.free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("FIRE_SORCERER_NETWORK_CONTACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_dedup_key_and_source_mask_contract() -> void:
	var mp_game := TestMpGame.new()
	var projectile_id := 81001
	var elite_projectile_id := 81011
	mp_game.call(
		"_remember_projectile_record",
		projectile_id,
		1,
		FIREBALL_TYPE,
		FIREBALL_DAMAGE,
		7.0
	)
	mp_game.call(
		"_remember_projectile_record",
		elite_projectile_id,
		1,
		ELITE_FIREBALL_TYPE,
		ELITE_FIREBALL_DAMAGE,
		7.0
	)
	var fire_key_peer_two := String(mp_game.call(
		"_get_multiplayer_player_hit_key",
		projectile_id,
		2,
		&"fire_sorcerer_fireball_a"
	))
	var fire_key_peer_three := String(mp_game.call(
		"_get_multiplayer_player_hit_key",
		projectile_id,
		3,
		&"fire_sorcerer_fireball_a"
	))
	var ordinary_key_peer_two := String(mp_game.call(
		"_get_multiplayer_player_hit_key",
		projectile_id,
		2,
		&"capoo_mage_fireball"
	))
	var ordinary_key_peer_three := String(mp_game.call(
		"_get_multiplayer_player_hit_key",
		projectile_id,
		3,
		&"capoo_mage_fireball"
	))
	var elite_fire_key_peer_two := String(mp_game.call(
		"_get_multiplayer_player_hit_key",
		elite_projectile_id,
		2,
		&"fire_sorcerer_elite_fireball_a"
	))
	var elite_fire_key_peer_three := String(mp_game.call(
		"_get_multiplayer_player_hit_key",
		elite_projectile_id,
		3,
		&"fire_sorcerer_elite_fireball_a"
	))
	_expect(
		fire_key_peer_two == fire_key_peer_three
		and elite_fire_key_peer_two == elite_fire_key_peer_three
		and not fire_key_peer_two.contains(":2:")
		and not elite_fire_key_peer_two.contains(":2:")
		and ordinary_key_peer_two != ordinary_key_peer_three,
		"Normal and Elite Fire A/B/C dedupe keys must omit target_peer_id while ordinary projectile keys retain it."
	)
	_expect(
		bool(mp_game.call(
			"try_consume_fire_sorcerer_fireball_contact",
			projectile_id,
			&"fire_sorcerer_fireball_a"
		))
		and not bool(mp_game.call(
			"try_consume_fire_sorcerer_fireball_contact",
			projectile_id,
			&"fire_sorcerer_fireball_a"
		))
		and not bool(mp_game.call(
			"try_consume_fire_sorcerer_fireball_contact",
			projectile_id,
			&"fire_sorcerer_elite_fireball_b"
		))
		and bool(mp_game.call(
			"try_consume_fire_sorcerer_fireball_contact",
			projectile_id,
			&"fire_sorcerer_fireball_b"
		))
		and bool(mp_game.call(
			"try_consume_fire_sorcerer_fireball_contact",
			projectile_id,
			&"fire_sorcerer_fireball_c"
		)),
		"A normal volley record must consume normal A/B/C once and reject Elite sources without poisoning its source mask."
	)
	_expect(
		bool(mp_game.call(
			"try_consume_fire_sorcerer_fireball_contact",
			elite_projectile_id,
			&"fire_sorcerer_elite_fireball_a"
		))
		and not bool(mp_game.call(
			"try_consume_fire_sorcerer_fireball_contact",
			elite_projectile_id,
			&"fire_sorcerer_fireball_a"
		))
		and not bool(mp_game.call(
			"try_consume_fire_sorcerer_fireball_contact",
			elite_projectile_id,
			&"fire_sorcerer_elite_fireball_a"
		))
		and bool(mp_game.call(
			"try_consume_fire_sorcerer_fireball_contact",
			elite_projectile_id,
			&"fire_sorcerer_elite_fireball_b"
		))
		and bool(mp_game.call(
			"try_consume_fire_sorcerer_fireball_contact",
			elite_projectile_id,
			&"fire_sorcerer_elite_fireball_c"
		)),
		"An Elite volley record must consume Elite A/B/C once and reject normal sources without poisoning its source mask."
	)
	mp_game.free()


func _test_elite_projectile_instantiation_contract() -> void:
	var mp_game := TestMpGame.new()
	var projectile := mp_game.call(
		"_instantiate_projectile",
		ELITE_FIREBALL_TYPE,
		1,
		Vector2.RIGHT,
		ELITE_FIREBALL_DAMAGE,
		115.0,
		7.0,
		false,
		0,
		0
	) as FireSorcererFireballVolley
	_expect(
		projectile != null,
		"Multiplayer projectile dispatch must instantiate the independent Elite Fire volley."
	)
	if projectile == null:
		mp_game.free()
		return
	mp_game.call(
		"_setup_projectile_network_identity",
		projectile,
		81012,
		1,
		ELITE_FIREBALL_TYPE
	)
	test_scene.add_child(projectile)
	var projectile_script := projectile.get_script() as Script
	_expect(
		projectile_script != null
		and projectile_script.resource_path
			== "res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.gd"
		and projectile.scene_file_path
			== "res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn"
		and projectile.source_type == ELITE_FIREBALL_TYPE
		and projectile.damage == ELITE_FIREBALL_DAMAGE
		and is_equal_approx(projectile.speed, 115.0)
		and projectile.call("_get_ball_source_type", 0)
			== &"fire_sorcerer_elite_fireball_a"
		and projectile.call("_get_ball_source_type", 1)
			== &"fire_sorcerer_elite_fireball_b"
		and projectile.call("_get_ball_source_type", 2)
			== &"fire_sorcerer_elite_fireball_c",
		"Elite network dispatch must preserve its independent scene, root source "
		+ "type, 70 damage, 115 speed, and Elite A/B/C sources."
	)
	projectile.free()
	mp_game.free()


func _test_elite_volley_source_family_and_first_contact() -> void:
	var projectile_id := 81013
	contact_authority.call(
		"_remember_projectile_record",
		projectile_id,
		1,
		ELITE_FIREBALL_TYPE,
		ELITE_FIREBALL_DAMAGE,
		7.0
	)
	var first_player := _spawn_player(Vector2(-600.0, -300.0), 12)
	var second_player := _spawn_player(Vector2(-700.0, -300.0), 13)
	var first_volley := _spawn_elite_volley(Vector2.ZERO, projectile_id)
	var second_volley := _spawn_elite_volley(Vector2.ZERO, projectile_id)
	var request_count_before := test_scene.player_damage_request_count
	first_volley.call("_on_ball_body_entered", first_player, 0)
	second_volley.call("_on_ball_body_entered", second_player, 0)
	_expect(
		test_scene.player_damage_request_count == request_count_before + 1
		and test_scene.every_player_request_was_preconsumed
		and test_scene.every_player_request_used_magic_damage
		and test_scene.last_player_damage_type
			== int(EnemyConfig.DamageType.MAGIC)
		and bool(contact_authority.call(
			"_is_fire_sorcerer_fireball_contact_consumed",
			projectile_id,
			&"fire_sorcerer_elite_fireball_a"
		))
		and not bool(contact_authority.call(
			"_is_fire_sorcerer_fireball_contact_consumed",
			projectile_id,
			&"fire_sorcerer_fireball_a"
		))
		and not bool(first_volley.call("_is_ball_active", 0))
		and not bool(second_volley.call("_is_ball_active", 0)),
		"Elite Fire A must claim exactly one Elite-family network contact across replicas without aliasing normal Fire A."
	)
	test_scene.player_damage_request_count = request_count_before
	test_scene.every_player_request_was_preconsumed = true
	test_scene.every_player_request_used_magic_damage = true
	test_scene.last_player_damage_type = int(EnemyConfig.DamageType.PHYSICAL)


func _test_host_successful_hits_register_burn_statuses() -> void:
	var burn_scheduler := root.get_node("BurnStatusScheduler")
	burn_scheduler.call("clear_all")
	var mp_game := TestMpGame.new()
	var net_manager := TestNetManager.new()
	var game := Game.new()
	var normal_player := _spawn_player(Vector2(-800.0, -300.0), 20)
	var elite_player := _spawn_player(Vector2(-900.0, -300.0), 21)
	normal_player.physical_defense = 999
	normal_player.set("_base_physical_defense", 999)
	elite_player.physical_defense = 999
	elite_player.set("_base_physical_defense", 999)
	game.peer_players[20] = normal_player
	game.peer_players[21] = elite_player
	mp_game.set("net_manager", net_manager)
	mp_game.set("game", game)

	var normal_projectile_id := 81020
	var elite_projectile_id := 81021
	mp_game.call(
		"_remember_projectile_record",
		normal_projectile_id,
		1,
		FIREBALL_TYPE,
		FIREBALL_DAMAGE,
		7.0
	)
	mp_game.call(
		"_remember_projectile_record",
		elite_projectile_id,
		1,
		ELITE_FIREBALL_TYPE,
		ELITE_FIREBALL_DAMAGE,
		7.0
	)
	var normal_was_handled := mp_game.request_multiplayer_player_damage(
		normal_projectile_id,
		20,
		FIREBALL_DAMAGE,
		&"fire_sorcerer_fireball_a",
		EnemyConfig.DamageType.MAGIC,
		Vector2.RIGHT,
		true
	)
	var elite_was_handled := mp_game.request_multiplayer_player_damage(
		elite_projectile_id,
		21,
		ELITE_FIREBALL_DAMAGE,
		&"fire_sorcerer_elite_fireball_a",
		EnemyConfig.DamageType.MAGIC,
		Vector2.RIGHT,
		true
	)
	var normal_burn := _get_burn_source_snapshot(normal_player, FIREBALL_TYPE)
	var elite_burn := _get_burn_source_snapshot(
		elite_player,
		ELITE_FIREBALL_TYPE
	)
	_expect(
		normal_was_handled
		and normal_player.current_health == TEST_HEALTH - FIREBALL_DAMAGE
		and int(normal_burn.get("tick_damage", 0)) == 5
		and is_equal_approx(float(normal_burn.get("time_left", 0.0)), 5.0),
		"A successful Host normal Fire hit must deal 40 magic damage and register a 5-second level-5 burn."
	)
	_expect(
		elite_was_handled
		and elite_player.current_health
			== TEST_HEALTH - ELITE_FIREBALL_DAMAGE
		and int(elite_burn.get("tick_damage", 0)) == 10
		and is_equal_approx(float(elite_burn.get("time_left", 0.0)), 5.0),
		"A successful Host Elite Fire hit must deal 70 magic damage and register a 5-second level-10 burn."
	)

	normal_player.magic_defense = 20
	normal_player.set("_base_magic_defense", 20)
	normal_player.invincibility_time_left = 0.37
	var health_before_burn_tick := normal_player.current_health
	mp_game.sent_methods.clear()
	mp_game.sent_arguments.clear()
	var burn_tick_was_handled := (
		mp_game.request_multiplayer_player_burn_tick(20, FIREBALL_TYPE)
	)
	var burn_event_index := mp_game.sent_methods.find(
		&"net_player_damage_applied"
	)
	var burn_event_arguments: Array = (
		mp_game.sent_arguments[burn_event_index]
		if burn_event_index >= 0
		else []
	)
	_expect(
		burn_tick_was_handled
		and normal_player.current_health == health_before_burn_tick - 4
		and is_equal_approx(normal_player.invincibility_time_left, 0.37)
		and burn_event_arguments.size() == 8
		and int(burn_event_arguments[4]) == 4
		and int(burn_event_arguments[6])
			== int(EnemyConfig.DamageType.MAGIC)
		and not bool(burn_event_arguments[7]),
		"A Host burn tick must use magic defense, synchronize one magic-damage event with grant_hit_invincibility=false, and preserve the Player invincibility timer."
	)

	burn_scheduler.call("clear_all")
	game.peer_players.clear()
	mp_game.free()
	net_manager.free()
	game.free()


func _test_host_invincible_first_contact_is_consumed() -> void:
	var burn_scheduler := root.get_node("BurnStatusScheduler")
	burn_scheduler.call("clear_all")
	var mp_game := TestMpGame.new()
	var net_manager := TestNetManager.new()
	var game := Game.new()
	var invincible_player := _spawn_player(Vector2(-400.0, -400.0), 2)
	var second_player := _spawn_player(Vector2(-500.0, -400.0), 3)
	game.peer_players[2] = invincible_player
	game.peer_players[3] = second_player
	mp_game.set("net_manager", net_manager)
	mp_game.set("game", game)
	var projectile_id := 81002
	mp_game.call(
		"_remember_projectile_record",
		projectile_id,
		1,
		FIREBALL_TYPE,
		FIREBALL_DAMAGE,
		7.0
	)
	invincible_player.last_damage_taken = 73
	invincible_player.invincibility_time_left = 1.0
	var request_was_handled := mp_game.request_multiplayer_player_damage(
		projectile_id,
		2,
		FIREBALL_DAMAGE,
		&"fire_sorcerer_fireball_a",
		EnemyConfig.DamageType.MAGIC,
		Vector2.RIGHT,
		true
	)
	var global_hit_key := String(mp_game.call(
		"_get_multiplayer_player_hit_key",
		projectile_id,
		2,
		&"fire_sorcerer_fireball_a"
	))
	var processed_hits := mp_game.get("_processed_player_hit_ids") as Dictionary
	_expect(
		request_was_handled
		and invincible_player.current_health == TEST_HEALTH
		and bool(mp_game.call(
			"_is_fire_sorcerer_fireball_contact_consumed",
			projectile_id,
			&"fire_sorcerer_fireball_a"
		))
		and processed_hits.has(global_hit_key)
		and not bool(burn_scheduler.call(
			"has_burn",
			invincible_player,
			FIREBALL_TYPE
		)),
		"Host invincibility must consume and cache the Fire A first contact with zero damage without registering burn."
	)
	invincible_player.invincibility_time_left = 0.0
	mp_game.request_multiplayer_player_damage(
		projectile_id,
		3,
		FIREBALL_DAMAGE,
		&"fire_sorcerer_fireball_a",
		EnemyConfig.DamageType.MAGIC,
		Vector2.RIGHT,
		true
	)
	_expect(
		second_player.current_health == TEST_HEALTH,
		"An invincibility-consumed Host fireball must not damage a second player."
	)
	burn_scheduler.call("clear_all")
	game.peer_players.clear()
	mp_game.free()
	net_manager.free()
	game.free()


func _test_client_invincible_first_contact_reports_zero() -> void:
	var burn_scheduler := root.get_node("BurnStatusScheduler")
	burn_scheduler.call("clear_all")
	var mp_game := TestMpGame.new()
	var net_manager := TestNetManager.new()
	net_manager.host_mode = false
	net_manager.local_peer_id = 4
	var game := Game.new()
	var invincible_player := _spawn_player(Vector2(-400.0, -500.0), 4)
	var second_player := _spawn_player(Vector2(-500.0, -500.0), 5)
	game.peer_players[4] = invincible_player
	game.peer_players[5] = second_player
	mp_game.set("net_manager", net_manager)
	mp_game.set("game", game)
	var projectile_id := 81003
	mp_game.call(
		"_remember_projectile_record",
		projectile_id,
		1,
		FIREBALL_TYPE,
		FIREBALL_DAMAGE,
		7.0
	)
	invincible_player.last_damage_taken = 91
	invincible_player.invincibility_time_left = 1.0
	mp_game.request_multiplayer_player_damage(
		projectile_id,
		4,
		FIREBALL_DAMAGE,
		&"fire_sorcerer_fireball_b",
		EnemyConfig.DamageType.MAGIC,
		Vector2.RIGHT,
		true
	)
	_expect(
		mp_game.report_count == 1
		and mp_game.last_reported_source_id == projectile_id
		and mp_game.last_reported_peer_id == 4
		and mp_game.last_reported_health == TEST_HEALTH
		and mp_game.last_reported_applied_damage == 0
		and not bool(burn_scheduler.call(
			"has_burn",
			invincible_player,
			FIREBALL_TYPE
		)),
		"Client invincibility must report one zero-damage consumption event without leaking stale damage or registering burn."
	)
	mp_game.request_multiplayer_player_damage(
		projectile_id,
		5,
		FIREBALL_DAMAGE,
		&"fire_sorcerer_fireball_b",
		EnemyConfig.DamageType.MAGIC,
		Vector2.RIGHT,
		true
	)
	_expect(
		mp_game.report_count == 1
		and second_player.current_health == TEST_HEALTH,
		"Client global Fire B consumption must suppress every later target for the same source tuple."
	)
	burn_scheduler.call("clear_all")
	game.peer_players.clear()
	mp_game.free()
	net_manager.free()
	game.free()


func _test_volley_player_plant_and_world_first_contact() -> void:
	var burn_scheduler := root.get_node("BurnStatusScheduler")
	burn_scheduler.call("clear_all")
	var player_projectile_id := 81004
	_remember_contact_record(player_projectile_id)
	var first_player := _spawn_player(Vector2(-200.0, -300.0), 6)
	var second_player := _spawn_player(Vector2(-300.0, -300.0), 7)
	var first_player_volley := _spawn_volley(Vector2.ZERO, player_projectile_id)
	var second_player_volley := _spawn_volley(Vector2.ZERO, player_projectile_id)
	first_player_volley.call("_on_ball_body_entered", first_player, 0)
	second_player_volley.call("_on_ball_body_entered", second_player, 0)
	_expect(
		test_scene.player_damage_request_count == 1
		and test_scene.every_player_request_was_preconsumed
		and test_scene.every_player_request_used_magic_damage
		and test_scene.last_player_damage_type
			== int(EnemyConfig.DamageType.MAGIC)
		and not bool(first_player_volley.call("_is_ball_active", 0))
		and not bool(second_player_volley.call("_is_ball_active", 0)),
		"Player contact must claim Fire A before reporting magic damage, and every replica must expire immediately."
	)

	var plant_projectile_id := 81005
	_remember_contact_record(plant_projectile_id)
	var first_plant := _spawn_plant(Vector2(-200.0, -200.0), false)
	var second_plant := _spawn_plant(Vector2(-300.0, -200.0), false)
	first_plant.physical_defense = 99
	first_plant.magic_defense = 20
	var first_plant_volley := _spawn_volley(Vector2.ZERO, plant_projectile_id)
	var second_plant_volley := _spawn_volley(Vector2.ZERO, plant_projectile_id)
	first_plant_volley.call("_on_ball_body_entered", first_plant, 1)
	second_plant_volley.call("_on_ball_body_entered", second_plant, 1)
	_expect(
		first_plant.current_health == TEST_HEALTH - 32
		and second_plant.current_health == TEST_HEALTH
		and bool(burn_scheduler.call(
			"has_burn",
			first_plant,
			FIREBALL_TYPE
		))
		and not bool(first_plant_volley.call("_is_ball_active", 1))
		and not bool(second_plant_volley.call("_is_ball_active", 1)),
		"Plant contact must deal magic damage, register burn, and globally consume Fire B."
	)
	burn_scheduler.call("_advance_active_burns", 1.01)
	_expect(
		first_plant.current_health == TEST_HEALTH - 36,
		"Plant level-5 burn must tick as 4 magic damage against 20 magic defense."
	)

	var world_projectile_id := 81006
	_remember_contact_record(world_projectile_id)
	var world_body := StaticBody2D.new()
	world_body.collision_layer = 0
	test_scene.add_child(world_body)
	var untouched_plant := _spawn_plant(Vector2(-300.0, -100.0), false)
	var world_volley := _spawn_volley(Vector2.ZERO, world_projectile_id)
	var later_plant_volley := _spawn_volley(Vector2.ZERO, world_projectile_id)
	world_volley.call("_on_ball_body_entered", world_body, 2)
	later_plant_volley.call("_on_ball_body_entered", untouched_plant, 2)
	_expect(
		untouched_plant.current_health == TEST_HEALTH
		and not bool(world_volley.call("_is_ball_active", 2))
		and not bool(later_plant_volley.call("_is_ball_active", 2)),
		"World contact must globally consume Fire C and block a later plant hit."
	)
	burn_scheduler.call("clear_all")


func _test_compensation_sweep_and_normal_path_cost() -> void:
	FireSorcererFireballVolley.set_performance_metrics_enabled(true)
	var normal_volley := _spawn_volley(Vector2(0.0, 400.0), 0)
	var retained_query := normal_volley.motion_sweep.query
	var every_ball_uses_the_authored_shape := true
	for ball_index in range(FireSorcererFireballVolley.BALL_COUNT):
		every_ball_uses_the_authored_shape = (
			every_ball_uses_the_authored_shape
			and retained_query.shape
				== normal_volley.ball_collision_shapes[ball_index].shape
			and retained_query.collision_mask
				== FireSorcererFireballVolley.AUTHORED_COLLISION_MASK
		)
	normal_volley.call("_advance_ball_positions", 0.25)
	var normal_metrics := FireSorcererFireballVolley.get_performance_metrics()
	_expect(
		every_ball_uses_the_authored_shape
		and retained_query.collide_with_bodies
		and not retained_query.collide_with_areas
		and int(normal_metrics.get("compensation_sweep_calls", -1)) == 0,
		"Normal movement must retain one authored shape query without issuing it."
	)

	var wall := _spawn_static_body(
		Vector2(32.0, 0.0),
		Vector2(4.0, 100.0),
		1
	)
	var wall_volley := _spawn_volley(Vector2.ZERO, 0)
	await physics_frame
	await process_frame
	FireSorcererFireballVolley.reset_performance_metrics()
	wall_volley.simulate_compensated_motion(0.25)
	var wall_metrics := FireSorcererFireballVolley.get_performance_metrics()
	var all_balls_stopped_before_wall := true
	for ball in wall_volley.ball_areas:
		all_balls_stopped_before_wall = (
			all_balls_stopped_before_wall
			and ball.global_position.x <= 30.1
		)
	_expect(
		wall_volley.active_ball_mask == 0
		and all_balls_stopped_before_wall
		and int(wall_metrics.get("compensation_sweep_calls", 0)) > 0,
		"Compensation shape sweeps must stop every fireball at the first wall instead of tunneling through it."
	)

	# Fire A starts overlapped, so this guards the explicit preflight required
	# because PhysicsDirectSpaceState2D.cast_motion ignores initial overlaps.
	# Fire B remains outside the authored 3.5 px radius.
	var target_plant := _spawn_plant(Vector2(32.0, 202.0), true)
	var target_volley := _spawn_volley(Vector2(0.0, 200.0), 0)
	await physics_frame
	await process_frame
	target_volley.simulate_compensated_motion(0.25)
	_expect(
		target_plant.current_health == TEST_HEALTH - FIREBALL_DAMAGE
		and not bool(target_volley.call("_is_ball_active", 0))
		and bool(target_volley.call("_is_ball_active", 1))
		and bool(target_volley.call("_is_ball_active", 2)),
		"Compensation shape sweeps must catch a target while leaving non-intersecting sibling balls live."
	)

	var swept_plant := _spawn_plant(Vector2(42.0, 602.0), true)
	var swept_volley := _spawn_volley(Vector2(0.0, 600.0), 0)
	await physics_frame
	swept_volley.simulate_compensated_motion(0.25)
	_expect(
		swept_plant.current_health == TEST_HEALTH - FIREBALL_DAMAGE
		and not bool(swept_volley.call("_is_ball_active", 0))
		and bool(swept_volley.call("_is_ball_active", 1))
		and bool(swept_volley.call("_is_ball_active", 2)),
		"A moving shape sweep must resolve the damageable collider at its unsafe fraction."
	)

	var graze_start := Vector2(0.0, 800.0)
	var graze_wall := _spawn_static_body(
		Vector2(40.0, 804.5),
		Vector2(2.0, 2.0),
		1
	)
	var graze_volley := _spawn_volley(graze_start, 0)
	await physics_frame
	var ball_a_start := graze_volley.ball_areas[0].global_position
	var center_ray := PhysicsRayQueryParameters2D.create(
		ball_a_start,
		ball_a_start + Vector2(25.0, 0.0),
		1
	)
	var center_ray_missed := test_scene.get_world_2d().direct_space_state.intersect_ray(
		center_ray
	).is_empty()
	graze_volley.simulate_compensated_motion(0.25)
	_expect(
		center_ray_missed
		and not bool(graze_volley.call("_is_ball_active", 0))
		and bool(graze_volley.call("_is_ball_active", 1))
		and bool(graze_volley.call("_is_ball_active", 2)),
		"The authored offset circle sweep must catch a graze that the retired center ray misses."
	)
	wall.collision_layer = 0
	graze_wall.collision_layer = 0


func _remember_contact_record(projectile_id: int) -> void:
	contact_authority.call(
		"_remember_projectile_record",
		projectile_id,
		1,
		FIREBALL_TYPE,
		FIREBALL_DAMAGE,
		7.0
	)


func _get_burn_source_snapshot(
	target: Object,
	source_family: StringName
) -> Dictionary:
	var burn_scheduler := root.get_node("BurnStatusScheduler")
	return burn_scheduler.call(
		"get_source_snapshot",
		target,
		source_family
	) as Dictionary


func _spawn_player(position: Vector2, peer_id: int) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_scene.add_child(player)
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


func _spawn_plant(
	position: Vector2,
	with_collision_shape: bool
) -> PlantDefense:
	var plant := PlantDefense.new()
	plant.max_health = TEST_HEALTH
	plant.current_health = TEST_HEALTH
	plant.magic_defense = 0
	plant.physical_defense = 0
	plant.collision_layer = 512 if with_collision_shape else 0
	plant.collision_mask = 0
	if with_collision_shape:
		var collision_shape := CollisionShape2D.new()
		var rectangle := RectangleShape2D.new()
		rectangle.size = Vector2(4.0, 6.0)
		collision_shape.shape = rectangle
		plant.add_child(collision_shape)
	test_scene.add_child(plant)
	plant.global_position = position
	return plant


func _spawn_static_body(
	position: Vector2,
	shape_size: Vector2,
	collision_layer: int
) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = collision_layer
	body.collision_mask = 0
	var collision_shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = shape_size
	collision_shape.shape = rectangle
	body.add_child(collision_shape)
	test_scene.add_child(body)
	body.global_position = position
	return body


func _spawn_volley(
	position: Vector2,
	projectile_id: int
) -> FireSorcererFireballVolley:
	var volley := (
		FIREBALL_VOLLEY_SCENE.instantiate()
		as FireSorcererFireballVolley
	)
	test_scene.add_child(volley)
	volley.global_position = position
	volley.setup(
		Vector2.RIGHT,
		FIREBALL_DAMAGE,
		100.0,
		7.0,
		null,
		0.0
	)
	volley.setup_multiplayer(projectile_id, 1, FIREBALL_TYPE)
	volley.set_physics_process(false)
	return volley


func _spawn_elite_volley(
	position: Vector2,
	projectile_id: int
) -> FireSorcererFireballVolley:
	var volley := (
		ELITE_FIREBALL_VOLLEY_SCENE.instantiate()
		as FireSorcererFireballVolley
	)
	test_scene.add_child(volley)
	volley.global_position = position
	volley.setup(
		Vector2.RIGHT,
		ELITE_FIREBALL_DAMAGE,
		115.0,
		7.0,
		null,
		0.0
	)
	volley.setup_multiplayer(projectile_id, 1, ELITE_FIREBALL_TYPE)
	volley.set_physics_process(false)
	return volley


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
