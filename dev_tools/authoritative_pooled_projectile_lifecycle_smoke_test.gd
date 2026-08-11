extends SceneTree

const ROGUE_GAME_01 := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn"
)
const ROGUE_GAME_02 := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_game_02.tscn"
)
const STANDARD_GAME := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const TOWER_DEFENSE_GAME := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const P1B_GAME := preload(
	"res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p1b.tscn"
)
const GUNNER_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_gunner.tres"
)
const AK_CONFIG := preload("res://resources/config/enemies/capoo_ak47.tres")
const SMG_CONFIG := preload("res://resources/config/enemies/capoo_smg.tres")

const SAMPLE_PHYSICS_FRAMES := 12
const MINIMUM_FLIGHT_DISTANCE := 1.0
const MAX_RECYCLE_PHYSICS_FRAMES := 180

var _failures := PackedStringArray()
var _saved_batched_motion_enabled := true
var _saved_smg_hitscan_enabled := true


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_saved_batched_motion_enabled = CapooAK47Bullet.batched_motion_enabled
	_saved_smg_hitscan_enabled = CapooSMG.hitscan_attack_enabled
	CapooAK47Bullet.batched_motion_enabled = true
	_assert_shared_scene_contracts()
	await _test_rogue_runtime(ROGUE_GAME_01, "狭路相逢", true)
	await _test_rogue_runtime(ROGUE_GAME_02, "地下教会", false)
	CapooAK47Bullet.batched_motion_enabled = _saved_batched_motion_enabled
	CapooSMG.hitscan_attack_enabled = _saved_smg_hitscan_enabled
	_finish()


func _test_rogue_runtime(
	runtime_scene: PackedScene,
	label: String,
	test_capoo_paths: bool
) -> void:
	var runtime := runtime_scene.instantiate() as RogueCombatGame
	_expect(runtime != null, "%s正式场景必须实例化 RogueCombatGame。" % label)
	if runtime == null:
		return
	runtime.auto_start_waves = false
	root.add_child(runtime)
	current_scene = runtime
	await process_frame
	await physics_frame
	runtime.set_process(false)
	runtime.set_physics_process(false)
	if runtime.player != null:
		runtime.player.set_process(false)
		runtime.player.set_physics_process(false)

	var pool := runtime.get_node_or_null("SessionObjectPool") as SessionObjectPool
	var motion_system := runtime.get_node_or_null(
		"CapooProjectileMotionSystem"
	) as CapooProjectileMotionSystem
	var pathfinder := runtime.get_node_or_null("GridPathfinder") as GridPathfinder
	_expect(pool != null, "%s必须提供正式会话对象池。" % label)
	_expect(motion_system != null, "%s必须提供批量弹丸运动系统。" % label)
	if pool != null and motion_system != null:
		await _test_gunner_authoritative_fire(
			runtime,
			pool,
			motion_system,
			pathfinder,
			label
		)
		if test_capoo_paths:
			await _test_ak_authoritative_fire(
				runtime,
				pool,
				motion_system,
				pathfinder
			)
			await _test_smg_projectile_fallback(
				runtime,
				pool,
				motion_system,
				pathfinder
			)

	current_scene = null
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_gunner_authoritative_fire(
	runtime: RogueCombatGame,
	pool: SessionObjectPool,
	motion_system: CapooProjectileMotionSystem,
	pathfinder: GridPathfinder,
	label: String
) -> void:
	var gunner := GUNNER_CONFIG.enemy_scene.instantiate() as CombatRobotGunner
	runtime.enemy_container.add_child(gunner)
	gunner.global_position = Vector2(145.0, 127.0)
	gunner.setup(GUNNER_CONFIG, runtime.player, pathfinder, runtime)
	gunner.set_process(false)
	gunner.set_physics_process(false)
	gunner.locked_fire_direction = Vector2.RIGHT
	var fired := bool(gunner.call("_fire_locked_bullet"))
	_expect(fired, "%s的持枪机器人必须通过权威生产路径成功开火。" % label)
	var bullet := _find_active_pooled_bullet(
		runtime,
		GUNNER_CONFIG.projectile_scene
	)
	await _assert_registered_flight_and_recycle(
		bullet,
		GUNNER_CONFIG.projectile_scene,
		pool,
		motion_system,
		SAMPLE_PHYSICS_FRAMES,
		label + "持枪机器人"
	)
	gunner.queue_free()
	await process_frame


func _test_ak_authoritative_fire(
	runtime: RogueCombatGame,
	pool: SessionObjectPool,
	motion_system: CapooProjectileMotionSystem,
	pathfinder: GridPathfinder
) -> void:
	var enemy := AK_CONFIG.enemy_scene.instantiate() as CapooAK47
	runtime.enemy_container.add_child(enemy)
	enemy.global_position = Vector2(145.0, 159.0)
	enemy.setup(AK_CONFIG, runtime.player, pathfinder, runtime)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	enemy.burst_shot_direction = Vector2.RIGHT
	var fired := bool(enemy.call("_fire_locked_bullet"))
	_expect(fired, "AK猫猫虫必须通过权威生产路径成功开火。")
	var bullet := _find_active_pooled_bullet(runtime, AK_CONFIG.projectile_scene)
	await _assert_registered_flight_and_recycle(
		bullet,
		AK_CONFIG.projectile_scene,
		pool,
		motion_system,
		SAMPLE_PHYSICS_FRAMES,
		"AK猫猫虫"
	)
	enemy.queue_free()
	await process_frame


