extends SceneTree

const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const LINGLAN_SCENE := preload("res://scene/boss/linglan/linglan_boss.tscn")
const SAKURA_BULLET_SCENE := preload(
	"res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn"
)
const SAKURA_HIT_EFFECT_SCENE := preload(
	"res://scene/boss/linglan/linglan_sakura_hit_effect.tscn"
)
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const CAPOO_PROJECTILE_MOTION_SYSTEM_SCENE := preload(
	"res://scene/enemy/capoo/capoo_projectile_motion_system.tscn"
)
const DAY_NIGHT_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)


class PoolRuntime:
	extends GameRuntimeBase

	var session_object_pool: SessionObjectPool = null
	var local_projectile_records: Array[Dictionary] = []

	func install_pool() -> void:
		var enemies := Node2D.new()
		enemies.name = "EnemyContainer"
		add_child(enemies)
		var pathfinder := Node.new()
		pathfinder.name = "GridPathfinder"
		add_child(pathfinder)
		add_child(CAPOO_PROJECTILE_MOTION_SYSTEM_SCENE.instantiate())
		session_object_pool = SessionObjectPool.new()
		session_object_pool.name = "SessionObjectPool"
		add_child(session_object_pool)

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return peer_players.get(peer_id) as Player

	func get_enemy_for_net_id(net_id: int) -> Enemy:
		return multiplayer_enemies_by_net_id.get(net_id) as Enemy

	func get_pickup_for_net_id(net_id: int) -> Pickup:
		return multiplayer_pickups.get(net_id) as Pickup

	func remove_multiplayer_player(peer_id: int) -> void:
		peer_players.erase(peer_id)

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func apply_remote_flow_state(_step_id: StringName, _state: int, _seconds: int) -> void:
		pass

	func get_flow_state_snapshot() -> Dictionary:
		return {}

	func apply_remote_boss_started(
		_net_id: int,
		_boss_config: BossConfig,
		_spawn_position: Vector2
	) -> void:
		pass

	func apply_remote_defeat() -> void:
		pass

	func apply_remote_victory() -> void:
		pass

	func apply_remote_enemy_count(_alive_count: int) -> void:
		pass

	func apply_remote_merchant_active(_active: bool) -> void:
		pass

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass

	func try_purchase_skill1_for_peer(_peer_id: int) -> int:
		return 0

	func apply_skill1_purchase_state(
		_peer_id: int,
		_current_xirang: int,
		_skill1_unlocked: bool,
		_skill1_upgrade_level: int = -1,
		_skill1_charge_duration: float = -1.0
	) -> void:
		pass

	func show_local_skill1_purchase_result(_result_code: int) -> void:
		pass

	func try_refresh_luoxi_collectibles_for_peer(_peer_id: int) -> int:
		return 0

	func get_luoxi_collectible_refresh_count(_peer_id: int) -> int:
		return 0

	func try_claim_luoxi_collectible_for_peer(
		_peer_id: int,
		_config_path_or_choice: Variant
	) -> int:
		return 0

	func has_luoxi_collectible_claimed(_peer_id: int) -> bool:
		return false

	func record_luoxi_collectible_claim(_peer_id: int) -> void:
		pass

	func mark_luoxi_collectible_claimed(_peer_id: int) -> void:
		pass

	func show_local_luoxi_collectible_result(_result_code: int) -> void:
		pass

	func show_local_luoxi_refresh_result(
		_result_code: int,
		_refresh_count: int,
		_current_xirang: int
	) -> void:
		pass

	func show_debug_collectible_grant_result(_config_path: String, _success: bool) -> void:
		pass

	func register_local_projectile(
		projectile: Node,
		projectile_type: StringName,
		owner_peer_id: int,
		spawn_position: Vector2,
		direction: Vector2,
		damage: int,
		speed: float,
		lifetime: float,
		pierces_enemies: bool = false,
		target_peer_id: int = 0,
		target_enemy_net_id: int = 0
	) -> void:
		local_projectile_records.append({
			"projectile": projectile,
			"projectile_type": projectile_type,
			"owner_peer_id": owner_peer_id,
			"spawn_position": spawn_position,
			"direction": direction,
			"damage": damage,
			"speed": speed,
			"lifetime": lifetime,
			"pierces_enemies": pierces_enemies,
			"target_peer_id": target_peer_id,
			"target_enemy_net_id": target_enemy_net_id,
		})
		if projectile.has_method("setup_multiplayer"):
			projectile.call(
				"setup_multiplayer",
				7000 + local_projectile_records.size(),
				owner_peer_id,
				projectile_type
			)


