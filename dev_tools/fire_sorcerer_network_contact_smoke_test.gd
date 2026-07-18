extends SceneTree

const FIREBALL_VOLLEY_SCENE := preload(
	"res://scene/enemy/fire_sorcerer_fireball_volley.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const TEST_HEALTH := 1000
const FIREBALL_DAMAGE := 50
const FIREBALL_TYPE: StringName = &"fire_sorcerer_fireball_volley"


class TestMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var report_count := 0
	var last_reported_source_id := 0
	var last_reported_peer_id := 0
	var last_reported_health := -1
	var last_reported_applied_damage := -1

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

	_test_dedup_key_and_source_mask_contract()
	_test_host_invincible_first_contact_is_consumed()
	_test_client_invincible_first_contact_reports_zero()
	_test_volley_player_plant_and_world_first_contact()
	await _test_compensation_sweep_and_normal_path_cost()

	FireSorcererFireballVolley.set_performance_metrics_enabled(false)
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
	mp_game.call(
		"_remember_projectile_record",
		projectile_id,
		1,
		FIREBALL_TYPE,
		FIREBALL_DAMAGE,
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
	_expect(
		fire_key_peer_two == fire_key_peer_three
		and not fire_key_peer_two.contains(":2:")
		and ordinary_key_peer_two != ordinary_key_peer_three,
		"Fire A/B/C dedupe keys must omit target_peer_id while ordinary projectile keys retain it."
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
		"One volley record must independently consume A, B and C exactly once."
	)
	mp_game.free()


func _test_host_invincible_first_contact_is_consumed() -> void:
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
		and processed_hits.has(global_hit_key),
		"Host invincibility must still consume and cache the Fire A first contact with zero damage."
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
	game.peer_players.clear()
	mp_game.free()
	net_manager.free()
	game.free()


func _test_client_invincible_first_contact_reports_zero() -> void:
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
		and mp_game.last_reported_applied_damage == 0,
		"Client invincibility must report one zero-damage consumption event without leaking stale damage."
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
	game.peer_players.clear()
	mp_game.free()
	net_manager.free()
	game.free()


func _test_volley_player_plant_and_world_first_contact() -> void:
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
		and not bool(first_player_volley.call("_is_ball_active", 0))
		and not bool(second_player_volley.call("_is_ball_active", 0)),
		"Player contact must claim Fire A before reporting, and every replica must expire immediately."
	)

	var plant_projectile_id := 81005
	_remember_contact_record(plant_projectile_id)
	var first_plant := _spawn_plant(Vector2(-200.0, -200.0), false)
	var second_plant := _spawn_plant(Vector2(-300.0, -200.0), false)
	var first_plant_volley := _spawn_volley(Vector2.ZERO, plant_projectile_id)
	var second_plant_volley := _spawn_volley(Vector2.ZERO, plant_projectile_id)
	first_plant_volley.call("_on_ball_body_entered", first_plant, 1)
	second_plant_volley.call("_on_ball_body_entered", second_plant, 1)
	_expect(
		first_plant.current_health == TEST_HEALTH - FIREBALL_DAMAGE
		and second_plant.current_health == TEST_HEALTH
		and not bool(first_plant_volley.call("_is_ball_active", 1))
		and not bool(second_plant_volley.call("_is_ball_active", 1)),
		"Plant contact must globally consume Fire B before any damage is applied."
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


func _test_compensation_sweep_and_normal_path_cost() -> void:
	var retained_query_before := (
		FireSorcererFireballVolley._get_compensation_ray_query()
	)
	FireSorcererFireballVolley.set_performance_metrics_enabled(true)
	var normal_volley := _spawn_volley(Vector2(0.0, 400.0), 0)
	normal_volley.call("_advance_ball_positions", 0.25)
	var normal_metrics := FireSorcererFireballVolley.get_performance_metrics()
	_expect(
		int(normal_metrics.get("compensation_sweep_calls", -1)) == 0,
		"Normal fireball movement must not issue compensation collision queries."
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
		"Compensation rays must stop every fireball at the first wall instead of tunneling through it."
	)

	var target_plant := _spawn_plant(Vector2(32.0, 200.0), true)
	var target_volley := _spawn_volley(Vector2(0.0, 200.0), 0)
	await physics_frame
	await process_frame
	target_volley.simulate_compensated_motion(0.25)
	_expect(
		target_plant.current_health == TEST_HEALTH - FIREBALL_DAMAGE
		and not bool(target_volley.call("_is_ball_active", 0))
		and bool(target_volley.call("_is_ball_active", 1))
		and bool(target_volley.call("_is_ball_active", 2)),
		"Compensation rays must catch a damageable target while leaving non-intersecting sibling balls live."
	)
	var retained_query_after := (
		FireSorcererFireballVolley._get_compensation_ray_query()
	)
	_expect(
		is_same(retained_query_before, retained_query_after),
		"Every compensated volley must reuse one retained ray query object."
	)
	wall.collision_layer = 0


func _remember_contact_record(projectile_id: int) -> void:
	contact_authority.call(
		"_remember_projectile_record",
		projectile_id,
		1,
		FIREBALL_TYPE,
		FIREBALL_DAMAGE,
		7.0
	)


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
		155.0,
		7.0,
		null,
		0.0
	)
	volley.setup_multiplayer(projectile_id, 1, FIREBALL_TYPE)
	volley.set_physics_process(false)
	return volley


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