func _test_smg_projectile_fallback(
	runtime: RogueCombatGame,
	pool: SessionObjectPool,
	motion_system: CapooProjectileMotionSystem,
	pathfinder: GridPathfinder
) -> void:
	CapooSMG.hitscan_attack_enabled = false
	var enemy := SMG_CONFIG.enemy_scene.instantiate() as CapooSMG
	runtime.enemy_container.add_child(enemy)
	enemy.global_position = Vector2(145.0, 191.0)
	enemy.setup(SMG_CONFIG, runtime.player, pathfinder, runtime)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	var fired := bool(enemy.call("_fire_bullet", Vector2.RIGHT))
	_expect(fired, "SMG hitscan=false时必须通过权威弹丸回退路径成功开火。")
	var bullet := _find_active_pooled_bullet(runtime, SMG_CONFIG.projectile_scene)
	await _assert_registered_flight_and_recycle(
		bullet,
		SMG_CONFIG.projectile_scene,
		pool,
		motion_system,
		4,
		"SMG弹丸回退"
	)
	enemy.queue_free()
	CapooSMG.hitscan_attack_enabled = _saved_smg_hitscan_enabled
	await process_frame


func _assert_registered_flight_and_recycle(
	bullet: CapooAK47Bullet,
	projectile_scene: PackedScene,
	pool: SessionObjectPool,
	motion_system: CapooProjectileMotionSystem,
	sample_frames: int,
	label: String
) -> void:
	_expect(bullet != null, "%s必须产生真实池化 CapooAK47Bullet。" % label)
	if bullet == null:
		return
	var start_position := bullet.global_position
	_expect(
		bullet.batched_motion_system == motion_system
		and motion_system.has_projectile(bullet),
		"%s在生产开火返回时必须已注册批量运动系统。" % label
	)
	for _frame_index in range(sample_frames):
		await physics_frame
	var flight_distance := bullet.global_position.distance_to(start_position)
	_expect(
		flight_distance > MINIMUM_FLIGHT_DISTANCE,
		"%s经过%d个物理帧必须产生位移，实测%.3f像素。"
		% [label, sample_frames, flight_distance]
	)
	for _frame_index in range(MAX_RECYCLE_PHYSICS_FRAMES):
		var metrics := pool.get_metrics(projectile_scene.resource_path)
		if (
			int(metrics.get("in_use", -1)) == 0
			and int(metrics.get("pending_release", -1)) == 0
		):
			break
		await physics_frame
	var final_metrics := pool.get_metrics(projectile_scene.resource_path)
	_expect(
		int(final_metrics.get("in_use", -1)) == 0
		and int(final_metrics.get("pending_release", -1)) == 0
		and int(final_metrics.get("inactive", 0)) > 0,
		"%s生命周期结束后必须完整归还对象池。" % label
	)
	_expect(
		not motion_system.has_projectile(bullet),
		"%s归还对象池后必须注销批量运动系统。" % label
	)


func _find_active_pooled_bullet(
	runtime: Node,
	projectile_scene: PackedScene
) -> CapooAK47Bullet:
	for child in runtime.get_children():
		var bullet := child as CapooAK47Bullet
		if bullet == null or not bullet.pool_active:
			continue
		if str(child.get_meta(SessionObjectPool.POOL_KEY_META, "")) == projectile_scene.resource_path:
			return bullet
	return null


func _assert_shared_scene_contracts() -> void:
	for contract in [
		[STANDARD_GAME, "标准作战"],
		[TOWER_DEFENSE_GAME, "塔防作战"],
		[P1B_GAME, "P1B"],
	]:
		var scene := (contract[0] as PackedScene).instantiate()
		var label := str(contract[1])
		_expect(
			scene.get_node_or_null("SessionObjectPool") is SessionObjectPool,
			"%s必须共享会话对象池合同。" % label
		)
		_expect(
			scene.get_node_or_null("CapooProjectileMotionSystem")
			is CapooProjectileMotionSystem,
			"%s必须共享批量弹丸运动合同。" % label
		)
		scene.free()
	for wave_path in [
		"res://resources/config/campaigns/test_arena/p1b/singleplayer/wave_01.tres",
		"res://resources/config/campaigns/test_arena/p1b/multiplayer/wave_01.tres",
	]:
		var wave := load(wave_path) as WaveConfig
		var gunner_count := 0
		if wave != null:
			for entry in wave.enemy_entries:
				if entry != null and entry.enemy_config == GUNNER_CONFIG:
					gunner_count += entry.count
		_expect(gunner_count == 200, "%s必须继续由200名普通枪手受益。" % wave_path)


func _finish() -> void:
	if _failures.is_empty():
		print("AUTHORITATIVE_POOLED_PROJECTILE_LIFECYCLE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
