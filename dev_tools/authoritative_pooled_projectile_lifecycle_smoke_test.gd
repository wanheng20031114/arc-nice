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
const GUNNER_ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_gunner_elite.tres"
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
			GUNNER_CONFIG,
			RapidFireSimulationService.Profile.GUNNER,
			label + "普通持枪机器人"
		)
		if test_capoo_paths:
			await _test_gunner_authoritative_fire(
				runtime,
				pool,
				motion_system,
				pathfinder,
				GUNNER_ELITE_CONFIG,
				RapidFireSimulationService.Profile.GUNNER_ELITE,
				label + "精英持枪机器人"
			)
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
	gunner_config: CombatRobotGunnerConfig,
	expected_profile: RapidFireSimulationService.Profile,
	label: String
) -> void:
	_expect(
		CombatRobotGunner.projectile_backend
		== CombatRobotGunner.ProjectileBackend.DATA,
		"%s生产默认必须使用DATA权威弹体后端。" % label
	)
	var combat_services := runtime.get_enemy_combat_services()
	var rapid_fire_service := (
		combat_services.get_rapid_fire_simulation_service()
		if combat_services != null
		else null
	) as RapidFireSimulationService
	_expect(rapid_fire_service != null, "%s必须接入共享连发弹体服务。" % label)
	if rapid_fire_service == null:
		return
	var pool_metrics_before := pool.get_metrics(
		gunner_config.projectile_scene.resource_path
	)
	var pool_in_use_before := int(pool_metrics_before.get("in_use", 0))
	var pool_pending_before := int(pool_metrics_before.get("pending_release", 0))
	var motion_count_before := motion_system.get_active_projectile_count()
	var service_metrics_before := rapid_fire_service.get_metrics()
	var active_slots_before := rapid_fire_service.get_active_slot_count()
	var data_slots_before := int(service_metrics_before.get("data_slots", 0))
	var advances_before := int(service_metrics_before.get("advances", 0))

	var gunner := gunner_config.enemy_scene.instantiate() as CombatRobotGunner
	runtime.enemy_container.add_child(gunner)
	gunner.global_position = Vector2(145.0, 127.0)
	gunner.setup(gunner_config, runtime.player, pathfinder, runtime)
	gunner.set_process(false)
	gunner.set_physics_process(false)
	gunner.locked_fire_direction = Vector2.RIGHT
	var fired := bool(gunner.call("_fire_locked_bullet"))
	_expect(fired, "%s必须通过权威生产路径成功开火。" % label)
	var data_handle := _find_live_rapid_handle_for_source(
		rapid_fire_service,
		int(gunner.get_instance_id()),
		RapidFireSimulationService.Mode.DATA,
		expected_profile
	)
	_expect(
		data_handle > RapidFireSimulationService.INVALID_HANDLE,
		"%s开火必须生成对应Profile的DATA句柄。" % label
	)
	_expect(
		rapid_fire_service.get_active_slot_count() == active_slots_before + 1
		and int(rapid_fire_service.get_metrics().get("data_slots", 0))
		== data_slots_before + 1,
		"%s开火必须只增加一个DATA权威记录。" % label
	)
	_expect(
		_find_active_pooled_bullet(
			runtime,
			gunner_config.projectile_scene
		) == null
		and motion_system.get_active_projectile_count() == motion_count_before,
		"%s DATA开火不得创建或注册权威Bullet Node/Area。" % label
	)
	var pool_metrics_after_fire := pool.get_metrics(
		gunner_config.projectile_scene.resource_path
	)
	_expect(
		int(pool_metrics_after_fire.get("in_use", 0)) == pool_in_use_before
		and int(pool_metrics_after_fire.get("pending_release", 0))
		== pool_pending_before,
		"%s DATA开火不得增加旧对象池占用。" % label
	)

	var start_position := rapid_fire_service.get_position(data_handle)
	var maximum_flight_distance := 0.0
	var maximum_pool_in_use := pool_in_use_before
	for _frame_index in range(SAMPLE_PHYSICS_FRAMES):
		await physics_frame
		maximum_pool_in_use = maxi(
			maximum_pool_in_use,
			int(
				pool.get_metrics(
					gunner_config.projectile_scene.resource_path
				).get("in_use", 0)
			)
		)
		if rapid_fire_service.is_handle_live(data_handle):
			maximum_flight_distance = maxf(
				maximum_flight_distance,
				rapid_fire_service.get_position(data_handle).distance_to(
					start_position
				)
			)
	_expect(
		maximum_flight_distance > MINIMUM_FLIGHT_DISTANCE
		and int(rapid_fire_service.get_metrics().get("advances", 0))
		> advances_before,
		"%s DATA句柄经过%d个物理帧必须推进，实测%.3f像素。"
		% [label, SAMPLE_PHYSICS_FRAMES, maximum_flight_distance]
	)

	for _frame_index in range(MAX_RECYCLE_PHYSICS_FRAMES):
		if not rapid_fire_service.is_handle_live(data_handle):
			break
		await physics_frame
		maximum_pool_in_use = maxi(
			maximum_pool_in_use,
			int(
				pool.get_metrics(
					gunner_config.projectile_scene.resource_path
				).get("in_use", 0)
			)
		)
	await physics_frame
	var final_service_metrics := rapid_fire_service.get_metrics()
	var final_pool_metrics := pool.get_metrics(
		gunner_config.projectile_scene.resource_path
	)
	_expect(
		not rapid_fire_service.is_handle_live(data_handle)
		and rapid_fire_service.get_active_slot_count() == active_slots_before
		and int(final_service_metrics.get("data_slots", 0)) == data_slots_before,
		"%s DATA弹体完成后必须失效句柄并回收活跃槽。" % label
	)
	_expect(
		maximum_pool_in_use == pool_in_use_before
		and int(final_pool_metrics.get("in_use", 0)) == pool_in_use_before
		and int(final_pool_metrics.get("pending_release", 0))
		== pool_pending_before,
		"%s DATA弹体整个生命周期不得增加旧对象池in_use。" % label
	)
	_expect(
		_find_active_pooled_bullet(
			runtime,
			gunner_config.projectile_scene
		) == null
		and motion_system.get_active_projectile_count() == motion_count_before,
		"%s DATA完成后不得遗留权威Bullet Node/Area或运动记录。" % label
	)
	gunner.queue_free()
	await process_frame


