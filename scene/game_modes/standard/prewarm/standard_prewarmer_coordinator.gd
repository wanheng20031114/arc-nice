extends Node
class_name StandardPrewarmerCoordinator

# 普通模式专属预热边界：共享波次实体池仍由 WaveCombatRuntimeBase 注册。
const TANGO_LASER_BULLET_POOL_SCENE := preload(
	"res://scene/player/tango/tango_laser_bullet.tscn"
)
const LINGLAN_SKILL1_BULLET_POOL_SCENE := preload(
	"res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn"
)
const LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE := preload(
	"res://scene/boss/linglan/linglan_sakura_hit_effect.tscn"
)
const LINGLAN_ENRAGE_SNIPER_CONFIG_PATH := (
	"res://resources/config/enemies/capoo_sniper.tres"
)
const RUNTIME_RESOURCE_WAIT_TIMEOUT_MSEC := 10_000

var runtime_scene_loads_requested: bool = false
var linglan_enrage_sniper_config: EnemyConfig = null
var runtime_resources_by_path: Dictionary[String, Resource] = {}
var runtime_preparation_failure_reason := ""

var _session_object_pool: SessionObjectPool = null
var _boss_coordinator: StandardBossCoordinator = null
var _boss_flow_enabled: bool = true
var _bound := false


func bind_dependencies(
	object_pool: SessionObjectPool,
	boss: StandardBossCoordinator,
	boss_flow_enabled: bool
) -> void:
	_session_object_pool = object_pool
	_boss_coordinator = boss
	_boss_flow_enabled = boss_flow_enabled
	_bound = _session_object_pool != null and _boss_coordinator != null


func is_bound() -> bool:
	return _bound


func configure_boss_flow_enabled(enabled: bool) -> void:
	_boss_flow_enabled = enabled


func replace_runtime_scene_loads_requested(requested: bool) -> void:
	runtime_scene_loads_requested = requested


func replace_linglan_enrage_sniper_config(config: EnemyConfig) -> void:
	linglan_enrage_sniper_config = config


func replace_runtime_resources_by_path(
	resources_by_path: Dictionary[String, Resource]
) -> void:
	runtime_resources_by_path = resources_by_path


func register_mode_object_pools() -> void:
	if _session_object_pool == null:
		push_error("StandardPrewarmerCoordinator: 对象池依赖尚未绑定。")
		return
	_session_object_pool.register_scene(TANGO_LASER_BULLET_POOL_SCENE, 64, 768)
	_session_object_pool.register_scene(LINGLAN_SKILL1_BULLET_POOL_SCENE, 64, 768)
	_session_object_pool.register_scene(LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE, 16, 96)


func schedule_boss_runtime_scene_loads() -> void:
	call_deferred("request_boss_runtime_scene_loads_deferred")


func request_boss_runtime_scene_loads() -> bool:
	if runtime_scene_loads_requested:
		return runtime_preparation_failure_reason.is_empty()
	if not _boss_flow_enabled:
		return true
	runtime_scene_loads_requested = true
	for resource_path in get_boss_runtime_resource_paths():
		var status := ResourceLoader.load_threaded_get_status(resource_path)
		if status in [
			ResourceLoader.THREAD_LOAD_IN_PROGRESS,
			ResourceLoader.THREAD_LOAD_LOADED,
		]:
			continue
		var error := ResourceLoader.load_threaded_request(
			resource_path,
			"",
			true,
			ResourceLoader.CACHE_MODE_REUSE
		)
		if error != OK:
			return _fail_runtime_preparation(
				"普通模式无法开始线程加载资源 %s：%s。"
				% [resource_path, error_string(error)]
			)
	return true


func get_boss_runtime_resource_paths() -> Array[String]:
	var paths := _boss_coordinator.get_runtime_resource_paths()
	paths.append(LINGLAN_ENRAGE_SNIPER_CONFIG_PATH)
	return paths


func prewarm_boss_runtime_resources() -> bool:
	if not _boss_flow_enabled:
		return true
	if not request_boss_runtime_scene_loads():
		return false
	for resource_path in get_boss_runtime_resource_paths():
		if runtime_resources_by_path.has(resource_path):
			continue
		var status := ResourceLoader.load_threaded_get_status(resource_path)
		var deadline_msec := Time.get_ticks_msec() + RUNTIME_RESOURCE_WAIT_TIMEOUT_MSEC
		while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await get_tree().process_frame
			if _should_abort_prewarm_after_frame():
				return false
			if Time.get_ticks_msec() >= deadline_msec:
				return _fail_runtime_preparation(
					"普通模式线程加载资源超时：%s。" % resource_path
				)
			status = ResourceLoader.load_threaded_get_status(resource_path)
		if status != ResourceLoader.THREAD_LOAD_LOADED:
			return _fail_runtime_preparation(
				"普通模式线程加载资源失败：%s（状态 %d）。"
				% [resource_path, status]
			)
		var runtime_resource := ResourceLoader.load_threaded_get(resource_path)
		if runtime_resource == null:
			return _fail_runtime_preparation(
				"普通模式线程资源已完成但无法取得实例：%s。" % resource_path
			)
		runtime_resources_by_path[resource_path] = runtime_resource
	return true


func get_linglan_enrage_sniper_config() -> EnemyConfig:
	if linglan_enrage_sniper_config == null:
		linglan_enrage_sniper_config = (
			load_threaded_or_direct(LINGLAN_ENRAGE_SNIPER_CONFIG_PATH) as EnemyConfig
		)
	return linglan_enrage_sniper_config


func load_threaded_or_direct(path: String) -> Resource:
	if path.is_empty():
		return null
	var retained_resource := runtime_resources_by_path.get(path) as Resource
	if retained_resource != null:
		return retained_resource
	var status := ResourceLoader.load_threaded_get_status(path)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		return ResourceLoader.load_threaded_get(path)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		# 正式准备屏障会在有界协程中收取结果；游戏热路径不得重新无期限阻塞。
		return null
	return load(path)


func _should_abort_prewarm_after_frame() -> bool:
	return not is_inside_tree()


func request_boss_runtime_scene_loads_deferred() -> bool:
	if DisplayServer.get_name() == "headless":
		return true
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree():
		return false
	return request_boss_runtime_scene_loads()


func _fail_runtime_preparation(reason: String) -> bool:
	if runtime_preparation_failure_reason.is_empty():
		runtime_preparation_failure_reason = reason
		push_error("StandardPrewarmerCoordinator: %s" % reason)
	# 协调器只返回精确原因；Provider 的 generation token 由外层模式根独占。
	return false
