extends SceneTree

const STANDARD_GAME_SCENE := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const MALFORMED_STANDARD_GAME_SCENE := preload(
	"res://dev_tools/fixtures/malformed_standard_game_prewarmer_probe.tscn"
)
const ENRAGE_SNIPER_CONFIG := preload(
	"res://resources/config/enemies/capoo_sniper.tres"
)
const EXPECTED_MODE_POOL_PATHS: Array[String] = [
	"res://scene/player/tango/tango_laser_bullet.tscn",
	"res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn",
	"res://scene/boss/linglan/linglan_sakura_hit_effect.tscn",
]
const EXPECTED_MODE_POOL_PREWARM_COUNTS: Array[int] = [64, 64, 16]
const EXPECTED_MODE_POOL_CAPACITIES: Array[int] = [768, 768, 96]
const EXPECTED_BOSS_RUNTIME_PATHS: Array[String] = [
	"res://resources/config/enemies/linglan_boss.tres",
	"res://scene/boss/linglan/linglan_boss_intro_vfx.tscn",
	"res://scene/boss/linglan/boss_health_hud.tscn",
	"res://resources/config/enemies/capoo_sniper.tres",
]


class RuntimePathProbeBoss:
	extends StandardBossCoordinator

	func get_runtime_resource_paths() -> Array[String]:
		return []


var failures: Array[String] = []
var test_root: Node2D = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "StandardPrewarmerCoordinatorSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_source_boundaries()
	await _test_static_binding_pools_paths_and_cache()
	await _test_no_boss_flow_preserves_legacy_request_semantics()
	await _test_malformed_scene_initialization_boundary()
	await _test_leave_tree_abort()

	test_root.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame
	if failures.is_empty():
		call_deferred("_finish_success")
		return
	call_deferred("_finish_with_failures")


func _finish_success() -> void:
	print("STANDARD_PREWARMER_COORDINATOR_SMOKE_TEST_OK")
	quit(0)


func _finish_with_failures() -> void:
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_source_boundaries() -> void:
	var root_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/standard_game.gd"
	)
	var coordinator_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/prewarm/standard_prewarmer_coordinator.gd"
	)
	var standard_scene := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/standard_game.tscn"
	)
	var malformed_scene := FileAccess.get_file_as_string(
		"res://dev_tools/fixtures/malformed_standard_game_prewarmer_probe.tscn"
	)
	for concrete_rule in [
		"ResourceLoader.load_threaded_request(resource_path)",
		"ResourceLoader.load_threaded_get_status(resource_path)",
		"session_object_pool.register_scene(TANGO_LASER_BULLET_POOL_SCENE",
		"boss_runtime_resources_by_path[resource_path] = runtime_resource",
	]:
		_expect(
			not root_source.contains(concrete_rule),
			"StandardGame 根不得继续实现预热具体规则：%s。" % concrete_rule
		)
	for forbidden_dependency in [
		"StandardGame",
		"TowerDefense",
		"Rogue",
		"current_scene",
		"get_parent()",
		"get_node(",
		"get_node_or_null(",
		"has_method(",
	]:
		_expect(
			not coordinator_source.contains(forbidden_dependency),
			"StandardPrewarmerCoordinator 不得反向猜测模式根：%s。"
			% forbidden_dependency
		)
	_expect(
		root_source.contains("standard_prewarmer.bind_dependencies(")
		and root_source.contains("\t\t\tsession_object_pool,")
		and root_source.contains("\t\t\tboss_coordinator,")
		and root_source.contains(
			"standard_prewarmer.load_threaded_or_direct"
		)
		and root_source.contains(
			"standard_prewarmer.get_linglan_enrage_sniper_config"
		),
		"StandardGame 必须显式注入对象池、Boss 资源路径与 resolver/provider。"
	)
	_expect(
		not root_source.contains("StandardPrewarmerCoordinator.new(")
		and not root_source.contains(
			"standard_prewarmer_coordinator.tscn\").instantiate"
		),
		"StandardGame 不得动态创建 PrewarmerCoordinator。"
	)
	_expect(
		standard_scene.contains(
			"res://scene/game_modes/standard/prewarm/standard_prewarmer_coordinator.tscn"
		)
		and standard_scene.contains("[node name=\"PrewarmerCoordinator\""),
		"StandardGame 场景必须静态实例化 PrewarmerCoordinator。"
	)
	_expect(
		coordinator_source.contains(
			"while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:"
		)
		and coordinator_source.contains("await get_tree().process_frame")
		and coordinator_source.contains(
			"if _should_abort_prewarm_after_frame():\n\t\t\t\treturn false"
		)
		and coordinator_source.contains(
			"func _should_abort_prewarm_after_frame() -> bool:\n\treturn not is_inside_tree()"
		)
		and coordinator_source.contains("RUNTIME_RESOURCE_WAIT_TIMEOUT_MSEC")
		and coordinator_source.contains("var error := ResourceLoader.load_threaded_request(")
		and coordinator_source.contains("if error != OK:")
		and coordinator_source.contains(
			"if status != ResourceLoader.THREAD_LOAD_LOADED:"
		)
		and not coordinator_source.contains("else load(resource_path)"),
		"threaded 预热必须逐帧有界等待、检查请求 Error，并对非 LOADED 状态 fail-close。"
	)
	_expect(
		coordinator_source.contains(
			"if DisplayServer.get_name() == \"headless\":\n\t\treturn true"
		)
		and coordinator_source.contains(
			"await get_tree().process_frame\n\tawait get_tree().process_frame"
		),
		"deferred 请求必须保持 headless 跳过与两帧等待顺序。"
	)
	_expect(
		root_source.contains(
			"if prewarmer_coordinator == null:\n\t\tpush_error(\"StandardGame: 缺少静态 PrewarmerCoordinator 节点。\")"
		),
		"StandardGame 必须明确验证缺失的静态 PrewarmerCoordinator。"
	)
	_expect(
		root_source.contains(
			"prewarmer_coordinator.configure_boss_flow_enabled(_uses_linglan_boss_flow())\n\tprewarmer_coordinator.schedule_boss_runtime_scene_loads()"
		),
		"runtime content schedule 前必须刷新当前 Boss flow 开关。"
	)
	_expect(
		malformed_scene.contains(
			"uid=\"uid://dc617yu013ej\" path=\"res://dev_tools/fixtures/malformed_standard_game_prewarmer_probe.gd\""
		),
		"malformed fixture 必须以脚本 .gd.uid 建立稳定引用。"
	)


