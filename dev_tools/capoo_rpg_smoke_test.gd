extends SceneTree

const CAPOO_SCENE := preload("res://scene/enemy/capoo/capoo_rpg.tscn")
const ROCKET_SCENE := preload("res://scene/enemy/capoo/capoo_rpg_rocket.tscn")
const EXPLOSION_SCENE := preload("res://scene/enemy/capoo/capoo_rpg_explosion.tscn")
const RocketSimulationServiceScript := preload(
	"res://scene/combat/simulation/capoo_rpg_rocket_simulation_service.gd"
)
const ExplosionResolutionServiceScript := preload(
	"res://scene/combat/simulation/explosion_resolution_service.gd"
)
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const CAPOO_CONFIG := preload("res://resources/config/enemies/capoo_rpg.tres")
const COMBAT_RUNTIME_FIXTURE_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)

var failures: Array[String] = []
var test_root: EnemyGameplayGatewayTestRuntime
var rocket_service: RocketSimulationServiceScript = null
var explosion_service: ExplosionResolutionServiceScript = null
var damageable_index: EnemyDamageableSpatialIndex = null


class ProbePlant:
	extends PlantDefense

	var accepted_request_count := 0
	var last_accepted_request: DamageRequest = null


	func apply_combat_damage(request: DamageRequest) -> DamageResult:
		var result := super.apply_combat_damage(request)
		if result.accepted:
			accepted_request_count += 1
			last_accepted_request = request
		return result


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = (
		COMBAT_RUNTIME_FIXTURE_SCENE.instantiate()
		as EnemyGameplayGatewayTestRuntime
	)
	test_root.name = "CapooRPGSmokeTestRuntime"
	root.add_child(test_root)
	current_scene = test_root
	_build_data_rocket_services()
	await process_frame
	await physics_frame

	_test_resource_contract()
	if rocket_service != null and explosion_service != null:
		await _test_windup_fire_and_cooldown()
		await _test_world_obstruction_blocks_attack()
		await _test_data_rocket_next_tick_and_world_priority()
		await _test_data_rocket_direct_dedupe_and_same_frame_settlement()
		await _test_death_interrupts_attack()
		await _test_proxy_action_visuals()

	test_root.prepare_for_scene_teardown()
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	var structured := {
		"schema_version": 1,
		"valid": failures.is_empty(),
		"verdict": "passed" if failures.is_empty() else "failed",
		"violations": failures.duplicate(),
	}
	print("CAPOO_RPG_SMOKE_RESULT %s" % JSON.stringify(structured))
	if failures.is_empty():
		print("CAPOO_RPG_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _build_data_rocket_services() -> void:
	var coordinator := test_root.get_enemy_simulation_coordinator()
	var combat_services := test_root.get_enemy_combat_services()
	_expect(coordinator != null, "Runtime must expose EnemySimulationCoordinator.")
	_expect(combat_services != null, "Runtime must expose EnemyCombatServices.")
	if coordinator == null or combat_services == null:
		return
	coordinator.process_mode = Node.PROCESS_MODE_DISABLED
	damageable_index = combat_services.get_enemy_damageable_spatial_index()
	rocket_service = combat_services.get_capoo_rpg_rocket_simulation_service()
	explosion_service = combat_services.get_explosion_resolution_service()
	_expect(rocket_service != null, "Rocket simulation service scene must instantiate.")
	_expect(explosion_service != null, "Explosion resolution service scene must instantiate.")
	if rocket_service == null or explosion_service == null:
		return
	rocket_service.process_mode = Node.PROCESS_MODE_DISABLED
	_expect(
		rocket_service.is_bound() and rocket_service.reserve(8),
		"Authored rocket simulation service must be bound with reserved capacity."
	)
	_expect(
		explosion_service.is_bound_to(test_root, coordinator),
		"Authored explosion resolution service must share the runtime context."
	)


func _test_resource_contract() -> void:
	_expect(CAPOO_CONFIG is CapooRPGConfig, "RPG config must use CapooRPGConfig.")
	_expect(CAPOO_CONFIG.display_name == "RPG猫猫虫", "Display name mismatch.")
	_expect(CAPOO_CONFIG.enemy_scene == CAPOO_SCENE, "RPG Capoo must use its own scene.")
	_expect(CAPOO_CONFIG.attack_audio_stream != null, "RPG fire audio is missing.")
	_expect(_resource_path(CAPOO_CONFIG.attack_audio_stream).ends_with("capoo_rpg_launch.wav"), "RPG must use its dedicated launch audio.")
	_expect(CAPOO_CONFIG.max_health == 200, "RPG health mismatch.")
	_expect(CAPOO_CONFIG.attack_damage == 20, "RPG damage mismatch.")
	_expect(CAPOO_CONFIG.physical_defense == 0, "RPG physical defense mismatch.")
	_expect(CAPOO_CONFIG.magic_defense == 0, "RPG magic defense mismatch.")
	_expect(is_equal_approx(CAPOO_CONFIG.move_speed, 16.0), "RPG move speed mismatch.")
	_expect(is_equal_approx(CAPOO_CONFIG.attack_range, 320.0), "RPG attack range mismatch.")
	_expect(is_equal_approx(CAPOO_CONFIG.attack_windup, 0.5), "RPG windup mismatch.")
	_expect(is_equal_approx(CAPOO_CONFIG.attack_interval, 6.0), "RPG cooldown mismatch.")
	_expect(is_equal_approx(CAPOO_CONFIG.projectile_speed, 210.0), "RPG rocket speed mismatch.")
	_expect(is_equal_approx(CAPOO_CONFIG.projectile_lifetime, 3.0), "RPG rocket lifetime mismatch.")
	_expect(is_equal_approx(CAPOO_CONFIG.explosion_radius, 44.0), "RPG explosion radius mismatch.")

	var rocket_frames := load("res://resources/animation/capoo_rpg_rocket.tres") as SpriteFrames
	var explosion_frames := load("res://resources/animation/capoo_rpg_explosion.tres") as SpriteFrames
	_expect(rocket_frames != null and rocket_frames.get_frame_count(&"fly") == 4, "RPG rocket frame count mismatch.")
	_expect(
		explosion_frames != null and explosion_frames.get_frame_count(&"explode") == 8,
		"RPG explosion frame count mismatch."
	)

	var texture := load("res://resources/texture/enemy/capoo/capoo_rpg.png") as Texture2D
	var rocket_texture := load("res://resources/texture/enemy/capoo/capoo_rpg_rocket.png") as Texture2D
	var explosion_texture := load("res://resources/texture/enemy/capoo/capoo_rpg_explosion.png") as Texture2D
	_expect(texture != null and texture.get_size() == Vector2(384, 384), "RPG sprite sheet size is incorrect.")
	_expect(rocket_texture != null and rocket_texture.get_size() == Vector2(128, 32), "RPG rocket sheet size is incorrect.")
	_expect(
		explosion_texture != null and explosion_texture.get_size() == Vector2(768, 96),
		"RPG explosion sheet size is incorrect."
	)

	var capoo_instance := CAPOO_SCENE.instantiate() as CapooRPG
	_expect(capoo_instance != null, "RPG Capoo scene did not instantiate CapooRPG.")
	if capoo_instance != null:
		_expect(capoo_instance.get_node_or_null("MuzzleHeat") is Polygon2D, "RPG scene is missing MuzzleHeat.")
		_expect(capoo_instance.get_node_or_null("AttackAudio") is AudioStreamPlayer2D, "RPG scene is missing AttackAudio.")
		var animated_sprite := capoo_instance.get_node("AnimatedSprite2D") as AnimatedSprite2D
		var scene_frames := animated_sprite.sprite_frames
		_expect(scene_frames != null, "RPG scene SpriteFrames are missing.")
		if scene_frames != null:
			_expect(scene_frames.get_frame_count(&"move") == 3, "RPG move frame count mismatch.")
			_expect(scene_frames.get_frame_count(&"windup") == 4, "RPG windup frame count mismatch.")
			_expect(scene_frames.get_frame_count(&"attack") == 4, "RPG attack frame count mismatch.")
			_expect(scene_frames.get_frame_count(&"death") == 3, "RPG death frame count mismatch.")
		var body_shape := capoo_instance.get_node("CollisionShape2D") as CollisionShape2D
		var touch_shape := capoo_instance.get_node("TouchDamageArea/CollisionShape2D") as CollisionShape2D
		_expect(body_shape.shape is RectangleShape2D, "RPG body collision must be scene-owned rectangle.")
		_expect(touch_shape.shape is RectangleShape2D, "RPG touch collision must be scene-owned rectangle.")
		_expect(body_shape.shape != touch_shape.shape, "RPG body and touch shapes must be independently editable.")
		capoo_instance.free()

	# Legacy scenes remain importable for compatibility only. Inspect the packed
	# resource state without instantiating either old projectile/effect node.
	var rocket_state := ROCKET_SCENE.get_state()
	var rocket_shape := _get_packed_scene_node_property(
		rocket_state, &"CollisionShape2D", &"shape"
	) as CapsuleShape2D
	var legacy_explosion_shape := _get_packed_scene_node_property(
		rocket_state, &"ExplosionShape", &"shape"
	) as CircleShape2D
	_expect(
		rocket_state.get_node_type(0) == &"Area2D" and rocket_shape != null,
		"Legacy RPG rocket compatibility resource must retain its authored capsule."
	)
	_expect(
		legacy_explosion_shape != null
		and is_equal_approx(legacy_explosion_shape.radius, 44.0),
		"Legacy RPG rocket compatibility resource must retain its blast radius."
	)
	var explosion_state := EXPLOSION_SCENE.get_state()
	var explosion_audio_stream := _get_packed_scene_node_property(
		explosion_state, &"ExplosionAudio", &"stream"
	) as AudioStream
	_expect(
		explosion_audio_stream != null,
		"Legacy RPG explosion compatibility resource must retain its audio stream."
	)


func _test_windup_fire_and_cooldown() -> void:
	rocket_service.clear()
	var player := _spawn_player(Vector2(240.0, 0.0), 200)
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	await _wait_physics_frames(3)

	_expect(enemy.combat_state == CapooRPG.CombatState.WINDUP, "RPG Capoo did not enter windup in range.")
	_expect(rocket_service.get_live_count() == 0, "RPG Capoo fired during early windup.")
	await _wait_physics_frames(20)
	_expect(rocket_service.get_live_count() == 0, "RPG Capoo fired before windup completed.")

	var guard_frames := 0
	while enemy.combat_state == CapooRPG.CombatState.WINDUP and guard_frames < 90:
		await physics_frame
		guard_frames += 1
	_expect(guard_frames < 90, "RPG windup did not finish in time.")
	await _wait_physics_frames(2)
	_expect(rocket_service.get_live_count() == 1, "RPG Capoo did not register exactly one data rocket.")
	_expect(_count_legacy_rocket_nodes() == 0, "DATA fire must not instantiate a legacy rocket node.")

	await _wait_physics_frames(180)
	_expect(rocket_service.get_live_count() == 1, "RPG Capoo fired again during cooldown.")
	_expect(enemy.combat_state != CapooRPG.CombatState.WINDUP, "RPG Capoo re-entered windup during cooldown.")

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_world_obstruction_blocks_attack() -> void:
	rocket_service.clear()
	var player := _spawn_player(Vector2(240.0, 0.0), 100)
	var wall := _spawn_wall(Vector2(120.0, 0.0), 16.0)
	await physics_frame
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	await _wait_physics_frames(24)

	_expect(enemy.combat_state == CapooRPG.CombatState.CHASE, "RPG Capoo attacked through a World-layer wall.")
	_expect(rocket_service.get_live_count() == 0, "RPG Capoo fired through a World-layer wall.")

	enemy.queue_free()
	wall.queue_free()
	player.queue_free()
	await physics_frame


func _test_data_rocket_next_tick_and_world_priority() -> void:
	if rocket_service == null:
		return
	rocket_service.clear()
	var next_tick_origin := Vector2(1200.0, 900.0)
	var next_tick_handle := _spawn_data_rocket(
		81001,
		next_tick_origin,
		Vector2.RIGHT,
		50.0,
		1.0,
		0.0
	)
	rocket_service.advance(0.1)
	_expect(
		rocket_service.is_handle_live(next_tick_handle)
		and rocket_service.get_position(next_tick_handle) == next_tick_origin
		and rocket_service.get_completion_count() == 0,
		"A newly spawned data rocket must not move or complete in its spawn physics frame."
	)
	await physics_frame
	rocket_service.advance(0.1)
	_expect(
		rocket_service.get_position(next_tick_handle).is_equal_approx(
			next_tick_origin + Vector2(5.0, 0.0)
		),
		"A data rocket must begin moving on the next physics frame."
	)
	_expect(rocket_service.release(next_tick_handle), "Next-tick probe rocket must release cleanly.")

	var world_origin := Vector2(1600.0, 900.0)
	var wall := _spawn_wall(world_origin + Vector2(10.0, 0.0), 3.0)
	var direct_probe := _spawn_probe_plant(
		"WorldPriorityDirectProbe",
		world_origin + Vector2(20.0, 0.0),
		3.0
	)
	await physics_frame
	var world_handle := _spawn_data_rocket(
		81002,
		world_origin,
		Vector2.RIGHT,
		100.0,
		1.0,
		0.0
	)
	await physics_frame
	rocket_service.advance(0.2)
	_expect(
		rocket_service.get_completion_count() == 1
		and rocket_service.get_completion_reason(0)
			== RocketSimulationServiceScript.CompletionReason.WORLD
		and rocket_service.get_completion_direct_hit(0) == null
		and not rocket_service.is_handle_live(world_handle),
		"World sweep must win before endpoint direct contact in the same tick."
	)
	_expect(
		_consume_completion(0) == 0
		and direct_probe.accepted_request_count == 0,
		"A zero-radius World completion must not leak a direct-hit damage request."
	)
	rocket_service.clear_completion_records()
	wall.queue_free()
	_unregister_and_free_plant(direct_probe)
	await physics_frame


func _test_data_rocket_direct_dedupe_and_same_frame_settlement() -> void:
	if rocket_service == null or explosion_service == null:
		return
	rocket_service.clear()
	var origin := Vector2(2200.0, 900.0)
	var direct_probe := _spawn_probe_plant(
		"DirectAndAoeProbe",
		origin + Vector2(20.0, 0.0),
		3.0
	)
	await physics_frame
	var handle := _spawn_data_rocket(
		82001,
		origin,
		Vector2.RIGHT,
		100.0,
		1.0,
		CAPOO_CONFIG.explosion_radius
	)
	await physics_frame
	var physics_frame_before := Engine.get_physics_frames()
	rocket_service.advance(0.2)
	_expect(
		rocket_service.get_completion_count() == 1
		and rocket_service.get_completion_reason(0)
			== RocketSimulationServiceScript.CompletionReason.DIRECT_HIT
		and rocket_service.get_completion_direct_hit(0) == direct_probe
		and not rocket_service.is_handle_live(handle),
		"Endpoint capsule overlap must produce the first admitted direct hit."
	)
	var accepted := _consume_completion(0)
	_expect(
		accepted == 1
		and direct_probe.accepted_request_count == 1
		and direct_probe.current_health == direct_probe.max_health - 20
		and direct_probe.last_accepted_request != null,
		"Direct-hit-first explosion must dedupe the same target from AoE and apply one real DamageRequest."
	)
	_expect(
		Engine.get_physics_frames() == physics_frame_before,
		"Rocket completion and explosion damage must settle synchronously in the same physics frame."
	)
	var explosion_metrics := explosion_service.get_metrics()
	_expect(
		int(explosion_metrics["duplicate_skip_count"]) >= 1,
		"Explosion resolution must record the direct-hit/AoE duplicate skip."
	)
	rocket_service.clear_completion_records()
	_unregister_and_free_plant(direct_probe)
	await physics_frame


func _test_death_interrupts_attack() -> void:
	rocket_service.clear()
	var player := _spawn_player(Vector2(240.0, 0.0), 100)
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	await _wait_physics_frames(3)

	_expect(enemy.combat_state == CapooRPG.CombatState.WINDUP, "Death test RPG did not enter windup.")
	enemy.apply_damage(CAPOO_CONFIG.max_health)
	await _wait_physics_frames(45)
	_expect(rocket_service.get_live_count() == 0, "Dead RPG Capoo fired after attack interruption.")

	if is_instance_valid(enemy):
		enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_proxy_action_visuals() -> void:
	var player := _spawn_player(Vector2(240.0, 0.0), 100)
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	enemy.configure_multiplayer_proxy()
	enemy.play_multiplayer_enemy_action(&"windup", Vector2.RIGHT, 1)
	await process_frame
	_expect(enemy.muzzle_heat.visible, "Proxy RPG windup muzzle heat did not appear.")
	_expect(enemy.animated_sprite.animation == CAPOO_CONFIG.windup_animation_name, "Proxy RPG did not play windup animation.")
	enemy.play_multiplayer_enemy_action(&"fire", Vector2.RIGHT, 2)
	await process_frame
	_expect(enemy.muzzle_heat.visible, "Proxy RPG fire muzzle heat did not appear.")
	_expect(enemy.animated_sprite.animation == CAPOO_CONFIG.attack_animation_name, "Proxy RPG did not play fire animation.")
	enemy.play_multiplayer_enemy_action(&"windup", Vector2.RIGHT, 3)
	enemy.play_multiplayer_enemy_action(&"fire", Vector2.LEFT, 4)
	await process_frame
	_expect(
		Vector2.RIGHT.rotated(enemy.muzzle_heat.rotation).dot(Vector2.LEFT) > 0.99,
		"Stale proxy RPG windup tween must not override newer fire direction."
	)
	enemy.play_multiplayer_death_sequence()
	await process_frame
	_expect(not enemy.muzzle_heat.visible, "Proxy RPG death must clear muzzle heat.")
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _spawn_player(position: Vector2, health: int) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	player.collision_layer = 2
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set("_base_max_health", health)
	player.max_health = health
	player.current_health = health
	player.health_bar.setup(player.max_health, player.current_health)
	return player


func _spawn_capoo(position: Vector2, player: Player) -> CapooRPG:
	var enemy := CAPOO_SCENE.instantiate() as CapooRPG
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(CAPOO_CONFIG, player, null, test_root)
	return enemy


func _spawn_data_rocket(
	projectile_id: int,
	position: Vector2,
	direction: Vector2,
	speed: float,
	lifetime: float,
	radius: float
) -> int:
	return rocket_service.spawn_authoritative(
		projectile_id,
		position,
		direction,
		CAPOO_CONFIG.attack_damage,
		speed,
		lifetime,
		radius,
		DamageSourceSnapshot.create(
			CombatRelationService.HOSTILE_WAVE,
			0,
			700,
			projectile_id,
			&"capoo_rpg_rocket"
		)
	)


func _spawn_probe_plant(
	plant_name: String,
	position: Vector2,
	radius: float
) -> ProbePlant:
	var plant := ProbePlant.new()
	plant.name = plant_name
	plant.collision_layer = 512
	plant.collision_mask = 0
	plant.max_health = 1000
	plant.current_health = 1000
	plant.physical_defense = 0
	plant.magic_defense = 0
	plant.bind_gameplay_context(test_root, null)
	var collision_shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = radius
	collision_shape.shape = circle
	plant.add_child(collision_shape)
	test_root.add_child(plant)
	plant.global_position = position
	_expect(
		damageable_index != null and damageable_index.register_damageable(plant),
		"Probe plant must register in the shared damageable spatial index."
	)
	return plant


func _unregister_and_free_plant(plant: ProbePlant) -> void:
	if damageable_index != null:
		damageable_index.unregister_damageable(plant)
	plant.queue_free()


func _consume_completion(index: int) -> int:
	if rocket_service == null or explosion_service == null:
		return 0
	return explosion_service.resolve_hostile_explosion(
		rocket_service.get_completion_position(index),
		rocket_service.get_completion_radius(index),
		rocket_service.get_completion_damage(index),
		rocket_service.get_completion_direct_hit(index),
		rocket_service.get_completion_damage_source_snapshot(index),
		700,
		rocket_service.get_completion_projectile_id(index),
		&"capoo_rpg_rocket",
		EnemyConfig.DamageType.PHYSICAL
	)


func _spawn_wall(position: Vector2, radius: float) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	wall.collision_mask = 0
	var wall_shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = radius
	wall_shape.shape = circle
	wall.add_child(wall_shape)
	test_root.add_child(wall)
	wall.global_position = position
	return wall


func _count_legacy_rocket_nodes() -> int:
	var count := 0
	for child in test_root.get_children():
		var script := child.get_script() as Script
		if (
			script != null
			and script.resource_path
				== "res://scene/enemy/capoo/capoo_rpg_rocket.gd"
			and not child.is_queued_for_deletion()
		):
			count += 1
	return count


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _resource_path(resource: Resource) -> String:
	return resource.resource_path if resource != null else ""


func _get_packed_scene_node_property(
	state: SceneState,
	node_name: StringName,
	property_name: StringName
) -> Variant:
	for node_index in range(state.get_node_count()):
		if state.get_node_name(node_index) != node_name:
			continue
		for property_index in range(state.get_node_property_count(node_index)):
			if (
				state.get_node_property_name(node_index, property_index)
				== property_name
			):
				return state.get_node_property_value(node_index, property_index)
	return null