var failures: Array[String] = []
var runtime: PoolRuntime = null
var pool: SessionObjectPool = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	runtime = PoolRuntime.new()
	runtime.name = "LinglanSkill1PoolRuntime"
	runtime.install_pool()
	runtime.add_child(DAY_NIGHT_SCENE.instantiate())
	root.add_child(runtime)
	current_scene = runtime
	pool = runtime.session_object_pool
	pool.register_scene(SAKURA_BULLET_SCENE, 1, 768)
	pool.register_scene(SAKURA_HIT_EFFECT_SCENE, 1, 96)

	await _test_boss_single_and_host_spawn_path()
	await _test_damage_trajectory_and_hit_effect_semantics()
	await _test_offscreen_hit_keeps_damage_without_visual_lease()
	await _test_multiplayer_client_spawn_and_cleanup_path()
	_test_production_runtime_registration_contract()

	current_scene = null
	runtime.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("LINGLAN_SKILL1_POOL_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_boss_single_and_host_spawn_path() -> void:
	var boss := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan must instantiate for the pooled authoritative spawn path.")
	if boss == null:
		return
	runtime.add_child(boss)
	await process_frame
	boss.global_position = Vector2(96.0, 64.0)
	boss.call("_spawn_skill1_projectile", Vector2.RIGHT)
	var first := _find_active_sakura_bullet()
	_expect(first != null, "Single-player/Host Linglan spawn must acquire a Sakura bullet.")
	if first == null:
		boss.queue_free()
		return
	var first_id := first.get_instance_id()
	_expect(
		first.get_parent() == pool
		and bool(first.get_meta(SessionObjectPool.POOL_ACTIVE_META, false)),
		"Authoritative Skill1 bullets must remain owned by the scene-authored session pool."
	)
	_expect(
		first.global_position.is_equal_approx(Vector2(114.0, 64.0))
		and first.direction == Vector2.RIGHT
		and is_zero_approx(first.rotation),
		"Pooled authoritative bullets must preserve spawn position and forward trajectory."
	)
	_expect(
		runtime.local_projectile_records.size() == 1
		and runtime.local_projectile_records[0].get("projectile") == first
		and runtime.local_projectile_records[0].get("projectile_type") == &"linglan_skill1"
		and runtime.local_projectile_records[0].get("spawn_position") == first.global_position
		and runtime.local_projectile_records[0].get("direction") == Vector2.RIGHT
		and int(runtime.local_projectile_records[0].get("damage", -1)) == 50
		and is_equal_approx(
			float(runtime.local_projectile_records[0].get("speed", -1.0)),
			300.0
		)
		and is_equal_approx(
			float(runtime.local_projectile_records[0].get("lifetime", -1.0)),
			2.0
		),
		"Host registration must receive the same pooled node and unchanged Skill1 payload."
	)
	first.retire()
	await _wait_for_quarantine()
	boss.call("_spawn_skill1_projectile", Vector2.UP)
	var reused := _find_active_sakura_bullet()
	_expect(
		reused != null and reused.get_instance_id() == first_id,
		"A subsequent authoritative ring must reuse the retained Sakura bullet."
	)
	if reused != null:
		_expect(
			reused.global_position.is_equal_approx(Vector2(96.0, 46.0))
			and reused.direction == Vector2.UP
			and is_equal_approx(reused.rotation, Vector2.UP.angle()),
			"Reused bullets must apply the new ring's position, direction, and rotation."
		)
		reused.retire()
	_expect(
		runtime.local_projectile_records.size() == 2
		and runtime.local_projectile_records[1].get("projectile") == reused,
		"Every reused Host projectile lease must still be registered for replication."
	)
	await _wait_for_quarantine()
	boss.queue_free()
	await process_frame


func _test_damage_trajectory_and_hit_effect_semantics() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	player.invincibility_duration = 0.0
	runtime.add_child(player)
	await process_frame
	player._base_max_health = 100
	player.max_health = 100
	player.current_health = 100
	player.health_bar.setup(100, 100)

	var bullet := pool.acquire(SAKURA_BULLET_SCENE) as LinglanSakuraBullet
	_expect(bullet != null, "Damage semantics fixture must acquire a Sakura bullet.")
	if bullet == null:
		player.queue_free()
		return
	bullet.top_level = true
	bullet.global_position = Vector2(32.0, 20.0)
	bullet.setup(Vector2.LEFT, 37, 225.0, 1.25)
	bullet.call("_on_body_entered", player)
	_expect(player.current_health == 63, "A pooled Sakura bullet must preserve exact player damage.")
	_expect(
		not bullet.pool_active and bullet.has_hit,
		"A successful hit must synchronously consume exactly one projectile lease."
	)
	var effect := _find_active_sakura_hit_effect()
	_expect(effect != null, "A successful pooled hit must preserve its Sakura particle effect.")
	if effect != null:
		_expect(
			effect.global_position.is_equal_approx(Vector2(32.0, 20.0))
			and is_equal_approx(effect.rotation, Vector2.LEFT.angle())
			and effect.emitting,
			"Pooled hit particles must preserve impact position, direction, and emission timing."
		)
		effect.call("_on_finished")
	await _wait_for_quarantine()
	bullet.call("_on_body_entered", player)
	_expect(player.current_health == 63, "A consumed pooled lease must never deal duplicate damage.")

	var expiry_bullet := pool.acquire(SAKURA_BULLET_SCENE) as LinglanSakuraBullet
	_expect(expiry_bullet != null, "Expiry semantics fixture must reacquire a Sakura bullet.")
	if expiry_bullet != null:
		expiry_bullet.setup(Vector2.DOWN, 50, 0.0, 0.01)
		expiry_bullet.call("_physics_process", 0.02)
		_expect(
			not expiry_bullet.pool_active and _find_active_sakura_hit_effect() == null,
			"Natural expiry must return the lease without inventing an impact effect."
		)
	await _wait_for_quarantine()
	player.queue_free()
	await process_frame


func _test_multiplayer_client_spawn_and_cleanup_path() -> void:
	var mp_game := MP_GAME_SCRIPT.new()
	mp_game.set("game", runtime)
	var first := mp_game.call(
		"_instantiate_projectile",
		&"linglan_skill1",
		999999,
		Vector2.LEFT,
		41,
		280.0,
		1.5,
		false,
		0,
		0
	) as LinglanSakuraBullet
	_expect(first != null, "Client proxy path must instantiate the Linglan Skill1 projectile.")
	if first == null:
		mp_game.free()
		return
	var first_id := first.get_instance_id()
	_expect(
		first.get_parent() == pool
		and first.damage == 41
		and is_equal_approx(first.speed, 280.0)
		and is_equal_approx(first.max_lifetime, 1.5),
		"Client proxy acquisition must use the pool without changing network payload values."
	)
	mp_game.call(
		"_setup_projectile_network_identity",
		first,
		9001,
		999999,
		&"linglan_skill1"
	)
	var known_projectiles := mp_game.get("_known_projectiles") as Dictionary
	known_projectiles[9001] = first
	first.retire()
	_expect(
		not known_projectiles.has(9001),
		"Pooled client projectile completion must synchronously remove its network registry entry."
	)
	await _wait_for_quarantine()
	var reused := mp_game.call(
		"_instantiate_projectile",
		&"linglan_skill1",
		999999,
		Vector2.RIGHT,
		50,
		300.0,
		2.0,
		false,
		0,
		0
	) as LinglanSakuraBullet
	_expect(
		reused != null and reused.get_instance_id() == first_id,
		"Client proxy Skill1 projectiles must reuse the same retained instance."
	)
	if reused != null:
		reused.retire()
	await _wait_for_quarantine()
	mp_game.free()


func _test_offscreen_hit_keeps_damage_without_visual_lease() -> void:
	var camera := Camera2D.new()
	camera.enabled = true
	runtime.add_child(camera)
	camera.global_position = Vector2.ZERO
	var player := PLAYER_SCENE.instantiate() as Player
	player.invincibility_duration = 0.0
	runtime.add_child(player)
	await process_frame
	player._base_max_health = 100
	player.max_health = 100
	player.current_health = 100
	player.health_bar.setup(100, 100)
	_expect(
		runtime.get_viewport().get_camera_2d() == camera,
		"Offscreen effect fixture must own the active viewport camera."
	)
	var bullet := pool.acquire(SAKURA_BULLET_SCENE) as LinglanSakuraBullet
	_expect(bullet != null, "Offscreen semantics fixture must acquire a Sakura bullet.")
	if bullet != null:
		bullet.top_level = true
		bullet.global_position = Vector2(100000.0, 100000.0)
		bullet.setup(Vector2.RIGHT, 29, 300.0, 2.0)
		bullet.call("_on_body_entered", player)
		_expect(
			player.current_health == 71,
			"Offscreen visual culling must not change authoritative player damage."
		)
		_expect(
			_find_active_sakura_hit_effect() == null,
			"A far-offscreen hit must not acquire a pure-visual particle lease."
		)
	await _wait_for_quarantine()
	player.queue_free()
	camera.queue_free()
	await process_frame


func _test_production_runtime_registration_contract() -> void:
	for runtime_script_path in [
		"res://scene/game.gd",
		"res://scene/game_tower_defense.gd",
	]:
		var source := FileAccess.get_file_as_string(runtime_script_path)
		_expect(
			source.contains("register_scene(LINGLAN_SKILL1_BULLET_POOL_SCENE")
			and source.contains("register_scene(LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE"),
			"Both production runtimes must register the authored Skill1 pools: %s"
			% runtime_script_path
		)


func _find_active_sakura_bullet() -> LinglanSakuraBullet:
	for child in pool.get_children():
		var bullet := child as LinglanSakuraBullet
		if bullet != null and bullet.pool_active:
			return bullet
	return null


func _find_active_sakura_hit_effect() -> LinglanSakuraHitEffect:
	for child in pool.get_children():
		var effect := child as LinglanSakuraHitEffect
		if effect != null and effect.pool_active:
			return effect
	return null


func _wait_for_quarantine() -> void:
	await physics_frame
	await process_frame
	await physics_frame
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