func _test_static_binding_pools_paths_and_cache() -> void:
	var game := STANDARD_GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame 必须可实例化用于 Prewarmer smoke。")
	if game == null:
		return
	game.auto_start_waves = false
	var coordinator := game.prewarmer_coordinator
	_expect(coordinator != null, "场景必须静态实例化 PrewarmerCoordinator。")
	if coordinator == null:
		game.queue_free()
		return
	var pending_cache: Dictionary[String, Resource] = {}
	var cached_sentinel: Resource = StandardGame.TANGO_LASER_BULLET_POOL_SCENE
	var cached_sentinel_path := "res://standard_prewarmer_cache_identity_probe.tres"
	pending_cache[cached_sentinel_path] = cached_sentinel
	var pending_enrage := ENRAGE_SNIPER_CONFIG as EnemyConfig
	coordinator.replace_runtime_resources_by_path(pending_cache)
	coordinator.replace_runtime_scene_loads_requested(true)
	coordinator.replace_linglan_enrage_sniper_config(pending_enrage)
	_expect(
		is_same(coordinator.runtime_resources_by_path, pending_cache),
		"静态协调器必须保持传入的 Boss resource cache 同一引用。"
	)
	_expect(
		coordinator.load_threaded_or_direct(cached_sentinel_path)
		== cached_sentinel
		and coordinator.get_linglan_enrage_sniper_config() == pending_enrage,
		"静态协调器 resolver/enrage 必须命中预置缓存。"
	)
	test_root.add_child(game)
	await process_frame
	await physics_frame

	_expect(
		coordinator != null and coordinator.is_bound(),
		"静态 PrewarmerCoordinator 必须绑定 SessionObjectPool 与 BossCoordinator。"
	)
	if coordinator == null:
		game.queue_free()
		await process_frame
		return
	_expect(
		is_same(coordinator.runtime_resources_by_path, pending_cache),
		"绑定后协调器必须继续接管同一个 pre-ready cache 容器。"
	)
	_expect(
		coordinator.runtime_scene_loads_requested
		and coordinator.linglan_enrage_sniper_config == pending_enrage,
		"绑定必须保留 request flag 与 enrage config 真源。"
	)
	var post_bind_sentinel: Resource = StandardGame.LINGLAN_SKILL1_BULLET_POOL_SCENE
	pending_cache["res://standard_prewarmer_post_bind_probe.tres"] = post_bind_sentinel
	_expect(
		coordinator.runtime_resources_by_path.get(
			"res://standard_prewarmer_post_bind_probe.tres"
		) == post_bind_sentinel,
		"绑定后原 cache 引用的原地写入必须继续对 façade 可见。"
	)

	var pool := game.session_object_pool
	var all_pool_paths: Array = pool.get_all_metrics().keys()
	_expect(
		all_pool_paths.slice(all_pool_paths.size() - 3) == EXPECTED_MODE_POOL_PATHS,
		"普通专属对象池必须保持 Tango→铃兰弹体→铃兰命中特效的注册顺序。"
	)
	for index in range(EXPECTED_MODE_POOL_PATHS.size()):
		var metrics := pool.get_metrics(EXPECTED_MODE_POOL_PATHS[index])
		_expect(
			int(metrics.get("created", -1))
			== EXPECTED_MODE_POOL_PREWARM_COUNTS[index]
			and int(metrics.get("inactive", -1))
			== EXPECTED_MODE_POOL_PREWARM_COUNTS[index]
			and int(metrics.get("retained_capacity", -1))
			== EXPECTED_MODE_POOL_CAPACITIES[index],
			"普通专属对象池 %s 必须保持 prewarm=%d/capacity=%d。"
			% [
				EXPECTED_MODE_POOL_PATHS[index],
				EXPECTED_MODE_POOL_PREWARM_COUNTS[index],
				EXPECTED_MODE_POOL_CAPACITIES[index],
			]
		)

	var first_boss := game.boss_coordinator.get_first_boss_config()
	var original_step_count := game.flow_graph.steps.size()
	game.flow_graph.steps.append(first_boss)
	var runtime_paths := coordinator.get_boss_runtime_resource_paths()
	_expect(
		runtime_paths == EXPECTED_BOSS_RUNTIME_PATHS,
		"Boss threaded 路径必须按 enemy→intro→HUD 去重，最后追加 enrage sniper：%s。"
		% [runtime_paths]
	)
	game.flow_graph.steps.resize(original_step_count)

	game.linglan_boss_enabled = false
	coordinator.replace_runtime_scene_loads_requested(false)
	game.call(
		"_initialize_mode_runtime_content",
		game.get_runtime_preparation_generation()
	)
	await process_frame
	_expect(
		not bool(coordinator.get("_boss_flow_enabled"))
		and not coordinator.runtime_scene_loads_requested,
		"bind 后关闭 export 时，runtime content schedule 必须刷新开关且不请求。"
	)
	coordinator.request_boss_runtime_scene_loads()
	_expect(
		not coordinator.runtime_scene_loads_requested,
		"禁用 Boss flow 时协调器不得启动 threaded load。"
	)
	coordinator.configure_boss_flow_enabled(true)
	coordinator.replace_runtime_scene_loads_requested(false)
	coordinator.request_boss_runtime_scene_loads()
	_expect(
		coordinator.runtime_scene_loads_requested,
		"首次启用请求必须设置幂等 request flag。"
	)
	var cache_before_second_request := coordinator.runtime_resources_by_path
	coordinator.request_boss_runtime_scene_loads()
	_expect(
		coordinator.runtime_scene_loads_requested
		and is_same(
			coordinator.runtime_resources_by_path,
			cache_before_second_request
		),
		"重复 threaded request 必须立即返回且不得替换 cache 容器。"
	)

	game.linglan_boss_enabled = true
	coordinator.configure_boss_flow_enabled(true)
	coordinator.replace_linglan_enrage_sniper_config(null)
	await coordinator.prewarm_boss_runtime_resources()
	for resource_path in EXPECTED_BOSS_RUNTIME_PATHS:
		_expect(
			coordinator.runtime_resources_by_path.get(resource_path) != null,
			"Boss prewarm 必须按原缓存键保留资源：%s。" % resource_path
		)
	_expect(
		coordinator.load_threaded_or_direct(cached_sentinel_path)
		== cached_sentinel,
		"协调器 resolver 必须优先返回同路径 retained cache。"
	)
	var enrage_config := coordinator.get_linglan_enrage_sniper_config()
	_expect(
		enrage_config != null
		and enrage_config.resource_path
		== StandardGame.LINGLAN_ENRAGE_SNIPER_CONFIG_PATH
		and coordinator.get_linglan_enrage_sniper_config() == enrage_config,
		"enrage config 必须保持单例懒缓存与原资源路径。"
	)
	_expect(
		coordinator.load_threaded_or_direct("") == null,
		"空路径 resolver 必须保持返回 null。"
	)
	coordinator.replace_runtime_scene_loads_requested(false)
	coordinator.configure_boss_flow_enabled(true)
	await coordinator.request_boss_runtime_scene_loads_deferred()
	_expect(
		not coordinator.runtime_scene_loads_requested,
		"headless deferred 请求必须保持 no-op。"
	)

	game.queue_free()
	await process_frame
	await physics_frame