func _test_ak_authoritative_fire(
	runtime: RogueCombatGame,
	pool: SessionObjectPool,
	motion_system: CapooProjectileMotionSystem,
	pathfinder: GridPathfinder
) -> void:
	_expect(
		CapooAK47.projectile_backend == CapooAK47.ProjectileBackend.DATA,
		"AK猫猫生产默认必须使用DATA权威弹体后端。"
	)
	var combat_services := runtime.get_enemy_combat_services()
	var rapid_fire_service := (
		combat_services.get_rapid_fire_simulation_service()
		if combat_services != null
		else null
	) as RapidFireSimulationService
	_expect(rapid_fire_service != null, "AK猫猫测试需要共享连发弹体服务。")
	if rapid_fire_service == null:
		return
	var pool_metrics_before := pool.get_metrics(AK_CONFIG.projectile_scene.resource_path)
	var pool_in_use_before := int(pool_metrics_before.get("in_use", 0))
	var pool_pending_before := int(pool_metrics_before.get("pending_release", 0))
	var motion_count_before := motion_system.get_active_projectile_count()
	var service_metrics_before := rapid_fire_service.get_metrics()
	var active_slots_before := rapid_fire_service.get_active_slot_count()
	var data_slots_before := int(service_metrics_before.get("data_slots", 0))
	var advances_before := int(service_metrics_before.get("advances", 0))

	var enemy := AK_CONFIG.enemy_scene.instantiate() as CapooAK47
	runtime.enemy_container.add_child(enemy)
	enemy.global_position = Vector2(145.0, 159.0)
	enemy.setup(AK_CONFIG, runtime.player, pathfinder, runtime)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	enemy.burst_shot_direction = Vector2.RIGHT
	var fired := bool(enemy.call("_fire_locked_bullet"))
	_expect(fired, "AK猫猫虫必须通过权威生产路径成功开火。")
	var data_handle := _find_live_ak_data_handle(
		rapid_fire_service,
		int(enemy.get_instance_id())
	)
	_expect(
		data_handle > RapidFireSimulationService.INVALID_HANDLE,
		"AK猫猫开火必须生成可追踪的DATA弹体句柄。"
	)
	var launch_source_snapshot := rapid_fire_service.get_damage_source_snapshot(
		data_handle
	)
	_expect(
		launch_source_snapshot != null
		and launch_source_snapshot.source_faction_id
		== enemy.get_combat_faction_id()
		and launch_source_snapshot.instigator_entity_id
		== int(enemy.get_instance_id())
		and launch_source_snapshot.event_source_id
		== rapid_fire_service.get_projectile_id(data_handle)
		and launch_source_snapshot.source_type
		== RapidFireSimulationService.AK_SOURCE_TYPE,
		"AK猫猫DATA注册必须显式冻结发射阵营、实例归属、弹体事件与来源类型。"
	)
	_expect(
		rapid_fire_service.get_active_slot_count() == active_slots_before + 1
		and int(rapid_fire_service.get_metrics().get("data_slots", 0))
		== data_slots_before + 1,
		"AK猫猫开火必须只增加一个DATA权威记录。"
	)
	_expect(
		_find_active_pooled_bullet(runtime, AK_CONFIG.projectile_scene) == null
		and motion_system.get_active_projectile_count() == motion_count_before,
		"AK猫猫DATA开火不得创建或注册权威Bullet Node/Area。"
	)
	var pool_metrics_after_fire := pool.get_metrics(
		AK_CONFIG.projectile_scene.resource_path
	)
	_expect(
		int(pool_metrics_after_fire.get("in_use", 0)) == pool_in_use_before
		and int(pool_metrics_after_fire.get("pending_release", 0))
		== pool_pending_before,
		"AK猫猫DATA开火不得增加对象池in_use或pending_release。"
	)

	var start_position := rapid_fire_service.get_position(data_handle)
	var maximum_flight_distance := 0.0
	var maximum_pool_in_use := pool_in_use_before
	for _frame_index in range(SAMPLE_PHYSICS_FRAMES):
		await physics_frame
		maximum_pool_in_use = maxi(
			maximum_pool_in_use,
			int(
				pool.get_metrics(AK_CONFIG.projectile_scene.resource_path).get(
					"in_use",
					0
				)
			)
		)
		if rapid_fire_service.is_handle_live(data_handle):
			maximum_flight_distance = maxf(
				maximum_flight_distance,
				rapid_fire_service.get_position(data_handle).distance_to(
					start_position
				)
			)
	_expect(
		maximum_flight_distance > MINIMUM_FLIGHT_DISTANCE
		and int(rapid_fire_service.get_metrics().get("advances", 0))
		> advances_before,
		"AK猫猫DATA句柄经过%d个物理帧必须由共享内核推进，实测%.3f像素。"
		% [SAMPLE_PHYSICS_FRAMES, maximum_flight_distance]
	)

	for _frame_index in range(MAX_RECYCLE_PHYSICS_FRAMES):
		if not rapid_fire_service.is_handle_live(data_handle):
			break
		await physics_frame
		maximum_pool_in_use = maxi(
			maximum_pool_in_use,
			int(
				pool.get_metrics(AK_CONFIG.projectile_scene.resource_path).get(
					"in_use",
					0
				)
			)
		)
	# Give frame-end stable compaction one physics turn after the handle retires.
	await physics_frame
	var final_service_metrics := rapid_fire_service.get_metrics()
	var final_pool_metrics := pool.get_metrics(
		AK_CONFIG.projectile_scene.resource_path
	)
	_expect(
		not rapid_fire_service.is_handle_live(data_handle)
		and rapid_fire_service.get_active_slot_count() == active_slots_before
		and int(final_service_metrics.get("data_slots", 0)) == data_slots_before,
		"AK猫猫DATA弹体完成后必须使句柄失效并回收活跃槽。"
	)
	_expect(
		maximum_pool_in_use == pool_in_use_before
		and int(final_pool_metrics.get("in_use", 0)) == pool_in_use_before
		and int(final_pool_metrics.get("pending_release", 0)) == pool_pending_before,
		"AK猫猫DATA弹体整个生命周期不得占用旧对象池。"
	)
	_expect(
		_find_active_pooled_bullet(runtime, AK_CONFIG.projectile_scene) == null
		and motion_system.get_active_projectile_count() == motion_count_before,
		"AK猫猫DATA弹体完成后不得遗留权威Bullet Node/Area或运动系统记录。"
	)
	enemy.queue_free()
	await process_frame


