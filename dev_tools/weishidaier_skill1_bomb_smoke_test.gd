extends SceneTree

const BOMB_SCENE := preload(
	"res://scene/player/weishidaier/weishidaier_skill1_bomb.tscn"
)
const BASIC_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const DENSE_ENEMY_COUNT := 48

var failures: Array[String] = []


class HostRuntimeStub:
	extends Node2D

	var authoritative_damage_calls: int = 0
	var legacy_hit_report_calls: int = 0

	func is_client_view_runtime() -> bool:
		return false

	func apply_multiplayer_collectible_enemy_damage(
		enemy: Enemy,
		damage: int,
		impact_direction: Vector2,
		damage_type: int = EnemyConfig.DamageType.MAGIC,
		show_hit_particles: bool = true
	) -> bool:
		authoritative_damage_calls += 1
		return enemy.apply_damage(
			damage,
			impact_direction,
			damage_type as EnemyConfig.DamageType,
			show_hit_particles
		)

	func request_enemy_hit_report(
		_projectile_id: int,
		_owner_peer_id: int,
		_enemy_net_id: int,
		_damage: int,
		_impact_direction: Vector2
	) -> void:
		legacy_hit_report_calls += 1


class ClientRuntimeStub:
	extends Node2D

	var authoritative_damage_calls: int = 0
	var legacy_hit_report_calls: int = 0

	func is_client_view_runtime() -> bool:
		return true

	func apply_multiplayer_collectible_enemy_damage(
		_enemy: Enemy,
		_damage: int,
		_impact_direction: Vector2,
		_damage_type: int = EnemyConfig.DamageType.MAGIC,
		_show_hit_particles: bool = true
	) -> bool:
		authoritative_damage_calls += 1
		return false

	func request_enemy_hit_report(
		_projectile_id: int,
		_owner_peer_id: int,
		_enemy_net_id: int,
		_damage: int,
		_impact_direction: Vector2
	) -> void:
		legacy_hit_report_calls += 1


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _verify_explosion_shape_isolation()
	await _verify_dense_singleplayer_explosion_has_no_result_cap()
	await _verify_direct_body_hit_is_always_included()
	await _verify_host_uses_authoritative_damage_path()
	await _verify_client_proxy_is_visual_only()

	current_scene = null
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("WEISHIDAIER_SKILL1_BOMB_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_explosion_shape_isolation() -> void:
	var scene := Node2D.new()
	scene.name = "BombShapeIsolationTest"
	root.add_child(scene)
	current_scene = scene

	var first_bomb := BOMB_SCENE.instantiate() as WeishidaierSkill1Bomb
	var second_bomb := BOMB_SCENE.instantiate() as WeishidaierSkill1Bomb
	first_bomb.explosion_radius = 31.0
	second_bomb.explosion_radius = 57.0
	first_bomb.monitoring = false
	second_bomb.monitoring = false
	scene.add_child(first_bomb)
	scene.add_child(second_bomb)
	first_bomb.set_physics_process(false)
	second_bomb.set_physics_process(false)

	var first_circle := first_bomb.explosion_shape.shape as CircleShape2D
	var second_circle := second_bomb.explosion_shape.shape as CircleShape2D
	_expect(
		first_circle != null and second_circle != null,
		"Bomb instances must expose their authored explosion CircleShapes."
	)
	if first_circle != null and second_circle != null:
		_expect(
			first_circle.resource_local_to_scene and second_circle.resource_local_to_scene,
			"Runtime-mutated bomb explosion Shapes must remain local to each scene instance."
		)
		_expect(
			first_circle != second_circle
			and is_equal_approx(first_circle.radius, 31.0)
			and is_equal_approx(second_circle.radius, 57.0),
			"Two bombs with different radii must not share or overwrite explosion Shapes."
		)
		first_circle.radius = 12.0
		_expect(
			is_equal_approx(second_circle.radius, 57.0),
			"Mutating one bomb explosion Shape must not leak into another bomb."
		)
	await _free_scene(scene)


func _verify_dense_singleplayer_explosion_has_no_result_cap() -> void:
	var scene := Node2D.new()
	scene.name = "DenseSingleplayerBombTest"
	root.add_child(scene)
	current_scene = scene

	var enemies: Array[Enemy] = []
	for _enemy_index in range(DENSE_ENEMY_COUNT):
		enemies.append(_spawn_enemy(scene, Vector2(128.0, 128.0)))
	var bomb := _spawn_bomb(scene, Vector2(128.0, 128.0), 1)
	await physics_frame
	await physics_frame

	bomb._apply_explosion_damage()
	var damaged_count := 0
	for enemy in enemies:
		if enemy != null and enemy.current_health == BASIC_CONFIG.max_health - 1:
			damaged_count += 1
	_expect(
		damaged_count == DENSE_ENEMY_COUNT,
		"Singleplayer explosion must damage all %d overlapping enemies, got %d."
		% [DENSE_ENEMY_COUNT, damaged_count]
	)
	await _free_scene(scene)


func _verify_direct_body_hit_is_always_included() -> void:
	var scene := Node2D.new()
	scene.name = "DirectBombHitTest"
	root.add_child(scene)
	current_scene = scene
	var enemy := _spawn_enemy(scene, Vector2(512.0, 0.0))
	var bomb := _spawn_bomb(scene, Vector2.ZERO, 1)
	await physics_frame

	# Keep the test target outside the radius so only the body_entered argument
	# can include it. A real callback occurs at contact, but this proves the
	# direct collider can never be dropped by query ordering or pagination.
	bomb._on_body_entered(enemy)
	_expect(
		enemy.current_health == BASIC_CONFIG.max_health - 1,
		"The Enemy passed by body_entered must be damaged even when absent from the query."
	)
	await _free_scene(scene)


func _verify_host_uses_authoritative_damage_path() -> void:
	var scene := HostRuntimeStub.new()
	scene.name = "HostBombTest"
	root.add_child(scene)
	current_scene = scene
	var enemy := _spawn_enemy(scene, Vector2(64.0, 64.0))
	var bomb := _spawn_bomb(scene, Vector2(64.0, 64.0), 1)
	bomb.setup_multiplayer(1000001, 1, &"skill1_bomb")
	await physics_frame
	await physics_frame

	bomb._apply_explosion_damage()
	_expect(
		scene.authoritative_damage_calls == 1,
		"Host bomb must settle each enemy through the authoritative damage API."
	)
	_expect(
		scene.legacy_hit_report_calls == 0,
		"Host bomb must not use the legacy per-target hit-report path."
	)
	_expect(
		enemy.current_health == BASIC_CONFIG.max_health - 1,
		"Host authoritative bomb settlement must damage the enemy exactly once."
	)
	await _free_scene(scene)


func _verify_client_proxy_is_visual_only() -> void:
	var scene := ClientRuntimeStub.new()
	scene.name = "ClientBombProxyTest"
	root.add_child(scene)
	current_scene = scene
	var enemy := _spawn_enemy(scene, Vector2(64.0, 64.0))
	var bomb := _spawn_bomb(scene, Vector2(64.0, 64.0), 1)
	bomb.setup_multiplayer(2000001, 2, &"skill1_bomb")
	await physics_frame

	bomb._on_body_entered(enemy)
	_expect(
		enemy.current_health == BASIC_CONFIG.max_health,
		"Client-view bomb proxy must not mutate local enemy health."
	)
	_expect(
		scene.authoritative_damage_calls == 0,
		"Client-view bomb proxy must not invoke the Host damage API."
	)
	_expect(
		scene.legacy_hit_report_calls == 0,
		"Client-view bomb proxy must not send per-target hit reports."
	)
	var explosion_effect_count := 0
	for child in scene.get_children():
		if child is WeishidaierSkill1Explosion:
			explosion_effect_count += 1
	_expect(
		explosion_effect_count == 1,
		"Client-view bomb proxy must still spawn its local explosion effect."
	)
	await _free_scene(scene)


func _spawn_enemy(parent: Node, position: Vector2) -> Enemy:
	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	parent.add_child(enemy)
	enemy.global_position = position
	enemy.setup(BASIC_CONFIG, null)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	return enemy


func _spawn_bomb(parent: Node, position: Vector2, bomb_damage: int) -> WeishidaierSkill1Bomb:
	var bomb := BOMB_SCENE.instantiate() as WeishidaierSkill1Bomb
	bomb.monitoring = false
	bomb.monitorable = false
	parent.add_child(bomb)
	bomb.global_position = position
	bomb.setup(null, Vector2.RIGHT, bomb_damage)
	bomb.set_physics_process(false)
	return bomb


func _free_scene(scene: Node) -> void:
	if scene != null and is_instance_valid(scene):
		scene.queue_free()
	await process_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