func _test_no_boss_flow_preserves_legacy_request_semantics() -> void:
	var pool := SessionObjectPool.new()
	var boss := RuntimePathProbeBoss.new()
	var coordinator := StandardPrewarmerCoordinator.new()
	test_root.add_child(pool)
	test_root.add_child(boss)
	test_root.add_child(coordinator)
	coordinator.bind_dependencies(pool, boss, true)
	var expected_paths: Array[String] = [
		StandardPrewarmerCoordinator.LINGLAN_ENRAGE_SNIPER_CONFIG_PATH,
	]
	_expect(
		coordinator.get_boss_runtime_resource_paths() == expected_paths,
		"无 Boss flow 但 export=true 时必须保持旧语义：路径仍追加 enrage sniper。"
	)
	coordinator.request_boss_runtime_scene_loads()
	_expect(
		coordinator.runtime_scene_loads_requested
		and coordinator.runtime_resources_by_path.is_empty(),
		"无 Boss flow 但 export=true 时首次 request 仍须置 flag，且 request 本身不填 cache。"
	)
	var sniper_path := expected_paths[0]
	var status := ResourceLoader.load_threaded_get_status(sniper_path)
	while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await process_frame
		status = ResourceLoader.load_threaded_get_status(sniper_path)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		var requested_resource := ResourceLoader.load_threaded_get(sniper_path)
		_expect(requested_resource != null, "无 Boss flow 的 sniper threaded request 必须可回收。")
		requested_resource = null
	coordinator.queue_free()
	boss.queue_free()
	pool.queue_free()
	await process_frame
	await physics_frame