func _find_live_ak_data_handle(
	rapid_fire_service: RapidFireSimulationService,
	source_enemy_id: int
) -> int:
	for stable_index in range(rapid_fire_service.get_dense_record_count()):
		var handle := rapid_fire_service.get_handle_at_stable_index(stable_index)
		if (
			handle > RapidFireSimulationService.INVALID_HANDLE
			and rapid_fire_service.get_slot_mode(handle)
			== RapidFireSimulationService.Mode.DATA
			and rapid_fire_service.get_slot_profile(handle)
			== RapidFireSimulationService.Profile.AK
			and rapid_fire_service.get_source_enemy_id(handle) == source_enemy_id
		):
			return handle
	return RapidFireSimulationService.INVALID_HANDLE


func _find_live_rapid_handle_for_source(
	rapid_fire_service: RapidFireSimulationService,
	source_enemy_id: int,
	mode: RapidFireSimulationService.Mode,
	profile: RapidFireSimulationService.Profile
) -> int:
	for stable_index in range(rapid_fire_service.get_dense_record_count()):
		var handle := rapid_fire_service.get_handle_at_stable_index(stable_index)
		if (
			handle > RapidFireSimulationService.INVALID_HANDLE
			and rapid_fire_service.get_source_enemy_id(handle) == source_enemy_id
			and rapid_fire_service.get_slot_mode(handle) == mode
			and rapid_fire_service.get_slot_profile(handle) == profile
		):
			return handle
	return RapidFireSimulationService.INVALID_HANDLE


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