func _test_malformed_scene_initialization_boundary() -> void:
	var malformed := MALFORMED_STANDARD_GAME_SCENE.instantiate() as StandardGame
	_expect(malformed != null, "malformed StandardGame probe 必须可实例化。")
	if malformed == null:
		return
	malformed.auto_start_waves = false
	var prewarmer := malformed.get_node_or_null("PrewarmerCoordinator")
	_expect(prewarmer != null, "malformed probe 删除前必须存在静态 Prewarmer。")
	if prewarmer != null:
		malformed.remove_child(prewarmer)
		prewarmer.free()
	test_root.add_child(malformed)
	await process_frame
	await physics_frame
	_expect(
		bool(malformed.get("validation_reached")),
		"缺失 Prewarmer 时初始化必须干净进入场景验证，而不是提前退出或崩溃。"
	)
	_expect(
		malformed.is_runtime_preparation_failed()
		and malformed.runtime_preparation_failure_reason
		== "波次模式场景内容校验失败。",
		"malformed 场景必须立即发布精确 FAILED，不能静默等待全局超时。"
	)
	_expect(
		malformed.music_coordinator.is_bound()
		and malformed.pickup_registry.is_bound()
		and malformed.player_roster_coordinator.is_bound()
		and malformed.merchant_coordinator.is_bound()
		and malformed.campaign_wave_coordinator.wave_hud == malformed.wave_hud,
		"缺失 Prewarmer 不得跳过 Music/Pickup/Player/Merchant/Campaign 的既有绑定。"
	)
	_expect(
		not malformed.boss_coordinator.is_bound(),
		"缺失 Prewarmer 时 Boss 不得获得动态 fallback resolver。"
	)
	malformed.queue_free()
	await process_frame
	await physics_frame


func _test_leave_tree_abort() -> void:
	var coordinator := StandardPrewarmerCoordinator.new()
	test_root.add_child(coordinator)
	_expect(
		not coordinator._should_abort_prewarm_after_frame(),
		"Prewarmer 在树内时不得命中离树中止 guard。"
	)
	test_root.remove_child(coordinator)
	_expect(
		coordinator._should_abort_prewarm_after_frame(),
		"Prewarmer 离树后生产 guard 必须立即判定中止；源码门禁同时锁定该 guard 位于 cache 写入前。"
	)
	coordinator.free()
	await process_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
